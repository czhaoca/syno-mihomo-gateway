#!/bin/sh
# preflight_linux.sh (scripts/linux) - generic-Linux preflight overlay (epic
# generic-linux-port, #48): the macvlan-viability guard, its wiring into the
# deploy entry and the apply_predeployment_cleanup + create_network choke
# points (ack BEFORE any teardown), the fresh-seed image-ref blanking that
# closes the express-path bypass, and the docker-default registry wizard
# (DEC-4). ADDITIVE like the rest of scripts/linux/: only
# install-linux.sh sources this file (LAST, after the pi engine and the i18n
# overlay), and every redefinition here shadows by name at call time - the
# stock installer modules and the scripts/pi/ engine stay frozen. Requires the
# full install-linux.sh module set sourced first (common.sh, ui.sh, i18n.sh +
# overlays, envedit.sh, registry.sh, resolve.sh, netscan.sh, wizards.sh,
# scripts/pi/preflight.sh, flow_compose.sh, flow_lite.sh). POSIX /bin/sh.

# linux_virt_detect - print the detected VM/cloud flavor and return 0, or
# return 1 on bare metal (DEC-A: systemd-detect-virt first - curated and
# maintained - with a /sys/class/dmi read as the fallback where systemd is
# absent; SMG_LX_DMI_DIR is the test seam). Heuristic by design: a bridged VM
# where macvlan works fine can false-positive, which is acceptable because the
# guard below only warns and asks - it never refuses. A false NEGATIVE just
# means no guard, exactly today's behavior. The DMI needles avoid vendor
# strings that also appear on bare metal (Surface reports "Microsoft
# Corporation", Chromebooks report "Google" - so match the VM/cloud product
# combos instead: "Virtual Machine", "Google Compute Engine").
linux_virt_detect() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    _lv_t="$(systemd-detect-virt --vm 2>/dev/null)"
    if [ -n "$_lv_t" ] && [ "$_lv_t" != none ]; then
      printf '%s\n' "$_lv_t"
      return 0
    fi
    return 1
  fi
  _lv_d="${SMG_LX_DMI_DIR:-/sys/class/dmi/id}"
  _lv_s="$(cat "$_lv_d/sys_vendor" "$_lv_d/product_name" 2>/dev/null | tr '\n' ' ')"
  [ -n "$_lv_s" ] || return 1
  case "$_lv_s" in
    *QEMU*|*KVM*|*VMware*|*VirtualBox*|*innotek*|*Xen*|*'Virtual Machine'*| \
    *Amazon*|*'Google Compute Engine'*|*'Alibaba Cloud'*|*OpenStack*| \
    *DigitalOcean*|*Hetzner*|*Vultr*|*Scaleway*|*Parallels*|*Nutanix*|*oVirt*)
      printf '%s\n' "$_lv_s" | sed 's/ *$//'
      return 0 ;;
  esac
  return 1
}

# linux_macvlan_guard - the macvlan-viability gate: on a virt/cloud host warn
# that macvlan children often cannot forward LAN traffic (cloud VPCs filter
# unknown source MACs; some hypervisor vswitches drop them), recommend lite
# mode, and require an explicit acknowledgment (default No) before a macvlan
# deploy - never a silent hard refusal (mirrors the ARMv6 ack posture,
# pre-decided #48). The session memo means the wizard-time ack is not re-asked
# when the same deploy reaches the create_network choke point below.
linux_macvlan_guard() {
  [ "${SMG_LX_MACVLAN_ACK:-0}" = 1 ] && return 0
  _lg_v="$(linux_virt_detect)" || return 0
  ui_warn "$(msgf lx_warn_macvlan_virt "$_lg_v")"
  ui_warn "$(msg lx_warn_macvlan_virt_2)"
  ui_yesno "$(msg lx_ask_macvlan_ack)" n || return 1
  SMG_LX_MACVLAN_ACK=1
  return 0
}

# pi_flow_deploy_entry - same tiny dispatch as the pi original (flow_compose.sh)
# plus the viability gate between the mode wizard and the compose flow: a
# declined ack STEERS into the sanctioned lite flow instead of aborting
# (lite binds the host directly - no macvlan - so it works on these hosts).
pi_flow_deploy_entry() {
  pi_mode_wizard || return 1
  if [ "${PI_MODE:-}" = compose ] && ! linux_macvlan_guard; then
    ui_info "$(msg lx_steer_lite)"
    PI_MODE=lite
  fi
  case "${PI_MODE:-}" in
    compose) pi_flow_compose ;;
    lite)    pi_flow_lite ;;
    *)       return 1 ;;
  esac
}

# --- create_network interposition -------------------------------------------------
# The redeploy and Modify paths reach create_network WITHOUT passing the deploy
# entry above, so the guard must also sit at the choke point every macvlan
# creation funnels through - the same reasoning (and the same fail-closed
# capture pattern) as the pi wlan interposition in scripts/pi/preflight.sh.
# Capture the PI create_network (wlan refusal + delegate to the captured stock
# body) verbatim at source time, then wrap it with the viability gate. If the
# pi preflight's function layout ever changes, the eval fails or defines
# nothing and sourcing aborts loudly - caught by the CI sourcing test.
_lx_pfl_src="$REPO_ROOT/scripts/pi/preflight.sh"
if ! eval "lx_pi_create_network() {
$(sed -n '/^create_network() {$/,/^}$/p' "$_lx_pfl_src" | sed '1d;$d')
}" || ! command -v lx_pi_create_network >/dev/null 2>&1; then
  echo "FATAL: could not capture create_network from $_lx_pfl_src (layout changed?)" >&2
  exit "${EXIT_CONFIG:-3}"
fi

create_network() {
  linux_macvlan_guard || return 1
  lx_pi_create_network
}

# --- apply_predeployment_cleanup interposition ------------------------------------
# On the redeploy and Modify paths the FIRST destructive step is the cleanup
# (flow_redeploy, flow_modify's apply branch and setup_network_interactive all
# run apply_predeployment_cleanup before create_network), so gating only at
# create_network would ask the macvlan question AFTER a working stack was torn
# down - and a declined (default-No) ack would strand the operator with the
# old deployment gone. Interpose the guard here too: the ack (or the session
# memo from an earlier answer) resolves BEFORE anything is removed, and a
# decline aborts pre-mutation with the deployment intact. Same fail-closed
# capture pattern as create_network above.
_lx_pp_src="$REPO_ROOT/scripts/installer/preprocess.sh"
if ! eval "lx_stock_apply_predeployment_cleanup() {
$(sed -n '/^apply_predeployment_cleanup() {$/,/^}$/p' "$_lx_pp_src" | sed '1d;$d')
}" || ! command -v lx_stock_apply_predeployment_cleanup >/dev/null 2>&1; then
  echo "FATAL: could not capture apply_predeployment_cleanup from $_lx_pp_src (layout changed?)" >&2
  exit "${EXIT_CONFIG:-3}"
fi

apply_predeployment_cleanup() {
  linux_macvlan_guard || return 1
  lx_stock_apply_predeployment_cleanup
}

# --- seed_config interposition ----------------------------------------------------
# The committed .env.example ships NONEMPTY placeholder ACR image refs, and the
# express fast path (wizard_express + flow_deploy's image gate) treats nonempty
# refs as "already configured" - so a fresh generic install accepting the
# express screen would never reach the registry wizard and would deploy the
# acr placeholders. Blank the two image refs when (and only when) seed_config
# CREATES the .env: the express screen then honestly reports that the image
# wizard will run, flow_deploy's gate falls through to wizard_images (the
# docker-default wizard below), and compose's ${VAR:?} wiring keeps a manual
# deploy of the half-seeded file failing loudly. An existing .env - however it
# was configured - is never touched.
_lx_wz_src="$REPO_ROOT/scripts/installer/wizards.sh"
if ! eval "lx_stock_seed_config() {
$(sed -n '/^seed_config() {$/,/^}$/p' "$_lx_wz_src" | sed '1d;$d')
}" || ! command -v lx_stock_seed_config >/dev/null 2>&1; then
  echo "FATAL: could not capture seed_config from $_lx_wz_src (layout changed?)" >&2
  exit "${EXIT_CONFIG:-3}"
fi

seed_config() {
  _ls_fresh=0
  [ -f "${ENV_FILE:-}" ] || _ls_fresh=1
  lx_stock_seed_config || return 1
  if [ "$_ls_fresh" = 1 ]; then
    env_set MIHOMO_IMAGE '' || return 1
    env_set METACUBEXD_IMAGE '' || return 1
  fi
  return 0
}

# wizard_images - the generic registry wizard (DEC-4): docker (upstream
# multi-arch Docker Hub / ghcr.io) is the DEFAULT for the generic audience,
# acr stays selectable for mainland-China users with the arch notice for
# non-amd64 hosts (the default mirror pipeline publishes amd64 only). Writes
# ONLY the user's gitignored .env via env_set - the committed .env.example
# keeps its acr default untouched. flow_deploy calls wizard_images BY NAME at
# runtime, so this last-sourced definition retargets the stock deploy pipeline
# without touching scripts/installer/. Past the mode pick the body mirrors the
# stock wizard_images (wizards.sh) line for line - keep them in step.
wizard_images() {
  ui_step "$(msg step_images)"
  _mode=""
  ui_say "$(msg lx_images_where)"
  ui_menu_select _sel "$(msg images_choose)" \
    "$(msg lx_images_opt_docker)" \
    "$(msg lx_images_opt_acr)"
  case "$UI_MENU_INDEX" in
    2) _mode=acr ;;
    *) _mode=docker ;;
  esac
  # shellcheck disable=SC2034  # read by pi_acr_arch_notice + resolve_images (other modules) at run time
  REGISTRY_MODE="$_mode"

  if [ "$_mode" = acr ]; then
    pi_acr_arch_notice
    ui_ask DOCKER_REGISTRY "$(msg q_acr_host)" "$(env_get DOCKER_REGISTRY || echo 'registry.cn-shenzhen.aliyuncs.com')"
    env_set DOCKER_REGISTRY "$DOCKER_REGISTRY"
    ui_ask ACR_NAMESPACE "$(msg q_acr_namespace)" "$(env_get ACR_NAMESPACE || echo '')"
    env_set ACR_NAMESPACE "$ACR_NAMESPACE"
    ui_ask DOCKER_USERNAME "$(msg q_acr_username)" "$(env_get DOCKER_USERNAME || echo '')"
    env_set DOCKER_USERNAME "$DOCKER_USERNAME"
    ui_ask_secret ACR_PASSWORD "$(msg q_acr_password)"
    [ -n "$ACR_PASSWORD" ] && env_set ACR_PASSWORD "$ACR_PASSWORD"
  fi

  ui_ask MIHOMO_TAG "$(msg q_mihomo_tag)" "$(env_get MIHOMO_TAG || echo latest)"
  env_set MIHOMO_TAG "$MIHOMO_TAG"
  ui_ask METACUBEXD_TAG "$(msg q_metacubexd_tag)" "$(env_get METACUBEXD_TAG || echo latest)"
  env_set METACUBEXD_TAG "$METACUBEXD_TAG"

  # resolve + persist the image refs from the saved settings (lib/resolve.sh).
  # shellcheck disable=SC2034  # consumed inside resolve_images at run time
  REGISTRY_MODE="$_mode"
  resolve_images || { diagnose "$(msg diag_derive_images)" "$(msg diag_derive_images_fix)"; return 1; }
  ui_ok "$(msgf ok_images "$MIHOMO_IMAGE")"
  ui_ok "$(msgf ok_images_cont "$METACUBEXD_IMAGE")"

  if ui_yesno "$(msg ask_cloudflared)" n; then
    ui_ask CF_TAG "$(msg q_cf_tag)" "$(env_get CF_TAG || echo latest)"
    env_set CF_TAG "$CF_TAG"
    if CF_IMAGE="$(derive_ref cloudflared "$CF_TAG")"; then
      env_set CF_IMAGE "$CF_IMAGE"
      ui_ok "$(msgf ok_cf_image "$CF_IMAGE")"
    fi
    # Reuse the token from an already-running cloudflared container when present
    # (blue-green preserves it); only force a token to provision the first one.
    if cloudflared_token_present; then
      ui_info "$(msgf info_cf_detected "${CF_CONTAINER_NAME:-cloudflared}")"
      ui_ask_secret CF_TUNNEL_TOKEN "$(msg q_cf_token)"
      [ -n "$CF_TUNNEL_TOKEN" ] && env_set CF_TUNNEL_TOKEN "$CF_TUNNEL_TOKEN"
    else
      while :; do
        ui_ask_secret CF_TUNNEL_TOKEN "$(msg q_cf_token_new)"
        [ -n "$CF_TUNNEL_TOKEN" ] && break
        ui_warn "$(msg warn_cf_token_required)"
      done
      env_set CF_TUNNEL_TOKEN "$CF_TUNNEL_TOKEN"
    fi
  fi
  # Persist the concrete update-target references, including a cloudflared ref
  # added just above (lib/resolve.sh).
  resolve_update_images
  return 0
}
