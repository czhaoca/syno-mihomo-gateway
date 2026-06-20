#!/bin/sh
# cloudflared.sh - staged updates for the EXTERNAL cloudflared container.
#
# A temporary connector is first started without the canonical container's host
# ports or static IPs.  Once it is connected, the canonical container is rebuilt
# with the preserved run specification and the new image.  The temporary
# connector stays online until the canonical replacement is verified.  If that
# final step fails, the old image is recreated from the same saved specification.
#
# Requires common.sh + registry.sh (DOCKER_BIN, log_*). POSIX /bin/sh.
# shellcheck disable=SC2016 # Docker Go templates are intentionally single quoted.

CF_CANDIDATE_SUFFIX="${CF_CANDIDATE_SUFFIX:--candidate}"
CF_KEEP_CANDIDATE=0
CF_WORKDIR=""

_cloudflared_running() {
  [ "$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]
}

# cloudflared_token_present [NAME] - 0 if an existing cloudflared container (NAME,
# default CF_CONTAINER_NAME) already carries a TUNNEL_TOKEN the blue-green updater
# can reuse, so the installer can offer "Enter to reuse" instead of demanding one.
# Reads only the token's PRESENCE; the value is never copied out. Resolves docker
# via _net_docker so it works in the wizard before DOCKER_BIN is set.
cloudflared_token_present() {
  _ctp_name="${1:-${CF_CONTAINER_NAME:-cloudflared}}"
  _ctp_d="$(_net_docker)"
  "$_ctp_d" inspect "$_ctp_name" >/dev/null 2>&1 || return 1
  "$_ctp_d" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$_ctp_name" 2>/dev/null \
    | grep -q '^TUNNEL_TOKEN=.'
}

cloudflared_cleanup_workdir() {
  [ -n "${CF_WORKDIR:-}" ] || return 0
  rm -rf "$CF_WORKDIR" 2>/dev/null || true
  CF_WORKDIR=""
}

# A candidate can be the only live tunnel after an interrupted recovery. Never
# reap it merely because its name is temporary.
cloudflared_cleanup_candidate() {
  [ "${CF_KEEP_CANDIDATE:-0}" = 1 ] && return 0
  _ccc_cand="${CF_CONTAINER_NAME}${CF_CANDIDATE_SUFFIX}"
  "$DOCKER_BIN" inspect "$_ccc_cand" >/dev/null 2>&1 || return 0
  if _cloudflared_running "$CF_CONTAINER_NAME"; then
    log_warn "removing stale cloudflared candidate while the canonical connector is running: $_ccc_cand"
    "$DOCKER_BIN" rm -f "$_ccc_cand" >/dev/null 2>&1 || return 1
    return 0
  fi
  if _cloudflared_running "$_ccc_cand"; then
    CF_KEEP_CANDIDATE=1
    log_error "candidate '$_ccc_cand' may be the only live connector; leaving it untouched"
    log_error "restore '$CF_CONTAINER_NAME', verify it, then remove or rename the candidate manually"
    return 1
  fi
  log_warn "removing stopped stale cloudflared candidate: $_ccc_cand"
  "$DOCKER_BIN" rm -f "$_ccc_cand" >/dev/null 2>&1 || return 1
}

cloudflared_wait_connected() {
  _cwc_name="$1"; _cwc_timeout="$2"; _cwc_waited=0
  while [ "$_cwc_waited" -lt "$_cwc_timeout" ]; do
    _cloudflared_running "$_cwc_name" || {
      log_error "cloudflared $_cwc_name exited early"
      return 1
    }
    _cwc_health="$("$DOCKER_BIN" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$_cwc_name" 2>/dev/null)"
    [ "$_cwc_health" = healthy ] && return 0
    if "$DOCKER_BIN" logs "$_cwc_name" 2>&1 \
      | grep -Eqi 'Registered tunnel connection|Connection [0-9a-f-]+ registered|registered tunnel connection'; then
      return 0
    fi
    sleep 3
    _cwc_waited=$((_cwc_waited + 3))
  done
  return 1
}

_cloudflared_make_workdir() {
  cloudflared_cleanup_workdir
  CF_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/smg-cloudflared.XXXXXX" 2>/dev/null)" || {
    log_error "could not create a private cloudflared state directory"
    return 1
  }
  chmod 700 "$CF_WORKDIR" 2>/dev/null || {
    cloudflared_cleanup_workdir
    return 1
  }
  return 0
}

# Keep tunnel credentials out of the docker client argv/process list. The
# private env file is removed by cloudflared_cleanup_workdir after each attempt.
_cloudflared_set_token_override() {
  [ -n "${CF_TUNNEL_TOKEN:-}" ] || return 0
  case "$CF_TUNNEL_TOKEN" in
    *'
'*) log_error "CF_TUNNEL_TOKEN must be a single line"; return 1 ;;
  esac
  sed '/^TUNNEL_TOKEN=/d' "$CF_WORKDIR/env" >"$CF_WORKDIR/env.next" || return 1
  printf 'TUNNEL_TOKEN=%s\n' "$CF_TUNNEL_TOKEN" >>"$CF_WORKDIR/env.next" || return 1
  chmod 600 "$CF_WORKDIR/env.next" 2>/dev/null || return 1
  mv "$CF_WORKDIR/env.next" "$CF_WORKDIR/env" || return 1
}

# Capture the subset of Docker run configuration this updater can faithfully
# replay. Values with spaces remain one line/argument and are never eval'd.
_cloudflared_capture_spec() {
  _ccs_name="$1"
  _cloudflared_make_workdir || return 1

  _ccs_container_network="$("$DOCKER_BIN" inspect -f '{{.HostConfig.NetworkMode}}' "$_ccs_name" 2>/dev/null)"
  case "$_ccs_container_network" in container:*)
    log_error "cloudflared uses container network mode, which cannot be replayed safely"
    cloudflared_cleanup_workdir; return 1 ;;
  esac
  if [ "$("$DOCKER_BIN" inspect -f '{{.HostConfig.AutoRemove}}' "$_ccs_name" 2>/dev/null)" = true ]; then
    log_error "cloudflared was created with --rm; automatic replacement is unsafe"
    cloudflared_cleanup_workdir; return 1
  fi

  "$DOCKER_BIN" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/env" 2>/dev/null || return 1
  chmod 600 "$CF_WORKDIR/env" 2>/dev/null || return 1
  _cloudflared_set_token_override || { cloudflared_cleanup_workdir; return 1; }
  "$DOCKER_BIN" inspect -f '{{range .Config.Cmd}}{{println .}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/cmd" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range .Config.Entrypoint}}{{println .}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/entrypoint" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/binds" 2>/dev/null || return 1
  awk -F: 'NF >= 2 { print $2 }' "$CF_WORKDIR/binds" >"$CF_WORKDIR/bind-destinations" || return 1
  "$DOCKER_BIN" inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{printf "%s|%s|%t\n" .Name .Destination .RW}}{{end}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/volumes" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range $p,$c := .HostConfig.PortBindings}}{{range $c}}{{printf "%s|%s|%s\n" .HostIp .HostPort $p}}{{end}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/ports" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s|%s\n" $k $v.IPAddress}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/networks.raw" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range .HostConfig.Dns}}{{println .}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/dns" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/extra-hosts" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/cap-add" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range .HostConfig.CapDrop}}{{println .}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/cap-drop" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range .HostConfig.SecurityOpt}}{{println .}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/security-opt" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range .HostConfig.Devices}}{{printf "%s:%s:%s\n" .PathOnHost .PathInContainer .CgroupPermissions}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/devices" 2>/dev/null || return 1
  "$DOCKER_BIN" inspect -f '{{range $p,$o := .HostConfig.Tmpfs}}{{printf "%s|%s\n" $p $o}}{{end}}' "$_ccs_name" >"$CF_WORKDIR/tmpfs" 2>/dev/null || return 1

  CF_SPEC_RESTART="$("$DOCKER_BIN" inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$_ccs_name" 2>/dev/null)"
  CF_SPEC_RESTART_MAX="$("$DOCKER_BIN" inspect -f '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "$_ccs_name" 2>/dev/null)"
  CF_SPEC_USER="$("$DOCKER_BIN" inspect -f '{{.Config.User}}' "$_ccs_name" 2>/dev/null)"
  CF_SPEC_WORKDIR="$("$DOCKER_BIN" inspect -f '{{.Config.WorkingDir}}' "$_ccs_name" 2>/dev/null)"
  CF_SPEC_READONLY="$("$DOCKER_BIN" inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$_ccs_name" 2>/dev/null)"
  CF_SPEC_PRIVILEGED="$("$DOCKER_BIN" inspect -f '{{.HostConfig.Privileged}}' "$_ccs_name" 2>/dev/null)"
  CF_SPEC_NETWORK_MODE="$_ccs_container_network"
  CF_OLD_IMAGE_ID="$("$DOCKER_BIN" inspect -f '{{.Image}}' "$_ccs_name" 2>/dev/null)"
  [ -n "$CF_OLD_IMAGE_ID" ] || {
    log_error "could not capture cloudflared's current image ID"
    cloudflared_cleanup_workdir; return 1
  }

  # Replay the original primary network first, then all additional networks.
  awk -F'|' -v primary="$CF_SPEC_NETWORK_MODE" '
    $1 == primary { print > primary_file; next }
    { print > extra_file }
  ' primary_file="$CF_WORKDIR/networks.primary" extra_file="$CF_WORKDIR/networks.extra" \
    "$CF_WORKDIR/networks.raw"
  [ -s "$CF_WORKDIR/networks.primary" ] || {
    sed -n '1p' "$CF_WORKDIR/networks.raw" >"$CF_WORKDIR/networks.primary"
    sed '1d' "$CF_WORKDIR/networks.raw" >"$CF_WORKDIR/networks.extra"
  }
  return 0
}

_cloudflared_run_saved() {
  _crs_mode="$1"; _crs_name="$2"; _crs_image="$3"
  if [ "$_crs_mode" = candidate ]; then
    set -- --name "$_crs_name" --env-file "$CF_WORKDIR/env" --restart no
  else
    _crs_restart="${CF_SPEC_RESTART:-unless-stopped}"
    [ "$_crs_restart" != no ] || _crs_restart=no
    if [ "$_crs_restart" = on-failure ] && [ "${CF_SPEC_RESTART_MAX:-0}" -gt 0 ] 2>/dev/null; then
      _crs_restart="on-failure:${CF_SPEC_RESTART_MAX}"
    fi
    set -- --name "$_crs_name" --env-file "$CF_WORKDIR/env" --restart "$_crs_restart"
  fi
  [ -n "${CF_SPEC_USER:-}" ] && set -- "$@" --user "$CF_SPEC_USER"
  [ -n "${CF_SPEC_WORKDIR:-}" ] && set -- "$@" --workdir "$CF_SPEC_WORKDIR"
  [ "${CF_SPEC_READONLY:-false}" = true ] && set -- "$@" --read-only
  [ "${CF_SPEC_PRIVILEGED:-false}" = true ] && set -- "$@" --privileged

  _crs_primary="$(head -n1 "$CF_WORKDIR/networks.primary" 2>/dev/null)"
  _crs_primary_name="${_crs_primary%%|*}"
  _crs_primary_ip="${_crs_primary#*|}"
  [ "$_crs_primary_ip" != "$_crs_primary" ] || _crs_primary_ip=""
  [ -n "$_crs_primary_name" ] && set -- "$@" --network "$_crs_primary_name"
  if [ "$_crs_mode" = canonical ] && [ -z "$_crs_primary_name" ]; then
    case "${CF_SPEC_NETWORK_MODE:-}" in
      host|none|bridge) set -- "$@" --network "$CF_SPEC_NETWORK_MODE" ;;
    esac
  fi
  if [ "$_crs_mode" = canonical ] && [ -n "$_crs_primary_ip" ]; then
    set -- "$@" --ip "$_crs_primary_ip"
  fi

  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" -v "$_crs_line"; done <"$CF_WORKDIR/binds"
  while IFS='|' read -r _crs_volume _crs_dest _crs_rw || [ -n "$_crs_volume$_crs_dest" ]; do
    [ -n "$_crs_volume" ] && [ -n "$_crs_dest" ] || continue
    grep -Fqx "$_crs_dest" "$CF_WORKDIR/bind-destinations" 2>/dev/null && continue
    if [ "$_crs_rw" = false ]; then set -- "$@" -v "$_crs_volume:$_crs_dest:ro"; else set -- "$@" -v "$_crs_volume:$_crs_dest"; fi
  done <"$CF_WORKDIR/volumes"
  if [ "$_crs_mode" = canonical ]; then
    while IFS='|' read -r _crs_hip _crs_hport _crs_cport || [ -n "$_crs_cport" ]; do
      [ -n "$_crs_cport" ] || continue
      if [ -n "$_crs_hip" ]; then set -- "$@" -p "$_crs_hip:$_crs_hport:$_crs_cport"; else set -- "$@" -p "$_crs_hport:$_crs_cport"; fi
    done <"$CF_WORKDIR/ports"
  fi
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --dns "$_crs_line"; done <"$CF_WORKDIR/dns"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --add-host "$_crs_line"; done <"$CF_WORKDIR/extra-hosts"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --cap-add "$_crs_line"; done <"$CF_WORKDIR/cap-add"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --cap-drop "$_crs_line"; done <"$CF_WORKDIR/cap-drop"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --security-opt "$_crs_line"; done <"$CF_WORKDIR/security-opt"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --device "$_crs_line"; done <"$CF_WORKDIR/devices"
  while IFS='|' read -r _crs_path _crs_opts || [ -n "$_crs_path" ]; do
    [ -n "$_crs_path" ] || continue
    if [ -n "$_crs_opts" ]; then set -- "$@" --tmpfs "$_crs_path:$_crs_opts"; else set -- "$@" --tmpfs "$_crs_path"; fi
  done <"$CF_WORKDIR/tmpfs"
  _crs_entrypoint="$(sed -n '1p' "$CF_WORKDIR/entrypoint")"
  [ -n "$_crs_entrypoint" ] && set -- "$@" --entrypoint "$_crs_entrypoint"
  set -- "$@" "$_crs_image"
  # Docker --entrypoint accepts only the executable. Preserve any additional
  # entrypoint argv by placing it before the saved Config.Cmd arguments.
  sed '1d' "$CF_WORKDIR/entrypoint" >"$CF_WORKDIR/entrypoint.rest"
  while IFS= read -r _crs_arg || [ -n "$_crs_arg" ]; do set -- "$@" "$_crs_arg"; done <"$CF_WORKDIR/entrypoint.rest"
  while IFS= read -r _crs_arg || [ -n "$_crs_arg" ]; do set -- "$@" "$_crs_arg"; done <"$CF_WORKDIR/cmd"

  if ! "$DOCKER_BIN" run -d "$@" >>"$LOG_FILE" 2>&1; then return 1; fi

  # The first line was used at docker run time. Attach remaining networks with
  # dynamic addresses for the candidate and their saved addresses for canonical.
  while IFS='|' read -r _crs_net _crs_ip || [ -n "$_crs_net" ]; do
    [ -n "$_crs_net" ] || continue
    if [ "$_crs_mode" = canonical ] && [ -n "$_crs_ip" ]; then
      "$DOCKER_BIN" network connect --ip "$_crs_ip" "$_crs_net" "$_crs_name" >>"$LOG_FILE" 2>&1 || return 1
    else
      "$DOCKER_BIN" network connect "$_crs_net" "$_crs_name" >>"$LOG_FILE" 2>&1 || return 1
    fi
  done <"$CF_WORKDIR/networks.extra"
  return 0
}

_cloudflared_restore_old() {
  _cro_blue="$1"; _cro_cand="$2"
  "$DOCKER_BIN" rm -f "$_cro_blue" >/dev/null 2>&1 || true
  log_warn "cloudflared: restoring previous image $CF_OLD_IMAGE_ID"
  if _cloudflared_run_saved canonical "$_cro_blue" "$CF_OLD_IMAGE_ID" \
     && cloudflared_wait_connected "$_cro_blue" "$CF_HEALTH_TIMEOUT"; then
    "$DOCKER_BIN" rm -f "$_cro_cand" >/dev/null 2>&1 || true
    log_warn "cloudflared: previous image restored and connected"
    return 0
  fi
  CF_KEEP_CANDIDATE=1
  log_error "cloudflared rollback failed; candidate kept running as '$_cro_cand'"
  return 1
}

cloudflared_blue_green() {
  _cbg_blue="$CF_CONTAINER_NAME"
  _cbg_cand="${CF_CONTAINER_NAME}${CF_CANDIDATE_SUFFIX}"
  CF_KEEP_CANDIDATE=0
  [ -n "${CF_IMAGE:-}" ] || { log_error "CF_IMAGE unset - cannot update cloudflared"; return 1; }
  cloudflared_cleanup_candidate || return 1

  # First provision has no run specification to preserve.
  if ! "$DOCKER_BIN" inspect "$_cbg_blue" >/dev/null 2>&1; then
    log_warn "no existing '$_cbg_blue' container - provisioning fresh from CF_IMAGE"
    [ -n "${CF_TUNNEL_TOKEN:-}" ] || { log_error "CF_TUNNEL_TOKEN required for first provisioning"; return 1; }
    _cloudflared_make_workdir || return 1
    : >"$CF_WORKDIR/env"
    chmod 600 "$CF_WORKDIR/env" 2>/dev/null || { cloudflared_cleanup_workdir; return 1; }
    _cloudflared_set_token_override || { cloudflared_cleanup_workdir; return 1; }
    if ! "$DOCKER_BIN" run -d --name "$_cbg_blue" --restart unless-stopped \
      --env-file "$CF_WORKDIR/env" "$CF_IMAGE" tunnel --no-autoupdate run >>"$LOG_FILE" 2>&1; then
      log_error "failed to start fresh cloudflared"
      "$DOCKER_BIN" rm -f "$_cbg_blue" >/dev/null 2>&1 || true
      cloudflared_cleanup_workdir
      return 1
    fi
    if ! cloudflared_wait_connected "$_cbg_blue" "$CF_HEALTH_TIMEOUT"; then
      log_error "fresh cloudflared never connected"
      "$DOCKER_BIN" rm -f "$_cbg_blue" >/dev/null 2>&1 || true
      cloudflared_cleanup_workdir
      return 1
    fi
    cloudflared_cleanup_workdir
    log_info "cloudflared: provisioned fresh and connected"
    return 0
  fi

  _cloudflared_capture_spec "$_cbg_blue" || return 1
  if ! _cloudflared_run_saved candidate "$_cbg_cand" "$CF_IMAGE"; then
    log_error "failed to start conflict-free cloudflared candidate; canonical connector is untouched"
    "$DOCKER_BIN" rm -f "$_cbg_cand" >/dev/null 2>&1 || true
    cloudflared_cleanup_workdir
    return 1
  fi
  if ! cloudflared_wait_connected "$_cbg_cand" "$CF_HEALTH_TIMEOUT"; then
    log_error "candidate never connected; canonical connector is untouched"
    "$DOCKER_BIN" logs --tail 50 "$_cbg_cand" >>"$LOG_FILE" 2>&1 || true
    "$DOCKER_BIN" rm -f "$_cbg_cand" >/dev/null 2>&1 || true
    cloudflared_cleanup_workdir
    return 1
  fi

  if ! "$DOCKER_BIN" stop "$_cbg_blue" >>"$LOG_FILE" 2>&1; then
    log_error "could not confirm canonical cloudflared stopped"
    if _cloudflared_running "$_cbg_blue"; then
      "$DOCKER_BIN" rm -f "$_cbg_cand" >/dev/null 2>&1 || true
    else
      "$DOCKER_BIN" start "$_cbg_blue" >>"$LOG_FILE" 2>&1 || true
      if cloudflared_wait_connected "$_cbg_blue" "$CF_HEALTH_TIMEOUT"; then
        "$DOCKER_BIN" rm -f "$_cbg_cand" >/dev/null 2>&1 || true
      else
        CF_KEEP_CANDIDATE=1
      fi
    fi
    cloudflared_cleanup_workdir
    return 1
  fi
  if ! "$DOCKER_BIN" rm "$_cbg_blue" >>"$LOG_FILE" 2>&1; then
    log_error "could not remove stopped canonical cloudflared; attempting to restart it"
    "$DOCKER_BIN" start "$_cbg_blue" >>"$LOG_FILE" 2>&1 || true
    if cloudflared_wait_connected "$_cbg_blue" "$CF_HEALTH_TIMEOUT"; then
      "$DOCKER_BIN" rm -f "$_cbg_cand" >/dev/null 2>&1 || true
    else
      CF_KEEP_CANDIDATE=1
    fi
    cloudflared_cleanup_workdir
    return 1
  fi

  if _cloudflared_run_saved canonical "$_cbg_blue" "$CF_IMAGE" \
     && cloudflared_wait_connected "$_cbg_blue" "$CF_HEALTH_TIMEOUT"; then
    "$DOCKER_BIN" rm -f "$_cbg_cand" >/dev/null 2>&1 || true
    cloudflared_cleanup_workdir
    log_info "cloudflared: canonical container updated and connected"
    return 0
  fi

  log_error "new canonical cloudflared failed; rolling back while the candidate remains connected"
  _cloudflared_restore_old "$_cbg_blue" "$_cbg_cand" || true
  cloudflared_cleanup_workdir
  # The old connector may be healthy again, but the requested update still
  # failed and must be reported as a partial failure by the orchestrator.
  return 1
}
