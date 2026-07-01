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
if [ -z "${REPO_ROOT:-}" ]; then
  case "$LIB_DIR" in
    */scripts/lib) REPO_ROOT="$(CDPATH='' cd -- "$LIB_DIR/../.." && pwd)" ;;
    */scripts)     REPO_ROOT="$(CDPATH='' cd -- "$LIB_DIR/.." && pwd)" ;;
    *)             REPO_ROOT="$(CDPATH='' cd -- "$LIB_DIR" && pwd)" ;;
  esac
fi

# Runtime data lives beside the replaceable release directory. A release ZIP can
# therefore be unpacked over/replaced without deleting credentials or generated
# configuration. GATEWAY_DATA_DIR may be exported for a non-standard layout.
GATEWAY_DATA_DIR="${GATEWAY_DATA_DIR:-$(dirname "$REPO_ROOT")/syno-mihomo-gateway-data}"
ENV_FILE="${ENV_FILE:-$GATEWAY_DATA_DIR/.env}"
CONFIG_STATE_DIR="${CONFIG_STATE_DIR:-$GATEWAY_DATA_DIR/config}"
SUBSCRIPTION_FILE="${SUBSCRIPTION_FILE:-$CONFIG_STATE_DIR/subscription.txt}"
export REPO_ROOT GATEWAY_DATA_DIR ENV_FILE CONFIG_STATE_DIR SUBSCRIPTION_FILE

# Create the persistent layout and import a legacy in-release installation once.
# Copy (rather than move) so a failed first run can still use the old release.
ensure_persistent_state() {
  mkdir -p "$CONFIG_STATE_DIR" "$GATEWAY_DATA_DIR/logs" || return 1
  chmod 700 "$GATEWAY_DATA_DIR" "$CONFIG_STATE_DIR" 2>/dev/null || true

  if [ ! -f "$ENV_FILE" ] && [ -f "$REPO_ROOT/.env" ]; then
    cp "$REPO_ROOT/.env" "$ENV_FILE" || return 1
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    echo "Migrated legacy .env to $ENV_FILE" >&2
  fi
  if [ ! -f "$SUBSCRIPTION_FILE" ] && [ -f "$REPO_ROOT/config/subscription.txt" ]; then
    cp "$REPO_ROOT/config/subscription.txt" "$SUBSCRIPTION_FILE" || return 1
    chmod 600 "$SUBSCRIPTION_FILE" 2>/dev/null || true
    echo "Migrated legacy subscription to $SUBSCRIPTION_FILE" >&2
  fi
  return 0
}

# Exit codes (see README / DSM Task Scheduler email-on-nonzero). The meanings
# of 0/2/3/4/5 are load-bearing for existing scheduled tasks - never repurpose
# them; new conditions get NEW codes (6/7 below, added for gateway.sh).
EXIT_OK=0            # success or clean no-op
EXIT_PARTIAL=2      # one component failed, others applied
EXIT_CONFIG=3       # config / preflight error - nothing changed
EXIT_LOCKED=4       # another run holds the lock
EXIT_LOGIN=5        # ACR login failed - nothing attempted
EXIT_ROOT=6         # verb needs root - nothing changed
EXIT_CONFIRM=7      # mutating verb refused without explicit --yes - nothing changed

# is_root / need_root - the per-verb privilege gate for headless callers.
# (scripts/installer/preflight.sh keeps its own identical is_root for the
# interactive path; both are trivial and behaviorally identical.)
is_root() { [ "$(id -u 2>/dev/null)" = "0" ]; }
need_root() {
  is_root && return 0
  log_error "this action requires root - re-run with sudo"
  return "$EXIT_ROOT"
}

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
  : "${DOCKER_READY_TIMEOUT:=120}"
  : "${DOCKER_READY_INTERVAL:=5}"
  : "${HEALTH_RETRIES:=6}"
  : "${HEALTH_INTERVAL:=10}"
  : "${HEALTH_MAX_RESTARTS:=3}"
  : "${TUN_DEVICE:=mihomo-tun}"
  # Transparent-gateway TUN is ON by default (stack: system keeps the controller
  # reachable - see scripts/render_config.sh and docs/troubleshooting.md). Set
  # TUN_ENABLE=false to run as a plain (non-gateway) proxy.
  : "${TUN_ENABLE:=true}"
  : "${TUN_AUTO_REDIRECT:=false}"
  : "${LOCK_DIR:=/tmp/syno-mihomo-update.lock}"
  export TUN_ENABLE TUN_AUTO_REDIRECT

  # Backward compatibility with the pre-1.2.11 template. The strict loader
  # intentionally does not perform arbitrary shell expansion.
  case "${UPDATE_IMAGES:-}" in
    ''|'${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}')
      UPDATE_IMAGES="${MIHOMO_IMAGE:-} ${METACUBEXD_IMAGE:-} ${CF_IMAGE:-}" ;;
  esac
  export UPDATE_IMAGES

  # Normalize UPDATE_LOG to an absolute path under persistent runtime data.
  case "$UPDATE_LOG" in
    /*) LOG_FILE="$UPDATE_LOG" ;;
    *)  LOG_FILE="$GATEWAY_DATA_DIR/${UPDATE_LOG#./}" ;;
  esac
  # Under the interactive installer, send all library output (compose up, image
  # pull, ACR login) to the install log so the on-screen "Details: <file>"
  # pointer actually points at the file that holds the error. The cron/boot path
  # never sets INSTALL_LOG, so it keeps logging to UPDATE_LOG. The gateway CLI
  # (scripts/gateway.sh) sets GATEWAY_LOG, which wins over both: every verb of
  # the unified CLI logs to one file, logs/gateway.log.
  [ -n "${INSTALL_LOG:-}" ] && LOG_FILE="$INSTALL_LOG"
  [ -n "${GATEWAY_LOG:-}" ] && LOG_FILE="$GATEWAY_LOG"
  LOG_DIR="$(dirname "$LOG_FILE")"
  [ "${NO_LOG_INIT:-0}" = 1 ] || mkdir -p "$LOG_DIR" 2>/dev/null || true
}

_ts() { date '+%Y-%m-%d %H:%M:%S %z'; }
log() {
  # log LEVEL message... GATEWAY_VERB/GATEWAY_RUN_ID (set by gateway.sh) add a
  # per-verb audit field. GATEWAY_LOG_QUIET=1 (set under --json) keeps stdout
  # clean for the single JSON result object: lines go to the file + stderr only.
  _lvl="$1"; shift
  _line="$(printf '%s [%s]%s %s' "$(_ts)" "$_lvl" "${GATEWAY_VERB:+ verb=$GATEWAY_VERB run=$GATEWAY_RUN_ID}" "$*")"
  if [ "${GATEWAY_LOG_QUIET:-0}" = 1 ]; then
    [ -n "${LOG_FILE:-}" ] && printf '%s\n' "$_line" >> "$LOG_FILE" 2>/dev/null
    printf '%s\n' "$_line" >&2
  else
    printf '%s\n' "$_line" | tee -a "${LOG_FILE:-/dev/stderr}"
  fi
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
