#!/bin/sh
# cloudflared.sh - blue-green reprovision of the EXTERNAL cloudflared container.
# It is NOT in docker-compose.yml; we manage it by name. The candidate is a faithful
# CLONE of the running container (all env, ports, binds, networks + static IP, restart
# policy and command) with only the image bumped - so the tunnel token AND any other
# settings (e.g. --metrics) are preserved. Cloudflare allows multiple simultaneous
# connectors per tunnel, so the candidate runs alongside the old one and the live
# tunnel never drops during verification.
# Requires common.sh + registry.sh sourced first (DOCKER_BIN, log_*).

CF_CANDIDATE_SUFFIX="-candidate"
CF_RENAME_RETRIES=5
# Set to 1 when a candidate has been promoted-but-not-renamed and must NOT be reaped
# by the EXIT trap (it is the only live connector at that point).
CF_KEEP_CANDIDATE=0

# Remove a leftover candidate from a previously crashed run (also called by the trap).
# Never removes a candidate we deliberately kept after a rename failure.
cloudflared_cleanup_candidate() {
  [ "${CF_KEEP_CANDIDATE:-0}" = 1 ] && return 0
  _cand="${CF_CONTAINER_NAME}${CF_CANDIDATE_SUFFIX}"
  if "$DOCKER_BIN" inspect "$_cand" >/dev/null 2>&1; then
    log_warn "removing stray cloudflared candidate: $_cand"
    "$DOCKER_BIN" rm -f "$_cand" >/dev/null 2>&1 || true
  fi
}

# Wait until the connector reports connected. Prefers native HEALTHCHECK, else the
# "Registered tunnel connection" log marker cloudflared emits per edge connection.
cloudflared_wait_connected() {
  _c="$1"; _timeout="$2"; _waited=0
  while [ "$_waited" -lt "$_timeout" ]; do
    _run="$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$_c" 2>/dev/null)"
    [ "$_run" = "true" ] || { log_error "cloudflared $_c exited early"; return 1; }
    _hs="$("$DOCKER_BIN" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$_c" 2>/dev/null)"
    [ "$_hs" = "healthy" ] && return 0
    if "$DOCKER_BIN" logs "$_c" 2>&1 | grep -Eqi 'Registered tunnel connection|Connection [0-9a-f-]+ registered|registered tunnel connection'; then
      return 0
    fi
    sleep 3; _waited=$((_waited+3))
  done
  return 1
}

# Promote candidate -> canonical name, retrying rename (daemon hiccups / name-reclaim
# races). On persistent failure, KEEP the candidate (it is the only live connector) and
# tell the trap to leave it alone, so the operator can rename it manually.
_cloudflared_promote() {
  _cand="$1"; _blue="$2"; _n=0
  while [ "$_n" -lt "$CF_RENAME_RETRIES" ]; do
    if "$DOCKER_BIN" rename "$_cand" "$_blue" >>"$LOG_FILE" 2>&1; then
      log_info "cloudflared: promoted candidate -> $_blue (token preserved)"
      return 0
    fi
    _n=$((_n+1)); sleep 2
  done
  CF_KEEP_CANDIDATE=1
  log_error "cloudflared rename failed ${CF_RENAME_RETRIES}x; candidate kept running as '$_cand' (only connector). Fix: docker rename $_cand $_blue"
  return 1
}

cloudflared_blue_green() {
  _blue="$CF_CONTAINER_NAME"
  _cand="${CF_CONTAINER_NAME}${CF_CANDIDATE_SUFFIX}"
  [ -n "${CF_IMAGE:-}" ] || { log_error "CF_IMAGE unset - cannot update cloudflared"; return 1; }
  cloudflared_cleanup_candidate

  # No existing container -> first-time provision (needs an explicit token).
  if ! "$DOCKER_BIN" inspect "$_blue" >/dev/null 2>&1; then
    log_warn "no existing '$_blue' container - provisioning fresh from CF_IMAGE"
    [ -n "${CF_TUNNEL_TOKEN:-}" ] || { log_error "CF_TUNNEL_TOKEN required (no container to clone the key from)"; return 1; }
    "$DOCKER_BIN" run -d --name "$_blue" --restart unless-stopped \
      -e TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" "$CF_IMAGE" tunnel --no-autoupdate run >>"$LOG_FILE" 2>&1 \
      || { log_error "failed to start fresh cloudflared"; return 1; }
    cloudflared_wait_connected "$_blue" "$CF_HEALTH_TIMEOUT" \
      || { log_error "fresh cloudflared never connected"; return 1; }
    log_info "cloudflared: provisioned fresh and connected"
    return 0
  fi

  # --- Clone the run spec of the running container (everything but the image) ---
  _restart="$("$DOCKER_BIN" inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$_blue" 2>/dev/null)"
  [ -n "$_restart" ] && [ "$_restart" != "no" ] || _restart="unless-stopped"
  # Original command (args after the image entrypoint); default to our standard run.
  _cmd="$("$DOCKER_BIN" inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' "$_blue" 2>/dev/null)"
  [ -n "$_cmd" ] || _cmd="tunnel --no-autoupdate run"
  # Networks: primary + its static IP (replay --ip only if statically assigned).
  _nets="$("$DOCKER_BIN" inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$_blue" 2>/dev/null)"
  _primary_net="$(printf '%s\n' "$_nets" | head -n1)"
  _ip=""
  if [ -n "$_primary_net" ]; then
    _ip="$("$DOCKER_BIN" inspect -f "{{with (index .NetworkSettings.Networks \"$_primary_net\")}}{{if .IPAMConfig}}{{.IPAMConfig.IPv4Address}}{{end}}{{end}}" "$_blue" 2>/dev/null)"
  fi
  # All env vars -> a temp env-file (survives spaces; carries TUNNEL_TOKEN + TUNNEL_METRICS etc.).
  _envf="$(mktemp 2>/dev/null || echo /tmp/cf-env.$$)"
  "$DOCKER_BIN" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$_blue" 2>/dev/null > "$_envf"

  # Token sanity (non-fatal): must come from env-file, the command, or the override.
  if [ -z "${CF_TUNNEL_TOKEN:-}" ] && ! grep -q '^TUNNEL_TOKEN=' "$_envf" 2>/dev/null \
       && ! printf '%s' "$_cmd" | grep -q -- '--token'; then
    log_warn "no TUNNEL_TOKEN found on '$_blue' (env/cmd) and no override - candidate may fail to connect"
  fi

  # Build the candidate run argv.
  set -- --name "$_cand" --env-file "$_envf" --restart "$_restart"
  [ -n "$_primary_net" ] && set -- "$@" --network "$_primary_net"
  [ -n "$_ip" ] && set -- "$@" --ip "$_ip"
  # Published ports.
  _ports="$("$DOCKER_BIN" inspect -f '{{range $p,$c := .HostConfig.PortBindings}}{{range $c}}{{println (printf "%s|%s|%s" .HostIp .HostPort $p)}}{{end}}{{end}}' "$_blue" 2>/dev/null)"
  while IFS='|' read -r _hip _hport _cport; do
    [ -n "$_cport" ] || continue
    if [ -n "$_hip" ]; then set -- "$@" -p "$_hip:$_hport:$_cport"; else set -- "$@" -p "$_hport:$_cport"; fi
  done <<EOF
$_ports
EOF
  # Bind mounts.
  _binds="$("$DOCKER_BIN" inspect -f '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$_blue" 2>/dev/null)"
  while IFS= read -r _b; do
    [ -n "$_b" ] && set -- "$@" -v "$_b"
  done <<EOF
$_binds
EOF
  # Override token wins (appended after --env-file).
  [ -n "${CF_TUNNEL_TOKEN:-}" ] && set -- "$@" -e TUNNEL_TOKEN="$CF_TUNNEL_TOKEN"
  set -- "$@" "$CF_IMAGE"

  log_info "cloudflared: launching candidate (net=${_primary_net:-default} ip=${_ip:-auto} restart=$_restart)"
  # shellcheck disable=SC2086  # $_cmd is intentionally word-split into command args
  if ! "$DOCKER_BIN" run -d "$@" $_cmd >>"$LOG_FILE" 2>&1; then
    log_error "failed to start cloudflared candidate"
    rm -f "$_envf" 2>/dev/null || true
    "$DOCKER_BIN" rm -f "$_cand" >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "$_envf" 2>/dev/null || true

  # Re-attach any additional networks beyond the primary.
  printf '%s\n' "$_nets" | tail -n +2 | while IFS= read -r _extra; do
    [ -n "$_extra" ] && "$DOCKER_BIN" network connect "$_extra" "$_cand" >>"$LOG_FILE" 2>&1 || true
  done

  # Prove the candidate is connected BEFORE touching blue.
  if ! cloudflared_wait_connected "$_cand" "$CF_HEALTH_TIMEOUT"; then
    log_error "candidate never connected within ${CF_HEALTH_TIMEOUT}s - ROLLBACK (blue untouched)"
    "$DOCKER_BIN" logs --tail 50 "$_cand" >>"$LOG_FILE" 2>&1 || true
    "$DOCKER_BIN" rm -f "$_cand" >/dev/null 2>&1 || true
    return 1
  fi

  # Cutover: stop+remove blue, then promote candidate (with rename retries).
  "$DOCKER_BIN" stop "$_blue" >>"$LOG_FILE" 2>&1 || true
  "$DOCKER_BIN" rm "$_blue"   >>"$LOG_FILE" 2>&1 || true
  _cloudflared_promote "$_cand" "$_blue"
}
