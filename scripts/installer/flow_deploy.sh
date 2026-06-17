#!/bin/sh
# flow_deploy.sh - Flow A: end-to-end deploy state machine.
#   seed -> env wizard -> image wizard -> subscription -> preflight -> network ->
#   ACR login (acr mode) -> compose up + health gate -> report.
#
# Requires the full installer module set sourced (see install.sh). POSIX /bin/sh.

# deploy_stack - bring the compose services up and health-gate them.
# _show_log_tail - print the tail of the deploy log so the operator sees the
# actual docker/compose error INLINE, not only in a file (LOG_FILE == the install
# log under the installer; see common.sh load_env).
_show_log_tail() {
  [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ] || return 0
  ui_say ""
  ui_say "$(msg info_log_tail)"
  tail -n 25 "$LOG_FILE" >&2 2>/dev/null
  ui_say ""
}

# reprovision_containers - if this app's containers already exist (running,
# stopped, created, or crash-looping), tear them down so the deploy recreates
# them cleanly from the current image + freshly rendered config. Visible (reports
# what it found) and idempotent: removes the compose project's containers (plus
# any orphan service), force-removes the named containers even when compose state
# is inconsistent ("container name already in use"), and detaches anything still
# bound to the macvlan network so its recreate can't fail with "container still
# attached". INSTALLER-ONLY: the auto-updater calls compose_up directly and must
# NOT force-recreate.
reprovision_containers() {
  [ -n "${DOCKER_BIN:-}" ] || return 0
  ui_step "$(msg step_reprovision)"

  _rp_found=""
  for _c in "$MIHOMO_CONTAINER" "$METACUBEXD_CONTAINER"; do
    [ -n "$_c" ] || continue
    _rp_st="$("$DOCKER_BIN" inspect -f '{{.State.Status}}' "$_c" 2>/dev/null)" || _rp_st=""
    [ -n "$_rp_st" ] && { ui_say "$(msgf reprov_found "$_c" "$_rp_st")"; _rp_found=1; }
  done

  # shellcheck disable=SC2086  # COMPOSE_CMD may be two words ("docker compose")
  ( cd "$REPO_ROOT" && $COMPOSE_CMD --env-file "$ENV_FILE" down --remove-orphans ) >>"${LOG_FILE:-/dev/null}" 2>&1 || true
  for _c in "$MIHOMO_CONTAINER" "$METACUBEXD_CONTAINER"; do
    [ -n "$_c" ] && "$DOCKER_BIN" rm -f "$_c" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
  done

  _rp_net="${TPROXY_NETWORK:-tproxy_network}"
  if network_exists "$_rp_net"; then
    for _rp_id in $("$DOCKER_BIN" ps -aq --filter "network=$_rp_net" 2>/dev/null); do
      "$DOCKER_BIN" network disconnect -f "$_rp_net" "$_rp_id" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    done
  fi

  if [ -n "$_rp_found" ]; then ui_ok "$(msg reprov_done)"; else ui_info "$(msg reprov_none)"; fi
  return 0
}

# _show_mihomo_logs - print the tail of `docker logs mihomo` so the operator sees
# the container's OWN crash reason (the install log only holds compose's output).
_show_mihomo_logs() {
  [ -n "${DOCKER_BIN:-}" ] || return 0
  ui_say ""
  ui_say "$(msg info_mihomo_logs)"
  "$DOCKER_BIN" logs --tail 30 "$MIHOMO_CONTAINER" 2>&1 | tail -n 30 >&2 || true
  ui_say ""
}

deploy_stack() {
  ui_step "$(msg step_deploy_stack)"
  # render_config.sh (the container entrypoint) hard-fails without a real
  # subscription URL, which crash-loops mihomo - guarantee one before deploying.
  ensure_subscription || return 1
  if [ "${REGISTRY_MODE:-acr}" = "acr" ]; then
    try "$(msg diag_acr_login)" "$(msg diag_acr_login_fix)" -- acr_login || { _show_log_tail; return 1; }
  else
    ui_info "$(msg info_skip_login)"
  fi

  # `docker compose up -d` pulls any missing images itself; do an explicit arch
  # check first so we never start an unrunnable image.
  for _img in "$MIHOMO_IMAGE" "$METACUBEXD_IMAGE"; do
    [ -n "$_img" ] || continue
    ui_info "$(msgf info_pulling "$_img")"
    try "$(msgf diag_pull_fail "$_img")" "$(msg diag_pull_fail_fix)" -- pull_image "$_img" || { _show_log_tail; return 1; }
    if ! arch_ok "$_img"; then
      diagnose "$(msgf diag_arch_mismatch "$_img")" "$(msgf diag_arch_mismatch_fix "${EXPECTED_ARCH:-amd64}")"
      return 1
    fi
  done

  ui_info "$(msg info_starting)"
  if ! compose_up; then
    _show_log_tail
    diagnose "$(msg diag_compose_up)" "$(msgf diag_compose_up_fix "$INSTALL_LOG")"
    return 1
  fi
  if health_gate; then
    ui_ok "$(msg ok_mihomo_healthy)"
    return 0
  fi
  _show_mihomo_logs
  diagnose "$(msg diag_unhealthy)" "$(msg diag_unhealthy_fix)"
  return 1
}

report_success() {
  ui_step "$(msg step_deploy_done)"
  ui_ok  "$(msg ok_gateway_up)"
  ui_say ""
  ui_say "$(msg rep_dashboard)"
  ui_say "$(msgf rep_dashboard_url "${WEB_UI_PORT:-8080}")"
  ui_say "$(msg rep_add_backend)"
  ui_say "$(msgf rep_backend_line "${MIHOMO_IP:-<mihomo-ip>}" "${CONTROLLER_PORT:-9090}")"
  ui_say ""
  ui_say "$(msgf rep_point_client "${MIHOMO_IP:-<mihomo-ip>}")"
  ui_warn "$(msgf rep_warn_isolation "${MIHOMO_IP:-<mihomo-ip>}")"
  ui_say ""
  ui_say "$(msg rep_next)"
  return 0
}

flow_deploy() {
  ui_step "$(msg step_deploy_e2e)"

  seed_config       || return 1
  load_env                                  # .env now exists; export its values

  scan_and_prefill  || return 1             # interface FIRST -> derive router/subnet
  load_env                                  # pick up derived ROUTER_IP/SUBNET_CIDR

  wizard_env        || return 1             # pre-filled; MIHOMO_IP conflict-checked
  wizard_images     || return 1
  wizard_subscription || return 1
  load_env                                  # re-load after the wizards wrote .env

  pf_docker         || return 1
  pf_arch

  # Reprovision existing containers BEFORE recreating the macvlan: a still-attached
  # container would make `docker network rm` (in create_network) fail.
  reprovision_containers
  create_network    || return 1             # root: TUN + macvlan (final IP guard inside)
  load_env

  deploy_stack      || return 1
  report_success
  return 0
}
