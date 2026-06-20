#!/bin/sh
# preprocess.sh - interactive cleanup planning for deploy/redeploy/modify.
#
# Decisions are collected before image preparation, but mutations are deferred
# until apply_predeployment_cleanup(), after every non-destructive validation has
# passed. Requires ui.sh, i18n.sh, lifecycle.sh. POSIX /bin/sh.

CLEANUP_CONTAINERS_MODE=preserve
CLEANUP_NETWORK_MODE=preserve

_preprocess_show_inventory() {
  ui_say "$(msgf prep_container_state "$LIFECYCLE_MIHOMO_STATUS" "$LIFECYCLE_UI_STATUS")"
  if [ "$LIFECYCLE_NETWORK_PRESENT" = 1 ]; then
    if [ "$LIFECYCLE_NETWORK_MATCHES" = 1 ]; then _pp_net="$(msg prep_net_match)"; else _pp_net="$(msg prep_net_drift)"; fi
    ui_say "$(msgf prep_network_state "${TPROXY_NETWORK:-tproxy_network}" "$_pp_net")"
    [ -z "$LIFECYCLE_ATTACHMENTS" ] || ui_say "$(msgf prep_network_attached "$LIFECYCLE_ATTACHMENTS")"
  else
    ui_say "$(msgf prep_network_state "${TPROXY_NETWORK:-tproxy_network}" "$(msg prep_net_absent)")"
  fi
}

plan_predeployment_cleanup() {
  while :; do
    ui_step "$(msg step_preprocess)"
    lifecycle_inspect
    _preprocess_show_inventory
    CLEANUP_CONTAINERS_MODE=preserve
    CLEANUP_NETWORK_MODE=preserve
    _pp_manual=0

    if [ "$LIFECYCLE_CONTAINERS_PRESENT" = 1 ]; then
      ui_menu_select _pp_containers "$(msg prep_containers_prompt)" \
        "$(msg prep_preserve)" "$(msg prep_auto)" "$(msg prep_manual)"
      case "$UI_MENU_INDEX" in
        1) if [ "$LIFECYCLE_CONTAINERS_SAFE" = 1 ]; then
             CLEANUP_CONTAINERS_MODE=preserve
           else
             ui_warn "$(msg prep_ambiguous)"; continue
           fi ;;
        2) if [ "$LIFECYCLE_CONTAINERS_SAFE" = 1 ]; then
             CLEANUP_CONTAINERS_MODE=auto
           else
             ui_warn "$(msg prep_ambiguous)"; continue
           fi ;;
        3) CLEANUP_CONTAINERS_MODE=manual; _pp_manual=1
           ui_say "$(msg prep_manual_commands)"; lifecycle_print_container_commands >&2 ;;
      esac
    fi

    if [ "$LIFECYCLE_NETWORK_PRESENT" = 1 ]; then
      ui_menu_select _pp_network "$(msg prep_network_prompt)" \
        "$(msg prep_preserve)" "$(msg prep_auto)" "$(msg prep_manual)"
      case "$UI_MENU_INDEX" in
        1) if [ "$LIFECYCLE_NETWORK_MATCHES" = 1 ]; then
             CLEANUP_NETWORK_MODE=preserve
           else
             ui_warn "$(msg prep_drift_requires_cleanup)"; continue
           fi ;;
        2) if [ "$LIFECYCLE_NETWORK_SAFE" != 1 ]; then
             ui_warn "$(msg prep_unrelated)"; continue
           elif [ -n "$LIFECYCLE_ATTACHMENTS" ] && [ "$CLEANUP_CONTAINERS_MODE" != auto ]; then
             ui_warn "$(msg prep_network_needs_containers)"; continue
           else
             CLEANUP_NETWORK_MODE=auto
           fi ;;
        3) CLEANUP_NETWORK_MODE=manual; _pp_manual=1
           ui_say "$(msg prep_manual_commands)"; lifecycle_print_network_commands >&2 ;;
      esac
    fi

    if [ "$_pp_manual" = 1 ]; then
      if ui_yesno "$(msg prep_rescan)" n; then continue; fi
      diagnose "$(msg prep_manual_pending)" "$(msg prep_manual_fix)"
      return 1
    fi
    export CLEANUP_CONTAINERS_MODE CLEANUP_NETWORK_MODE
    return 0
  done
}

apply_predeployment_cleanup() {
  ui_step "$(msg step_apply_preprocess)"
  lifecycle_inspect
  case "${CLEANUP_CONTAINERS_MODE:-preserve}" in
    auto) lifecycle_remove_containers || return 1 ;;
    preserve)
      if [ "$LIFECYCLE_CONTAINERS_SAFE" != 1 ]; then
        diagnose "$(msg prep_ambiguous)" "$(msg prep_manual_fix)"
        return 1
      fi ;;
    *) diagnose "$(msg prep_manual_pending)" "$(msg prep_manual_fix)"; return 1 ;;
  esac

  lifecycle_inspect
  case "${CLEANUP_NETWORK_MODE:-preserve}" in
    auto) lifecycle_remove_network || return 1 ;;
    preserve)
      if [ "$LIFECYCLE_NETWORK_PRESENT" = 1 ] && [ "$LIFECYCLE_NETWORK_MATCHES" != 1 ]; then
        diagnose "$(msg prep_drift_requires_cleanup)" "$(msg prep_manual_fix)"
        return 1
      fi ;;
    *) diagnose "$(msg prep_manual_pending)" "$(msg prep_manual_fix)"; return 1 ;;
  esac
  ui_ok "$(msg prep_applied)"
  return 0
}
