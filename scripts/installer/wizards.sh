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
    # A JUST-seeded .env must not keep the example's nonempty placeholder image
    # refs: they satisfy flow_deploy's express-path "already configured" gate
    # and would skip wizard_images (and the #54 network scan) entirely. Blank
    # them so env_get fails and the gate falls through - the stock mirror of
    # the generic-linux interposition (scripts/linux/preflight_linux.sh). Only
    # on this fresh-copy branch: an existing .env is never touched.
    env_set MIHOMO_IMAGE ''
    env_set METACUBEXD_IMAGE ''
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
  _we_tz="$(env_get TZ 2>/dev/null || example_default TZ)"

  ui_step "$(msg step_express)"
  ui_say "$(msgf express_iface "${_we_iface:-${PARENT_INTERFACE:-?}}")"
  ui_say "$(msgf express_net "$_we_router" "$_we_cidr")"
  ui_say "$(msgf express_ip "$_we_ip")"
  ui_say "$(msgf express_ports "$_we_web" "$_we_ctl")"
  ui_say "$(msgf express_dns "$_we_dns_b" "$_we_dns_d")"
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

  ui_ask TZ "$(msg q_tz)" "$(env_get TZ || example_default TZ)"
  env_set TZ "$TZ"
  ui_ok "$(msg ok_env_saved)"
  return 0
}

# _wi_fresh_install - 0 while no image source has ever been chosen: the saved
# ref is blank (fresh seeds blank it - stock and linux alike) or still the
# shipped .env.example placeholder (a pre-#54 .env seeded before the blanking
# landed). Anything else means the operator already configured a source, so
# the menu stays the manual override.
_wi_fresh_install() {
  _wf_img="$(env_get MIHOMO_IMAGE 2>/dev/null || echo '')"
  [ -z "$_wf_img" ] && return 0
  [ "$_wf_img" = "$(example_default MIHOMO_IMAGE)" ]
}

# _wi_apply_dns_variant VERDICT - on a conclusive 'unfiltered' verdict, switch
# a STILL-DEFAULT split-horizon pair to the no-detour foreign variant (both
# lists = the example foreign servers with their '#<group>' detours stripped -
# see docs/configuration.md). A pair the operator customized is never touched,
# and every value derives from .env.example at runtime (no DNS literals here;
# the literal-drift sweep in dsm_installer_check.sh enforces that).
_wi_apply_dns_variant() {
  [ "$1" = unfiltered ] || return 0
  _av_ex_cn="$(example_default DNS_CN_NAMESERVER)"
  _av_ex_fo="$(example_default DNS_FOREIGN_NAMESERVER)"
  [ -n "$_av_ex_fo" ] || return 0
  _av_cn="$(env_get DNS_CN_NAMESERVER 2>/dev/null || echo '')"
  _av_fo="$(env_get DNS_FOREIGN_NAMESERVER 2>/dev/null || echo '')"
  { [ -z "$_av_cn" ] || [ "$_av_cn" = "$_av_ex_cn" ]; } || return 0
  { [ -z "$_av_fo" ] || [ "$_av_fo" = "$_av_ex_fo" ]; } || return 0
  _av_plain="$(printf '%s' "$_av_ex_fo" | sed 's/#[^,]*//g')"
  [ -n "$_av_plain" ] || return 0
  # Belt-and-braces read-back on every write (env_set is self-verifying since
  # #59; this tested local proof STAYS): the swap is OPTIONAL - on any
  # unverified write the pair must end in a known state (shipped defaults)
  # and success must never be claimed.
  env_set DNS_CN_NAMESERVER "$_av_plain" || :
  if [ "$(env_get DNS_CN_NAMESERVER 2>/dev/null || echo '')" != "$_av_plain" ]; then
    ui_warn "$(msg scan_dns_rollback)"
    return 0
  fi
  env_set DNS_FOREIGN_NAMESERVER "$_av_plain" || :
  if [ "$(env_get DNS_FOREIGN_NAMESERVER 2>/dev/null || echo '')" != "$_av_plain" ]; then
    # never leave a half-rewritten pair: restore the CN list to the shipped
    # default and VERIFY the restore - an unverifiable restore is said out
    # loud, never papered over.
    env_set DNS_CN_NAMESERVER "$_av_ex_cn" || :
    if [ "$(env_get DNS_CN_NAMESERVER 2>/dev/null || echo '')" = "$_av_ex_cn" ]; then
      ui_warn "$(msg scan_dns_rollback)"
    else
      ui_warn "$(msg scan_dns_partial)"
    fi
    return 0
  fi
  ui_ok "$(msgf scan_dns_variant "$_av_plain")"
  return 0
}

# _wi_auto_scan - fresh installs only: classify the network (lib/network.sh)
# and pre-decide the image source (sets _mode) + DNS variant. Anything
# inconclusive leaves _mode empty so the menu + GFW question run exactly as
# before (#54 DEC-A, panel-confirmed: the verdict asserts HTTP 204, and
# 'filtered' stays the fail-safe default the shipped .env.example encodes).
_wi_auto_scan() {
  command -v scan_network_filtering >/dev/null 2>&1 || return 0
  ui_info "$(msg scan_probing)"
  _wa_v="$(scan_network_filtering)"
  case "$_wa_v" in
    unfiltered)
      if scan_registry_reachable; then
        _mode=docker
        ui_ok "$(msg scan_unfiltered)"
      else
        ui_info "$(msg scan_mixed)"
      fi ;;
    filtered)
      _mode=acr
      ui_ok "$(msg scan_filtered)" ;;
    *)
      ui_info "$(msg scan_unknown)" ;;
  esac
  _wi_apply_dns_variant "$_wa_v"
  return 0
}

# wizard_images - pick the image source (REGISTRY_MODE), collect registry creds
# + tags, and derive the image refs (req #4). On a fresh install a conclusive
# network scan pre-decides the source + DNS variant silently (#54); the menu
# below is the inconclusive fallback AND the Modify-flow manual override.
wizard_images() {
  ui_step "$(msg step_images)"
  _mode=""
  if _wi_fresh_install; then
    _wi_auto_scan
  fi
  if [ -z "$_mode" ]; then
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

# _pc_backfill_pair - upgrade path for a pre-v2 .env (#55): backfill whichever
# of the two split-horizon lists is missing/empty from the shipped
# .env.example defaults (the filtered fail-safe), because a pre-v2 file
# passes every other precheck yet hard-fails at render (render_config.sh
# names the missing variable and the entrypoint gate keeps the OLD config
# running - a confusing dead-end). Backs up .env BEFORE writing and prints
# every line written; a present value - customized or not - is never
# touched. Only a TRUE pre-v2 file (both lists missing) gets the one-time
# scan-driven variant upgrade a fresh install would get (#54); a partial
# repair stays minimal.
_pc_backfill_pair() {
  _bf_cn="$(env_get DNS_CN_NAMESERVER 2>/dev/null || echo '')"
  _bf_fo="$(env_get DNS_FOREIGN_NAMESERVER 2>/dev/null || echo '')"
  [ -z "$_bf_cn" ] || [ -z "$_bf_fo" ] || return 0
  _bf_ex_cn="$(example_default DNS_CN_NAMESERVER)"
  _bf_ex_fo="$(example_default DNS_FOREIGN_NAMESERVER)"
  if [ -z "$_bf_ex_cn" ] || [ -z "$_bf_ex_fo" ]; then
    ui_warn "$(msg warn_backfill_noexample)"
    return 0
  fi
  _pc_fixed=1
  _bf_bak="${ENV_FILE}.pre-v2.bak"
  # The backup is a PREREQUISITE, keep-first: no repair without a pristine
  # pre-repair snapshot, and a retry after a failed repair must never clobber
  # that snapshot with a half-written file.
  if [ ! -f "$_bf_bak" ]; then
    if ! cp "$ENV_FILE" "$_bf_bak" 2>/dev/null; then
      diagnose "$(msgf diag_backfill_backup "$_bf_bak")" "$(msg diag_backfill_backup_fix)"
      return 1
    fi
    ui_info "$(msgf backfill_backup "$_bf_bak")"
  else
    ui_info "$(msgf backfill_backup_kept "$_bf_bak")"
  fi
  # best-effort mode hardening covers a kept backup from an older run too
  chmod 600 "$_bf_bak" 2>/dev/null
  _bf_both=0
  [ -z "$_bf_cn" ] && [ -z "$_bf_fo" ] && _bf_both=1
  if [ -z "$_bf_cn" ]; then
    env_set DNS_CN_NAMESERVER "$_bf_ex_cn" || :
    # Belt-and-braces read-back (env_set is self-verifying since #59; this
    # tested local proof STAYS): this precheck repairs a secrets file, so
    # fail CLOSED here with the backup named - never let a missing list
    # ride on to the render dead-end.
    if [ "$(env_get DNS_CN_NAMESERVER 2>/dev/null || echo '')" != "$_bf_ex_cn" ]; then
      diagnose "$(msgf diag_backfill_write DNS_CN_NAMESERVER "$_bf_bak")" "$(msg diag_backfill_write_fix)"
      return 1
    fi
    ui_ok "$(msgf backfill_wrote DNS_CN_NAMESERVER "$_bf_ex_cn")"
  fi
  if [ -z "$_bf_fo" ]; then
    env_set DNS_FOREIGN_NAMESERVER "$_bf_ex_fo" || :
    if [ "$(env_get DNS_FOREIGN_NAMESERVER 2>/dev/null || echo '')" != "$_bf_ex_fo" ]; then
      diagnose "$(msgf diag_backfill_write DNS_FOREIGN_NAMESERVER "$_bf_bak")" "$(msg diag_backfill_write_fix)"
      return 1
    fi
    ui_ok "$(msgf backfill_wrote DNS_FOREIGN_NAMESERVER "$_bf_ex_fo")"
  fi
  [ "$_bf_both" = 1 ] || return 0
  command -v scan_network_filtering >/dev/null 2>&1 || return 0
  ui_info "$(msg scan_probing)"
  _wi_apply_dns_variant "$(scan_network_filtering)"
  return 0
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
  _pc_backfill_pair || return 1
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
