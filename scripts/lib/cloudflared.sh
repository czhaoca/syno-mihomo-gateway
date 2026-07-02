#!/bin/sh
# cloudflared.sh - staged updates for the EXTERNAL cloudflared container.
#
# A temporary connector is first started without the canonical container's host
# ports or static IPs.  Once it is connected, the canonical container is rebuilt
# with the preserved run specification and the new image.  The temporary
# connector stays online until the canonical replacement is verified.  If that
# final step fails, the old image is recreated from the same saved specification.
#
# Requires common.sh + registry.sh (DOCKER_BIN, log_*) and container.sh (the
# generic capture/replay engine this file specializes). POSIX /bin/sh.
# shellcheck disable=SC2016 # Docker Go templates are intentionally single quoted.

# Locate the sibling engine via whichever root the sourcing context provides:
# the ci suites set ROOT, orchestrator contexts export REPO_ROOT (common.sh),
# and a direct `. scripts/lib/cloudflared.sh` from an entry point leaves
# common.sh's LIB_DIR pointing at this directory.
if ! command -v container_capture_spec >/dev/null 2>&1; then
  if [ -f "${ROOT:-}/scripts/lib/container.sh" ]; then
    # shellcheck source=scripts/lib/container.sh
    . "$ROOT/scripts/lib/container.sh"
  elif [ -f "${REPO_ROOT:-}/scripts/lib/container.sh" ]; then
    # shellcheck source=scripts/lib/container.sh
    . "$REPO_ROOT/scripts/lib/container.sh"
  elif [ -f "${LIB_DIR:-}/container.sh" ]; then
    # shellcheck source=scripts/lib/container.sh
    . "$LIB_DIR/container.sh"
  else
    echo "cloudflared.sh: cannot locate scripts/lib/container.sh" >&2
    exit 1
  fi
fi

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
  container_cleanup_workdir
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
  container_make_workdir || return 1
  CF_WORKDIR="$CTR_WORKDIR"
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

# Capture via the generic engine, then overlay the cloudflared-specific token
# handling. CF_* names are kept as the public seam for the orchestrator/tests.
_cloudflared_capture_spec() {
  if ! container_capture_spec "$1"; then
    CF_WORKDIR=""
    return 1
  fi
  CF_WORKDIR="$CTR_WORKDIR"
  _cloudflared_set_token_override || { cloudflared_cleanup_workdir; return 1; }
  CF_OLD_IMAGE_ID="$CTR_OLD_IMAGE_ID"
  return 0
}

_cloudflared_run_saved() {
  container_run_saved "$@"
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
  # Fail-closed (DEC-4): refuse the update when the live connector carries
  # settings the replay engine cannot reproduce, instead of dropping them.
  container_parity_guard "$_cbg_blue" || { cloudflared_cleanup_workdir; return 1; }
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
