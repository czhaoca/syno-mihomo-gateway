#!/bin/sh
# flow_modify.sh - Flow C: change an existing deployment's configuration, then
# optionally apply (redeploy) with health-gated auto-rollback. Each sub-step
# edits only the keys it owns (env_set), so a working deploy is never corrupted
# by touching unrelated settings.
#
# Requires the installer module set sourced. POSIX /bin/sh.

# Apply through the same fail-closed preparation and health gate as Deploy and
# Redeploy. Keeping one path prevents Modify from bypassing config/arch/TUN checks.
apply_changes() {
  ui_step "$(msg step_apply)"
  if ! is_root; then
    diagnose "applying changes requires root privileges" "re-run: sudo sh ./${INSTALLER_ENTRY:-install.sh}"
    return 1
  fi
  load_env
  pf_docker || return 1
  if [ "$(stack_state)" = "fresh" ]; then
    ui_warn "$(msg warn_nothing_deployed)"
    return 1
  fi
  precheck_deploy || return 1
  pf_arch || return 1
  pf_web_port || return 1
  validate_selected_network || return 1
  plan_predeployment_cleanup || return 1
  prepare_stack || return 1
  apply_predeployment_cleanup || return 1
  if ! create_network; then
    _deploy_teardown_notice    # closed loop: say the old stack is gone (flow_deploy.sh)
    return 1
  fi
  load_env
  deploy_stack
}

flow_modify() {
  ui_step "$(msg step_modify)"
  if [ ! -f "$ENV_FILE" ]; then
    diagnose "$(msg diag_no_env)" "$(msg diag_no_env_fix)"
    return 1
  fi
  load_env
  ui_info "$(msgf info_stack_state "$(stack_state)")"

  while :; do
    ui_say ""
    ui_menu_select _sel "$(msg modify_what)" \
      "$(msg modify_net)" \
      "$(msg modify_images)" \
      "$(msg modify_sub)" \
      "$(msg modify_rerun_net)" \
      "$(msg modify_apply)" \
      "$(msg modify_back)"
    case "$UI_MENU_INDEX" in
      1) wizard_env && load_env ;;
      2) wizard_images && load_env ;;
      3) wizard_subscription ;;
      4) setup_network_interactive ;;
      5) apply_changes || ui_warn "$(msg warn_apply_failed)" ;;
      6) return 0 ;;
    esac
  done
}
