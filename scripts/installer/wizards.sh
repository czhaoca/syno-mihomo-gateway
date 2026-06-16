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
  ui_step "Preparing configuration files"
  if [ -f "$ENV_FILE" ]; then
    ui_ok ".env exists - keeping your settings"
  elif [ -f "$REPO_ROOT/.env.example" ]; then
    cp "$REPO_ROOT/.env.example" "$ENV_FILE" && chmod 600 "$ENV_FILE" \
      && ui_ok "created .env from the template (chmod 600)" \
      || { diagnose "could not create .env" "check write permission on this folder"; return 1; }
  else
    diagnose ".env.example is missing" "re-extract the release bundle"
    return 1
  fi

  _sub="$REPO_ROOT/config/subscription.txt"
  if [ ! -f "$_sub" ] && [ -f "$REPO_ROOT/config/subscription.txt.example" ]; then
    cp "$REPO_ROOT/config/subscription.txt.example" "$_sub" \
      && ui_ok "created config/subscription.txt from the template"
  fi

  if [ -d "$REPO_ROOT/scripts" ]; then
    chmod +x "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh \
             "$REPO_ROOT"/scripts/installer/*.sh 2>/dev/null
  fi
  return 0
}

# wizard_env - prompt + persist the network / DNS / port / secret settings.
wizard_env() {
  ui_step "Network & DNS configuration"
  ui_ask_validated ROUTER_IP "Router / Gateway IP" "$(env_get ROUTER_IP || echo 192.168.1.1)" is_ipv4
  env_set ROUTER_IP "$ROUTER_IP"
  ui_ask_validated SUBNET_CIDR "Home LAN subnet (CIDR)" "$(env_get SUBNET_CIDR || echo 192.168.1.0/24)" is_cidr
  env_set SUBNET_CIDR "$SUBNET_CIDR"
  ui_ask_validated MIHOMO_IP "Static LAN IP for mihomo (must be unused)" "$(env_get MIHOMO_IP || echo 192.168.1.100)" is_ipv4
  env_set MIHOMO_IP "$MIHOMO_IP"

  ui_ask_validated WEB_UI_PORT "Dashboard port (published on the NAS)" "$(env_get WEB_UI_PORT || echo 8080)" is_port
  env_set WEB_UI_PORT "$WEB_UI_PORT"
  if [ "$(pf_port_free "$WEB_UI_PORT"; echo $?)" = "1" ]; then
    ui_warn "port $WEB_UI_PORT looks already in use - pick another if the dashboard fails to start"
  fi
  ui_ask_validated CONTROLLER_PORT "Mihomo controller port" "$(env_get CONTROLLER_PORT || echo 9090)" is_port
  env_set CONTROLLER_PORT "$CONTROLLER_PORT"

  while :; do
    ui_ask_secret CONTROLLER_SECRET "Controller secret (Enter for no auth)"
    case "$CONTROLLER_SECRET" in
      *"|"*) ui_warn "the secret must not contain a '|' character" ;;
      *) break ;;
    esac
  done
  env_set CONTROLLER_SECRET "$CONTROLLER_SECRET"

  ui_ask DNS_DEFAULT_NAMESERVER "Bootstrap DNS (comma-separated)" "$(env_get DNS_DEFAULT_NAMESERVER || echo 114.114.114.114,223.5.5.5)"
  env_set DNS_DEFAULT_NAMESERVER "$DNS_DEFAULT_NAMESERVER"
  ui_ask DNS_NAMESERVER "Domestic DNS (comma-separated)" "$(env_get DNS_NAMESERVER || echo 114.114.114.114,223.5.5.5)"
  env_set DNS_NAMESERVER "$DNS_NAMESERVER"
  ui_ask DNS_FALLBACK "Overseas / fallback DNS (comma-separated)" "$(env_get DNS_FALLBACK || echo 8.8.8.8,8.8.4.4)"
  env_set DNS_FALLBACK "$DNS_FALLBACK"

  ui_ask TZ "Timezone" "$(env_get TZ || echo Asia/Shanghai)"
  env_set TZ "$TZ"
  ui_ok "saved network & DNS settings to .env"
  return 0
}

# wizard_images - pick the image source (REGISTRY_MODE), collect registry creds
# + tags, and derive the image refs (req #4).
wizard_images() {
  ui_step "Container image source"
  _sel=""; _mode=""
  ui_say "Where should the gateway pull its container images from?"
  ui_menu_select _sel "Choose" \
    "Alibaba ACR mirror (recommended for mainland China)" \
    "Docker Hub / ghcr upstream (BLOCKED in mainland China)"
  case "$_sel" in
    Alibaba*) _mode=acr ;;
    *)        _mode=docker ;;
  esac

  if [ "$_mode" = docker ]; then
    ui_warn "Docker Hub and ghcr.io are unreachable behind the mainland-China firewall."
    if ! ui_yesno "Does this NAS have UNFILTERED internet (not behind the GFW)?" n; then
      ui_warn "keeping the ACR mirror as the image source"
      _mode=acr
    fi
  fi
  REGISTRY_MODE="$_mode"

  if [ "$_mode" = acr ]; then
    ui_ask DOCKER_REGISTRY "ACR registry host (e.g. registry.cn-shenzhen.aliyuncs.com)" "$(env_get DOCKER_REGISTRY || echo '')"
    env_set DOCKER_REGISTRY "$DOCKER_REGISTRY"
    ui_ask ACR_NAMESPACE "ACR namespace" "$(env_get ACR_NAMESPACE || echo '')"
    env_set ACR_NAMESPACE "$ACR_NAMESPACE"
    ui_ask DOCKER_USERNAME "ACR username" "$(env_get DOCKER_USERNAME || echo '')"
    env_set DOCKER_USERNAME "$DOCKER_USERNAME"
    ui_ask_secret ACR_PASSWORD "ACR password / access token (Enter to keep existing)"
    [ -n "$ACR_PASSWORD" ] && env_set ACR_PASSWORD "$ACR_PASSWORD"
  fi

  ui_ask MIHOMO_TAG "mihomo image tag" "$(env_get MIHOMO_TAG || echo latest)"
  env_set MIHOMO_TAG "$MIHOMO_TAG"
  ui_ask METACUBEXD_TAG "metacubexd image tag" "$(env_get METACUBEXD_TAG || echo latest)"
  env_set METACUBEXD_TAG "$METACUBEXD_TAG"

  # refresh the shell vars derive_images reads, then resolve + persist refs.
  REGISTRY_MODE="$_mode"
  DOCKER_REGISTRY="$(env_get DOCKER_REGISTRY || echo '')"
  ACR_NAMESPACE="$(env_get ACR_NAMESPACE || echo '')"
  MIHOMO_TAG="$(env_get MIHOMO_TAG || echo latest)"
  METACUBEXD_TAG="$(env_get METACUBEXD_TAG || echo latest)"
  export REGISTRY_MODE DOCKER_REGISTRY ACR_NAMESPACE MIHOMO_TAG METACUBEXD_TAG
  derive_images || { diagnose "could not derive image references" "ACR mode needs the registry host AND namespace set"; return 1; }
  ui_ok "images: $MIHOMO_IMAGE"
  ui_ok "        $METACUBEXD_IMAGE"

  if ui_yesno "Also manage a cloudflared tunnel container? (advanced, optional)" n; then
    ui_ask CF_TAG "cloudflared image tag" "$(env_get CF_TAG || echo latest)"
    env_set CF_TAG "$CF_TAG"
    if CF_IMAGE="$(derive_ref cloudflared "$CF_TAG")"; then
      env_set CF_IMAGE "$CF_IMAGE"
      ui_ok "cloudflared image: $CF_IMAGE"
    fi
    ui_ask_secret CF_TUNNEL_TOKEN "cloudflared tunnel token (Enter to reuse the running one)"
    [ -n "$CF_TUNNEL_TOKEN" ] && env_set CF_TUNNEL_TOKEN "$CF_TUNNEL_TOKEN"
  fi
  return 0
}

# wizard_subscription - capture the airport/subscription URL into
# config/subscription.txt (never silently overwrite a real one).
wizard_subscription() {
  ui_step "Airport / subscription URL"
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
    ui_say "current: $_cur"
    ui_yesno "replace the existing subscription URL?" n || { ui_ok "kept the existing subscription"; return 0; }
  fi
  while :; do
    ui_ask _url "Subscription URL" ""
    case "$_url" in
      http://*|https://*) break ;;
      '') ui_warn "a subscription URL is required" ;;
      *) ui_warn "the URL must start with http:// or https://" ;;
    esac
  done
  if printf '%s\n' "$_url" > "$_sub"; then
    ui_ok "subscription saved"
    return 0
  fi
  diagnose "could not write $_sub" "check that this folder is writable"
  return 1
}
