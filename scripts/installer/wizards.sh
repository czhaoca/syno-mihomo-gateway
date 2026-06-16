#!/bin/sh
# wizards.sh - the guided configuration sub-steps shared by the deploy and
# modify flows: seed config files, the .env wizard, the image-source wizard, and
# the subscription wizard. Each prompt pre-fills from the current .env value so
# pressing Enter is a safe no-op (idempotent re-runs).
#
# Requires ui.sh, envedit.sh, preflight.sh sourced first. POSIX /bin/sh.

# seed_config - create .env + config/subscription.txt from the shipped examples
# if absent (never clobber a configured file), and restore +x on scripts. Folds
# bootstrap.sh's behavior so the operator only ever runs install.sh.
seed_config() {
  ui_step "$(msg step_seed)"
  if [ -f "$ENV_FILE" ]; then
    ui_ok "$(msg ok_env_keep)"
  elif [ -f "$REPO_ROOT/.env.example" ]; then
    cp "$REPO_ROOT/.env.example" "$ENV_FILE" && chmod 600 "$ENV_FILE" \
      && ui_ok "$(msg ok_env_created)" \
      || { diagnose "$(msg diag_env_create)" "$(msg diag_env_create_fix)"; return 1; }
  else
    diagnose "$(msg diag_no_example)" "$(msg diag_no_example_fix)"
    return 1
  fi

  # Persist the language picked on the first screen so the saved .env reflects it.
  env_set INSTALLER_LANG "${INSTALLER_LANG:-en}"

  _sub="$REPO_ROOT/config/subscription.txt"
  if [ ! -f "$_sub" ] && [ -f "$REPO_ROOT/config/subscription.txt.example" ]; then
    cp "$REPO_ROOT/config/subscription.txt.example" "$_sub" \
      && ui_ok "$(msg ok_sub_created)"
  fi

  if [ -d "$REPO_ROOT/scripts" ]; then
    chmod +x "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh \
             "$REPO_ROOT"/scripts/installer/*.sh 2>/dev/null
  fi
  return 0
}

# wizard_env - prompt + persist the network / DNS / port / secret settings.
wizard_env() {
  ui_step "$(msg step_env)"
  ui_ask_validated ROUTER_IP "$(msg q_router)" "$(env_get ROUTER_IP || echo 192.168.1.1)" is_ipv4
  env_set ROUTER_IP "$ROUTER_IP"
  ui_ask_validated SUBNET_CIDR "$(msg q_subnet)" "$(env_get SUBNET_CIDR || echo 192.168.1.0/24)" is_cidr
  env_set SUBNET_CIDR "$SUBNET_CIDR"
  while :; do
    ui_ask_validated MIHOMO_IP "$(msg q_mihomo_ip)" "$(env_get MIHOMO_IP || echo 192.168.1.100)" is_ipv4
    check_ip_conflict "$MIHOMO_IP" && break
  done
  env_set MIHOMO_IP "$MIHOMO_IP"

  ui_ask_validated WEB_UI_PORT "$(msg q_web_port)" "$(env_get WEB_UI_PORT || echo 8080)" is_port
  env_set WEB_UI_PORT "$WEB_UI_PORT"
  if [ "$(pf_port_free "$WEB_UI_PORT"; echo $?)" = "1" ]; then
    ui_warn "$(msgf warn_port_in_use "$WEB_UI_PORT")"
  fi
  ui_ask_validated CONTROLLER_PORT "$(msg q_controller_port)" "$(env_get CONTROLLER_PORT || echo 9090)" is_port
  env_set CONTROLLER_PORT "$CONTROLLER_PORT"

  while :; do
    ui_ask_secret CONTROLLER_SECRET "$(msg q_controller_secret)"
    case "$CONTROLLER_SECRET" in
      *"|"*) ui_warn "$(msg warn_secret_pipe)" ;;
      *) break ;;
    esac
  done
  env_set CONTROLLER_SECRET "$CONTROLLER_SECRET"

  ui_ask DNS_DEFAULT_NAMESERVER "$(msg q_dns_bootstrap)" "$(env_get DNS_DEFAULT_NAMESERVER || echo 1.1.1.1)"
  env_set DNS_DEFAULT_NAMESERVER "$DNS_DEFAULT_NAMESERVER"
  ui_ask DNS_NAMESERVER "$(msg q_dns_domestic)" "$(env_get DNS_NAMESERVER || echo 1.1.1.1)"
  env_set DNS_NAMESERVER "$DNS_NAMESERVER"
  ui_ask DNS_FALLBACK "$(msg q_dns_fallback)" "$(env_get DNS_FALLBACK || echo 1.1.1.1)"
  env_set DNS_FALLBACK "$DNS_FALLBACK"

  ui_ask TZ "$(msg q_tz)" "$(env_get TZ || echo Asia/Shanghai)"
  env_set TZ "$TZ"
  ui_ok "$(msg ok_env_saved)"
  return 0
}

# wizard_images - pick the image source (REGISTRY_MODE), collect registry creds
# + tags, and derive the image refs (req #4).
wizard_images() {
  ui_step "$(msg step_images)"
  _mode=""
  ui_say "$(msg images_where)"
  ui_menu_select _sel "$(msg images_choose)" \
    "$(msg images_opt_acr)" \
    "$(msg images_opt_docker)"
  case "$UI_MENU_INDEX" in
    1) _mode=acr ;;
    *) _mode=docker ;;
  esac

  if [ "$_mode" = docker ]; then
    ui_warn "$(msg warn_docker_blocked)"
    if ! ui_yesno "$(msg ask_unfiltered)" n; then
      ui_warn "$(msg warn_keep_acr)"
      _mode=acr
    fi
  fi
  REGISTRY_MODE="$_mode"

  if [ "$_mode" = acr ]; then
    ui_ask DOCKER_REGISTRY "$(msg q_acr_host)" "$(env_get DOCKER_REGISTRY || echo '')"
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

  # refresh the shell vars derive_images reads, then resolve + persist refs.
  REGISTRY_MODE="$_mode"
  DOCKER_REGISTRY="$(env_get DOCKER_REGISTRY || echo '')"
  ACR_NAMESPACE="$(env_get ACR_NAMESPACE || echo '')"
  MIHOMO_TAG="$(env_get MIHOMO_TAG || echo latest)"
  METACUBEXD_TAG="$(env_get METACUBEXD_TAG || echo latest)"
  export REGISTRY_MODE DOCKER_REGISTRY ACR_NAMESPACE MIHOMO_TAG METACUBEXD_TAG
  derive_images || { diagnose "$(msg diag_derive_images)" "$(msg diag_derive_images_fix)"; return 1; }
  ui_ok "$(msgf ok_images "$MIHOMO_IMAGE")"
  ui_ok "$(msgf ok_images_cont "$METACUBEXD_IMAGE")"

  if ui_yesno "$(msg ask_cloudflared)" n; then
    ui_ask CF_TAG "$(msg q_cf_tag)" "$(env_get CF_TAG || echo latest)"
    env_set CF_TAG "$CF_TAG"
    if CF_IMAGE="$(derive_ref cloudflared "$CF_TAG")"; then
      env_set CF_IMAGE "$CF_IMAGE"
      ui_ok "$(msgf ok_cf_image "$CF_IMAGE")"
    fi
    ui_ask_secret CF_TUNNEL_TOKEN "$(msg q_cf_token)"
    [ -n "$CF_TUNNEL_TOKEN" ] && env_set CF_TUNNEL_TOKEN "$CF_TUNNEL_TOKEN"
  fi
  return 0
}

# wizard_subscription - capture the airport/subscription URL into
# config/subscription.txt (never silently overwrite a real one).
wizard_subscription() {
  ui_step "$(msg step_sub)"
  _sub="$REPO_ROOT/config/subscription.txt"
  _example="$REPO_ROOT/config/subscription.txt.example"
  _cur=""
  if [ -f "$_sub" ]; then
    if [ -f "$_example" ] && cmp -s "$_sub" "$_example"; then
      _cur=""   # still the shipped placeholder
    else
      _cur="$(grep -v '^#' "$_sub" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n1)"
    fi
  fi
  if [ -n "$_cur" ]; then
    ui_say "$(msgf sub_current "$_cur")"
    ui_yesno "$(msg ask_replace_sub)" n || { ui_ok "$(msg ok_sub_kept)"; return 0; }
  fi
  while :; do
    ui_ask _url "$(msg q_sub_url)" ""
    case "$_url" in
      http://*|https://*) break ;;
      '') ui_warn "$(msg warn_sub_required)" ;;
      *) ui_warn "$(msg warn_sub_scheme)" ;;
    esac
  done
  if printf '%s\n' "$_url" > "$_sub"; then
    ui_ok "$(msg ok_sub_saved)"
    return 0
  fi
  diagnose "$(msgf diag_sub_write "$_sub")" "$(msg diag_sub_write_fix)"
  return 1
}
