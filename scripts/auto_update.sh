#!/bin/sh
# auto_update.sh - DSM-side image puller + safe redeployer for the mihomo gateway.
#
# Run by Synology DSM Task Scheduler (as root). Pulls the images listed in
# UPDATE_IMAGES from Alibaba ACR, detects which actually changed, and applies:
#   - mihomo / metacubexd : `docker compose up -d` + health gate + auto-rollback
#   - cloudflared (external): blue-green by name, preserving the tunnel token
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
  release_lock
  [ -n "${DOCKER_BIN:-}" ] && [ -n "${CF_CONTAINER_NAME:-}" ] && cloudflared_cleanup_candidate >/dev/null 2>&1
  cloudflared_cleanup_workdir
}
trap on_exit EXIT INT TERM

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

for img in $UPDATE_IMAGES; do
  [ -n "$img" ] || continue
  log_info "checking $img"
  if ! pull_image "$img"; then
    fail=1; summary="$summary
- PULL FAILED: $img"; continue
  fi
  if ! arch_ok "$img"; then
    fail=1; summary="$summary
- ARCH MISMATCH (skipped): $img"; continue
  fi
  case "$img" in
    "$MIHOMO_IMAGE")
      if deploy_needed "$img" "$MIHOMO_CONTAINER"; then
        compose_changed=1; changed_any=1
        mihomo_old="$(running_image_id "$MIHOMO_CONTAINER")"
        summary="$summary
- update: mihomo"
      fi ;;
    "$METACUBEXD_IMAGE")
      if deploy_needed "$img" "$METACUBEXD_CONTAINER"; then
        compose_changed=1; changed_any=1
        meta_old="$(running_image_id "$METACUBEXD_CONTAINER")"
        summary="$summary
- update: metacubexd"
      fi ;;
    "$CF_IMAGE")
      if deploy_needed "$img" "$CF_CONTAINER_NAME"; then
        cf_changed=1; changed_any=1
        summary="$summary
- update: cloudflared"
      fi ;;
    *)
      log_warn "pulled but mapped to NO deploy target (cache only): $img -- set MIHOMO_IMAGE/METACUBEXD_IMAGE/CF_IMAGE to this ref if it should drive a deploy" ;;
  esac
done

# An image can be valid for this architecture yet carry an nft-backed iptables
# frontend that the DSM kernel cannot service. Prove an explicit auto-redirect
# opt-in before any Compose recreation; keep unrelated cloudflared work eligible.
if [ "$compose_changed" -eq 1 ] && ! mihomo_auto_redirect_probe "$MIHOMO_IMAGE"; then
  fail=1; compose_changed=0
  summary="$summary
- compose: SKIPPED (TUN auto-redirect incompatible; set TUN_AUTO_REDIRECT=false)"
fi

# --- Nothing to do / dry-run short-circuits ---
if [ "$changed_any" -eq 0 ] && [ "$fail" -eq 0 ]; then
  log_info "no image changes."
  [ "$NOTIFY_ON_NOCHANGE" = "1" ] && notify "Mihomo Gateway: no updates" "All tracked images are current."
  exit "$EXIT_OK"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log_info "DRY-RUN - would apply:$summary"
  notify "Mihomo Gateway (dry-run)" "Would apply:$summary"
  [ "$fail" -eq 1 ] && exit "$EXIT_PARTIAL"
  exit "$EXIT_OK"
fi

# --- Apply: compose services (single up -d; recreates only what changed) ---
if [ "$compose_changed" -eq 1 ]; then
  log_info "applying validated local images (docker compose up -d --pull never when supported)"
  if compose_up_local; then
    if health_gate; then
      summary="$summary
- compose: applied + healthy"
    else
      log_error "health gate failed - rolling back to last-good image(s)"
      if rollback_compose "$mihomo_old" "$meta_old" && health_gate; then
        summary="$summary
- compose: FAILED health -> ROLLED BACK to last-good (now healthy)"
      else
        summary="$summary
- compose: FAILED health AND rollback incomplete -> MANUAL ATTENTION NEEDED"
      fi
      fail=1
    fi
  else
    log_error "docker compose up -d failed"
    if rollback_compose "$mihomo_old" "$meta_old" && health_gate; then
      summary="$summary
- compose: APPLY FAILED -> ROLLED BACK to last-good (now healthy)"
    else
      summary="$summary
- compose: APPLY FAILED AND rollback incomplete -> MANUAL ATTENTION NEEDED"
    fi
    fail=1
  fi
fi

# --- Apply: cloudflared blue-green ---
if [ "$cf_changed" -eq 1 ]; then
  log_info "applying cloudflared blue-green"
  if cloudflared_blue_green; then
    summary="$summary
- cloudflared: canonical container updated + connected (token preserved)"
  else
    summary="$summary
- cloudflared: update FAILED (old left running / rolled back)"
    fail=1
  fi
fi

# --- Hygiene: prune dangling layers only on full success (keeps rollback targets within a run) ---
if [ "$fail" -eq 0 ]; then
  "$DOCKER_BIN" image prune -f >>"$LOG_FILE" 2>&1 || true
fi

# --- Report ---
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
