#!/bin/sh
# preprocess.sh - interactive cleanup planning for deploy/redeploy/modify.
#
# Decisions are collected before image preparation, but mutations are deferred
# until apply_predeployment_cleanup(), after every non-destructive validation has
# passed. The decision POLICY (which plan is valid against the current
# inventory) lives in lib/resolve.sh (resolve_cleanup_*); this module only owns
# the menus and message rendering. Requires ui.sh, i18n.sh, lifecycle.sh,
# resolve.sh. POSIX /bin/sh.

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

# _preprocess_warn_reason - render resolve.sh's machine-readable rejection
# token (RESOLVE_CLEANUP_REASON) as the operator-facing localized warning.
_preprocess_warn_reason() {
  case "${RESOLVE_CLEANUP_REASON:-}" in
    ambiguous)        ui_warn "$(msg prep_ambiguous)" ;;
    foreign_project)  ui_warn "$(msgf prep_foreign_project "${LIFECYCLE_COMPOSE_PROJECT:-?}")" ;;
    drift)            ui_warn "$(msg prep_drift_requires_cleanup)" ;;
    unrelated)        ui_warn "$(msg prep_unrelated)" ;;
    needs_containers) ui_warn "$(msg prep_network_needs_containers)" ;;
    *)                ui_warn "$(msg prep_manual_pending)" ;;
  esac
}

# _preprocess_menu_mode - map the 3-item preserve/auto/manual menu onto the
# mode token resolve_cleanup_* validates.
_preprocess_menu_mode() {
  case "$UI_MENU_INDEX" in
    2) printf '%s' auto ;;
    3) printf '%s' manual ;;
    *) printf '%s' preserve ;;
  esac
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
      if ! resolve_cleanup_containers "$(_preprocess_menu_mode)"; then
        _preprocess_warn_reason; continue
      fi
      if [ "$CLEANUP_CONTAINERS_MODE" = manual ]; then
        _pp_manual=1
        ui_say "$(msg prep_manual_commands)"; lifecycle_print_container_commands >&2
      fi
    fi

    if [ "$LIFECYCLE_NETWORK_PRESENT" = 1 ]; then
      ui_menu_select _pp_network "$(msg prep_network_prompt)" \
        "$(msg prep_preserve)" "$(msg prep_auto)" "$(msg prep_manual)"
      if ! resolve_cleanup_network "$(_preprocess_menu_mode)"; then
        _preprocess_warn_reason; continue
      fi
      if [ "$CLEANUP_NETWORK_MODE" = manual ]; then
        _pp_manual=1
        ui_say "$(msg prep_manual_commands)"; lifecycle_print_network_commands >&2
      fi
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
