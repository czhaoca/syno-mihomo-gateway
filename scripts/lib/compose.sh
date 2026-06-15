#!/bin/sh
# compose.sh - recreate the in-compose services (mihomo, metacubexd), then a real
# health gate, with auto-rollback to the last-good image on failure.
# Requires common.sh + registry.sh sourced first (DOCKER_BIN, COMPOSE_CMD).

MIHOMO_CONTAINER="mihomo"
METACUBEXD_CONTAINER="mihomo-ui"

compose_up() {
  # COMPOSE_CMD may be two words ("docker compose"); leave unquoted on purpose.
  # shellcheck disable=SC2086
  ( cd "$REPO_ROOT" && $COMPOSE_CMD --env-file "$ENV_FILE" up -d ) >>"$LOG_FILE" 2>&1
}

# Probe the controller from INSIDE the mihomo netns (docker exec) so the macvlan
# host-isolation quirk (NAS can't reach its own macvlan IP) doesn't matter.
# Returns: 0 ok, 1 definitively failed, 2 probe unavailable (no downloader in image).
mihomo_controller_probe() {
  _url="http://127.0.0.1:${CONTROLLER_PORT}/version"
  if "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v wget >/dev/null 2>&1' 2>/dev/null; then
    if "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 5 -O /dev/null "$_url" 2>/dev/null; then return 0; else return 1; fi
  elif "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v curl >/dev/null 2>&1' 2>/dev/null; then
    if "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" curl -fsS -m 5 -o /dev/null "$_url" 2>/dev/null; then return 0; else return 1; fi
  fi
  return 2
}

# health_gate -> 0 healthy, 1 unhealthy. Checks mihomo is running, NOT crash-looping,
# and (when possible) that its controller answers. metacubexd is checked but only warned on.
health_gate() {
  _try=0
  while [ "$_try" -lt "$HEALTH_RETRIES" ]; do
    _try=$((_try+1))
    _running="$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$MIHOMO_CONTAINER" 2>/dev/null)"
    if [ "$_running" != "true" ]; then
      log_warn "health[$_try/$HEALTH_RETRIES]: $MIHOMO_CONTAINER not running yet"
      sleep "$HEALTH_INTERVAL"; continue
    fi
    # Crash-loop check: restart count must be stable across the interval.
    _rc1="$("$DOCKER_BIN" inspect -f '{{.RestartCount}}' "$MIHOMO_CONTAINER" 2>/dev/null)"
    sleep "$HEALTH_INTERVAL"
    _rc2="$("$DOCKER_BIN" inspect -f '{{.RestartCount}}' "$MIHOMO_CONTAINER" 2>/dev/null)"
    _running="$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$MIHOMO_CONTAINER" 2>/dev/null)"
    if [ "$_running" != "true" ] || [ "${_rc1:-0}" != "${_rc2:-0}" ]; then
      log_warn "health[$_try/$HEALTH_RETRIES]: $MIHOMO_CONTAINER unstable (running=$_running restarts $_rc1->$_rc2)"
      continue
    fi
    # Stable. Now the controller probe (in-container).
    mihomo_controller_probe
    case "$?" in
      0) log_info "health: mihomo running + controller OK"; _check_ui; return 0 ;;
      2) log_info "health: mihomo running + stable (controller probe unavailable in image)"; _check_ui; return 0 ;;
      1) log_warn "health[$_try/$HEALTH_RETRIES]: controller not answering yet" ;;
    esac
  done
  log_error "health gate FAILED for $MIHOMO_CONTAINER after $HEALTH_RETRIES tries"
  return 1
}

_check_ui() {
  _ui="$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$METACUBEXD_CONTAINER" 2>/dev/null)"
  [ "$_ui" = "true" ] || log_warn "metacubexd ($METACUBEXD_CONTAINER) is not running"
}

# rollback_compose MIHOMO_OLD_ID METACUBEXD_OLD_ID -> re-point each tag at its
# last-good image id (captured from the running container BEFORE the swap), then a
# single recreate. Empty args are skipped. Returns 0 if the recreate succeeded.
rollback_compose() {
  _m_old="$1"; _u_old="$2"
  [ -n "$_m_old" ] && { log_warn "rollback: re-tag $MIHOMO_IMAGE -> $_m_old";    "$DOCKER_BIN" tag "$_m_old" "$MIHOMO_IMAGE"     >>"$LOG_FILE" 2>&1; }
  [ -n "$_u_old" ] && { log_warn "rollback: re-tag $METACUBEXD_IMAGE -> $_u_old"; "$DOCKER_BIN" tag "$_u_old" "$METACUBEXD_IMAGE" >>"$LOG_FILE" 2>&1; }
  compose_up || { log_error "rollback compose up failed"; return 1; }
  return 0
}
