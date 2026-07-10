#!/bin/sh
# auto_update_lite.sh - bare-metal "lite" mode binary updater for the Raspberry
# Pi port (#20): the native-binary counterpart of scripts/auto_update.sh with
# the SAME operational contract (mkdir lock, UPDATE_ENABLED kill-switch,
# --dry-run/--force, rotating log, last-run state, notify reporting, the
# EXIT_* codes from scripts/lib/common.sh).
#
# Pipeline: resolve the release tag (DEC-D: a pinned MIHOMO_VERSION wins;
# otherwise the releases/latest redirect is followed THROUGH GH_MIRROR, and a
# mangled redirect is a classified failure - never a silent wrong version) ->
# no-change fast exit against state/lite/version -> #19's fail-closed verify
# ladder + atomic swap (pi_lite_install_binary: optional pinned sha -> gzip -t
# -> exec smoke -> tag match) -> systemctl restart -> lite_health_gate -> on a
# gate failure restore bin/mihomo.prev + the version state, restart, re-gate,
# exit partial.
#
# Run by cron (see pi_install_lite_crontab / pi_flow_cron) or by hand:
#   auto_update_lite.sh [--dry-run] [--force]
#   --dry-run : resolve + compare + report, but DO NOT download or swap anything
#   --force   : ignore UPDATE_ENABLED=false kill-switch
#
# Exit: 0 ok/no-op | 2 partial failure | 3 config/preflight | 4 locked
# POSIX /bin/sh only. No `set -e` - return codes are checked explicitly.

# Survive cron's stripped PATH.
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

# scripts/pi/ sits one level deeper than scripts/, so resolve REPO_ROOT before
# common.sh ($0-based, its own heuristic only knows scripts/ and scripts/lib).
# The SELF_DIR override exists for the CI suite, which sources this file.
SELF_DIR="${AUTO_UPDATE_LITE_SELF_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(CDPATH='' cd -- "$SELF_DIR/../.." && pwd)}"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/../lib/common.sh"
# shellcheck source=scripts/lib/notify.sh
. "$SELF_DIR/../lib/notify.sh"
# registry.sh supplies the shared config validators (_config_uint,
# validate_update_switch); its docker helpers are never called in lite mode.
# shellcheck source=scripts/lib/registry.sh
. "$SELF_DIR/../lib/registry.sh"
# shellcheck source=scripts/pi/detect.sh
. "$SELF_DIR/detect.sh"
# shellcheck source=scripts/pi/lite.sh
. "$SELF_DIR/lite.sh"

# write_last_run EXIT_CODE - same shape, atomicity and lock-skip semantics as
# auto_update.sh's record (a lock-denied second run must not clobber the live
# run's file); the lite copy lives beside the version state in state/lite/.
write_last_run() {
  _wlr_rc="$1"
  [ "$_wlr_rc" = "${EXIT_LOCKED:-4}" ] && return 0
  _wlr_dir="$GATEWAY_DATA_DIR/state/lite"
  mkdir -p "$_wlr_dir" 2>/dev/null || return 0
  chmod 700 "$_wlr_dir" 2>/dev/null || true
  # Guard-then-strip: the name accumulators are unset on early-abort paths,
  # and a bare ${var# } aborts BusyBox ash under set -u harnesses.
  _wlr_un="${updated_names:-}"; _wlr_fn="${failed_names:-}"; _wlr_rn="${rolled_names:-}"
  printf '{"ts":"%s","exit_code":%s,"dry_run":%s,"updated":%s,"unchanged":%s,"failed":%s,"rolled_back":%s,"updated_names":"%s","failed_names":"%s","rolled_back_names":"%s"}\n' \
    "$(_ts)" "$_wlr_rc" "${DRY_RUN:-0}" "${updated_n:-0}" "${unchanged_n:-0}" "${failed_n:-0}" "${rolled_n:-0}" \
    "${_wlr_un# }" "${_wlr_fn# }" "${_wlr_rn# }" \
    >"$_wlr_dir/last-run.json.next" 2>/dev/null || return 0
  chmod 600 "$_wlr_dir/last-run.json.next" 2>/dev/null || true
  mv "$_wlr_dir/last-run.json.next" "$_wlr_dir/last-run.json" 2>/dev/null || true
}

# validate_lite_update_config - the lite-relevant subset of registry.sh's
# validate_update_config: the health-gate knobs plus log rotation.
validate_lite_update_config() {
  validate_update_switch || return 1
  _config_uint HEALTH_RETRIES "${HEALTH_RETRIES:-}" 1 || return 1
  _config_uint HEALTH_INTERVAL "${HEALTH_INTERVAL:-}" 0 || return 1
  _config_uint HEALTH_MAX_RESTARTS "${HEALTH_MAX_RESTARTS:-}" 1 || return 1
  _config_uint LOG_KEEP "${LOG_KEEP:-}" 1 || return 1
  return 0
}

auto_update_lite_main() {

ensure_persistent_state || {
  echo "FATAL: cannot create persistent data directory: $GATEWAY_DATA_DIR" >&2
  exit "$EXIT_CONFIG"
}

DRY_RUN=0
FORCE=0
for _arg in "$@"; do
  case "$_arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    *) echo "unknown argument: $_arg" >&2; exit "$EXIT_CONFIG" ;;
  esac
done

load_env
rotate_log
# .env timezone is authoritative regardless of the system tz.
[ -n "${UPDATE_TZ:-}" ] && { TZ="$UPDATE_TZ"; export TZ; }

# shellcheck disable=SC2329  # invoked indirectly via trap
on_exit() {
  _oe_rc=$?
  write_last_run "$_oe_rc"
  release_lock
}
# Signals must TERMINATE, not resume (see auto_update.sh): `exit` inside a
# signal trap fires the EXIT trap exactly once, at real termination.
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_lock
log_info "=== lite auto-update start (dry_run=$DRY_RUN force=$FORCE) ==="

# Validate the boolean before interpreting it (a typo must fail loudly, not
# silently disable updates), then the kill-switch, then the remaining knobs.
validate_update_switch || {
  notify "Mihomo Gateway (lite): update aborted" "UPDATE_ENABLED must be true or false."
  exit "$EXIT_CONFIG"
}

if [ "$UPDATE_ENABLED" != "true" ] && [ "$FORCE" -ne 1 ]; then
  log_info "UPDATE_ENABLED=$UPDATE_ENABLED - disabled. Use --force to override. Exiting."
  exit "$EXIT_OK"
fi

validate_lite_update_config || {
  notify "Mihomo Gateway (lite): update aborted" "Invalid auto-update settings in .env."
  exit "$EXIT_CONFIG"
}

# --- Preflight (abort touching nothing): this box must BE a lite install ---
command -v systemctl >/dev/null 2>&1 || {
  log_error "systemctl not found - lite mode requires systemd"
  notify "Mihomo Gateway (lite): update aborted" "systemctl not found on this host."
  exit "$EXIT_CONFIG"
}
[ -f "$(pi_lite_unit_path)" ] || {
  log_error "unit $(pi_lite_unit_path) missing - lite mode is not installed here"
  notify "Mihomo Gateway (lite): update aborted" "mihomo-gateway.service is not installed."
  exit "$EXIT_CONFIG"
}
[ -x "$GATEWAY_DATA_DIR/bin/mihomo" ] || {
  log_error "no managed binary at $GATEWAY_DATA_DIR/bin/mihomo - run the lite install first"
  notify "Mihomo Gateway (lite): update aborted" "no managed mihomo binary found."
  exit "$EXIT_CONFIG"
}

updated_n=0; unchanged_n=0; failed_n=0; rolled_n=0
updated_names=""; failed_names=""; rolled_names=""

# --- Resolve (DEC-D) + no-change fast exit against the version state ---
_res_mode=latest
[ -n "${MIHOMO_VERSION:-}" ] && _res_mode=pin
_tag="$(pi_resolve_tag MetaCubeX/mihomo "${MIHOMO_VERSION:-}")" || {
  failed_n=1; failed_names=" mihomo"
  log_error "could not resolve the mihomo release tag (mode=$_res_mode)"
  notify "Mihomo Gateway (lite): update failed" "Release tag resolution failed (mirror/network). Pin MIHOMO_VERSION in .env to bypass."
  exit "$EXIT_PARTIAL"
}
_cur="$(cat "$GATEWAY_DATA_DIR/state/lite/version" 2>/dev/null)"
log_info "release check: running=${_cur:-unknown} target=$_tag (resolved via $_res_mode)"
if [ "$_tag" = "$_cur" ]; then
  unchanged_n=1
  log_info "no update: mihomo $_cur is current."
  [ "$NOTIFY_ON_NOCHANGE" = "1" ] && notify "Mihomo Gateway (lite): no updates" "mihomo $_cur is current."
  exit "$EXIT_OK"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log_info "DRY-RUN - would update mihomo ${_cur:-unknown} -> $_tag"
  notify "Mihomo Gateway (lite, dry-run)" "Would update: mihomo ${_cur:-unknown} -> $_tag (resolved via $_res_mode)."
  exit "$EXIT_OK"
fi

# --- Backup -> verify ladder + atomic swap (#19) -> restart -> health gate ---
cp -p "$GATEWAY_DATA_DIR/bin/mihomo" "$GATEWAY_DATA_DIR/bin/mihomo.prev" || {
  log_error "could not save the rollback copy bin/mihomo.prev - nothing was changed"
  notify "Mihomo Gateway (lite): update aborted" "Could not write the rollback copy."
  exit "$EXIT_CONFIG"
}
if ! pi_lite_install_binary "$_tag"; then
  failed_n=1; failed_names=" mihomo"
  log_error "mihomo $_tag failed the download/verify ladder - the running binary is untouched"
  notify "Mihomo Gateway (lite): update completed WITH ERRORS" "updated:0 unchanged:0 failed:1 rolled_back:0
- mihomo $_tag: FAILED the download/verify ladder (running binary untouched)"
  exit "$EXIT_PARTIAL"
fi
log_info "swapped mihomo ${_cur:-unknown} -> $_tag (rollback copy: bin/mihomo.prev)"
systemctl restart mihomo-gateway >>"$LOG_FILE" 2>&1

if lite_health_gate; then
  updated_n=1; updated_names=" mihomo"
  log_info "lite auto-update completed OK"
  notify "Mihomo Gateway (lite): updated" "updated:1 unchanged:0 failed:0 rolled_back:0
- mihomo ${_cur:-unknown} -> $_tag: applied + healthy (resolved via $_res_mode)"
  exit "$EXIT_OK"
fi

# --- Rollback: restore the saved binary + version state, restart, re-gate ---
log_error "health gate failed - rolling back to ${_cur:-the previous binary}"
if cp -p "$GATEWAY_DATA_DIR/bin/mihomo.prev" "$GATEWAY_DATA_DIR/bin/mihomo"; then
  # Keep state/lite/version truthful about the binary on disk: the next
  # scheduled run then sees the OLD version and retries the update, matching
  # the compose path's retry-next-run semantics after a rollback.
  [ -n "$_cur" ] && printf '%s\n' "$_cur" > "$GATEWAY_DATA_DIR/state/lite/version"
  systemctl restart mihomo-gateway >>"$LOG_FILE" 2>&1
  if lite_health_gate; then
    rolled_n=1; rolled_names=" mihomo"
    log_error "lite auto-update completed WITH ERRORS (rolled back)"
    notify "Mihomo Gateway (lite): update completed WITH ERRORS" "updated:0 unchanged:0 failed:0 rolled_back:1
- mihomo: $_tag FAILED health -> ROLLED BACK to ${_cur:-previous} (now healthy)"
    exit "$EXIT_PARTIAL"
  fi
fi
failed_n=1; failed_names=" mihomo"
log_error "mihomo: FAILED health AND rollback incomplete -> MANUAL ATTENTION NEEDED (journalctl -u mihomo-gateway -n 50)"
notify "Mihomo Gateway (lite): update completed WITH ERRORS" "- mihomo: FAILED AND rollback incomplete -> MANUAL ATTENTION NEEDED (inspect journalctl -u mihomo-gateway)"
exit "$EXIT_PARTIAL"
}

if [ "${AUTO_UPDATE_SOURCE_ONLY:-0}" != 1 ]; then
  auto_update_lite_main "$@"
fi
