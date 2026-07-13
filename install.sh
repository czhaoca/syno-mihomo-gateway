#!/bin/sh
# install.sh - guided, menu-driven installer for the Mihomo transparent-proxy
# gateway on Synology DSM. Run it from inside the unpacked folder:
#
#     sh ./install.sh
#
# It walks you through one of three actions:
#   1. Deploy the gateway end-to-end (config -> network -> images -> start)
#   2. Set up the automatic image-update schedule (cron)
#   3. Modify an existing deployment
#
# The script is modular: this entry point only wires the modules together and
# runs the menu. Each capability lives in scripts/installer/*.sh and reuses the
# shared runtime libraries in scripts/lib/*.sh.
#
# POSIX /bin/sh, BusyBox-safe (DSM). Root is required for the deploy/network
# steps (TUN device, macvlan, docker); the installer detects this and tells you
# how to re-run with sudo rather than failing halfway.

# SMG_INSTALL_ROOT lets the CI harness source this file from another directory
# (INSTALL_SOURCE_ONLY=1); interactively $0 always resolves the bundle folder.
REPO_ROOT="${SMG_INSTALL_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
LIB="$REPO_ROOT/scripts/lib"
INST="$REPO_ROOT/scripts/installer"

# --- source the runtime libraries and installer modules (fixed order) ---------
# ui.sh is kept out of common.sh so the unattended updater never sources TTY code.
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
# shellcheck source=scripts/lib/geodata.sh
. "$LIB/geodata.sh"
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
# checks.sh last of the libs: its header deps (common/scheduler/registry/
# compose/geodata/cloudflared/network/resolve) are all sourced above. The
# deploy report reuses its proxy_groups check (#37) - never forked.
# shellcheck source=scripts/lib/checks.sh
. "$LIB/checks.sh"
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
# shellcheck source=scripts/installer/flow_cron.sh
. "$INST/flow_cron.sh"
# shellcheck source=scripts/installer/flow_targets.sh
. "$INST/flow_targets.sh"
# shellcheck source=scripts/installer/flow_modify.sh
. "$INST/flow_modify.sh"

# Restore terminal echo if a secret prompt or Ctrl-C left it off. On an
# interrupt (Ctrl-C mid-mutation), additionally close the loop: tell the
# operator that any partial state is detected and offered for cleanup on the
# next run (the preprocessing step's inventory), instead of exiting silently.
# shellcheck disable=SC2329  # invoked indirectly via trap
_on_exit() { stty echo </dev/tty 2>/dev/null; }
# shellcheck disable=SC2329  # invoked indirectly via trap
_on_int() {
  stty echo </dev/tty 2>/dev/null
  # Reap the config staging dir: it holds a copy of the subscription URL
  # (token included) and must not survive an interrupted run.
  [ -n "${SMG_CFG_STAGE:-}" ] && rm -rf "$SMG_CFG_STAGE" 2>/dev/null
  printf '\n%s\n' "$(msg warn_interrupted 2>/dev/null || echo 'interrupted - partial state is detected on the next run')" >&2
  exit 130
}

# _mm_banner - one line of live state above the menu, so "is my gateway up?"
# never needs a flow. Read-only: a quiet dotenv load for display values plus
# stack_state's docker inspects; every failure degrades to the fresh banner.
_mm_banner() {
  [ -f "$ENV_FILE" ] && dotenv_load "$ENV_FILE" >/dev/null 2>&1
  case "$(stack_state 2>/dev/null)" in
    deployed)
      _bn_nas="$(_iface_ipv4 "${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}" 2>/dev/null)"
      [ -n "$_bn_nas" ] || _bn_nas='<NAS-IP>'
      ui_say "$(msgf st_deployed "${MIHOMO_IP:-?}" "$_bn_nas" "${WEB_UI_PORT:-8080}")" ;;
    partial)
      ui_say "$(msg st_partial)" ;;
    *)
      ui_say "$(msg st_fresh)" ;;
  esac
}

# _mm_deploy_label - the first menu item adapts to state: once a .env exists,
# hint that option 2 reuses the saved settings (the installer knows; the
# operator should not have to).
_mm_deploy_label() {
  if [ -f "$ENV_FILE" ]; then
    printf '%s%s' "$(msg menu_deploy)" "$(msg menu_deploy_saved_hint)"
  else
    printf '%s' "$(msg menu_deploy)"
  fi
}

# _run_doctor - seam for tests; interactively this is the real diagnostics run.
_run_doctor() { sh "$REPO_ROOT/scripts/doctor.sh"; }

# menu_status_flow - the Status / Diagnose menu item: a read-only summary
# (state, containers, dashboard URL, TUN mode) plus an optional doctor run -
# the recovery tools become part of the loop they close.
menu_status_flow() {
  ui_step "$(msg status_title)"
  [ -f "$ENV_FILE" ] && dotenv_load "$ENV_FILE" >/dev/null 2>&1
  lifecycle_inspect 2>/dev/null
  ui_say "$(msgf status_state "$(stack_state 2>/dev/null)")"
  ui_say "$(msgf status_mihomo "${LIFECYCLE_MIHOMO_STATUS:-absent}" "${MIHOMO_IP:-?}")"
  ui_say "$(msgf status_ui "${LIFECYCLE_UI_STATUS:-absent}")"
  _ms_nas="$(_iface_ipv4 "${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}" 2>/dev/null)"
  [ -n "$_ms_nas" ] || _ms_nas='<NAS-IP>'
  ui_say "$(msgf status_dashboard "$_ms_nas" "${WEB_UI_PORT:-8080}")"
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

main_menu() {
  while :; do
    ui_say ""
    ui_say "${C_BOLD}$(msg title)${C_RESET}"
    _mm_banner
    ui_menu_select _choice "$(msg menu_action)" \
      "$(_mm_deploy_label)" \
      "$(msg menu_redeploy)" \
      "$(msg menu_cron)" \
      "$(msg menu_modify)" \
      "$(msg menu_status)" \
      "$(msg menu_quit)"
    case "$UI_MENU_INDEX" in
      1) flow_deploy   || ui_warn "$(msg warn_deploy_unfinished)" ;;
      2) flow_redeploy || ui_warn "$(msg warn_redeploy_unfinished)" ;;
      3) flow_cron     || ui_warn "$(msg warn_cron_unfinished)" ;;
      4) flow_modify ;;
      5) menu_status_flow ;;
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

# Rotating-free install log for diagnostics (referenced by diagnose()).
INSTALL_LOG="${INSTALL_LOG:-$GATEWAY_DATA_DIR/logs/install.log}"
mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null
export INSTALL_LOG

trap _on_exit EXIT
trap _on_int INT TERM

# This installer is interactive: it reads choices from the terminal even when
# stdin is piped. Bail clearly if there is no controlling terminal.
if [ ! -r /dev/tty ]; then
  echo "install.sh is interactive - run it in a terminal:  sh ./install.sh" >&2
  exit "${EXIT_CONFIG:-3}"
fi

# Language selection is the FIRST screen, so every message below (including
# location errors) renders in the chosen language. env_get/env_set (envedit.sh)
# and ENV_FILE (common.sh) are already sourced above.
choose_language

ui_step "$(msg step_installer)"

# req #3: the bundle can be unpacked anywhere, but it must live under the Docker
# shared folder. Check that FIRST and stop with guidance if it doesn't.
ui_info "$(msg info_check_loc)"
if ! check_location; then
  ui_error "$(msg err_loc_blocked)"
  exit "${EXIT_CONFIG:-3}"
fi

if ! is_root; then
  ui_warn "$(msg warn_not_root)"
  ui_warn "$(msg warn_not_root2)"
  sudo_rerun_hint
fi

main_menu
exit "${EXIT_OK:-0}"

fi
