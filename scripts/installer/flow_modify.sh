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
  ui_step "Apply changes (redeploy)"
  load_env
  pf_docker || return 1
  if [ "$(stack_state)" = "fresh" ]; then
    ui_warn "nothing is deployed yet - use the end-to-end deploy (main menu option 1) instead"
    return 1
  fi

  _m_old="$(running_image_id mihomo 2>/dev/null)"
  _x_old="$(running_image_id mihomo-ui 2>/dev/null)"

  if [ "${REGISTRY_MODE:-acr}" = "acr" ]; then
    acr_login || ui_warn "ACR login failed - a changed image may fail to pull"
  fi

  ui_info "redeploying (docker compose up -d; re-renders config, pulls changed images)"
  if compose_up && health_gate; then
    ui_ok "applied + healthy"
    return 0
  fi

  ui_warn "health gate failed - rolling back to the last-good images"
  if rollback_compose "$_m_old" "$_x_old" && health_gate; then
    ui_warn "rolled back to last-good (now healthy) - your change was NOT applied"
  else
    diagnose "redeploy failed AND rollback incomplete" "inspect 'docker ps -a' and 'docker logs mihomo'; manual recovery may be needed"
  fi
  return 1
}

flow_modify() {
  ui_step "Modify existing configuration"
  if [ ! -f "$ENV_FILE" ]; then
    diagnose ".env not found" "run the end-to-end deploy first (main menu option 1)"
    return 1
  fi
  load_env
  ui_info "current stack state: $(stack_state)"

  _sel=""
  while :; do
    ui_say ""
    ui_menu_select _sel "What do you want to change?" \
      "Network & DNS settings (.env wizard)" \
      "Image source / registry / tags" \
      "Subscription URL" \
      "Re-run network setup (interface / macvlan)" \
      "Apply changes now (redeploy with rollback)" \
      "Back to main menu"
    case "$_sel" in
      "Network & DNS"*)       wizard_env && load_env ;;
      "Image source"*)        wizard_images && load_env ;;
      "Subscription"*)        wizard_subscription ;;
      "Re-run network"*)      setup_network_interactive ;;
      "Apply changes"*)       apply_changes ;;
      "Back"*)                return 0 ;;
    esac
  done
}
