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

compose_config_check() {
  # shellcheck disable=SC2086
  if ( cd "$REPO_ROOT" && $COMPOSE_CMD --env-file "$ENV_FILE" config >/dev/null ) \
      >>"$LOG_FILE" 2>&1; then
    return 0
  fi
  log_error "Docker Compose rejected docker-compose.yml + .env"
  return 1
}

compose_supports_pull_never() {
  # Docker Compose v2 supports up --pull never; legacy v1 generally does not.
  # shellcheck disable=SC2086
  ( cd "$REPO_ROOT" && $COMPOSE_CMD up --help 2>/dev/null ) \
    | grep -- '--pull' | grep -q 'never'
}

compose_up_local() {
  # Images were explicitly pulled, inspected, and architecture-checked already.
  # Prevent a second implicit pull between validation and container recreation.
  if compose_supports_pull_never; then
    # shellcheck disable=SC2086
    ( cd "$REPO_ROOT" && $COMPOSE_CMD --env-file "$ENV_FILE" up -d --pull never ) >>"$LOG_FILE" 2>&1
    return $?
  fi
  log_warn "Compose lacks 'up --pull never'; using legacy cached-image behavior"
  # shellcheck disable=SC2086
  ( cd "$REPO_ROOT" && $COMPOSE_CMD --env-file "$ENV_FILE" up -d ) >>"$LOG_FILE" 2>&1
}

compose_recreate() {
  # Installer deploys must restart mihomo so a newly rendered bind-mounted
  # configuration takes effect even when the image and compose model are unchanged.
  # shellcheck disable=SC2086
  ( cd "$REPO_ROOT" && $COMPOSE_CMD --env-file "$ENV_FILE" up -d --force-recreate ) >>"$LOG_FILE" 2>&1
}

# Probe the controller from INSIDE the mihomo netns (docker exec) so the macvlan
# host-isolation quirk (NAS can't reach its own macvlan IP) doesn't matter.
# Returns: 0 ok, 1 definitively failed, 2 probe unavailable (no downloader in image).
mihomo_controller_probe() {
  _url="http://127.0.0.1:${CONTROLLER_PORT}/version"
  _auth=""
  [ -n "${CONTROLLER_SECRET:-}" ] && _auth="Authorization: Bearer ${CONTROLLER_SECRET}"
  # The bearer token never rides the host-visible docker exec argv (the
  # project's no-secrets-on-argv rule): it is handed over on stdin instead.
  if "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v wget >/dev/null 2>&1' 2>/dev/null; then
    if [ -n "$_auth" ]; then
      printf '%s\n' "$_auth" | "$DOCKER_BIN" exec -i "$MIHOMO_CONTAINER" \
        sh -c 'IFS= read -r SMG_AUTH; exec wget -q -T 5 -O /dev/null --header "$SMG_AUTH" "$1"' _ "$_url" 2>/dev/null
    else
      "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 5 -O /dev/null "$_url" 2>/dev/null
    fi
    return $?
  elif "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v curl >/dev/null 2>&1' 2>/dev/null; then
    if [ -n "$_auth" ]; then
      printf '%s\n' "$_auth" | "$DOCKER_BIN" exec -i "$MIHOMO_CONTAINER" \
        sh -c 'IFS= read -r SMG_AUTH; exec curl -fsS -m 5 -o /dev/null -H "$SMG_AUTH" "$1"' _ "$_url" 2>/dev/null
    else
      "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" curl -fsS -m 5 -o /dev/null "$_url" 2>/dev/null
    fi
    return $?
  fi
  return 2
}

# Verify the transparent-gateway dataplane, not only the management API. A
# healthy controller without the runtime TUN interface leaves LAN clients with
# no route through the proxy while appearing healthy to Docker.
# Only meaningful when TUN_ENABLE=true: the default deploy runs WITHOUT mihomo-tun
# (reachable proxy + controller via the redir/tproxy/mixed ports), so there is no
# TUN dataplane to verify and the probe is a no-op.
mihomo_gateway_probe() {
  [ "${TUN_ENABLE:-false}" = true ] || return 0
  _tun="${TUN_DEVICE:-mihomo-tun}"
  if ! "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c \
      'test -d "/sys/class/net/$1"' sh "$_tun" 2>/dev/null; then
    log_warn "gateway probe: TUN interface '$_tun' is missing inside $MIHOMO_CONTAINER"
    return 1
  fi
  _forward="$("$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c \
      'cat /proc/sys/net/ipv4/ip_forward 2>/dev/null' 2>/dev/null)"
  if [ "$_forward" != "1" ]; then
    log_warn "gateway probe: net.ipv4.ip_forward=${_forward:-unknown}, expected 1"
    return 1
  fi
  return 0
}

# health_gate -> 0 healthy, 1 unhealthy. Checks mihomo is running, NOT crash-looping,
# and (when possible) that its controller answers. metacubexd is checked but only warned on.
health_gate() {
  _try=0
  # Restart count when the gate started: a single stable interval is NOT proof of
  # health if the container has been crash-looping (and only momentarily paused).
  _rc_start="$("$DOCKER_BIN" inspect -f '{{.RestartCount}}' "$MIHOMO_CONTAINER" 2>/dev/null)"
  _rc_start="${_rc_start:-0}"
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
    # Even if stable across THIS interval, reject a container that has restarted
    # repeatedly since the gate started - it is crash-looping, not healthy.
    if [ "$(( ${_rc2:-0} - _rc_start ))" -ge "${HEALTH_MAX_RESTARTS:-3}" ]; then
      log_warn "health[$_try/$HEALTH_RETRIES]: $MIHOMO_CONTAINER crash-looping (restarted $(( ${_rc2:-0} - _rc_start ))x since deploy)"
      continue
    fi
    # Stable. Now the controller probe (in-container).
    mihomo_controller_probe
    case "$?" in
      0) if mihomo_gateway_probe; then
           log_info "health: mihomo running + controller OK + TUN gateway ready"
           _check_ui; return 0
         fi ;;
      2) log_warn "health[$_try/$HEALTH_RETRIES]: controller probe unavailable in image" ;;
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
  [ -n "$_m_old$_u_old" ] || { log_error "rollback unavailable: no previous running image IDs"; return 1; }
  if [ -n "$_m_old" ] && ! "$DOCKER_BIN" image inspect "$_m_old" >/dev/null 2>&1; then
    log_error "rollback image is missing: $_m_old"
    return 1
  fi
  if [ -n "$_u_old" ] && ! "$DOCKER_BIN" image inspect "$_u_old" >/dev/null 2>&1; then
    log_error "rollback image is missing: $_u_old"
    return 1
  fi
  if [ -n "$_m_old" ]; then
    log_warn "rollback: re-tag $MIHOMO_IMAGE -> $_m_old"
    "$DOCKER_BIN" tag "$_m_old" "$MIHOMO_IMAGE" >>"$LOG_FILE" 2>&1 \
      || { log_error "rollback re-tag failed for $MIHOMO_IMAGE"; return 1; }
  fi
  if [ -n "$_u_old" ]; then
    log_warn "rollback: re-tag $METACUBEXD_IMAGE -> $_u_old"
    "$DOCKER_BIN" tag "$_u_old" "$METACUBEXD_IMAGE" >>"$LOG_FILE" 2>&1 \
      || { log_error "rollback re-tag failed for $METACUBEXD_IMAGE"; return 1; }
  fi
  compose_up_local || { log_error "rollback compose up failed"; return 1; }
  return 0
}
