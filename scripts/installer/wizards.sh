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

# _sanitize_url - clean the common paste artifacts that corrupt a pasted
# subscription URL ("the https link is not properly copied"):
#   * bracketed-paste wrappers: modern terminals send the pasted text wrapped in
#     ESC[200~ ... ESC[201~; a bare `read` captures them literally. Strip ALL
#     control chars (URLs never contain them; this also drops a stray CR) then
#     remove the leftover [200~ / [201~ markers.
#   * surrounding single/double quotes (users paste "https://...").
#   * a leading "label=" prefix (the documented Name=URL file format) so the
#     interactive wizard accepts the same form the file does.
#   * leading/trailing whitespace.
# Echoes the cleaned value; does not validate. POSIX/BusyBox-safe.
_sanitize_url() {
  printf '%s' "$1" \
    | tr -d '[:cntrl:]' \
    | sed -e 's/\[20[01]~//g' \
          -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" \
          -e 's/^[A-Za-z0-9_.-]*=//' \
          -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
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
    ui_ask _raw "$(msg q_sub_url)" ""
    _url="$(_sanitize_url "$_raw")"
    case "$_url" in
      http://*|https://*) : ;;
      '') ui_warn "$(msg warn_sub_required)"; continue ;;
      *)  ui_warn "$(msg warn_sub_scheme)";  continue ;;
    esac
    # Echo EXACTLY what was captured so a truncated/garbled paste is caught NOW,
    # before a failed deploy. Default yes; answer no to re-enter.
    ui_say "$(msgf sub_confirm "$_url")"
    ui_yesno "$(msg ask_sub_ok)" y && break
  done
  if printf '%s\n' "$_url" > "$_sub"; then
    ui_ok "$(msg ok_sub_saved)"
    return 0
  fi
  diagnose "$(msgf diag_sub_write "$_sub")" "$(msg diag_sub_write_fix)"
  return 1
}

# ensure_subscription - guarantee config/subscription.txt holds a CLEAN, usable
# URL before deploy. The container entrypoint (render_config.sh) HARD-FAILS
# without one (crash-loops mihomo), and a paste-corrupted line (bracketed-paste
# residue / control chars) renders a broken url. Bounces to wizard_subscription
# if the file is missing, still the shipped placeholder, or lacks an http(s)
# line; if the stored line is dirty but recoverable, offers the cleaned URL.
# Returns non-zero only if the operator declines to provide a valid URL.
ensure_subscription() {
  _sub="$REPO_ROOT/config/subscription.txt"
  _example="$REPO_ROOT/config/subscription.txt.example"

  # 1) Missing, or still the shipped placeholder -> enter a fresh URL.
  if [ ! -f "$_sub" ] || { [ -f "$_example" ] && cmp -s "$_sub" "$_example"; }; then
    ui_warn "$(msg warn_no_sub)"
    wizard_subscription || return 1
    return 0
  fi

  # 2) Take the first real line and SANITIZE it; the cleaned value is what render
  #    will effectively use (minus paste corruption render's label-strip can't
  #    fix). Decide on the cleaned result, not on grep of the raw bytes - so a
  #    control-char-garbled line never slips through on any grep implementation.
  _line="$(grep -v '^#' "$_sub" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n1)"
  _clean="$(_sanitize_url "$_line")"
  case "$_clean" in
    http://*|https://*) : ;;
    *) ui_warn "$(msg warn_no_sub)"; wizard_subscription || return 1; return 0 ;;
  esac

  # 3) Recoverable URL, but was the stored line garbled (control chars incl. ESC,
  #    or bracketed-paste markers)? Detect with shell globbing only (no grep, no
  #    binary-mode surprises); offer the cleaned URL, else re-enter.
  _dirty=0
  case "$_line" in *[[:cntrl:]]* | *'[200~'* | *'[201~'*) _dirty=1 ;; esac
  if [ "$_dirty" = 1 ]; then
    ui_warn "$(msg warn_sub_dirty)"
    ui_say "$(msgf sub_confirm "$_clean")"
    if ui_yesno "$(msg ask_sub_ok)" y; then
      printf '%s\n' "$_clean" > "$_sub" && ui_ok "$(msg ok_sub_saved)"
    else
      wizard_subscription || return 1
    fi
  fi
  return 0
}

# precheck_env - validate the SAVED .env before a deploy that reuses it, and
# BOUNCE BACK to re-enter only the fields that are missing/invalid (rather than
# letting create_network / render_config.sh / compose fail mid-deploy). Each
# fix is persisted. Returns non-zero only if the operator quits / declines.
_pc_need() {  # KEY VALIDATOR PROMPT_MSG_KEY DEFAULT
  _pc_k="$1"; _pc_ck="$2"; _pc_qk="$3"; _pc_df="$4"
  _pc_cur="$(env_get "$_pc_k" 2>/dev/null || echo '')"
  if "$_pc_ck" "$_pc_cur"; then return 0; fi
  _pc_fixed=1
  ui_warn "$(msgf precheck_bad "$_pc_k" "$_pc_cur")"
  ui_ask_validated _pc_nv "$(msg "$_pc_qk")" "${_pc_cur:-$_pc_df}" "$_pc_ck"
  env_set "$_pc_k" "$_pc_nv"
}

precheck_env() {
  ui_step "$(msg precheck_step)"
  _pc_fixed=0
  _pc_need ROUTER_IP   is_ipv4 q_router 192.168.1.1
  _pc_need SUBNET_CIDR is_cidr q_subnet 192.168.1.0/24
  # MIHOMO_IP: validate AND conflict-check on re-entry (DHCP collision guard).
  _pc_cur="$(env_get MIHOMO_IP 2>/dev/null || echo '')"
  if ! is_ipv4 "$_pc_cur"; then
    _pc_fixed=1
    ui_warn "$(msgf precheck_bad MIHOMO_IP "$_pc_cur")"
    while :; do
      ui_ask_validated MIHOMO_IP "$(msg q_mihomo_ip)" "${_pc_cur:-192.168.1.100}" is_ipv4
      check_ip_conflict "$MIHOMO_IP" && break
    done
    env_set MIHOMO_IP "$MIHOMO_IP"
  fi
  _pc_need WEB_UI_PORT     is_port     q_web_port        8080
  _pc_need CONTROLLER_PORT is_port     q_controller_port 9090
  _pc_need DNS_DEFAULT_NAMESERVER is_dns_list q_dns_bootstrap 1.1.1.1
  _pc_need DNS_NAMESERVER         is_dns_list q_dns_domestic  1.1.1.1
  _pc_need DNS_FALLBACK           is_dns_list q_dns_fallback  1.1.1.1
  # Image refs must resolve or compose fails closed (${MIHOMO_IMAGE:?}).
  if [ -z "$(env_get MIHOMO_IMAGE 2>/dev/null || echo '')" ] \
     || [ -z "$(env_get METACUBEXD_IMAGE 2>/dev/null || echo '')" ]; then
    _pc_fixed=1
    ui_warn "$(msg precheck_images)"
    wizard_images || return 1
  fi
  load_env
  [ "$_pc_fixed" = 0 ] && ui_ok "$(msg precheck_ok)"
  return 0
}

# precheck_deploy - the single ".env AND subscription.txt" gate for a reuse
# deploy: validate/repair the saved .env, then the subscription URL.
precheck_deploy() {
  precheck_env || return 1
  ensure_subscription || return 1
  return 0
}
