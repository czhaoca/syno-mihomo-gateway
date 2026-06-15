#!/bin/sh
# common.sh - shared helpers for the auto-update orchestrator.
# POSIX /bin/sh only (DSM ships BusyBox; no bashisms / associative arrays).
# Sourced by scripts/auto_update.sh and the other lib/*.sh files.
#
# Provides: REPO_ROOT/ENV_FILE, load_env, logging + rotation, mkdir-based lock,
# and the EXIT_* status codes. Intentionally does NOT use `set -e`/`set -u` -
# the orchestrator checks return codes explicitly so one soft failure never
# tears down the gateway by surprise.

# Resolve repo root regardless of cwd (DSM cron runs from /).
LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
case "$LIB_DIR" in
  */scripts/lib) REPO_ROOT="$(CDPATH='' cd -- "$LIB_DIR/../.." && pwd)" ;;
  */scripts)     REPO_ROOT="$(CDPATH='' cd -- "$LIB_DIR/.." && pwd)" ;;
  *)             REPO_ROOT="$(CDPATH='' cd -- "$LIB_DIR" && pwd)" ;;
esac
ENV_FILE="$REPO_ROOT/.env"

# Exit codes (see README / DSM Task Scheduler email-on-nonzero).
EXIT_OK=0            # success or clean no-op
EXIT_PARTIAL=2      # one component failed, others applied
EXIT_CONFIG=3       # config / preflight error - nothing changed
EXIT_LOCKED=4       # another run holds the lock
EXIT_LOGIN=5        # ACR login failed - nothing attempted

load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "FATAL: .env not found at $ENV_FILE (copy .env.example -> .env)" >&2
    exit "$EXIT_CONFIG"
  fi
  # Source (not `export $(... xargs)`) so values with spaces/special chars survive.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  # Defaults for optional tunables (keeps .env lean).
  : "${UPDATE_ENABLED:=true}"
  : "${EXPECTED_ARCH:=amd64}"
  : "${CONTROLLER_PORT:=9090}"
  : "${CF_CONTAINER_NAME:=cloudflared}"
  : "${CF_HEALTH_TIMEOUT:=60}"
  : "${NOTIFY_ON_NOCHANGE:=0}"
  : "${UPDATE_LOG:=./logs/auto-update.log}"
  : "${LOG_KEEP:=7}"
  : "${LOG_MAX_BYTES:=1048576}"
  : "${PULL_RETRIES:=3}"
  : "${PULL_RETRY_DELAY:=10}"
  : "${HEALTH_RETRIES:=6}"
  : "${HEALTH_INTERVAL:=10}"
  : "${LOCK_DIR:=/tmp/syno-mihomo-update.lock}"

  # Normalize UPDATE_LOG to an absolute path under the repo when relative.
  case "$UPDATE_LOG" in
    /*) LOG_FILE="$UPDATE_LOG" ;;
    *)  LOG_FILE="$REPO_ROOT/${UPDATE_LOG#./}" ;;
  esac
  LOG_DIR="$(dirname "$LOG_FILE")"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
}

_ts() { date '+%Y-%m-%d %H:%M:%S %z'; }
log() {
  # log LEVEL message...
  _lvl="$1"; shift
  printf '%s [%s] %s\n' "$(_ts)" "$_lvl" "$*" | tee -a "${LOG_FILE:-/dev/stderr}"
}
log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }

rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  _sz="$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')"
  [ -n "$_sz" ] || return 0
  [ "$_sz" -lt "$LOG_MAX_BYTES" ] && return 0
  _i="$LOG_KEEP"
  while [ "$_i" -gt 1 ]; do
    [ -f "${LOG_FILE}.$((_i-1))" ] && mv "${LOG_FILE}.$((_i-1))" "${LOG_FILE}.${_i}"
    _i=$((_i-1))
  done
  mv "$LOG_FILE" "${LOG_FILE}.1"
}

# --- mkdir-based lock (atomic on POSIX, BusyBox-safe; no flock dependency) ---
# LOCK_HELD guards release: only the process that actually acquired the lock may
# remove it. Without this, a locked-out run's EXIT trap would rm -rf the lock dir
# owned by the still-running holder, defeating the mutex during a live redeploy.
LOCK_HELD=0
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    LOCK_HELD=1
    return 0
  fi
  _oldpid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "$_oldpid" ] && kill -0 "$_oldpid" 2>/dev/null; then
    log_warn "another run (pid $_oldpid) is active - skipping."
    exit "$EXIT_LOCKED"
  fi
  log_warn "stale lock (pid ${_oldpid:-unknown}) - reclaiming."
  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    LOCK_HELD=1
    return 0
  fi
  log_error "could not acquire lock at $LOCK_DIR"
  exit "$EXIT_LOCKED"
}
release_lock() {
  [ "${LOCK_HELD:-0}" = 1 ] || return 0
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  LOCK_HELD=0
}
