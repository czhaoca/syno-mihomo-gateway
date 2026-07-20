#!/bin/sh
# flow_redeploy.sh - redeploy an already-configured gateway WITHOUT re-entering
# everything. Loads the saved .env, optionally lets the operator fix just the
# conflicting LAN IP (the common case) or re-pick the interface, then recreates
# the network + restarts with the health-gated rollback from deploy_stack.
#
# Requires the installer module set sourced (deploy_stack/report_success live in
# flow_deploy.sh; create_network/scan_and_prefill/check_ip_conflict in netscan.sh).
# POSIX /bin/sh.

flow_redeploy() {
  ui_step "$(msg step_redeploy)"
  if ! is_root; then
    diagnose "redeployment requires root privileges" "re-run: sudo sh ./${INSTALLER_ENTRY:-install.sh}"
    return 1
  fi
  if [ ! -f "$ENV_FILE" ]; then
    diagnose "$(msg diag_no_env_redeploy)" "$(msg diag_no_env_fix)"
    return 1
  fi
  load_env

  ui_say ""
  ui_say "$(msg redeploy_current)"
  ui_say "$(msgf redeploy_iface "$(env_get PARENT_INTERFACE 2>/dev/null || msg redeploy_iface_auto)")"
  ui_say "$(msgf redeploy_router "${ROUTER_IP:-?}")"
  ui_say "$(msgf redeploy_subnet "${SUBNET_CIDR:-?}")"
  ui_say "$(msgf redeploy_mihomo "${MIHOMO_IP:-?}")"
  ui_say "$(msgf redeploy_images "${MIHOMO_IMAGE:-?}")"
  _rd_sub="$(grep -v '^#' "$SUBSCRIPTION_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n1)"
  ui_say "$(msgf redeploy_sub "${_rd_sub:-$(msg redeploy_sub_none)}")"

  load_env

  ui_menu_select _r "$(msg redeploy_what)" \
    "$(msg redeploy_asis)" \
    "$(msg redeploy_edit)" \
    "$(msg redeploy_change_ip)" \
    "$(msg redeploy_repick)" \
    "$(msg modify_back)"
  case "$UI_MENU_INDEX" in
    1) : ;;
    2) wizard_env && load_env ;;
    3) while :; do
         ui_ask_validated MIHOMO_IP "$(msg q_new_mihomo_ip)" "${MIHOMO_IP:-192.168.1.100}" is_ipv4
         check_ip_conflict "$MIHOMO_IP" && break
       done
       env_set MIHOMO_IP "$MIHOMO_IP"; load_env ;;
    4) scan_and_prefill || return 1; load_env ;;
    5) return 0 ;;
  esac

  # Validate the saved .env + subscription.txt and BOUNCE BACK to re-enter any
  # missing/invalid/garbled value, so a reuse-deploy can't fail mid-flight.
  precheck_deploy || return 1

  pf_docker || return 1
  pf_arch || return 1
  pf_web_port || return 1
  validate_selected_network || return 1
  plan_predeployment_cleanup || return 1
  prepare_stack || return 1
  apply_predeployment_cleanup || return 1
  if ! create_network; then      # root: TUN + macvlan (re-runs the final IP guard)
    _deploy_teardown_notice      # closed loop: say the old stack is gone (flow_deploy.sh)
    return 1
  fi
  load_env
  deploy_stack || return 1
  report_success
  return 0
}
