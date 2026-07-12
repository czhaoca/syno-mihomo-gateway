#!/bin/sh
# wizards.sh - the guided configuration sub-steps shared by the deploy and
# modify flows: seed config files, the .env wizard, the image-source wizard, and
# the subscription wizard. Each prompt pre-fills from the current .env value so
# pressing Enter is a safe no-op (idempotent re-runs).
#
# Requires ui.sh, envedit.sh, preflight.sh sourced first. POSIX /bin/sh.

# example_default KEY - print KEY's shipped default from the tracked
# .env.example, the single sanctioned home for documented defaults (CLAUDE.md:
# no duplicated DNS/network literals in code; #27). Same never-eval discipline
# and last-assignment-wins semantics as dotenv_get, but against the example
# file: the line scan is duplicated here rather than repointing ENV_FILE in a
# subshell, which would trip SC2031 at every later ENV_FILE use. Values go
# through the shared dotenv_decode; prints nothing when the key is absent.
example_default() {
  _ed_file="${REPO_ROOT:-}/.env.example"
  [ -f "$_ed_file" ] || return 0
  _ed_raw="$(awk -v k="$1" 'index($0, k"=") == 1 { v = substr($0, length(k) + 2) }
                            END { printf "%s", v }' "$_ed_file")"
  [ -n "$_ed_raw" ] || return 0
  dotenv_decode "$_ed_raw" || :
}

# offer_dns_privacy_upgrade - one-shot .env migration to the split-horizon v2
# DNS profile (interactive, default No, never silent). Fires only when the
# saved .env predates the split pair (DNS_CN_NAMESERVER empty): writes both
# split lists from the .env.example defaults, and - only when the current
# DNS_NAMESERVER is a plain-IP list (the pre-1.3.8 default shape; any value
# carrying '://' is a deliberate custom choice) - refreshes it to the
# encrypted DoH-on-IP default. Declining changes nothing; the offer returns
# on the next redeploy (stateless). Values come from example_default(),
# never from literals in this file (#27).
offer_dns_privacy_upgrade() {
  _odp_cn="$(env_get DNS_CN_NAMESERVER 2>/dev/null || echo '')"
  [ -z "$_odp_cn" ] || return 0
  _odp_cn_new="$(example_default DNS_CN_NAMESERVER)"
  _odp_fo_new="$(example_default DNS_FOREIGN_NAMESERVER)"
  { [ -n "$_odp_cn_new" ] && [ -n "$_odp_fo_new" ]; } || return 0
  ui_say ""
  ui_say "$(msg dnsup_head)"
  ui_say "$(msgf dnsup_cn "$_odp_cn_new")"
  ui_say "$(msgf dnsup_foreign "$_odp_fo_new")"
  _odp_ns="$(env_get DNS_NAMESERVER 2>/dev/null || echo '')"
  _odp_ns_new="$(example_default DNS_NAMESERVER)"
  _odp_refresh=0
  case "$_odp_ns" in
    *://*) : ;;  # custom encrypted resolver list - never clobbered
    *)
      if [ -n "$_odp_ns" ] && [ -n "$_odp_ns_new" ] && [ "$_odp_ns" != "$_odp_ns_new" ]; then
        _odp_refresh=1
        ui_say "$(msgf dnsup_ns "$_odp_ns" "$_odp_ns_new")"
      fi ;;
  esac
  if ui_yesno "$(msg dnsup_ask)" n; then
    env_set DNS_CN_NAMESERVER "$_odp_cn_new"
    env_set DNS_FOREIGN_NAMESERVER "$_odp_fo_new"
    if [ "$_odp_refresh" = 1 ]; then
      env_set DNS_NAMESERVER "$_odp_ns_new"
    fi
    ui_ok "$(msg dnsup_done)"
  else
    ui_say "$(msg dnsup_skipped)"
  fi
  return 0
}

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

  _sub="$SUBSCRIPTION_FILE"
  if [ ! -f "$_sub" ] && [ -f "$REPO_ROOT/config/subscription.txt.example" ]; then
    cp "$REPO_ROOT/config/subscription.txt.example" "$_sub" \
      && chmod 600 "$_sub" 2>/dev/null \
      && ui_ok "$(msg ok_sub_created)"
  fi

  if [ -d "$REPO_ROOT/scripts" ]; then
    chmod +x "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh \
             "$REPO_ROOT"/scripts/installer/*.sh 2>/dev/null
  fi
  return 0
}

# _gen_secret - print a random 32-hex dashboard secret (empty on failure so
# callers can degrade gracefully). POSIX/BusyBox-safe.
_gen_secret() {
  [ -r /dev/urandom ] || return 0
  head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'
}

# _secret_guard - never let an empty CONTROLLER_SECRET slip through silently:
# offer to auto-generate one (default yes); declining is the explicit
# "leave the dashboard unauthenticated" opt-out. A preset secret is untouched.
_secret_guard() {
  _sg_cur="$(env_get CONTROLLER_SECRET 2>/dev/null || echo '')"
  [ -z "$_sg_cur" ] || return 0
  ui_warn "$(msg warn_secret_empty)"
  if ui_yesno "$(msg ask_gen_secret)" y; then
    _sg_new="$(_gen_secret)"
    if [ -n "$_sg_new" ]; then
      env_set CONTROLLER_SECRET "$_sg_new"
      CONTROLLER_SECRET="$_sg_new"; export CONTROLLER_SECRET
      ui_ok "$(msg ok_secret_generated)"
    else
      ui_warn "$(msg warn_gen_secret_failed)"
    fi
  else
    ui_warn "$(msg warn_secret_none)"
  fi
  return 0
}

# wizard_express - the one-screen fast path (DEC-A on the work order): when
# every value is detected or saved, show them ALL on a single confirmation
# screen and persist on accept. Returns 1 (without persisting) when detections
# are incomplete or the operator declines - the full wizard chain is the
# per-item edit escape. This screen IS the explicit confirmation of the
# LAN-affecting change; it never silently applies anything.
wizard_express() {
  _we_router="$(env_get ROUTER_IP 2>/dev/null || echo '')"
  _we_cidr="$(env_get SUBNET_CIDR 2>/dev/null || echo '')"
  [ -n "$_we_router" ] && [ -n "$_we_cidr" ] || return 1
  _we_iface=""
  [ "${IFACE_MANUAL:-0}" = 1 ] || _we_iface="${PARENT_INTERFACE:-${CHOSEN_IFACE:-}}"
  resolve_notify_scan() { ui_info "$(msg info_ip_suggest_scan)"; }
  _we_cur="$(env_get MIHOMO_IP 2>/dev/null || echo '')"
  _we_ip="$(resolve_mihomo_ip "$_we_cur" "$_we_cidr" "$_we_router" "$_we_iface")"
  [ -n "$_we_ip" ] || return 1
  _we_web="$(env_get WEB_UI_PORT 2>/dev/null || example_default WEB_UI_PORT)"
  _we_ctl="$(env_get CONTROLLER_PORT 2>/dev/null || example_default CONTROLLER_PORT)"
  _we_dns_b="$(env_get DNS_DEFAULT_NAMESERVER 2>/dev/null || example_default DNS_DEFAULT_NAMESERVER)"
  _we_dns_d="$(env_get DNS_NAMESERVER 2>/dev/null || example_default DNS_NAMESERVER)"
  _we_dns_f="$(env_get DNS_FALLBACK 2>/dev/null || example_default DNS_FALLBACK)"
  _we_tz="$(env_get TZ 2>/dev/null || example_default TZ)"

  ui_step "$(msg step_express)"
  ui_say "$(msgf express_iface "${_we_iface:-${PARENT_INTERFACE:-?}}")"
  ui_say "$(msgf express_net "$_we_router" "$_we_cidr")"
  ui_say "$(msgf express_ip "$_we_ip")"
  ui_say "$(msgf express_ports "$_we_web" "$_we_ctl")"
  ui_say "$(msgf express_dns "$_we_dns_b" "$_we_dns_d" "$_we_dns_f")"
  ui_say "$(msgf express_tz "$_we_tz")"
  _we_img="$(env_get MIHOMO_IMAGE 2>/dev/null || echo '')"
  if [ -n "$_we_img" ]; then
    ui_say "$(msgf express_images "$_we_img")"
  else
    ui_say "$(msg express_images_wizard)"
  fi
  ui_say "$(msg express_edit_hint)"
  ui_yesno "$(msg ask_express)" y || return 1

  while :; do
    check_ip_conflict "$_we_ip" && break
    return 1   # conflict declined -> edit per item in the full wizard
  done
  env_set MIHOMO_IP "$_we_ip"
  env_set WEB_UI_PORT "$_we_web"
  env_set CONTROLLER_PORT "$_we_ctl"
  env_set DNS_DEFAULT_NAMESERVER "$_we_dns_b"
  env_set DNS_NAMESERVER "$_we_dns_d"
  env_set DNS_FALLBACK "$_we_dns_f"
  env_set TZ "$_we_tz"
  MIHOMO_IP="$_we_ip"; export MIHOMO_IP
  _secret_guard
  ui_ok "$(msg ok_env_saved)"
  return 0
}

# wizard_env - prompt + persist the network / DNS / port / secret settings.
wizard_env() {
  ui_step "$(msg step_env)"
  ui_ask_validated ROUTER_IP "$(msg q_router)" "$(env_get ROUTER_IP || example_default ROUTER_IP)" is_ipv4
  env_set ROUTER_IP "$ROUTER_IP"
  ui_ask_validated SUBNET_CIDR "$(msg q_subnet)" "$(env_get SUBNET_CIDR || example_default SUBNET_CIDR)" is_cidr
  env_set SUBNET_CIDR "$SUBNET_CIDR"
  # Suggest a free static IP near the NAS instead of the stale placeholder:
  # resolve_mihomo_ip (lib/resolve.sh) keeps a saved value that is still a
  # usable host in THIS subnet (idempotent re-run), else scans for the next
  # free address above the NAS's own IP on the chosen interface (skipped when
  # the operator typed the interface name by hand).
  _mihomo_cur="$(env_get MIHOMO_IP 2>/dev/null || echo '')"
  _scan_iface=""
  [ "${IFACE_MANUAL:-0}" = 1 ] || _scan_iface="${PARENT_INTERFACE:-${CHOSEN_IFACE:-}}"
  resolve_notify_scan() { ui_info "$(msg info_ip_suggest_scan)"; }
  _mihomo_def="$(resolve_mihomo_ip "$_mihomo_cur" "$SUBNET_CIDR" "$ROUTER_IP" "$_scan_iface")"
  [ -n "$_mihomo_def" ] || _mihomo_def="${_mihomo_cur:-$(example_default MIHOMO_IP)}"
  while :; do
    ui_ask_validated MIHOMO_IP "$(msg q_mihomo_ip)" "$_mihomo_def" is_ipv4
    check_ip_conflict "$MIHOMO_IP" && break
  done
  env_set MIHOMO_IP "$MIHOMO_IP"

  ui_ask_validated WEB_UI_PORT "$(msg q_web_port)" "$(env_get WEB_UI_PORT || example_default WEB_UI_PORT)" is_port
  env_set WEB_UI_PORT "$WEB_UI_PORT"
  if [ "$(pf_port_free "$WEB_UI_PORT"; echo $?)" = "1" ]; then
    ui_warn "$(msgf warn_port_in_use "$WEB_UI_PORT")"
  fi
  ui_ask_validated CONTROLLER_PORT "$(msg q_controller_port)" "$(env_get CONTROLLER_PORT || example_default CONTROLLER_PORT)" is_port
  env_set CONTROLLER_PORT "$CONTROLLER_PORT"

  # Pressing Enter on a re-run must keep the saved secret (idempotent
  # re-runs), never silently clear it - every configured dashboard would
  # lose its backend. An explicit '-' clears; empty-with-no-saved-secret
  # still goes through _secret_guard's generate offer.
  _we_secret_cur="$(env_get CONTROLLER_SECRET 2>/dev/null || echo '')"
  while :; do
    if [ -n "$_we_secret_cur" ]; then
      ui_ask_secret CONTROLLER_SECRET "$(msg q_controller_secret_keep)"
    else
      ui_ask_secret CONTROLLER_SECRET "$(msg q_controller_secret)"
    fi
    case "$CONTROLLER_SECRET" in
      *"|"*) ui_warn "$(msg warn_secret_pipe)" ;;
      *) break ;;
    esac
  done
  _we_secret_cleared=0
  if [ -n "$_we_secret_cur" ] && [ -z "$CONTROLLER_SECRET" ]; then
    CONTROLLER_SECRET="$_we_secret_cur"
  elif [ "$CONTROLLER_SECRET" = "-" ]; then
    CONTROLLER_SECRET=""; _we_secret_cleared=1
  fi
  env_set CONTROLLER_SECRET "$CONTROLLER_SECRET"
  if [ "$_we_secret_cleared" = 1 ]; then
    ui_warn "$(msg warn_secret_none)"   # explicit clear = explicit opt-out
  else
    _secret_guard   # empty -> offer to generate (explicit opt-out preserved)
  fi

  ui_ask_validated DNS_DEFAULT_NAMESERVER "$(msg q_dns_bootstrap)" "$(env_get DNS_DEFAULT_NAMESERVER || example_default DNS_DEFAULT_NAMESERVER)" is_dns_list
  env_set DNS_DEFAULT_NAMESERVER "$DNS_DEFAULT_NAMESERVER"
  ui_ask_validated DNS_NAMESERVER "$(msg q_dns_domestic)" "$(env_get DNS_NAMESERVER || example_default DNS_NAMESERVER)" is_dns_list
  env_set DNS_NAMESERVER "$DNS_NAMESERVER"
  ui_ask_validated DNS_FALLBACK "$(msg q_dns_fallback)" "$(env_get DNS_FALLBACK || example_default DNS_FALLBACK)" is_dns_list
  env_set DNS_FALLBACK "$DNS_FALLBACK"

  ui_ask TZ "$(msg q_tz)" "$(env_get TZ || example_default TZ)"
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

# wizard_subscription - capture the airport/subscription URL into
# config/subscription.txt (never silently overwrite a real one). URL cleanup
# and the stored-value read live in lib/resolve.sh (_sanitize_url,
# resolve_subscription_url, subscription_current).
wizard_subscription() {
  ui_step "$(msg step_sub)"
  _sub="$SUBSCRIPTION_FILE"
  _cur="$(subscription_current)"
  if [ -n "$_cur" ]; then
    ui_say "$(msgf sub_current "$_cur")"
    ui_yesno "$(msg ask_replace_sub)" n || { ui_ok "$(msg ok_sub_kept)"; return 0; }
  fi
  while :; do
    ui_ask _raw "$(msg q_sub_url)" ""
    if ! _url="$(resolve_subscription_url "$_raw")"; then
      case "$_url" in
        '') ui_warn "$(msg warn_sub_required)"; continue ;;
        *)  ui_warn "$(msg warn_sub_scheme)";  continue ;;
      esac
    fi
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
  _sub="$SUBSCRIPTION_FILE"
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
_pc_need() {  # KEY VALIDATOR PROMPT_MSG_KEY (the re-ask default comes from .env.example)
  _pc_k="$1"; _pc_ck="$2"; _pc_qk="$3"
  _pc_cur="$(env_get "$_pc_k" 2>/dev/null || echo '')"
  if "$_pc_ck" "$_pc_cur"; then return 0; fi
  _pc_fixed=1
  ui_warn "$(msgf precheck_bad "$_pc_k" "$_pc_cur")"
  ui_ask_validated _pc_nv "$(msg "$_pc_qk")" "${_pc_cur:-$(example_default "$_pc_k")}" "$_pc_ck"
  env_set "$_pc_k" "$_pc_nv"
}

precheck_env() {
  ui_step "$(msg precheck_step)"
  _pc_fixed=0
  _pc_need ROUTER_IP   is_ipv4 q_router
  _pc_need SUBNET_CIDR is_cidr q_subnet
  # MIHOMO_IP: validate AND conflict-check on re-entry (DHCP collision guard).
  # Also require membership in the (just-validated) SUBNET_CIDR: after an
  # interface re-pick onto a new subnet, a saved IP from the OLD subnet would
  # otherwise sail through here and dead-end the flow in the later network
  # validation with a hint that never names MIHOMO_IP as the problem.
  _pc_cur="$(env_get MIHOMO_IP 2>/dev/null || echo '')"
  _pc_cidr="$(env_get SUBNET_CIDR 2>/dev/null || echo '')"
  if ! is_ipv4 "$_pc_cur" || { [ -n "$_pc_cidr" ] && ! ipv4_in_cidr "$_pc_cur" "$_pc_cidr"; }; then
    _pc_fixed=1
    ui_warn "$(msgf precheck_bad MIHOMO_IP "$_pc_cur")"
    while :; do
      ui_ask_validated MIHOMO_IP "$(msg q_mihomo_ip)" "${_pc_cur:-$(example_default MIHOMO_IP)}" is_ipv4
      if [ -n "$_pc_cidr" ] && ! ipv4_in_cidr "$MIHOMO_IP" "$_pc_cidr"; then
        ui_warn "$(msgf precheck_bad MIHOMO_IP "$MIHOMO_IP")"
        continue
      fi
      check_ip_conflict "$MIHOMO_IP" && break
    done
    env_set MIHOMO_IP "$MIHOMO_IP"
  fi
  _pc_need WEB_UI_PORT     is_port     q_web_port
  _pc_need CONTROLLER_PORT is_port     q_controller_port
  _pc_need DNS_DEFAULT_NAMESERVER is_dns_list q_dns_bootstrap
  _pc_need DNS_NAMESERVER         is_dns_list q_dns_domestic
  _pc_need DNS_FALLBACK           is_dns_list q_dns_fallback
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
