#!/bin/sh
# auto_update.sh - DSM-side image puller + safe redeployer for the mihomo gateway.
#
# Run by Synology DSM Task Scheduler (as root). Pulls the images listed in
# UPDATE_IMAGES plus every enrolled generic target (lib/targets.sh) from
# Alibaba ACR, detects which actually changed, and applies serially, lowest
# blast radius first (DEC-5: generic -> cloudflared -> compose gateway LAST):
#   - enrolled generic containers: in-place recreate via lib/container.sh with
#     a tiered health gate + saved-spec auto-restore + last-good persistence
#   - cloudflared (external): blue-green by name, preserving the tunnel token
#   - mihomo / metacubexd : `docker compose up -d` + health gate + auto-rollback
# Reports via Synology push notification + a rotating log file.
#
# Usage: auto_update.sh [--dry-run] [--force]
#   --dry-run : pull + detect + report, but DO NOT swap anything
#   --force   : ignore UPDATE_ENABLED=false kill-switch
#
# Exit: 0 ok/no-op | 2 partial failure | 3 config/preflight | 4 locked | 5 ACR login
# POSIX /bin/sh only (DSM BusyBox). No `set -e` - return codes are checked explicitly.

# Survive cron's stripped PATH on DSM.
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

SELF_DIR="${AUTO_UPDATE_SELF_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/lib/common.sh"
# shellcheck source=scripts/lib/notify.sh
. "$SELF_DIR/lib/notify.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SELF_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/compose.sh
. "$SELF_DIR/lib/compose.sh"
# shellcheck source=scripts/lib/cloudflared.sh
. "$SELF_DIR/lib/cloudflared.sh"
# shellcheck source=scripts/lib/targets.sh
. "$SELF_DIR/lib/targets.sh"

# write_last_run EXIT_CODE - one JSON object describing this run, written
# atomically on every terminal path (the EXIT trap). A lock-denied second run
# must not clobber the live run's record. Counters default to 0 on paths that
# abort before detection.
write_last_run() {
  _wlr_rc="$1"
  [ "$_wlr_rc" = "${EXIT_LOCKED:-4}" ] && return 0
  _wlr_dir="$GATEWAY_DATA_DIR/state"
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

# persist_last_good NAME IMAGE_ID - record the proven-good image + spec digest
# under GATEWAY_DATA_DIR/state/last-good/NAME. Written only after the health
# gate passes, so the record always points at a working combination; survives
# `image prune` for cross-run rollback.
persist_last_good() {
  _plg_name="$1"; _plg_id="$2"
  [ -n "$_plg_id" ] || return 1
  _plg_dir="$GATEWAY_DATA_DIR/state/last-good"
  mkdir -p "$_plg_dir" 2>/dev/null || return 1
  chmod 700 "$_plg_dir" 2>/dev/null || true
  _plg_digest=""
  if [ -n "${CTR_WORKDIR:-}" ] && [ -d "$CTR_WORKDIR" ]; then
    _plg_digest="$(find "$CTR_WORKDIR" -type f 2>/dev/null | LC_ALL=C sort | xargs cat 2>/dev/null | cksum | awk '{ print $1 }')"
  fi
  {
    printf 'image_id=%s\n' "$_plg_id"
    printf 'spec_digest=%s\n' "$_plg_digest"
    printf 'updated=%s\n' "$(_ts)"
  } >"$_plg_dir/$_plg_name.next" || return 1
  chmod 600 "$_plg_dir/$_plg_name.next" 2>/dev/null || return 1
  mv "$_plg_dir/$_plg_name.next" "$_plg_dir/$_plg_name" || return 1
}

# generic_health_gate NAME PROBE -> 0 healthy. The DEC-2 ladder: running ->
# stable/non-crash-looping RestartCount -> native healthcheck (when the image
# defines one) -> optional per-target probe. All probes run in-netns via
# docker exec/logs (the NAS cannot reach its own macvlan children).
generic_health_gate() {
  _ghg_name="$1"; _ghg_probe="$2"; _ghg_try=0; _ghg_floor_warned=0
  _ghg_rc_start="$("$DOCKER_BIN" inspect -f '{{.RestartCount}}' "$_ghg_name" 2>/dev/null)"
  _ghg_rc_start="${_ghg_rc_start:-0}"
  while [ "$_ghg_try" -lt "$HEALTH_RETRIES" ]; do
    _ghg_try=$((_ghg_try+1))
    _ghg_running="$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$_ghg_name" 2>/dev/null)"
    if [ "$_ghg_running" != true ]; then
      log_warn "health[$_ghg_try/$HEALTH_RETRIES]: $_ghg_name not running yet"
      sleep "$HEALTH_INTERVAL"; continue
    fi
    _ghg_rc1="$("$DOCKER_BIN" inspect -f '{{.RestartCount}}' "$_ghg_name" 2>/dev/null)"
    sleep "$HEALTH_INTERVAL"
    _ghg_rc2="$("$DOCKER_BIN" inspect -f '{{.RestartCount}}' "$_ghg_name" 2>/dev/null)"
    _ghg_running="$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$_ghg_name" 2>/dev/null)"
    if [ "$_ghg_running" != true ] || [ "${_ghg_rc1:-0}" != "${_ghg_rc2:-0}" ]; then
      log_warn "health[$_ghg_try/$HEALTH_RETRIES]: $_ghg_name unstable (running=$_ghg_running restarts $_ghg_rc1->$_ghg_rc2)"
      continue
    fi
    if [ "$(( ${_ghg_rc2:-0} - _ghg_rc_start ))" -ge "${HEALTH_MAX_RESTARTS:-3}" ]; then
      # RestartCount only ever grows: once the ceiling is crossed this verdict
      # can never clear, so give up now instead of burning the remaining tries.
      log_error "health: $_ghg_name crash-looping (restarted $(( ${_ghg_rc2:-0} - _ghg_rc_start ))x since deploy) - giving up"
      return 1
    fi
    _ghg_health="$("$DOCKER_BIN" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$_ghg_name" 2>/dev/null)"
    case "$_ghg_health" in
      healthy|none) : ;;
      *)
        log_warn "health[$_ghg_try/$HEALTH_RETRIES]: $_ghg_name native health=$_ghg_health"
        continue ;;
    esac
    case "$_ghg_probe" in
      exec:*)
        # Enrollment screened metacharacters; still split into argv ourselves
        # (glob expansion off) and exec without any shell interpolation.
        set -f
        # shellcheck disable=SC2086
        set -- ${_ghg_probe#exec:}
        set +f
        if ! "$DOCKER_BIN" exec "$_ghg_name" "$@" >/dev/null 2>&1; then
          log_warn "health[$_ghg_try/$HEALTH_RETRIES]: $_ghg_name exec probe failed"
          continue
        fi ;;
      log:*)
        if ! "$DOCKER_BIN" logs "$_ghg_name" 2>&1 | grep -Eq -- "${_ghg_probe#log:}"; then
          log_warn "health[$_ghg_try/$HEALTH_RETRIES]: $_ghg_name log marker not found"
          continue
        fi ;;
      '')
        if [ "$_ghg_health" = none ] && [ "$_ghg_floor_warned" -eq 0 ]; then
          _ghg_floor_warned=1
          log_warn "health: $_ghg_name has no healthcheck and no probe - floor-only gate (running + stable restarts)"
        fi ;;
    esac
    log_info "health: $_ghg_name passed (native=$_ghg_health probe=${_ghg_probe:-none})"
    return 0
  done
  log_error "health gate FAILED for $_ghg_name after $HEALTH_RETRIES tries"
  return 1
}

# generic_update_target NAME IMAGE PROBE -> 0 updated+healthy | 2 rolled back
# to the saved old image (now healthy) | 3 refused/aborted with the container
# UNTOUCHED (engine refusal, parity guard, rm failure) | 1 failed with
# rollback incomplete (manual attention).
# DEC-3: in-place recreate; on gate failure auto-restore from the saved spec
# and old image ID captured before anything was touched.
generic_update_target() {
  _gut_name="$1"; _gut_image="$2"; _gut_probe="$3"
  container_capture_spec "$_gut_name" || return 3
  container_parity_guard "$_gut_name" || { container_cleanup_workdir; return 3; }
  if ! "$DOCKER_BIN" rm -f "$_gut_name" >>"$LOG_FILE" 2>&1; then
    log_error "could not remove old container '$_gut_name'; nothing was changed"
    container_cleanup_workdir
    return 3
  fi
  if container_run_saved canonical "$_gut_name" "$_gut_image" \
     && generic_health_gate "$_gut_name" "$_gut_probe"; then
    persist_last_good "$_gut_name" "$(local_image_id "$_gut_image")" \
      || log_warn "could not persist the last-good record for '$_gut_name'"
    container_cleanup_workdir
    return 0
  fi
  log_error "generic update failed for '$_gut_name' - restoring the saved container"
  if container_restore_old "$_gut_name" && generic_health_gate "$_gut_name" "$_gut_probe"; then
    container_cleanup_workdir
    return 2
  fi
  container_cleanup_workdir
  return 1
}

auto_update_main() {

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
# .env timezone is authoritative regardless of NAS system tz.
[ -n "${UPDATE_TZ:-}" ] && { TZ="$UPDATE_TZ"; export TZ; }

# shellcheck disable=SC2329  # invoked indirectly via trap
on_exit() {
  _oe_rc=$?
  write_last_run "$_oe_rc"
  release_lock
  # A dry run must stay read-only: never reap candidate containers from it.
  if [ "${DRY_RUN:-0}" -ne 1 ]; then
    [ -n "${DOCKER_BIN:-}" ] && [ -n "${CF_CONTAINER_NAME:-}" ] && cloudflared_cleanup_candidate >/dev/null 2>&1
  fi
  cloudflared_cleanup_workdir
}
# Signals must TERMINATE, not resume: a trap that merely runs cleanup and
# returns would release the lock and delete workdirs while the interrupted
# update keeps executing. `exit` inside a signal trap fires the EXIT trap
# exactly once, so cleanup still happens - at real termination.
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_lock
log_info "=== auto-update start (dry_run=$DRY_RUN force=$FORCE) ==="

# Validate the boolean before interpreting it. A typo such as
# UPDATE_ENABLED=False must fail loudly, not silently disable updates.
validate_update_switch || {
  notify "Mihomo Gateway: update aborted" "UPDATE_ENABLED must be true or false."
  exit "$EXIT_CONFIG"
}

# Kill-switch.
if [ "$UPDATE_ENABLED" != "true" ] && [ "$FORCE" -ne 1 ]; then
  log_info "UPDATE_ENABLED=$UPDATE_ENABLED - disabled. Use --force to override. Exiting."
  exit "$EXIT_OK"
fi

# With updates enabled, validate all remaining data-only settings before
# waiting for Docker or contacting the registry.
validate_update_config || {
  notify "Mihomo Gateway: update aborted" "Invalid auto-update settings in .env."
  exit "$EXIT_CONFIG"
}

# --- Preflight (abort touching nothing on any failure) ---
wait_for_docker_ready || { notify "Mihomo Gateway: update aborted" "Container Manager/Docker did not become ready."; exit "$EXIT_CONFIG"; }
check_arch_expectation || { notify "Mihomo Gateway: update aborted" "EXPECTED_ARCH does not match this NAS."; exit "$EXIT_CONFIG"; }
check_tun            || { notify "Mihomo Gateway: update aborted" "/dev/net/tun missing - run setup_network.sh."; exit "$EXIT_CONFIG"; }
check_network        || { notify "Mihomo Gateway: update aborted" "tproxy_network missing/mismatched - run setup_network.sh."; exit "$EXIT_CONFIG"; }
compose_config_check || { notify "Mihomo Gateway: update aborted" "Docker Compose configuration is invalid."; exit "$EXIT_CONFIG"; }
acr_login            || { notify "Mihomo Gateway: update aborted" "ACR login failed - check ACR_PASSWORD/token."; exit "$EXIT_LOGIN"; }

# --- Detect changes (pull, arch-check, compare running-vs-local) ---
compose_changed=0; cf_changed=0; changed_any=0; fail=0
mihomo_old=""; meta_old=""; summary=""
updated_n=0; unchanged_n=0; failed_n=0; rolled_n=0
updated_names=""; failed_names=""; rolled_names=""
compose_marked=0; compose_marked_names=""

for img in $UPDATE_IMAGES; do
  [ -n "$img" ] || continue
  log_info "checking $img"
  if ! pull_image "$img"; then
    fail=1; failed_n=$((failed_n + 1)); failed_names="$failed_names $img"; summary="$summary
- PULL FAILED: $img$(pull_failure_hint)"; continue
  fi
  if ! arch_ok "$img"; then
    fail=1; failed_n=$((failed_n + 1)); failed_names="$failed_names $img"; summary="$summary
- ARCH MISMATCH (skipped): $img"; continue
  fi
  case "$img" in
    "$MIHOMO_IMAGE")
      if deploy_needed "$img" "$MIHOMO_CONTAINER"; then
        compose_changed=1; changed_any=1; compose_marked=$((compose_marked + 1))
        compose_marked_names="$compose_marked_names mihomo"
        mihomo_old="$(running_image_id "$MIHOMO_CONTAINER")"
        summary="$summary
- update: mihomo"
      else
        unchanged_n=$((unchanged_n + 1))
      fi ;;
    "$METACUBEXD_IMAGE")
      if deploy_needed "$img" "$METACUBEXD_CONTAINER"; then
        compose_changed=1; changed_any=1; compose_marked=$((compose_marked + 1))
        compose_marked_names="$compose_marked_names metacubexd"
        meta_old="$(running_image_id "$METACUBEXD_CONTAINER")"
        summary="$summary
- update: metacubexd"
      else
        unchanged_n=$((unchanged_n + 1))
      fi ;;
    "$CF_IMAGE")
      if deploy_needed "$img" "$CF_CONTAINER_NAME"; then
        cf_changed=1; changed_any=1
        summary="$summary
- update: cloudflared"
      else
        unchanged_n=$((unchanged_n + 1))
      fi ;;
    *)
      log_warn "pulled but mapped to NO deploy target (cache only): $img -- set MIHOMO_IMAGE/METACUBEXD_IMAGE/CF_IMAGE to this ref if it should drive a deploy" ;;
  esac
done

# --- Detect changes (enrolled generic targets) ---
# targets_discover already applied the eligibility policy (enrolled + running
# + ACR ref, minus the trio/compose/ambiguous/denylist); stdout is data-only.
GEN_QUEUE=""
_gen_list="$(targets_discover 2>>"$LOG_FILE")" || {
  fail=1; failed_n=$((failed_n + 1)); summary="$summary
- generic targets: INVALID enrollment list (see log)"; _gen_list=""
}
if [ -n "$_gen_list" ]; then
  while IFS='|' read -r _g_name _g_image _g_strategy _g_probe; do
    [ -n "$_g_name" ] || continue
    log_info "checking generic target $_g_name ($_g_image)"
    if ! pull_image "$_g_image"; then
      fail=1; failed_n=$((failed_n + 1)); failed_names="$failed_names $_g_name"; summary="$summary
- PULL FAILED: $_g_name ($_g_image)$(pull_failure_hint)"; continue
    fi
    if ! arch_ok "$_g_image"; then
      fail=1; failed_n=$((failed_n + 1)); failed_names="$failed_names $_g_name"; summary="$summary
- ARCH MISMATCH (skipped): $_g_name ($_g_image)"; continue
    fi
    if deploy_needed "$_g_image" "$_g_name"; then
      changed_any=1
      GEN_QUEUE="$GEN_QUEUE$_g_name|$_g_image|$_g_probe
"
      summary="$summary
- update: $_g_name"
    else
      unchanged_n=$((unchanged_n + 1))
    fi
  done <<GEN_EOF
$_gen_list
GEN_EOF
fi

# --- Nothing to do / dry-run short-circuits ---
if [ "$changed_any" -eq 0 ] && [ "$fail" -eq 0 ]; then
  log_info "no image changes."
  [ "$NOTIFY_ON_NOCHANGE" = "1" ] && notify "Mihomo Gateway: no updates" "All tracked images are current."
  exit "$EXIT_OK"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  # The TUN auto-redirect probe below runs a privileged container; a dry run
  # must not, so it only notes that the probe would gate the real apply.
  [ "$compose_changed" -eq 1 ] && [ "${TUN_AUTO_REDIRECT:-false}" = true ] && summary="$summary
- note: TUN auto-redirect compatibility will be probed before the compose apply"
  log_info "DRY-RUN - would apply:$summary"
  notify "Mihomo Gateway (dry-run)" "Would apply:$summary"
  [ "$fail" -eq 1 ] && exit "$EXIT_PARTIAL"
  exit "$EXIT_OK"
fi

# An image can be valid for this architecture yet carry an nft-backed iptables
# frontend that the DSM kernel cannot service. Prove an explicit auto-redirect
# opt-in before any Compose recreation; keep unrelated cloudflared work eligible.
if [ "$compose_changed" -eq 1 ] && ! mihomo_auto_redirect_probe "$MIHOMO_IMAGE"; then
  fail=1; compose_changed=0; failed_n=$((failed_n + compose_marked))
  failed_names="$failed_names$compose_marked_names"
  summary="$summary
- compose: SKIPPED (TUN auto-redirect incompatible; set TUN_AUTO_REDIRECT=false)"
fi

# --- Apply, strictly serial, lowest blast radius first (DEC-5):
# generic targets -> cloudflared -> the compose gateway pair LAST, so every
# earlier step still rides a known-good gateway and the highest-risk change
# happens when everything else has already settled.

# --- Apply: enrolled generic targets (in-place recreate + tiered gate) ---
if [ -n "$GEN_QUEUE" ]; then
  while IFS='|' read -r _g_name _g_image _g_probe; do
    [ -n "$_g_name" ] || continue
    log_info "applying generic target $_g_name"
    generic_update_target "$_g_name" "$_g_image" "$_g_probe"
    case "$?" in
      0)
        updated_n=$((updated_n + 1)); updated_names="$updated_names $_g_name"; summary="$summary
- $_g_name: applied + healthy" ;;
      2)
        fail=1; rolled_n=$((rolled_n + 1)); rolled_names="$rolled_names $_g_name"; summary="$summary
- $_g_name: FAILED health -> ROLLED BACK to last-good (now healthy)" ;;
      3)
        fail=1; failed_n=$((failed_n + 1)); failed_names="$failed_names $_g_name"; summary="$summary
- $_g_name: REFUSED (not replayable - container untouched; see log, or de-enroll it)" ;;
      *)
        fail=1; failed_n=$((failed_n + 1)); failed_names="$failed_names $_g_name"; summary="$summary
- $_g_name: FAILED AND rollback incomplete -> MANUAL ATTENTION NEEDED" ;;
    esac
  done <<GEN_EOF
$GEN_QUEUE
GEN_EOF
fi

# --- Apply: cloudflared blue-green ---
if [ "$cf_changed" -eq 1 ]; then
  log_info "applying cloudflared blue-green"
  if cloudflared_blue_green; then
    updated_n=$((updated_n + 1)); updated_names="$updated_names cloudflared"; summary="$summary
- cloudflared: canonical container updated + connected (token preserved)"
  else
    fail=1
    case "${CF_BG_OUTCOME:-}" in
      rolled_back)
        rolled_n=$((rolled_n + 1)); rolled_names="$rolled_names cloudflared"; summary="$summary
- cloudflared: update FAILED -> ROLLED BACK to the previous connector (now connected)" ;;
      manual)
        failed_n=$((failed_n + 1)); failed_names="$failed_names cloudflared"; summary="$summary
- cloudflared: FAILED AND canonical not restored -> MANUAL ATTENTION NEEDED (the -candidate container may be the only live connector - do not remove it)" ;;
      *)
        failed_n=$((failed_n + 1)); failed_names="$failed_names cloudflared"; summary="$summary
- cloudflared: update FAILED (candidate discarded; the old connector is untouched)" ;;
    esac
  fi
fi

# --- Apply: compose services (single up -d; recreates only what changed) ---
if [ "$compose_changed" -eq 1 ]; then
  log_info "applying validated local images (docker compose up -d --pull never when supported)"
  if compose_up_local; then
    if health_gate; then
      updated_n=$((updated_n + compose_marked)); updated_names="$updated_names$compose_marked_names"; summary="$summary
- compose: applied + healthy"
    else
      log_error "health gate failed - rolling back to last-good image(s)"
      if rollback_compose "$mihomo_old" "$meta_old" && health_gate; then
        rolled_n=$((rolled_n + compose_marked)); rolled_names="$rolled_names$compose_marked_names"; summary="$summary
- compose: FAILED health -> ROLLED BACK to last-good (now healthy)"
      else
        failed_n=$((failed_n + compose_marked)); failed_names="$failed_names$compose_marked_names"; summary="$summary
- compose: FAILED health AND rollback incomplete -> MANUAL ATTENTION NEEDED"
      fi
      fail=1
    fi
  else
    log_error "docker compose up -d failed"
    if rollback_compose "$mihomo_old" "$meta_old" && health_gate; then
      rolled_n=$((rolled_n + compose_marked)); rolled_names="$rolled_names$compose_marked_names"; summary="$summary
- compose: APPLY FAILED -> ROLLED BACK to last-good (now healthy)"
    else
      failed_n=$((failed_n + compose_marked)); failed_names="$failed_names$compose_marked_names"; summary="$summary
- compose: APPLY FAILED AND rollback incomplete -> MANUAL ATTENTION NEEDED"
    fi
    fail=1
  fi
fi

# --- Hygiene: prune dangling layers only on full success (keeps rollback targets within a run) ---
if [ "$fail" -eq 0 ]; then
  "$DOCKER_BIN" image prune -f >>"$LOG_FILE" 2>&1 || true
fi

# --- Report (sectioned: counts first, then the per-target bullet detail) ---
summary="updated:$updated_n unchanged:$unchanged_n failed:$failed_n rolled_back:$rolled_n
$summary"
if [ "$fail" -eq 1 ]; then
  log_error "auto-update completed WITH ERRORS"
  notify "Mihomo Gateway: update completed WITH ERRORS" "$summary"
  exit "$EXIT_PARTIAL"
fi
log_info "auto-update completed OK"
notify "Mihomo Gateway: updated" "$summary"
exit "$EXIT_OK"
}

if [ "${AUTO_UPDATE_SOURCE_ONLY:-0}" != 1 ]; then
  auto_update_main "$@"
fi
