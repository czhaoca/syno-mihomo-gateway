#!/bin/sh
# network.sh - POSIX network primitives for the gateway: the TUN device, LAN
# interface enumeration/detection, and the macvlan "tproxy_network".
#
# Single source of truth shared by THREE callers:
#   - scripts/setup_network.sh        (headless: DSM boot-up self-heal task)
#   - scripts/installer/netscan.sh    (interactive: scan + pick/enter parent)
#   - scripts/installer/preflight.sh  (read-only checks)
#
# POSIX /bin/sh only (DSM ships BusyBox: no `grep -oP`/`\K`, no `[[ ]]`, no
# `read -p`, no arrays). NO `set -e` - callers check return codes.
#
# Requires common.sh sourced first (log_*). Uses ${DOCKER_BIN:-docker} so it
# works whether or not registry.sh:detect_compose has run yet.

TPROXY_NETWORK="${TPROXY_NETWORK:-tproxy_network}"

# Resolve a docker binary without depending on detect_compose having run.
_net_docker() {
  if [ -n "${DOCKER_BIN:-}" ]; then printf '%s' "$DOCKER_BIN"; return 0; fi
  command -v docker 2>/dev/null && return 0
  for _c in /usr/local/bin/docker /usr/bin/docker; do
    [ -x "$_c" ] && { printf '%s' "$_c"; return 0; }
  done
  printf 'docker'
}

# ensure_tun_device - create /dev/net/tun (c 10 200) if missing and make it
# usable. Needs root (mknod/chmod). Idempotent. Returns non-zero on failure.
ensure_tun_device() {
  if [ ! -c /dev/net/tun ]; then
    mkdir -p /dev/net 2>/dev/null
    if ! mknod /dev/net/tun c 10 200 2>/dev/null; then
      log_error "could not create /dev/net/tun (need root: 'sudo')"
      return 1
    fi
  fi
  if ! chmod 0666 /dev/net/tun 2>/dev/null; then
    log_error "could not chmod /dev/net/tun (need root: 'sudo')"
    return 1
  fi
  log_info "/dev/net/tun ready"
  return 0
}

# _iface_ipv4 IFACE - print the first IPv4 bound to IFACE, or empty. POSIX-only.
_iface_ipv4() {
  _if="$1"
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show dev "$_if" 2>/dev/null \
      | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig "$_if" 2>/dev/null \
      | sed -n 's/.*inet \(addr:\)\{0,1\}\([0-9.]*\).*/\2/p' | head -n1
  fi
}

# scan_interfaces - print candidate LAN parent interfaces, one per line, as
# "IFACE IPV4" (a literal "-" when the iface has no IPv4; both fields are
# space-free so callers can split on the single space). Filters out loopback and
# virtual/docker interfaces (lo, docker*, veth*, br-*, tproxy_network bridges).
# Prefers `ip`, falls back to `ifconfig`. Newest BusyBox has both; DSM has one.
scan_interfaces() {
  _names=""
  if command -v ip >/dev/null 2>&1; then
    _names="$(ip -o link show 2>/dev/null | sed -n 's/^[0-9]*: \([^:@]*\).*/\1/p')"
  elif command -v ifconfig >/dev/null 2>&1; then
    # First token of each non-indented "iface ..." line (Linux + BusyBox styles).
    _names="$(ifconfig -a 2>/dev/null | sed -n 's/^\([A-Za-z0-9._-]*\)[: ].*/\1/p')"
  fi
  [ -n "$_names" ] || return 0
  printf '%s\n' "$_names" | while IFS= read -r _if; do
    [ -n "$_if" ] || continue
    case "$_if" in
      lo|docker*|veth*|br-*|"$TPROXY_NETWORK"*) continue ;;
    esac
    _ip4="$(_iface_ipv4 "$_if")"
    printf '%s %s\n' "$_if" "${_ip4:--}"
  done
}

# detect_parent_interface ROUTER_IP - best-effort auto-detect of the macvlan
# parent: the interface that routes to ROUTER_IP, else the default route's dev.
# Same `sed` idiom as registry.sh:check_network (NOT `grep -oP`, which BusyBox
# lacks). Prints the iface name or empty.
detect_parent_interface() {
  _router="$1"; _parent=""
  if command -v ip >/dev/null 2>&1; then
    if [ -n "$_router" ]; then
      _parent="$(ip route get "$_router" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -n1)"
    fi
    [ -n "$_parent" ] || _parent="$(ip route show default 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -n1)"
  fi
  printf '%s' "$_parent"
}

# detect_gateway - print the default-route gateway (router) IPv4, or empty.
detect_gateway() {
  command -v ip >/dev/null 2>&1 || return 0
  ip route show default 2>/dev/null | sed -n 's/.*via \([0-9.]*\).*/\1/p' | head -n1
}

# iface_cidr IFACE - print the connected IPv4 subnet CIDR for IFACE (e.g.
# 192.168.1.0/24), read straight from the kernel route table (no netmask
# bit-math). Rejects a host route (/32) or an implausibly wide mask (<8) and
# prints nothing then, so callers fall back to a typed default.
iface_cidr() {
  _if="$1"; [ -n "$_if" ] || return 0
  command -v ip >/dev/null 2>&1 || return 0
  _c="$(ip route show dev "$_if" scope link 2>/dev/null | sed -n 's#^\([0-9.]*/[0-9][0-9]*\) .*#\1#p' | head -n1)"
  [ -n "$_c" ] || _c="$(ip route show dev "$_if" 2>/dev/null | sed -n 's#^\([0-9.]*/[0-9][0-9]*\) .*#\1#p' | head -n1)"
  case "$_c" in */*) _m="${_c#*/}" ;; *) return 0 ;; esac
  case "$_m" in ''|*[!0-9]*) return 0 ;; esac
  { [ "$_m" -lt 8 ] || [ "$_m" -ge 32 ]; } && return 0
  printf '%s' "$_c"
}

# ip_in_use IP - best-effort "does this IP already answer on the LAN" probe.
# 3-tier: arping (L2) -> ping (use -W, which BusyBox honors; NOT -w) -> unknown.
# Returns 0 = in use, 1 = free, 2 = cannot determine. NEVER hard-blocks; callers
# warn + allow override. Must run BEFORE the macvlan container exists (the NAS
# cannot reach its OWN macvlan IP once deployed - see mihomo_owns_ip).
ip_in_use() {
  _ip="$1"; [ -n "$_ip" ] || return 2
  if command -v arping >/dev/null 2>&1; then
    _pi="${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}"
    [ -n "$_pi" ] && arping -c 1 -w 2 -I "$_pi" "$_ip" >/dev/null 2>&1 && return 0
  fi
  if command -v ping >/dev/null 2>&1; then
    ping -c 1 -W 1 "$_ip" >/dev/null 2>&1 && return 0
    return 1
  fi
  return 2
}

# mihomo_owns_ip IP - 0 if the existing 'mihomo' container already holds IP, so
# a re-deploy never flags its own IP as a conflict. Checks the configured
# IPAMConfig AND the live IPAddress across its networks (guards a nil IPAMConfig).
mihomo_owns_ip() {
  _ip="$1"; [ -n "$_ip" ] || return 1
  _d="$(_net_docker)"
  _have="$("$_d" inspect -f '{{range .NetworkSettings.Networks}}{{if .IPAMConfig}}{{.IPAMConfig.IPv4Address}}{{end}} {{.IPAddress}} {{end}}' mihomo 2>/dev/null)"
  case " $_have " in *" $_ip "*) return 0 ;; esac
  return 1
}

# interface_exists IFACE - 0 if the interface is present on the host.
interface_exists() {
  _if="$1"; [ -n "$_if" ] || return 1
  if command -v ip >/dev/null 2>&1; then
    ip link show "$_if" >/dev/null 2>&1
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig "$_if" >/dev/null 2>&1
  else
    return 0   # cannot verify; don't block
  fi
}

# network_exists [NAME] - 0 if the docker network exists. Defaults to tproxy_network.
network_exists() {
  _name="${1:-$TPROXY_NETWORK}"
  _d="$(_net_docker)"
  "$_d" network inspect "$_name" >/dev/null 2>&1
}

# recreate_macvlan PARENT [SUBNET] [GATEWAY] [NAME] - (re)create the macvlan
# network on PARENT. Removes an existing same-named network first so a changed
# parent/subnet takes effect (idempotent). SUBNET/GATEWAY/NAME default to
# $SUBNET_CIDR/$ROUTER_IP/$TPROXY_NETWORK from .env. Returns non-zero on failure.
recreate_macvlan() {
  _parent="$1"
  _subnet="${2:-$SUBNET_CIDR}"
  _gw="${3:-$ROUTER_IP}"
  _name="${4:-$TPROXY_NETWORK}"
  _d="$(_net_docker)"

  [ -n "$_parent" ] || { log_error "recreate_macvlan: no parent interface given"; return 1; }
  [ -n "$_subnet" ] || { log_error "recreate_macvlan: SUBNET_CIDR is empty (set it in .env)"; return 1; }
  [ -n "$_gw" ]     || { log_error "recreate_macvlan: ROUTER_IP is empty (set it in .env)"; return 1; }

  if network_exists "$_name"; then
    log_warn "docker network '$_name' exists - removing to re-create"
    if ! "$_d" network rm "$_name" >/dev/null 2>&1; then
      # A still-attached container blocks removal: force-disconnect every container
      # bound to it, then retry. (reprovision_containers normally clears these
      # first, but this keeps the network teardown self-healing for any caller.)
      for _cid in $("$_d" ps -aq --filter "network=$_name" 2>/dev/null); do
        log_warn "detaching container $_cid from '$_name'"
        "$_d" network disconnect -f "$_name" "$_cid" >/dev/null 2>&1 || true
      done
      if ! "$_d" network rm "$_name" >/dev/null 2>&1; then
        log_error "could not remove existing '$_name' (is a container still attached? 'docker network inspect $_name')"
        return 1
      fi
    fi
  fi

  if "$_d" network create -d macvlan \
       --subnet="$_subnet" --gateway="$_gw" \
       -o parent="$_parent" "$_name" >/dev/null 2>&1; then
    log_info "macvlan '$_name' created (parent=$_parent subnet=$_subnet gateway=$_gw)"
    return 0
  fi
  log_error "failed to create macvlan '$_name' on parent '$_parent' (check: parent up? subnet/gateway match the LAN? need root?)"
  return 1
}
