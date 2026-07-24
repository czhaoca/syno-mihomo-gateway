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
  # The auth header (bearer token) never rides the host-visible docker exec
  # argv (no-secrets-on-argv rule): it is handed over on stdin instead.
  if "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v wget >/dev/null 2>&1' 2>/dev/null; then
    if [ -n "$_cg_h" ]; then
      printf '%s\n' "$_cg_h" | "$DOCKER_BIN" exec -i "$MIHOMO_CONTAINER" \
        sh -c 'IFS= read -r SMG_AUTH; exec wget -q -T 8 -O - --header "$SMG_AUTH" "$1"' _ "$_cg_u" 2>/dev/null
    else
      "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 8 -O - "$_cg_u" 2>/dev/null
    fi
  elif "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v curl >/dev/null 2>&1' 2>/dev/null; then
    if [ -n "$_cg_h" ]; then
      printf '%s\n' "$_cg_h" | "$DOCKER_BIN" exec -i "$MIHOMO_CONTAINER" \
        sh -c 'IFS= read -r SMG_AUTH; exec curl -fsS -m 8 -H "$SMG_AUTH" "$1"' _ "$_cg_u" 2>/dev/null
    else
      "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" curl -fsS -m 8 "$_cg_u" 2>/dev/null
    fi
  fi
}

# proxy_egress_probe - EXTRA GUARD: a mihomo "Running + controller OK" health gate
# does NOT prove the proxy can actually reach the internet. Ask mihomo to GET a
# test URL THROUGH the rule target (the Routing Mode group) via the controller's
# delay API, so a "started but every node times out" state (dead / expired /
# blocked subscription nodes) is surfaced NOW with a clear diagnosis, not later
# as failing traffic. Warns; never fails the deploy (the gateway itself is
# correctly set up). The spaced group name is %20-encoded onto the URL only
# (matching the doctor's probe of the same spaced name); messages keep the
# human name.
proxy_egress_probe() {
  [ -n "${DOCKER_BIN:-}" ] || return 0
  _eg_grp="${EGRESS_TEST_GROUP:-Routing Mode}"
  _eg_url="${EGRESS_TEST_URL:-http://www.gstatic.com/generate_204}"
  _eg_to="${EGRESS_TEST_TIMEOUT_MS:-5000}"
  if ! "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" sh -c 'command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1' 2>/dev/null; then
    ui_info "$(msg info_egress_skip)"
    return 0
  fi
  _eg_enc="$(printf '%s' "$_eg_grp" | sed 's/ /%20/g')"
  _eg_api="http://127.0.0.1:${CONTROLLER_PORT:-9090}/proxies/${_eg_enc}/delay?timeout=${_eg_to}&url=${_eg_url}"
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
  PREVIOUS_PANEL_IMAGE_ID="$(running_image_id "${PANEL_CONTAINER:-mihomo-panel}")"
  if [ "${REGISTRY_MODE:-acr}" = "acr" ]; then
    try "$(msg diag_acr_login)" "$(msg diag_acr_login_fix)" -- acr_login || { _show_log_tail; return 1; }
  else
    ui_info "$(msg info_skip_login)"
  fi

  # `docker compose up -d` pulls any missing images itself; do an explicit arch
  # check first so we never start an unrunnable image. The panel ref joins the
  # loop (#68) so a bad/unpullable panel image fails HERE, before any teardown.
  for _img in "$MIHOMO_IMAGE" "$METACUBEXD_IMAGE" "${PANEL_IMAGE:-}"; do
    [ -n "$_img" ] || continue
    ui_info "$(msgf info_pulling "$_img")"
    try "$(msgf diag_pull_fail "$_img")" "$(msg diag_pull_fail_fix)" -- pull_image "$_img" || { _show_log_tail; return 1; }
    if ! arch_ok "$_img"; then
      diagnose "$(msgf diag_arch_mismatch "$_img")" "$(msgf diag_arch_mismatch_fix "${EXPECTED_ARCH:-amd64}")"
      return 1
    fi
  done

  pf_compose_config || return 1
  ui_info "$(msg info_cfg_validate)"
  _cfg_test="$(mktemp -d "${TMPDIR:-/tmp}/smg-config.XXXXXX" 2>/dev/null)" || {
    diagnose "$(msg diag_cfg_tmp)" "$(msg diag_cfg_tmp_fix)"
    return 1
  }
  chmod 700 "$_cfg_test" 2>/dev/null || true
  # Tracked globally so the Ctrl-C trap can reap it: the staged copy holds
  # the subscription URL (token included) and must not outlive the run.
  SMG_CFG_STAGE="$_cfg_test"
  if ! cp "$REPO_ROOT/config/config.template.yaml" "$SUBSCRIPTION_FILE" "$_cfg_test/"; then
    rm -rf "$_cfg_test"; SMG_CFG_STAGE=""
    diagnose "$(msg diag_cfg_stage)" "$(msg diag_cfg_stage_fix)"
    return 1
  fi
  if ! MIHOMO_CONFIG_DIR="$_cfg_test" sh "$REPO_ROOT/scripts/render_config.sh" \
      >>"${LOG_FILE:-/dev/null}" 2>&1; then
    rm -rf "$_cfg_test"; SMG_CFG_STAGE=""
    diagnose "$(msg diag_cfg_render)" "$(msg diag_cfg_render_fix)"
    return 1
  fi
  if ! "$DOCKER_BIN" run --rm --entrypoint /mihomo \
      -v "$_cfg_test/config.yaml:/root/.config/mihomo/config.yaml:ro" \
      "$MIHOMO_IMAGE" -t -d /root/.config/mihomo \
      >>"${LOG_FILE:-/dev/null}" 2>&1; then
    rm -rf "$_cfg_test"; SMG_CFG_STAGE=""
    _show_log_tail
    diagnose "$(msg diag_cfg_reject)" "$(msg diag_cfg_reject_fix)"
    return 1
  fi
  if ! mihomo_auto_redirect_probe "$MIHOMO_IMAGE"; then
    rm -rf "$_cfg_test"; SMG_CFG_STAGE=""
    _show_log_tail
    diagnose "$(msg diag_auto_redirect)" "$(msg diag_auto_redirect_fix)"
    return 1
  fi
  rm -rf "$_cfg_test"; SMG_CFG_STAGE=""

  # Pre-seed the geo databases so mihomo's FIRST start never blocks on a
  # cross-border download (GEOSITE/GEOIP rules need them). Non-fatal: mihomo
  # can still fetch them itself; the doctor reports the cache state.
  if geodata_cached "$CONFIG_STATE_DIR"; then
    ui_ok "$(msg ok_geodata)"
  else
    ui_info "$(msg info_geodata)"
    if geodata_preseed "$CONFIG_STATE_DIR"; then
      ui_ok "$(msg ok_geodata)"
    else
      ui_warn "$(msg warn_geodata)"
    fi
  fi
  panel_prepare_dirs   # hand the panel's bind mounts to its uid before compose up
  return 0
}

# _deploy_teardown_notice - the closed-loop guarantee: when pre-deployment
# cleanup already removed the old stack (a cleanup mode was 'auto') and a later
# step fails, say so explicitly - the operator must know the gateway is DOWN,
# not assume the previous deployment still runs. Shared by deploy and redeploy.
_deploy_teardown_notice() {
  case "${CLEANUP_CONTAINERS_MODE:-preserve}:${CLEANUP_NETWORK_MODE:-preserve}" in
    *auto*) ui_warn "$(msg warn_prev_removed)"; ui_warn "$(msg warn_prev_removed_fix)" ;;
  esac
  return 1
}

rollback_installer_stack() {
  [ -n "${PREVIOUS_MIHOMO_IMAGE_ID:-}${PREVIOUS_METACUBEXD_IMAGE_ID:-}${PREVIOUS_PANEL_IMAGE_ID:-}" ] || return 1
  ui_warn "$(msg warn_rollback_attempt)"
  rollback_compose "${PREVIOUS_MIHOMO_IMAGE_ID:-}" "${PREVIOUS_METACUBEXD_IMAGE_ID:-}" \
    "${PREVIOUS_PANEL_IMAGE_ID:-}" \
    && health_gate
}

deploy_stack() {
  ui_step "$(msg step_deploy_stack)"
  ui_info "$(msg info_starting)"
  if ! compose_recreate; then
    _show_log_tail
    diagnose "$(msg diag_compose_up)" "$(msgf diag_compose_up_fix "$INSTALL_LOG")"
    rollback_installer_stack && ui_warn "$(msg warn_rollback_ok)"
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
    ui_warn "$(msg warn_rollback_ok)"
  else
    ui_error "$(msg err_rollback_failed)"
  fi
  return 1
}

# _ui_running - seam: is the dashboard container running? (tests stub this)
_ui_running() {
  "$DOCKER_BIN" inspect -f '{{.State.Running}}' "$METACUBEXD_CONTAINER" 2>/dev/null
}

# _report_pg_probe - post-deploy filtered-group surfacing (#37): run the
# doctor's proxy_groups check (scripts/lib/checks.sh - reused, never forked)
# once and stash the record for the verify-table row and the end-of-report
# block. DEC-A: reporting only - never fails the deploy. Guarded: several CI
# subshells source this flow without checks.sh; they get the skip row.
_report_pg_probe() {
  SMG_PG_VALUE=unknown SMG_PG_DETAIL=''
  command -v chk_proxy_groups >/dev/null 2>&1 || return 0
  CHECK_VALUE='' CHECK_SEV=ok CHECK_DETAIL='' CHECK_HINT=''
  chk_proxy_groups 2>/dev/null || return 0
  SMG_PG_VALUE="${CHECK_VALUE:-unknown}"
  SMG_PG_DETAIL="$CHECK_DETAIL"
  return 0
}

# _report_verify_table - the post-deploy verification table: re-probe what the
# health gate proved and show it as explicit rows, so success is demonstrated,
# not asserted. Informational only - never fails the deploy.
_report_verify_table() {
  ui_say "$(msg verify_title)"
  _vt_rc=0
  mihomo_controller_probe || _vt_rc=$?   # set -e-safe (the CI harness runs -eu)
  case "$_vt_rc" in
    0) ui_say "$(msgf verify_ok "$(msg verify_controller)")" ;;
    2) ui_say "$(msgf verify_skip "$(msg verify_controller)")" ;;
    *) ui_say "$(msgf verify_failed "$(msg verify_controller)")" ;;
  esac
  if [ "${TUN_ENABLE:-true}" = true ]; then
    if mihomo_gateway_probe; then
      ui_say "$(msgf verify_ok "$(msg verify_tun)")"
    else
      ui_say "$(msgf verify_failed "$(msg verify_tun)")"
    fi
  else
    ui_say "$(msgf verify_skip "$(msg verify_tun_off)")"
  fi
  if [ "$(_ui_running)" = "true" ]; then
    ui_say "$(msgf verify_ok "$(msg verify_ui)")"
  else
    ui_say "$(msgf verify_failed "$(msg verify_ui)")"
  fi
  _report_pg_probe
  case "$SMG_PG_VALUE" in
    ok)            ui_say "$(msgf verify_ok "$(msg verify_groups)")" ;;
    default-empty) ui_say "$(msgf verify_failed "$(msg verify_groups)")" ;;
    country-empty|provider-empty)
                   ui_say "$(msgf verify_warn "$(msg verify_groups)")" ;;
    *)             ui_say "$(msgf verify_skip "$(msg verify_groups)")" ;;
  esac
  if [ -n "${CONTROLLER_SECRET:-}" ]; then
    ui_say "$(msg rep_secret_loc)"
  else
    ui_warn "$(msg warn_dashboard_open)"
  fi
  return 0
}

report_success() {
  _rs_parent="${CHOSEN_IFACE:-${PARENT_INTERFACE:-}}"
  [ -n "$_rs_parent" ] \
    || _rs_parent="$(detect_parent_interface "${ROUTER_IP:-}")"
  _rs_nas_ip="$(_iface_ipv4 "$_rs_parent")"
  if [ -z "$_rs_nas_ip" ]; then
    # Platform-conditional placeholder (#53): unset PLATFORM_LABEL = DSM text.
    case "${PLATFORM_LABEL:-dsm}" in
      dsm) _rs_nas_ip='<NAS-IP>' ;;
      *)   _rs_nas_ip='<host-IP>' ;;
    esac
  fi

  ui_step "$(msg step_deploy_done)"
  ui_ok  "$(msg ok_gateway_up)"
  ui_say ""
  _report_verify_table
  ui_say ""
  ui_say "$(msg rep_dashboard)"
  ui_say "$(msgf rep_dashboard_url "$_rs_nas_ip" "${WEB_UI_PORT:-8080}")"
  ui_say "$(msg rep_add_backend)"
  ui_say "$(msgf rep_backend_line "${MIHOMO_IP:-<mihomo-ip>}" "${CONTROLLER_PORT:-9090}")"
  ui_say ""
  ui_say "$(msgf rep_point_client "${MIHOMO_IP:-<mihomo-ip>}")"
  ui_warn "$(msgf rep_warn_isolation "${MIHOMO_IP:-<mihomo-ip>}")"
  ui_say "$(msgf rep_reach_test "${MIHOMO_IP:-<mihomo-ip>}" "${CONTROLLER_PORT:-9090}")"
  ui_say ""
  ui_say "$(msg rep_next)"
  # Filtered-group finding LAST, below the success banner and the dashboard
  # help, so the operator's FINAL screen carries it (#37 DEC-A placement
  # rider: a mid-flow line is drowned by the success report). The deploy
  # still succeeds - empty filtered groups REJECT (fail closed) and recovery
  # is one dashboard click + a .env fix.
  case "${SMG_PG_VALUE:-unknown}" in
    default-empty)
      ui_say ""
      diagnose "$(msg diag_pg_default)" "$(msg diag_pg_default_fix)"
      [ -z "${SMG_PG_DETAIL:-}" ] || ui_say "  $SMG_PG_DETAIL" ;;
    country-empty)
      ui_say ""
      diagnose "$(msg diag_pg_country)" "$(msg diag_pg_country_fix)"
      [ -z "${SMG_PG_DETAIL:-}" ] || ui_say "  $SMG_PG_DETAIL" ;;
    provider-empty)
      ui_say ""
      diagnose "$(msg diag_pg_provider)" "$(msg diag_pg_provider_fix)"
      [ -z "${SMG_PG_DETAIL:-}" ] || ui_say "  $SMG_PG_DETAIL" ;;
  esac
  return 0
}

flow_deploy() {
  ui_step "$(msg step_deploy_e2e)"

  if ! is_root; then
    diagnose "deployment requires root privileges" "re-run: sudo sh ./${INSTALLER_ENTRY:-install.sh}"
    return 1
  fi

  seed_config       || return 1
  load_env                                  # .env now exists; export its values

  pf_docker         || return 1             # lifecycle inspect/cleanup needs docker
  plan_predeployment_cleanup || return 1    # DECIDE first (on the saved .env params)
                                            # so interface + IP detection run clean

  scan_and_prefill  || return 1             # interface -> derive router/subnet
  load_env                                  # pick up derived ROUTER_IP/SUBNET_CIDR

  # Express fast path (one confirmation screen of all detected/saved values);
  # declining - or incomplete detection - falls back to the per-item wizards.
  _fd_express=0
  if wizard_express; then _fd_express=1; fi
  if [ "$_fd_express" = 0 ]; then
    wizard_env      || return 1             # MIHOMO_IP suggested from the NAS IP
  fi
  if [ "$_fd_express" = 1 ] \
     && [ -n "$(env_get MIHOMO_IMAGE 2>/dev/null || echo '')" ] \
     && [ -n "$(env_get METACUBEXD_IMAGE 2>/dev/null || echo '')" ]; then
    :                                       # image refs already resolved + shown
  else
    wizard_images   || return 1
  fi
  if [ "$_fd_express" = 1 ] && resolve_subscription_url "$(subscription_current)" >/dev/null 2>&1; then
    :                                       # a valid stored URL was part of the screen
  else
    wizard_subscription || return 1
  fi
  load_env                                  # re-load after the wizards wrote .env

  # Gateway panel knobs (#68): derive PANEL_IMAGE, generate PANEL_SECRET,
  # ask/validate PANEL_IP. Runs AFTER the wizards (needs SUBNET_CIDR,
  # MIHOMO_IP and the registry knobs) and BEFORE prepare_stack (whose
  # compose-config preflight fails closed on the missing knobs).
  _pc_panel_backfill || return 1
  load_env

  pf_arch           || return 1
  pf_web_port       || return 1
  validate_selected_network || return 1
  prepare_stack     || return 1             # pull + validate NEW images (non-destructive)

  apply_predeployment_cleanup || return 1   # TEAR DOWN only after validation (safety kept)
  if ! create_network; then                 # root: TUN + macvlan (final IP guard inside)
    _deploy_teardown_notice                 # closed loop: say the old stack is gone
    return 1
  fi
  load_env

  # deploy_stack's own rollback messaging (warn_rollback_ok/err_rollback_failed)
  # already states the outcome, so no teardown notice is layered on top here.
  deploy_stack      || return 1
  report_success
  return 0
}
