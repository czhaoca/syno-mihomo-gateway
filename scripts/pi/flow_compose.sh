#!/bin/sh
# flow_compose.sh (scripts/pi) - the Pi mode wizard + the compose-parity deploy
# wrapper (#18). The deploy itself is the UNCHANGED DSM pipeline (flow_deploy /
# flow_redeploy); this file only adds the Pi preflights around it and writes
# the install-mode marker after success. Requires detect.sh, preflight.sh (pi),
# i18n_pi.sh and the full installer module set sourced first (see
# install-pi.sh). POSIX /bin/sh.

# pi_hw_banner - detected hardware + the recommended mode, above the wizard.
pi_hw_banner() {
  ui_step "$(msg pi_hw_title)"
  ui_say "$(msgf pi_hw_model "$(pi_model)")"
  ui_say "$(msgf pi_hw_mem "$(pi_mem_mb)")"
  ui_say "$(msgf pi_hw_arch "$(pi_lite_asset_arch)")"
  ui_say "$(msgf pi_hw_recommend "$(pi_recommend_mode)")"
}

# pi_mode_wizard - set PI_MODE=compose|lite per the owner-decided table and the
# arch gates: ARMv6 sits behind the explicit best-effort ack (DEC-5), and
# 32-bit armv7 never gets compose offered (DEC-A: no metacubexd arm/v7 image).
pi_mode_wizard() {
  pi_hw_banner
  _mw_arch="$(pi_lite_asset_arch)"
  case "$_mw_arch" in
    armv6)
      pi_armv6_ack || { ui_say "$(msg pi_ack_declined)"; return 1; }
      ui_info "$(msg pi_info_compose_armv6)"
      PI_MODE=lite
      return 0 ;;
    armv7)
      ui_info "$(msg pi_info_compose_armv7)"
      PI_MODE=lite
      return 0 ;;
  esac
  [ "$(pi_recommend_mode)" = compose-tuned ] && ui_info "$(msg pi_info_lowram_tuning)"
  ui_menu_select _mw_pick "$(msg pi_ask_mode)" \
    "$(msg pi_mode_compose)" \
    "$(msg pi_mode_lite)"
  case "$UI_MENU_INDEX" in
    1) PI_MODE=compose ;;
    *) PI_MODE=lite ;;
  esac
  return 0
}

# pi_flow_compose - Pi guards -> EXPECTED_ARCH alignment -> the stock deploy
# pipeline -> the mode marker. The ACR notice must print BEFORE any pull
# (DEC-3); flow_deploy's first pull happens inside prepare_stack, well after.
pi_flow_compose() {
  pi_wlan_guard || return 1
  pi_align_expected_arch || return 1
  load_env
  pi_acr_arch_notice
  flow_deploy || return 1
  pi_write_mode_marker pi-compose
  return 0
}

# pi_flow_redeploy - same wrapper around the saved-.env redeploy flow.
pi_flow_redeploy() {
  pi_wlan_guard || return 1
  pi_align_expected_arch || return 1
  load_env
  pi_acr_arch_notice
  flow_redeploy || return 1
  pi_write_mode_marker pi-compose
  return 0
}

# pi_flow_deploy_entry - menu item 1: mode wizard, then dispatch to the chosen
# flavor (compose here, lite in flow_lite.sh).
pi_flow_deploy_entry() {
  pi_mode_wizard || return 1
  case "${PI_MODE:-}" in
    compose) pi_flow_compose ;;
    lite)    pi_flow_lite ;;
    *)       return 1 ;;
  esac
}
