#!/bin/sh
# install-pi.sh - guided, menu-driven installer for the Mihomo transparent-proxy
# gateway on a Raspberry Pi (generic Linux). Run it from inside the unpacked
# folder:
#
#     sh ./install-pi.sh
#
# ADDITIVE entry point (epic raspberry-pi-port): the DSM installer (install.sh)
# is untouched; this entry sources the same shared runtime libraries and
# installer modules, plus the scripts/pi/ overlay. A mode wizard recommends the
# install flavor from the detected hardware:
#   - Docker compose mode reuses the full DSM-proven deploy pipeline
#     (digest-gated pulls, health gate, rollback) - needs a 64-bit OS + 1 GB RAM.
#   - Bare-metal "lite" mode (256-512 MB tier, ARMv6 best-effort): mihomo runs
#     as a native binary with its built-in dashboard - no Docker, no macvlan.
#
# POSIX /bin/sh. Root is required for the deploy/network steps (TUN device,
# macvlan, docker); the installer detects this and tells you how to re-run.

# SMG_INSTALL_ROOT lets the CI harness source this file from another directory
# (INSTALL_SOURCE_ONLY=1); interactively $0 always resolves the bundle folder.
REPO_ROOT="${SMG_INSTALL_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
LIB="$REPO_ROOT/scripts/lib"
INST="$REPO_ROOT/scripts/installer"
PI="$REPO_ROOT/scripts/pi"

# --- source the runtime libraries and installer modules (fixed order) ---------
# Same set and order as install.sh; the pi overlay comes last so its i18n
# overlay and preflights win without touching the stock modules.
# shellcheck source=scripts/lib/common.sh
. "$LIB/common.sh"
# shellcheck source=scripts/lib/scheduler.sh
. "$LIB/scheduler.sh"
# shellcheck source=scripts/installer/ui.sh
. "$INST/ui.sh"
# shellcheck source=scripts/installer/i18n.sh
. "$INST/i18n.sh"
# shellcheck source=scripts/lib/notify.sh
. "$LIB/notify.sh"
# shellcheck source=scripts/lib/registry.sh
. "$LIB/registry.sh"
# shellcheck source=scripts/lib/compose.sh
. "$LIB/compose.sh"
# shellcheck source=scripts/lib/cloudflared.sh
. "$LIB/cloudflared.sh"
# shellcheck source=scripts/lib/targets.sh
. "$LIB/targets.sh"
# shellcheck source=scripts/lib/network.sh
. "$LIB/network.sh"
# shellcheck source=scripts/lib/lifecycle.sh
. "$LIB/lifecycle.sh"
# shellcheck source=scripts/lib/resolve.sh
. "$LIB/resolve.sh"
# shellcheck source=scripts/installer/envedit.sh
. "$INST/envedit.sh"
# shellcheck source=scripts/installer/preflight.sh
. "$INST/preflight.sh"
# shellcheck source=scripts/installer/netscan.sh
. "$INST/netscan.sh"
# shellcheck source=scripts/installer/preprocess.sh
. "$INST/preprocess.sh"
# shellcheck source=scripts/installer/wizards.sh
. "$INST/wizards.sh"
# shellcheck source=scripts/installer/flow_deploy.sh
. "$INST/flow_deploy.sh"
# shellcheck source=scripts/installer/flow_redeploy.sh
. "$INST/flow_redeploy.sh"
# shellcheck source=scripts/installer/flow_targets.sh
. "$INST/flow_targets.sh"
# shellcheck source=scripts/installer/flow_modify.sh
. "$INST/flow_modify.sh"
# --- the pi overlay (never sourced by install.sh) ------------------------------
# shellcheck source=scripts/pi/detect.sh
. "$PI/detect.sh"
# shellcheck source=scripts/pi/preflight.sh
. "$PI/preflight.sh"
# shellcheck source=scripts/pi/i18n_pi.sh
. "$PI/i18n_pi.sh"
# shellcheck source=scripts/pi/lite.sh
. "$PI/lite.sh"
# shellcheck source=scripts/pi/flow_compose.sh
. "$PI/flow_compose.sh"
# shellcheck source=scripts/pi/flow_lite.sh
. "$PI/flow_lite.sh"

# Restore terminal echo if a secret prompt or Ctrl-C left it off; on interrupt
# also reap the config staging dir (holds the subscription URL) and close the
# loop like install.sh does.
# shellcheck disable=SC2329  # invoked indirectly via trap
_on_exit() { stty echo </dev/tty 2>/dev/null; }
# shellcheck disable=SC2329  # invoked indirectly via trap
_on_int() {
  stty echo </dev/tty 2>/dev/null
  [ -n "${SMG_CFG_STAGE:-}" ] && rm -rf "$SMG_CFG_STAGE" 2>/dev/null
  printf '\n%s\n' "$(msg warn_interrupted 2>/dev/null || echo 'interrupted - partial state is detected on the next run')" >&2
  exit 130
}

# _pm_banner - one line of live state above the menu (compose-mode stack state;
# mirrors install.sh's _mm_banner). Read-only; every failure degrades cleanly.
_pm_banner() {
  [ -f "$ENV_FILE" ] && dotenv_load "$ENV_FILE" >/dev/null 2>&1
  case "$(stack_state 2>/dev/null)" in
    deployed)
      _pb_host="$(_iface_ipv4 "${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}" 2>/dev/null)"
      [ -n "$_pb_host" ] || _pb_host='<Pi-IP>'
      ui_say "$(msgf st_deployed "${MIHOMO_IP:-?}" "$_pb_host" "${WEB_UI_PORT:-8080}")" ;;
    partial)
      ui_say "$(msg st_partial)" ;;
    *)
      ui_say "$(msg st_fresh)" ;;
  esac
}

# _run_doctor - seam for tests; interactively this is the real diagnostics run.
_run_doctor() { sh "$REPO_ROOT/scripts/doctor.sh"; }

# pi_menu_status_flow - read-only status summary + optional doctor run
# (mirrors install.sh's menu_status_flow; compose-mode surfaces are identical).
pi_menu_status_flow() {
  ui_step "$(msg status_title)"
  [ -f "$ENV_FILE" ] && dotenv_load "$ENV_FILE" >/dev/null 2>&1
  lifecycle_inspect 2>/dev/null
  ui_say "$(msgf status_state "$(stack_state 2>/dev/null)")"
  ui_say "$(msgf status_mihomo "${LIFECYCLE_MIHOMO_STATUS:-absent}" "${MIHOMO_IP:-?}")"
  ui_say "$(msgf status_ui "${LIFECYCLE_UI_STATUS:-absent}")"
  _ps_host="$(_iface_ipv4 "${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}" 2>/dev/null)"
  [ -n "$_ps_host" ] || _ps_host='<Pi-IP>'
  ui_say "$(msgf status_dashboard "$_ps_host" "${WEB_UI_PORT:-8080}")"
  ui_say "$(msgf status_tun "${TUN_ENABLE:-true}")"
  if ui_yesno "$(msg ask_run_doctor)" n; then
    if _run_doctor; then
      ui_ok "$(msg ok_doctor_done)"
    else
      ui_warn "$(msgf warn_doctor_rc "$?")"
    fi
  fi
  return 0
}

main_menu_pi() {
  while :; do
    ui_say ""
    ui_say "${C_BOLD}$(msg pi_title)${C_RESET}"
    _pm_banner
    ui_menu_select _choice "$(msg menu_action)" \
      "$(msg pi_menu_deploy)" \
      "$(msg menu_redeploy)" \
      "$(msg menu_modify)" \
      "$(msg menu_status)" \
      "$(msg menu_quit)"
    case "$UI_MENU_INDEX" in
      1) pi_flow_deploy_entry || ui_warn "$(msg warn_deploy_unfinished)" ;;
      2) pi_flow_redeploy     || ui_warn "$(msg warn_redeploy_unfinished)" ;;
      3) flow_modify ;;
      4) pi_menu_status_flow ;;
      5) ui_say "$(msg bye)"; return 0 ;;
    esac
  done
}

# --- entry --------------------------------------------------------------------
# Guarded so the CI harness can source the definitions above without running
# the interactive entry (INSTALL_SOURCE_ONLY=1; see scripts/ci).
if [ "${INSTALL_SOURCE_ONLY:-0}" != 1 ]; then

ensure_persistent_state || {
  echo "FATAL: cannot create persistent data directory: $GATEWAY_DATA_DIR" >&2
  exit "${EXIT_CONFIG:-3}"
}

INSTALL_LOG="${INSTALL_LOG:-$GATEWAY_DATA_DIR/logs/install.log}"
mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null
export INSTALL_LOG

trap _on_exit EXIT
trap _on_int INT TERM

if [ ! -r /dev/tty ]; then
  echo "install-pi.sh is interactive - run it in a terminal:  sh ./install-pi.sh" >&2
  exit "${EXIT_CONFIG:-3}"
fi

choose_language

ui_step "$(msg pi_step_installer)"

ui_info "$(msg info_check_loc)"
if ! pi_check_location; then
  ui_error "$(msg err_loc_blocked)"
  exit "${EXIT_CONFIG:-3}"
fi

if ! is_root; then
  ui_warn "$(msg warn_not_root)"
  ui_warn "$(msg warn_not_root2)"
  pi_sudo_rerun_hint
fi

main_menu_pi
exit "${EXIT_OK:-0}"

fi
