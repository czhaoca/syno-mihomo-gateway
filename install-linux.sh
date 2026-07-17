#!/bin/sh
# install-linux.sh - guided, menu-driven installer for the Mihomo transparent-
# proxy gateway on a generic Linux host (amd64 + arm64). Run it from inside the
# unpacked folder:
#
#     sh ./install-linux.sh
#
# ADDITIVE entry point (epic generic-linux-port): the DSM installer (install.sh)
# and the Pi entry (install-pi.sh) are untouched; this entry sources the same
# shared runtime libraries and installer modules, the UNCHANGED scripts/pi/
# engine, and last the scripts/linux/ overlay for generic phrasing. A mode
# wizard recommends the install flavor from the detected hardware:
#   - Docker compose mode reuses the full DSM-proven deploy pipeline
#     (digest-gated pulls, health gate, rollback) - needs a 64-bit OS + 1 GB RAM.
#   - Bare-metal "lite" mode: mihomo runs as a native binary with its built-in
#     dashboard - no Docker, no macvlan (works on hosts where macvlan cannot).
#
# POSIX /bin/sh. Root is required for the deploy/network steps (TUN device,
# macvlan, docker); the installer detects this and tells you how to re-run.

# SMG_INSTALL_ROOT lets the CI harness source this file from another directory
# (INSTALL_SOURCE_ONLY=1); interactively $0 always resolves the bundle folder.
REPO_ROOT="${SMG_INSTALL_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
LIB="$REPO_ROOT/scripts/lib"
INST="$REPO_ROOT/scripts/installer"
PI="$REPO_ROOT/scripts/pi"
LX="$REPO_ROOT/scripts/linux"

# --- source the runtime libraries and installer modules (fixed order) ---------
# Same set and order as install-pi.sh; the linux overlay comes last so its
# i18n delta and rerun-hint retarget win without touching the pi engine.
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
# --- the pi engine (unchanged; the generic entry reuses it wholesale) ----------
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
# --- the linux overlay (never sourced by install.sh or install-pi.sh) ----------
# shellcheck source=scripts/linux/i18n_linux.sh
. "$LX/i18n_linux.sh"
# shellcheck source=scripts/linux/preflight_linux.sh
. "$LX/preflight_linux.sh"

# Restore terminal echo if a secret prompt or Ctrl-C left it off; on interrupt
# also reap the config staging dir (holds the subscription URL) and the
# lite_ctl filter buffer, and close the loop like install.sh does.
# shellcheck disable=SC2329  # invoked indirectly via trap
_on_exit() {
  stty echo </dev/tty 2>/dev/null
  [ -n "${SMG_LX_LC_TMP:-}" ] && rm -f "$SMG_LX_LC_TMP" 2>/dev/null
}
# shellcheck disable=SC2329  # invoked indirectly via trap
_on_int() {
  stty echo </dev/tty 2>/dev/null
  [ -n "${SMG_CFG_STAGE:-}" ] && rm -rf "$SMG_CFG_STAGE" 2>/dev/null
  [ -n "${SMG_LX_LC_TMP:-}" ] && rm -f "$SMG_LX_LC_TMP" 2>/dev/null
  printf '\n%s\n' "$(msg warn_interrupted 2>/dev/null || echo 'interrupted - partial state is detected on the next run')" >&2
  exit 130
}

# _lm_banner - one line of live state above the menu (compose-mode stack state;
# mirrors install-pi.sh's _pm_banner). Read-only; every failure degrades cleanly.
_lm_banner() {
  [ -f "$ENV_FILE" ] && dotenv_load "$ENV_FILE" >/dev/null 2>&1
  case "$(stack_state 2>/dev/null)" in
    deployed)
      _lb_host="$(_iface_ipv4 "${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}" 2>/dev/null)"
      [ -n "$_lb_host" ] || _lb_host='<host-IP>'
      ui_say "$(msgf st_deployed "${MIHOMO_IP:-?}" "$_lb_host" "${WEB_UI_PORT:-8080}")" ;;
    partial)
      ui_say "$(msg st_partial)" ;;
    *)
      ui_say "$(msg st_fresh)" ;;
  esac
}

# _run_doctor - seam for tests; interactively this is the real diagnostics run.
_run_doctor() { sh "$REPO_ROOT/scripts/doctor.sh"; }
# _lx_lite_ctl VERB - lite-mode status/doctor come from lite_ctl (same seams
# install-pi.sh uses), but lite_ctl runs as a SUBPROCESS sourcing its own
# catalogs, so the i18n overlay cannot reach its two Pi-worded literals
# (the '<Pi-IP>' dashboard placeholder and the "(Raspberry Pi OS: ...)"
# port-53 hint); rebrand them here instead - scripts/pi/ stays frozen. Output
# is buffered so the child's exit code survives the filter; the buffer merges
# stderr into stdout (a status/diagnose surface - both streams are for the
# operator's eyes). If mktemp fails, degrade to the unfiltered run.
_lx_lite_ctl() {
  _ll_tmp="$(mktemp 2>/dev/null)" || {
    sh "$REPO_ROOT/scripts/pi/lite_ctl.sh" "$1"
    return $?
  }
  SMG_LX_LC_TMP="$_ll_tmp"
  sh "$REPO_ROOT/scripts/pi/lite_ctl.sh" "$1" >"$_ll_tmp" 2>&1
  _ll_rc=$?
  sed -e 's/<Pi-IP>/<host-IP>/g' -e 's/(Raspberry Pi OS: /(/g' "$_ll_tmp"
  rm -f "$_ll_tmp"
  SMG_LX_LC_TMP=''
  return "$_ll_rc"
}
_run_lite_status() { _lx_lite_ctl status; }
_run_lite_doctor() { _lx_lite_ctl doctor; }

# linux_menu_status_flow - read-only status summary + optional doctor run,
# dispatched on the install-mode marker (tokens stay pi-lite/pi-compose per the
# epic constraints): a lite box has no containers to inspect, so it routes to
# lite_ctl; anything else keeps the compose surfaces (mirrors install-pi.sh's
# pi_menu_status_flow).
linux_menu_status_flow() {
  ui_step "$(msg status_title)"
  if [ "$(cat "$GATEWAY_DATA_DIR/state/install-mode" 2>/dev/null)" = pi-lite ]; then
    _run_lite_status
    if ui_yesno "$(msg ask_run_doctor)" n; then
      if _run_lite_doctor; then
        ui_ok "$(msg ok_doctor_done)"
      else
        ui_warn "$(msgf warn_doctor_rc "$?")"
      fi
    fi
    return 0
  fi
  [ -f "$ENV_FILE" ] && dotenv_load "$ENV_FILE" >/dev/null 2>&1
  lifecycle_inspect 2>/dev/null
  ui_say "$(msgf status_state "$(stack_state 2>/dev/null)")"
  ui_say "$(msgf status_mihomo "${LIFECYCLE_MIHOMO_STATUS:-absent}" "${MIHOMO_IP:-?}")"
  ui_say "$(msgf status_ui "${LIFECYCLE_UI_STATUS:-absent}")"
  _ls_host="$(_iface_ipv4 "${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}" 2>/dev/null)"
  [ -n "$_ls_host" ] || _ls_host='<host-IP>'
  ui_say "$(msgf status_dashboard "$_ls_host" "${WEB_UI_PORT:-8080}")"
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

main_menu_linux() {
  while :; do
    ui_say ""
    ui_say "${C_BOLD}$(msg pi_title)${C_RESET}"
    _lm_banner
    ui_menu_select _choice "$(msg menu_action)" \
      "$(msg pi_menu_deploy)" \
      "$(msg menu_redeploy)" \
      "$(msg menu_cron)" \
      "$(msg menu_modify)" \
      "$(msg menu_status)" \
      "$(msg menu_quit)"
    case "$UI_MENU_INDEX" in
      1) pi_flow_deploy_entry || ui_warn "$(msg warn_deploy_unfinished)" ;;
      2) pi_flow_redeploy     || ui_warn "$(msg warn_redeploy_unfinished)" ;;
      3) pi_flow_cron         || ui_warn "$(msg warn_cron_unfinished)" ;;
      4) flow_modify ;;
      5) linux_menu_status_flow ;;
      6) ui_say "$(msg bye)"; return 0 ;;
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
  echo "install-linux.sh is interactive - run it in a terminal:  sh ./install-linux.sh" >&2
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

main_menu_linux
exit "${EXIT_OK:-0}"

fi
