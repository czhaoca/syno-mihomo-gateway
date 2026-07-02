#!/bin/sh
# flow_targets.sh - Flow B2: per-container opt-in for the generic auto-update
# driver. Scans running containers already on the configured ACR registry and
# writes the managed enrollment list via scripts/lib/targets.sh (the same list
# `gateway.sh update --enable/--disable/--list-targets` manages). The gateway
# trio is never offered; compose-managed and ambiguous containers are shown
# but not offerable; database-like images require an explicit second
# confirmation (DEC-8: recreate has no quiesce).
#
# Requires the installer module set + lib/targets.sh sourced. POSIX /bin/sh.

flow_targets() {
  ui_step "$(msg step_targets)"
  if [ -z "${DOCKER_REGISTRY:-}" ] || [ -z "${ACR_NAMESPACE:-}" ]; then
    ui_warn "$(msg targets_no_acr)"
    return 0
  fi
  _ft_d="$(_net_docker)" || _ft_d=""
  if [ -z "$_ft_d" ] || ! "$_ft_d" info >/dev/null 2>&1; then
    ui_warn "$(msg targets_no_docker)"
    return 0
  fi
  # targets.sh primitives (classify/enroll/remove) resolve docker via
  # DOCKER_BIN; pin it to the binary this scan resolved so the whole flow
  # sees one consistent daemon view (a stale DOCKER_BIN from an earlier
  # deploy step would silently classify against the wrong docker).
  DOCKER_BIN="$_ft_d"

  _ft_found=0; _ft_enrolled=0; _ft_removed=0
  for _ft_name in $("$_ft_d" ps --format '{{.Names}}' 2>/dev/null); do
    [ -n "$_ft_name" ] || continue
    _ft_img="$("$_ft_d" inspect -f '{{.Config.Image}}' "$_ft_name" 2>/dev/null)"
    case "$_ft_img" in
      "$DOCKER_REGISTRY/$ACR_NAMESPACE/"*) : ;;
      *) continue ;;
    esac
    if _targets_reserved_name "$_ft_name"; then
      continue
    fi
    _ft_found=$((_ft_found + 1))
    case "$(targets_classify_container "$_ft_name")" in
      managed)
        ui_info "$(msgf targets_excluded "$_ft_name" "$_ft_img" "$(msg targets_reason_compose)")"
        continue ;;
      ambiguous)
        ui_info "$(msgf targets_excluded "$_ft_name" "$_ft_img" "$(msg targets_reason_ambiguous)")"
        continue ;;
    esac
    _ft_cur=n
    if [ -f "$TARGETS_FILE" ] && grep -q "^$(_targets_name_pattern "$_ft_name")|" "$TARGETS_FILE" 2>/dev/null; then
      _ft_cur=y
    fi
    if ui_yesno "$(msgf q_target_optin "$_ft_name" "$_ft_img")" "$_ft_cur"; then
      # The DEC-8 risk confirmation fires only on a NEW database enrollment:
      # an already-enrolled database accepted that risk when it was enrolled,
      # and accepting the defaults on a re-run must never change anything.
      if [ "$_ft_cur" != y ] && targets_image_databaselike "$_ft_img"; then
        ui_warn "$(msgf warn_target_db "$_ft_name" "$_ft_img")"
        if ! ui_yesno "$(msg q_target_db_confirm)" n; then
          continue
        fi
      fi
      if [ "$_ft_cur" != y ]; then
        if target_enroll "$_ft_name"; then
          _ft_enrolled=$((_ft_enrolled + 1))
          ui_ok "$(msgf ok_target_enrolled "$_ft_name")"
        else
          ui_warn "$(msgf warn_target_enroll_failed "$_ft_name")"
        fi
      fi
    else
      if [ "$_ft_cur" = y ]; then
        if target_remove "$_ft_name"; then
          _ft_removed=$((_ft_removed + 1))
          ui_ok "$(msgf ok_target_removed "$_ft_name")"
        fi
      fi
    fi
  done

  if [ "$_ft_found" = 0 ]; then
    ui_info "$(msg targets_none_found)"
    return 0
  fi
  ui_ok "$(msgf ok_targets_done "$_ft_enrolled" "$_ft_removed")"
  return 0
}
