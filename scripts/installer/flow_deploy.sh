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

# Validate ownership of fixed container names before Compose changes anything.
# Never force-remove or disconnect unrelated containers from a user-managed NAS.
reprovision_containers() {
  [ -n "${DOCKER_BIN:-}" ] || return 0
  ui_step "$(msg step_reprovision)"

  _rp_found=""
  for _c in "$MIHOMO_CONTAINER" "$METACUBEXD_CONTAINER"; do
    [ -n "$_c" ] || continue
    _rp_st="$("$DOCKER_BIN" inspect -f '{{.State.Status}}' "$_c" 2>/dev/null)" || _rp_st=""
    [ -n "$_rp_st" ] || continue
    case "$_c" in
      "$MIHOMO_CONTAINER") _rp_expected=mihomo ;;
      *) _rp_expected=metacubexd ;;
    esac
    _rp_service="$("$DOCKER_BIN" inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$_c" 2>/dev/null)"
    if [ "$_rp_service" != "$_rp_expected" ]; then
      diagnose "container name '$_c' is owned by another deployment" \
        "rename/remove that container explicitly, then retry"
      return 1
    fi
    ui_say "$(msgf reprov_found "$_c" "$_rp_st")"; _rp_found=1
  done
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

# _ctrl_get URL [HEADER] - GET URL from INSIDE the mihomo container (so the
# macvlan host-isolation quirk doesn't matter) and echo the body. Uses whichever
# of wget/curl the image ships; empty output on any failure (incl. non-2xx).
_ctrl_get() {
  _cg_u="$1"; _cg_h="$2"
  if "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v wget >/dev/null 2>&1' 2>/dev/null; then
    if [ -n "$_cg_h" ]; then
      "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 8 -O - --header "$_cg_h" "$_cg_u" 2>/dev/null
    else
      "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 8 -O - "$_cg_u" 2>/dev/null
    fi
  elif "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v curl >/dev/null 2>&1' 2>/dev/null; then
    if [ -n "$_cg_h" ]; then
      "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" curl -fsS -m 8 -H "$_cg_h" "$_cg_u" 2>/dev/null
    else
      "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" curl -fsS -m 8 "$_cg_u" 2>/dev/null
    fi
  fi
}

# proxy_egress_probe - EXTRA GUARD: a mihomo "Running + controller OK" health gate
# does NOT prove the proxy can actually reach the internet. Ask mihomo to GET a
# test URL THROUGH the rule target (the PROXY group) via the controller's delay
# API, so a "started but every node times out" state (dead / expired / blocked
# subscription nodes) is surfaced NOW with a clear diagnosis, not later as failing
# traffic. Warns; never fails the deploy (the gateway itself is correctly set up).
proxy_egress_probe() {
  [ -n "${DOCKER_BIN:-}" ] || return 0
  _eg_grp="${EGRESS_TEST_GROUP:-PROXY}"
  _eg_url="${EGRESS_TEST_URL:-http://www.gstatic.com/generate_204}"
  _eg_to="${EGRESS_TEST_TIMEOUT_MS:-5000}"
  if ! "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1' 2>/dev/null; then
    ui_info "$(msg info_egress_skip)"
    return 0
  fi
  _eg_api="http://127.0.0.1:${CONTROLLER_PORT:-9090}/proxies/${_eg_grp}/delay?timeout=${_eg_to}&url=${_eg_url}"
  _eg_hdr=""
  [ -n "${CONTROLLER_SECRET:-}" ] && _eg_hdr="Authorization: Bearer ${CONTROLLER_SECRET}"
  ui_info "$(msgf info_egress_test "$_eg_url")"
  _eg_out="$(_ctrl_get "$_eg_api" "$_eg_hdr")"
  case "$_eg_out" in
    *'"delay"'*)
      _eg_ms="$(printf '%s' "$_eg_out" | sed -n 's/.*"delay"[^0-9]*\([0-9]\{1,\}\).*/\1/p')"
      ui_ok "$(msgf ok_egress "${_eg_ms:-?}")" ;;
    *)
      diagnose "$(msgf diag_egress "$_eg_grp")" "$(msg diag_egress_fix)" ;;
  esac
  return 0
}

# Non-destructive deployment preparation. Every registry/image/config failure is
# detected before a healthy running stack or its macvlan can be touched.
prepare_stack() {
  ensure_subscription || return 1
  PREVIOUS_MIHOMO_IMAGE_ID="$(running_image_id "$MIHOMO_CONTAINER")"
  PREVIOUS_METACUBEXD_IMAGE_ID="$(running_image_id "$METACUBEXD_CONTAINER")"
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

  pf_compose_config || return 1
  ui_info "validating the rendered Mihomo configuration"
  _cfg_test="$(mktemp -d "${TMPDIR:-/tmp}/smg-config.XXXXXX" 2>/dev/null)" || {
    diagnose "could not create a private temporary config directory" "check free space and /tmp permissions"
    return 1
  }
  chmod 700 "$_cfg_test" 2>/dev/null || true
  if ! cp "$REPO_ROOT/config/config.template.yaml" "$REPO_ROOT/config/subscription.txt" "$_cfg_test/"; then
    rm -rf "$_cfg_test"
    diagnose "could not stage the Mihomo configuration" "check config file permissions"
    return 1
  fi
  if ! MIHOMO_CONFIG_DIR="$_cfg_test" sh "$REPO_ROOT/scripts/render_config.sh" \
      >>"${LOG_FILE:-/dev/null}" 2>&1; then
    rm -rf "$_cfg_test"
    diagnose "failed to render config/config.yaml" \
      "check the subscription, DNS values, and write permissions"
    return 1
  fi
  if ! "$DOCKER_BIN" run --rm --entrypoint /mihomo \
      -v "$_cfg_test/config.yaml:/root/.config/mihomo/config.yaml:ro" \
      "$MIHOMO_IMAGE" -t -d /root/.config/mihomo \
      >>"${LOG_FILE:-/dev/null}" 2>&1; then
    rm -rf "$_cfg_test"
    _show_log_tail
    diagnose "the pulled Mihomo image rejected the rendered configuration" \
      "review config/config.yaml and the error above"
    return 1
  fi
  rm -rf "$_cfg_test"
  return 0
}

rollback_installer_stack() {
  [ -n "${PREVIOUS_MIHOMO_IMAGE_ID:-}${PREVIOUS_METACUBEXD_IMAGE_ID:-}" ] || return 1
  ui_warn "deployment failed structural health checks; attempting the last running images"
  rollback_compose "${PREVIOUS_MIHOMO_IMAGE_ID:-}" "${PREVIOUS_METACUBEXD_IMAGE_ID:-}" \
    && health_gate
}

deploy_stack() {
  ui_step "$(msg step_deploy_stack)"
  ui_info "$(msg info_starting)"
  if ! compose_recreate; then
    _show_log_tail
    diagnose "$(msg diag_compose_up)" "$(msgf diag_compose_up_fix "$INSTALL_LOG")"
    rollback_installer_stack && ui_warn "previous images restored and healthy"
    return 1
  fi
  if health_gate; then
    ui_ok "$(msg ok_mihomo_healthy)"
    proxy_egress_probe          # extra guard: real GET through the proxy nodes
    return 0
  fi
  _show_mihomo_logs
  diagnose "$(msg diag_unhealthy)" "$(msg diag_unhealthy_fix)"
  if rollback_installer_stack; then
    ui_warn "previous images restored and healthy"
  else
    ui_error "automatic rollback was unavailable or did not restore health"
  fi
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

  if ! is_root; then
    diagnose "deployment requires root privileges" "re-run: sudo sh ./install.sh"
    return 1
  fi

  seed_config       || return 1
  load_env                                  # .env now exists; export its values

  scan_and_prefill  || return 1             # interface FIRST -> derive router/subnet
  load_env                                  # pick up derived ROUTER_IP/SUBNET_CIDR

  wizard_env        || return 1             # pre-filled; MIHOMO_IP conflict-checked
  wizard_images     || return 1
  wizard_subscription || return 1
  load_env                                  # re-load after the wizards wrote .env

  pf_docker         || return 1
  pf_arch           || return 1
  pf_web_port       || return 1
  validate_selected_network || return 1
  prepare_stack     || return 1

  reprovision_containers || return 1
  create_network    || return 1             # root: TUN + macvlan (final IP guard inside)
  load_env

  deploy_stack      || return 1
  report_success
  return 0
}
