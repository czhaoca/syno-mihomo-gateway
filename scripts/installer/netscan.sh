#!/bin/sh
# netscan.sh - the interactive network wizard: scan the host's LAN interfaces,
# let the operator pick a scanned one or type their own, derive the macvlan
# parameters from it, and (with root) create the TUN device + macvlan.
#
# Two phases so the deploy flow can scan FIRST (pre-filling ROUTER_IP/SUBNET_CIDR
# before the env wizard) and create the network LAST (after config):
#   scan_and_prefill   - no root: choose interface + derive/persist net params
#   create_network     - root: TUN device + macvlan
# setup_network_interactive runs both (used by the modify flow).
#
# Requires ui.sh, network.sh, envedit.sh, preflight.sh sourced. POSIX /bin/sh.

# choose_interface - sets global CHOSEN_IFACE. Returns non-zero if none chosen.
choose_interface() {
  CHOSEN_IFACE=""
  _auto="$(detect_parent_interface "${ROUTER_IP:-}")"
  _scan="$(scan_interfaces)"

  ui_say ""
  ui_say "$(msg net_ifaces)"
  _names=""; _n=0
  _oldifs="$IFS"; IFS='
'
  for _line in $_scan; do
    [ -n "$_line" ] || continue
    _name="${_line%% *}"; _ip="${_line#* }"
    _n=$((_n + 1))
    _names="$_names $_name"
    _mark=""
    [ -n "$_auto" ] && [ "$_name" = "$_auto" ] && _mark="$(msg net_auto_mark)"
    printf '  %s) %-12s ip=%s%s\n' "$_n" "$_name" "$_ip" "$_mark" >&2
  done
  IFS="$_oldifs"
  _manual=$((_n + 1))
  printf '  %s) %s\n' "$_manual" "$(msg net_manual_entry)" >&2

  while :; do
    printf '%s [1-%s]: ' "$(msg net_choose)" "$_manual" >&2
    _read_line _c
    case "$_c" in ''|*[!0-9]*) ui_warn "$(msg warn_num)"; continue ;; esac
    if [ "$_c" -ge 1 ] && [ "$_c" -le "$_n" ]; then
      _i=0
      for _nm in $_names; do
        _i=$((_i + 1))
        [ "$_i" = "$_c" ] && { CHOSEN_IFACE="$_nm"; break; }
      done
      break
    elif [ "$_c" = "$_manual" ]; then
      ui_ask CHOSEN_IFACE "$(msg net_iface_name)" "$_auto"
      if [ -n "$CHOSEN_IFACE" ] && ! interface_exists "$CHOSEN_IFACE"; then
        ui_warn "$(msgf warn_iface_absent "$CHOSEN_IFACE")"
        ui_yesno "$(msg ask_use_anyway)" n || { CHOSEN_IFACE=""; continue; }
      fi
      break
    fi
    ui_warn "$(msg warn_range)"
  done

  [ -n "$CHOSEN_IFACE" ] || { diagnose "$(msg diag_no_iface)" "$(msg diag_no_iface_fix)"; return 1; }
  ui_ok "$(msgf ok_iface "$CHOSEN_IFACE")"
  return 0
}

# check_ip_conflict IP - returns 0 if it's safe to use IP (free, ours, or the
# operator overrode the warning), 1 if the operator wants to choose another.
check_ip_conflict() {
  _ip="$1"
  mihomo_owns_ip "$_ip" && return 0          # our own container already holds it
  ip_in_use "$_ip"
  case "$?" in
    0) ui_warn "$(msgf warn_ip_taken "$_ip")"
       ui_yesno "$(msgf ask_use_ip "$_ip")" n ;;   # yes -> 0 (ok), no -> 1 (re-choose)
    2) ui_info "$(msgf info_ip_unverified "$_ip")"; return 0 ;;
    *) return 0 ;;                            # free
  esac
}

# scan_and_prefill - choose the interface and derive + persist ROUTER_IP /
# SUBNET_CIDR / PARENT_INTERFACE from it (so wizard_env pre-fills). No root.
scan_and_prefill() {
  ui_step "$(msg step_net_iface)"
  choose_interface || return 1
  env_set PARENT_INTERFACE "$CHOSEN_IFACE"
  _gw="$(detect_gateway)"
  _cidr="$(iface_cidr "$CHOSEN_IFACE")"
  if [ -n "$_gw" ]; then env_set ROUTER_IP "$_gw"; ui_ok "$(msgf ok_router_gw "$_gw")"; fi
  if [ -n "$_cidr" ]; then env_set SUBNET_CIDR "$_cidr"; ui_ok "$(msgf ok_lan_subnet "$_cidr")"; fi
  [ -n "$_gw" ] && [ -n "$_cidr" ] \
    || ui_info "$(msg info_net_partial)"
  return 0
}

# create_network - root step: ensure the TUN device + (re)create the macvlan.
validate_selected_network() {
  _vs_pi="${CHOSEN_IFACE:-$(env_get PARENT_INTERFACE 2>/dev/null || detect_parent_interface "${ROUTER_IP:-}")}"
  [ -n "$_vs_pi" ] || { diagnose "$(msg diag_no_iface_sel)" "$(msg diag_no_iface_sel_fix)"; return 1; }
  if validate_network_plan "$_vs_pi" "${SUBNET_CIDR:-}" "${ROUTER_IP:-}" "${MIHOMO_IP:-}"; then
    return 0
  fi
  diagnose "network settings are internally inconsistent" \
    "choose the LAN interface again and ensure router/gateway IPs belong to the selected subnet"
  return 1
}

create_network() {
  ui_step "$(msg step_create_net)"
  if ! is_root; then
    ui_warn "$(msg warn_net_need_root)"
    sudo_rerun_hint
    return 1
  fi
  if [ -z "${ROUTER_IP:-}" ] || [ -z "${SUBNET_CIDR:-}" ]; then
    diagnose "$(msg diag_no_net_params)" "$(msg diag_no_net_params_fix)"
    return 1
  fi
  _pi="${CHOSEN_IFACE:-$(env_get PARENT_INTERFACE 2>/dev/null || detect_parent_interface "${ROUTER_IP:-}")}"
  [ -n "$_pi" ] || { diagnose "$(msg diag_no_iface_sel)" "$(msg diag_no_iface_sel_fix)"; return 1; }
  validate_network_plan "$_pi" "$SUBNET_CIDR" "$ROUTER_IP" "$MIHOMO_IP" || {
    diagnose "network settings are internally inconsistent" "correct the interface, subnet, router, and Mihomo IP"
    return 1
  }

  # Final conflict guard (the IP could have been taken since the wizard ran).
  if [ -n "${MIHOMO_IP:-}" ]; then
    check_ip_conflict "$MIHOMO_IP" || { diagnose "$(msgf diag_ip_in_use "$MIHOMO_IP")" "$(msg diag_ip_in_use_fix)"; return 1; }
  fi

  _net="${TPROXY_NETWORK:-tproxy_network}"
  if network_exists "$_net" && ! macvlan_matches "$_net" "$_pi" "$SUBNET_CIDR" "$ROUTER_IP"; then
    diagnose "network '$_net' still has a different macvlan configuration" \
      "run the installer's preprocessing step and choose automatic or manual network cleanup"
    return 1
  fi

  ensure_tun_device || { diagnose "$(msg diag_tun_fail)" "$(msg diag_tun_fail_fix)"; return 1; }
  if recreate_macvlan "$_pi"; then
    ui_ok "$(msgf ok_macvlan "$_pi")"
    return 0
  fi
  diagnose "$(msgf diag_macvlan_fail "$_pi")" \
    "$(msgf diag_macvlan_fail_fix "$_pi")"
  return 1
}

# setup_network_interactive - scan + create in one go (used by the modify flow).
setup_network_interactive() {
  scan_and_prefill || return 1
  load_env                       # refresh derived ROUTER_IP/SUBNET_CIDR
  validate_selected_network || return 1
  plan_predeployment_cleanup || return 1
  apply_predeployment_cleanup || return 1
  create_network
}
