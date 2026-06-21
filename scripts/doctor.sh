#!/bin/sh
# Read-only DSM diagnostics for the Mihomo gateway.
# Exit: 0 structurally healthy | 2 degraded optional service/egress | 3 broken.

PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/lib/common.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SELF_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/network.sh
. "$SELF_DIR/lib/network.sh"
# shellcheck source=scripts/lib/compose.sh
. "$SELF_DIR/lib/compose.sh"

CHECK_EGRESS=0
NO_LOG_INIT=1
export NO_LOG_INIT
case "${1:-}" in
  '') : ;;
  --egress) CHECK_EGRESS=1 ;;
  *) echo "Usage: sh scripts/doctor.sh [--egress]" >&2; exit "$EXIT_CONFIG" ;;
esac

broken=0
degraded=0
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'ERROR %s\n' "$*" >&2; broken=1; }
warn() { printf 'WARN  %s\n' "$*" >&2; degraded=1; }

printf '%s\n' 'Mihomo Gateway diagnostics (read-only)'

if [ ! -f "$ENV_FILE" ]; then
  bad ".env is missing: $ENV_FILE"
else
  load_env
  ok ".env parsed safely"
fi

if ! detect_compose >/dev/null 2>&1; then
  bad "Docker or Compose is unavailable"
elif ! "$DOCKER_BIN" info >/dev/null 2>&1; then
  bad "Docker daemon is unavailable or permission was denied"
else
  ok "Docker daemon and Compose are available"
fi

if [ "$broken" -eq 0 ]; then
  _host_arch="$(host_arch)"
  if [ "$_host_arch" != "${EXPECTED_ARCH:-amd64}" ]; then
    bad "EXPECTED_ARCH=${EXPECTED_ARCH:-amd64}, host=$_host_arch"
  else
    ok "host architecture=$_host_arch"
  fi

  if check_tun >/dev/null 2>&1; then ok "host /dev/net/tun exists"; else bad "host /dev/net/tun is missing"; fi
  if check_network >/dev/null 2>&1; then
    ok "macvlan network is present and consistent"
  else
    bad "macvlan network is missing or inconsistent"
  fi

  # shellcheck disable=SC2086 # COMPOSE_CMD may be two words
  if ( cd "$REPO_ROOT" && $COMPOSE_CMD --env-file "$ENV_FILE" config >/dev/null ) 2>/dev/null; then
    ok "Compose configuration is valid"
  else
    bad "Compose configuration is invalid"
  fi

  _state="$("$DOCKER_BIN" inspect -f '{{.State.Status}}' "$MIHOMO_CONTAINER" 2>/dev/null)"
  _restarts="$("$DOCKER_BIN" inspect -f '{{.RestartCount}}' "$MIHOMO_CONTAINER" 2>/dev/null)"
  if [ "$_state" != running ]; then
    bad "mihomo container state=${_state:-missing}"
  else
    ok "mihomo is running (restarts=${_restarts:-0})"
    if [ "${TUN_ENABLE:-false}" != true ]; then
      ok "TUN transparent gateway disabled (TUN_ENABLE=false) - reachable proxy + controller mode"
    elif mihomo_gateway_probe >/dev/null 2>&1; then
      ok "in-container TUN gateway is ready"
    else
      bad "in-container TUN gateway is not ready"
    fi
    if mihomo_controller_probe >/dev/null 2>&1; then ok "controller API responds"; else bad "controller API does not respond"; fi
    _img="${MIHOMO_IMAGE:-}"
    if [ -n "$_img" ]; then
      if arch_ok "$_img" >/dev/null 2>&1; then
        ok "mihomo image architecture matches the host"
      else
        bad "mihomo image architecture does not match the host"
      fi
    fi
  fi

  _ui="$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$METACUBEXD_CONTAINER" 2>/dev/null)"
  if [ "$_ui" = true ]; then ok "dashboard container is running"; else warn "dashboard container is not running"; fi
fi

if [ "$CHECK_EGRESS" -eq 1 ] && [ "$broken" -eq 0 ]; then
  _url="http://127.0.0.1:${CONTROLLER_PORT:-9090}/proxies/PROXY/delay?timeout=5000&url=http://www.gstatic.com/generate_204"
  _header=""
  [ -n "${CONTROLLER_SECRET:-}" ] && _header="Authorization: Bearer ${CONTROLLER_SECRET}"
  if "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v wget >/dev/null 2>&1' 2>/dev/null; then
    if [ -n "$_header" ]; then
      _out="$("$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 8 -O - --header "$_header" "$_url" 2>/dev/null)"
    else
      _out="$("$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 8 -O - "$_url" 2>/dev/null)"
    fi
  else
    _out=""
  fi
  case "$_out" in *'"delay"'*) ok "proxy egress probe succeeded" ;;
    *) warn "proxy egress probe failed or no downloader is available" ;;
  esac
fi

if [ "$broken" -ne 0 ]; then
  printf '%s\n' "Result: BROKEN. See logs/install.log and: docker logs $MIHOMO_CONTAINER" >&2
  exit "$EXIT_CONFIG"
fi
if [ "$degraded" -ne 0 ]; then
  printf '%s\n' 'Result: DEGRADED.' >&2
  exit "$EXIT_PARTIAL"
fi
printf '%s\n' 'Result: HEALTHY.'
exit "$EXIT_OK"
