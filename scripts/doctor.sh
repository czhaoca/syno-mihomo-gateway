#!/bin/sh
# Read-only host diagnostics for the Mihomo gateway (DSM + generic Linux).
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
# shellcheck source=scripts/lib/geodata.sh
. "$SELF_DIR/lib/geodata.sh"
# shellcheck source=scripts/lib/cloudflared.sh
. "$SELF_DIR/lib/cloudflared.sh"
# shellcheck source=scripts/lib/resolve.sh
. "$SELF_DIR/lib/resolve.sh"
# shellcheck source=scripts/lib/scheduler.sh
. "$SELF_DIR/lib/scheduler.sh"
# shellcheck source=scripts/lib/checks.sh
. "$SELF_DIR/lib/checks.sh"

CHECK_EGRESS=0
NO_LOG_INIT=1
export NO_LOG_INIT
case "${1:-}" in
  '') : ;;
  --egress) CHECK_EGRESS=1 ;;
  *) echo "Usage: sh scripts/doctor.sh [--egress]" >&2; exit "$EXIT_CONFIG" ;;
esac

# The checks themselves live in lib/checks.sh (#30) - one table, two
# renderers. This renderer maps each record's severity to the human
# vocabulary: ok -> 'ok    <detail>' on stdout, bad -> 'ERROR' on stderr
# (BROKEN/EXIT_CONFIG), warn -> 'WARN ' on stderr (DEGRADED/EXIT_PARTIAL),
# silent -> nothing (unknown/disabled/absent stay --json-only). '#hint'
# records are the extra remediation lines. Runs as the last stage of the
# checks_run pipe, so it owns the exit code (every pipeline stage is a
# subshell under BusyBox ash - counters cannot cross back).
render_human() {
  _rh_broken=0; _rh_degraded=0
  while IFS='|' read -r _rh_n _rh_v _rh_s _rh_d; do
    if [ "$_rh_n" = '#hint' ]; then
      printf '%s\n' "$_rh_v" >&2
      continue
    fi
    case "$_rh_s" in
      bad)  printf 'ERROR %s\n' "$_rh_d" >&2; _rh_broken=1 ;;
      warn) printf 'WARN  %s\n' "$_rh_d" >&2; _rh_degraded=1 ;;
      ok)   [ -z "$_rh_d" ] || printf 'ok    %s\n' "$_rh_d" ;;
      *)    : ;;   # silent
    esac
  done

  # Optional egress probe (human mode only; --egress). The bearer token must
  # not ride the host-visible docker exec argv (the project's no-secrets-on-
  # argv rule): hand it over on stdin. The rule target's spaced name rides
  # the URL %20-encoded (Proxy Mode -> Proxy%20Mode).
  if [ "$CHECK_EGRESS" -eq 1 ] && [ "$_rh_broken" -eq 0 ]; then
    _rh_url="http://127.0.0.1:${CONTROLLER_PORT:-9090}/proxies/Proxy%20Mode/delay?timeout=5000&url=http://www.gstatic.com/generate_204"
    _rh_header=""
    [ -n "${CONTROLLER_SECRET:-}" ] && _rh_header="Authorization: Bearer ${CONTROLLER_SECRET}"
    if "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v wget >/dev/null 2>&1' 2>/dev/null; then
      if [ -n "$_rh_header" ]; then
        # shellcheck disable=SC2016 # $SMG_AUTH expands in the container shell
        _rh_out="$(printf '%s\n' "$_rh_header" | "$DOCKER_BIN" exec -i "$MIHOMO_CONTAINER" \
          sh -c 'IFS= read -r SMG_AUTH; exec wget -q -T 8 -O - --header "$SMG_AUTH" "$1"' _ "$_rh_url" 2>/dev/null)"
      else
        _rh_out="$("$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 8 -O - "$_rh_url" 2>/dev/null)"
      fi
    else
      _rh_out=""
    fi
    case "$_rh_out" in *'"delay"'*) printf 'ok    %s\n' "proxy egress probe succeeded" ;;
      *) printf 'WARN  %s\n' "proxy egress probe failed or no downloader is available" >&2; _rh_degraded=1 ;;
    esac
  fi

  if [ "$_rh_broken" -ne 0 ]; then
    printf '%s\n' "Result: BROKEN. See logs/install.log and: docker logs $MIHOMO_CONTAINER" >&2
    return "$EXIT_CONFIG"
  fi
  if [ "$_rh_degraded" -ne 0 ]; then
    printf '%s\n' 'Result: DEGRADED.' >&2
    return "$EXIT_PARTIAL"
  fi
  printf '%s\n' 'Result: HEALTHY.'
  return "$EXIT_OK"
}

printf '%s\n' 'Mihomo Gateway diagnostics (read-only)'

# load_env only when the file exists (a malformed .env exits 3 here, exactly
# as before); a missing one is chk_env's bad record, hints included.
if [ -f "$ENV_FILE" ]; then
  load_env
fi

# Populate DOCKER_BIN in THIS shell before the pipe forks: both pipeline
# stages are sibling subshells, so chk_docker's own detect_compose call can
# never reach render_human's egress block (it would probe with an empty
# command name and false-warn). Idempotent with chk_docker's call.
detect_compose >/dev/null 2>&1 || :

checks_run | render_human
exit "$?"
