#!/bin/sh
# flow_modify.sh - Flow C: change an existing deployment's configuration, then
# optionally apply (redeploy) with health-gated auto-rollback. Each sub-step
# edits only the keys it owns (env_set), so a working deploy is never corrupted
# by touching unrelated settings.
#
# Requires the installer module set sourced. POSIX /bin/sh.

# apply_changes - re-render + redeploy the compose services with rollback. A
# `docker compose up -d` re-runs the entrypoint renderer (picking up new DNS /
# subscription / secret) and pulls any image whose ref changed.
apply_changes() {
  ui_step "$(msg step_apply)"
  load_env
  pf_docker || return 1
  if [ "$(stack_state)" = "fresh" ]; then
    ui_warn "$(msg warn_nothing_deployed)"
    return 1
  fi

  _m_old="$(running_image_id mihomo 2>/dev/null)"
  _x_old="$(running_image_id mihomo-ui 2>/dev/null)"

  if [ "${REGISTRY_MODE:-acr}" = "acr" ]; then
    acr_login || ui_warn "$(msg warn_acr_login_soft)"
  fi

  ui_info "$(msg info_redeploying)"
  if compose_up && health_gate; then
    ui_ok "$(msg ok_applied)"
    return 0
  fi

  ui_warn "$(msg warn_health_rollback)"
  if rollback_compose "$_m_old" "$_x_old" && health_gate; then
    ui_warn "$(msg warn_rolled_back)"
  else
    diagnose "$(msg diag_rollback_fail)" "$(msg diag_rollback_fail_fix)"
  fi
  return 1
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
      5) apply_changes ;;
      6) return 0 ;;
    esac
  done
}
