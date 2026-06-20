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

# --- strict dotenv parsing ---------------------------------------------------
# .env is shared with Docker Compose, but it is data, not a shell program. Do
# not source it: an ordinary password containing '&', '$', spaces, or quotes can
# otherwise be mangled, and command substitutions in a hand-edited file execute.
dotenv_decode() {
  _dd_raw="$1"
  case "$_dd_raw" in
    \"*\")
      [ "${_dd_raw%\"}" != "$_dd_raw" ] || return 1
      _dd_raw="${_dd_raw#\"}"; _dd_raw="${_dd_raw%\"}"
      DOTENV_RAW="$_dd_raw" awk 'BEGIN {
        s=ENVIRON["DOTENV_RAW"]; out=""; esc=0
        for (i=1; i<=length(s); i++) {
          c=substr(s,i,1)
          if (esc) { if (c ~ /[\\"$`]/) out=out c; else out=out "\\" c; esc=0 }
          else if (c == "\\") esc=1
          else if (c == "$" && substr(s,i+1,1) == "$") { out=out "$"; i++ }
          else out=out c
        }
        if (esc) out=out "\\"
        printf "%s", out
      }' ;;
    \'*\')
      [ "${_dd_raw%\'}" != "$_dd_raw" ] || return 1
      _dd_raw="${_dd_raw#\'}"; _dd_raw="${_dd_raw%\'}"
      printf '%s' "$_dd_raw" ;;
    \"*|\'*) return 1 ;; # unmatched opening quote
    *) printf '%s' "$_dd_raw" | sed 's/[[:space:]]*$//' ;;
  esac
}

dotenv_get() {
  _dg_key="$1"
  [ -f "$ENV_FILE" ] || return 1
  _dg_raw="$(DOTENV_KEY="$_dg_key" awk '
    BEGIN { k=ENVIRON["DOTENV_KEY"]; found=0 }
    $0 ~ "^" k "=" { sub("^" k "=", ""); v=$0; found=1 }
    END { if (found) printf "%s", v; else exit 1 }
  ' "$ENV_FILE")" || return 1
  dotenv_decode "$_dg_raw"
}

dotenv_load() {
  _dl_file="${1:-$ENV_FILE}"
  [ -f "$_dl_file" ] || return 1
  _dl_n=0
  while IFS= read -r _dl_line || [ -n "$_dl_line" ]; do
    _dl_n=$((_dl_n + 1))
    _dl_line="$(printf '%s' "$_dl_line" | sed 's/\r$//')"
    case "$_dl_line" in ''|'#'*) continue ;; esac
    case "$_dl_line" in
      *=*) _dl_key="${_dl_line%%=*}"; _dl_raw="${_dl_line#*=}" ;;
      *) log_error "invalid .env line $_dl_n (expected KEY=VALUE)"; return 1 ;;
    esac
    case "$_dl_key" in ''|[0-9]*|*[!A-Za-z0-9_]*)
      log_error "invalid .env key: $_dl_key"; return 1 ;;
    esac
    if ! _dl_value="$(dotenv_decode "$_dl_raw")"; then
      log_error "invalid quoted value for $_dl_key in $_dl_file"
      return 1
    fi
    export "$_dl_key=$_dl_value" || { log_error "could not export $_dl_key"; return 1; }
  done < "$_dl_file"
  return 0
}

load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "FATAL: .env not found at $ENV_FILE (copy .env.example -> .env)" >&2
    exit "$EXIT_CONFIG"
  fi
  if ! dotenv_load "$ENV_FILE"; then
    echo "FATAL: invalid .env at $ENV_FILE" >&2
    exit "$EXIT_CONFIG"
  fi

  # Defaults for optional tunables (keeps .env lean).
  : "${INSTALLER_LANG:=en}"
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
  : "${HEALTH_MAX_RESTARTS:=3}"
  : "${TUN_DEVICE:=mihomo-tun}"
  : "${LOCK_DIR:=/tmp/syno-mihomo-update.lock}"

  # Backward compatibility with the pre-1.2.11 template. The strict loader
  # intentionally does not perform arbitrary shell expansion.
  case "${UPDATE_IMAGES:-}" in
    ''|'${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}')
      UPDATE_IMAGES="${MIHOMO_IMAGE:-} ${METACUBEXD_IMAGE:-} ${CF_IMAGE:-}" ;;
  esac
  export UPDATE_IMAGES

  # Normalize UPDATE_LOG to an absolute path under the repo when relative.
  case "$UPDATE_LOG" in
    /*) LOG_FILE="$UPDATE_LOG" ;;
    *)  LOG_FILE="$REPO_ROOT/${UPDATE_LOG#./}" ;;
  esac
  # Under the interactive installer, send all library output (compose up, image
  # pull, ACR login) to the install log so the on-screen "Details: <file>"
  # pointer actually points at the file that holds the error. The cron/boot path
  # never sets INSTALL_LOG, so it keeps logging to UPDATE_LOG.
  [ -n "${INSTALL_LOG:-}" ] && LOG_FILE="$INSTALL_LOG"
  LOG_DIR="$(dirname "$LOG_FILE")"
  [ "${NO_LOG_INIT:-0}" = 1 ] || mkdir -p "$LOG_DIR" 2>/dev/null || true
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
