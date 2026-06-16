#!/bin/sh
# flow_deploy.sh - Flow A: end-to-end deploy state machine.
#   seed -> env wizard -> image wizard -> subscription -> preflight -> network ->
#   ACR login (acr mode) -> compose up + health gate -> report.
#
# Requires the full installer module set sourced (see install.sh). POSIX /bin/sh.

# deploy_stack - bring the compose services up and health-gate them.
deploy_stack() {
  ui_step "Deploy the stack"
  if [ "${REGISTRY_MODE:-acr}" = "acr" ]; then
    try "ACR login failed" "check DOCKER_USERNAME / ACR_PASSWORD (token expiry?) in .env" -- acr_login || return 1
  else
    ui_info "REGISTRY_MODE=docker - skipping registry login (public images)"
  fi

  # `docker compose up -d` pulls any missing images itself; do an explicit arch
  # check first so we never start an unrunnable image.
  for _img in "$MIHOMO_IMAGE" "$METACUBEXD_IMAGE"; do
    [ -n "$_img" ] || continue
    ui_info "pulling $_img"
    try "could not pull $_img" "confirm the image exists in your registry and the NAS can reach it" -- pull_image "$_img" || return 1
    if ! arch_ok "$_img"; then
      diagnose "image arch mismatch for $_img" "mirror a ${EXPECTED_ARCH:-amd64} image, or set EXPECTED_ARCH to this NAS's arch in .env"
      return 1
    fi
  done

  ui_info "starting containers (docker compose up -d)"
  if ! compose_up; then
    diagnose "docker compose up -d failed" "review the output above and $INSTALL_LOG; verify the macvlan network and .env image refs"
    return 1
  fi
  if health_gate; then
    ui_ok "mihomo is running and healthy"
    return 0
  fi
  diagnose "mihomo did not become healthy" "inspect 'docker logs mihomo'; a bad subscription URL or DNS in .env is the usual cause"
  return 1
}

report_success() {
  ui_step "Deployment complete"
  ui_ok  "The gateway is up."
  ui_say ""
  ui_say "Dashboard (open from a LAN device that is NOT the NAS):"
  ui_say "    http://<NAS-IP>:${WEB_UI_PORT:-8080}"
  ui_say "  Add a backend in the dashboard:"
  ui_say "    Host=${MIHOMO_IP:-<mihomo-ip>}  Port=${CONTROLLER_PORT:-9090}  Secret=<your controller secret>"
  ui_say ""
  ui_say "Point a client's gateway + DNS at ${MIHOMO_IP:-<mihomo-ip>} to route it through the proxy."
  ui_warn "The NAS itself cannot reach ${MIHOMO_IP:-the mihomo IP} (macvlan isolation) - always test from another device."
  ui_say ""
  ui_say "Next: set up automatic image updates from the main menu (option 2)."
  return 0
}

flow_deploy() {
  ui_step "End-to-end deploy"

  seed_config       || return 1
  load_env                                  # .env now exists; export its values
  wizard_env        || return 1
  wizard_images     || return 1
  wizard_subscription || return 1
  load_env                                  # re-load after the wizards wrote .env

  pf_docker         || return 1
  pf_arch

  setup_network_interactive || return 1
  load_env                                  # network.sh did not touch .env, but be safe

  deploy_stack      || return 1
  report_success
  return 0
}
