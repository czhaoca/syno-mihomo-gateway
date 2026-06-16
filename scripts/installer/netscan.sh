#!/bin/sh
# netscan.sh - the interactive network wizard (req #5): scan the host's LAN
# interfaces, let the operator pick a scanned one or type their own, then drive
# scripts/lib/network.sh to create the TUN device + macvlan.
#
# The auto-detected parent (the interface that routes to ROUTER_IP) is marked as
# the recommended choice and used as the default for manual entry, so it agrees
# with registry.sh:check_network's later parent verification.
#
# Requires ui.sh, network.sh, preflight.sh (is_root/sudo_rerun_hint) sourced.
# POSIX /bin/sh, BusyBox-safe.

# choose_interface - sets global CHOSEN_IFACE. Returns non-zero if none chosen.
choose_interface() {
  CHOSEN_IFACE=""
  _auto="$(detect_parent_interface "${ROUTER_IP:-}")"
  _scan="$(scan_interfaces)"

  ui_say ""
  ui_say "Network interfaces on this host:"
  _names=""; _n=0
  _oldifs="$IFS"; IFS='
'
  for _line in $_scan; do
    [ -n "$_line" ] || continue
    _name="${_line%% *}"; _ip="${_line#* }"
    _n=$((_n + 1))
    _names="$_names $_name"
    _mark=""
    [ -n "$_auto" ] && [ "$_name" = "$_auto" ] && _mark="  <- auto-detected (recommended)"
    printf '  %s) %-12s ip=%s%s\n' "$_n" "$_name" "$_ip" "$_mark" >&2
  done
  IFS="$_oldifs"
  _manual=$((_n + 1))
  printf '  %s) (type an interface name manually)\n' "$_manual" >&2

  while :; do
    printf 'Choose the LAN interface for mihomo [1-%s]: ' "$_manual" >&2
    IFS= read -r _c </dev/tty || _c=""
    case "$_c" in ''|*[!0-9]*) ui_warn "enter a number 1-$_manual"; continue ;; esac
    if [ "$_c" -ge 1 ] && [ "$_c" -le "$_n" ]; then
      _i=0
      for _nm in $_names; do
        _i=$((_i + 1))
        [ "$_i" = "$_c" ] && { CHOSEN_IFACE="$_nm"; break; }
      done
      break
    elif [ "$_c" = "$_manual" ]; then
      ui_ask CHOSEN_IFACE "Interface name" "$_auto"
      if [ -n "$CHOSEN_IFACE" ] && ! interface_exists "$CHOSEN_IFACE"; then
        ui_warn "interface '$CHOSEN_IFACE' is not present on this host right now"
        ui_yesno "use it anyway?" n || { CHOSEN_IFACE=""; continue; }
      fi
      break
    fi
    ui_warn "out of range (1-$_manual)"
  done

  [ -n "$CHOSEN_IFACE" ] || { diagnose "no interface chosen" "re-run and pick a number, or type a valid interface name"; return 1; }
  ui_ok "interface: $CHOSEN_IFACE"
  return 0
}

# setup_network_interactive - the full network step: root check, TUN, pick
# interface, (re)create macvlan. Returns 0 on success.
setup_network_interactive() {
  ui_step "Network setup (TUN device + macvlan)"
  if ! is_root; then
    ui_warn "creating /dev/net/tun and the macvlan network requires root."
    sudo_rerun_hint
    return 1
  fi
  if [ -z "${ROUTER_IP:-}" ] || [ -z "${SUBNET_CIDR:-}" ]; then
    diagnose "ROUTER_IP / SUBNET_CIDR not set" "run the configuration step first (the network is created from them)"
    return 1
  fi

  ensure_tun_device || { diagnose "could not prepare /dev/net/tun" "run the installer as root (sudo)"; return 1; }
  choose_interface || return 1

  if recreate_macvlan "$CHOSEN_IFACE"; then
    ui_ok "macvlan network ready (parent=$CHOSEN_IFACE)"
    return 0
  fi
  diagnose "failed to create the macvlan network on '$CHOSEN_IFACE'" \
    "confirm ROUTER_IP/SUBNET_CIDR in .env match this LAN, that '$CHOSEN_IFACE' is the LAN-facing NIC, and that no container still holds the old network"
  return 1
}
