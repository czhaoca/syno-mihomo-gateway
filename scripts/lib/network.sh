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
# L2 driver for the gateway network. macvlan is the default AND the only driver that
# supports the transparent-gateway role: LAN clients set their default gateway to
# MIHOMO_IP, so the container must receive frames whose L3 destination is an arbitrary
# external IP. macvlan switches on the child's own MAC and delivers them; ipvlan L2
# demultiplexes by DESTINATION IP and shares the parent MAC, so it will NOT hand those
# forwarded frames to the container - the proxy silently stops routing clients.
# ipvlan is therefore only a dashboard-reachability escape hatch for the SOME Open
# vSwitch configurations where a macvlan child's fresh MAC is not flooded to peer
# ports - never a fix for the forwarding role. A macvlan child IS LAN-reachable on
# a typical OVS parent (ovs_eth0, verified empirically), so keep macvlan and treat
# warn_if_ovs_parent as a heads-up, not a failure.
TPROXY_DRIVER="${TPROXY_DRIVER:-macvlan}"

# Resolve a docker binary without depending on detect_compose having run.
_net_docker() {
  if [ -n "${DOCKER_BIN:-}" ]; then printf '%s' "$DOCKER_BIN"; return 0; fi
  command -v docker 2>/dev/null && return 0
  for _c in /usr/local/bin/docker /usr/bin/docker; do
    [ -x "$_c" ] && { printf '%s' "$_c"; return 0; }
  done
  printf 'docker'
}

# _dns_probe NS DOMAIN - one bounded lookup against one nameserver. Wrapped in
# `timeout` when available so a black-holing resolver cannot hang the doctor.
_dns_probe() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 nslookup "$2" "$1" >/dev/null 2>&1
  else
    nslookup "$2" "$1" >/dev/null 2>&1
  fi
}

# resolv_conf_probe - probe EVERY nameserver in the host's resolver config
# (SMG_RESOLV_CONF overrides the path - also the test seam) against
# ${SMG_DNS_PROBE_DOMAIN:-www.gstatic.com}, the same neutral target the proxy
# health checks use. A host whose only resolver is unreachable cannot resolve
# anything - and neither can any bridge container inheriting its resolv.conf.
# Prints "TOTAL DEAD DEAD_LIST" on stdout.
# rc 0 = every resolver answers | 1 = at least one is dead | 2 = unknown
# (no nslookup, unreadable config, or no nameserver lines to probe).
resolv_conf_probe() {
  _rcp_conf="${SMG_RESOLV_CONF:-/etc/resolv.conf}"
  command -v nslookup >/dev/null 2>&1 || return 2
  [ -r "$_rcp_conf" ] || return 2
  _rcp_domain="${SMG_DNS_PROBE_DOMAIN:-www.gstatic.com}"
  _rcp_total=0; _rcp_dead=0; _rcp_dead_list=""
  for _rcp_ns in $(awk '$1 == "nameserver" { print $2 }' "$_rcp_conf" 2>/dev/null); do
    _rcp_total=$((_rcp_total + 1))
    if ! _dns_probe "$_rcp_ns" "$_rcp_domain"; then
      _rcp_dead=$((_rcp_dead + 1))
      _rcp_dead_list="${_rcp_dead_list:+$_rcp_dead_list,}$_rcp_ns"
    fi
  done
  [ "$_rcp_total" -gt 0 ] || return 2
  printf '%s %s %s\n' "$_rcp_total" "$_rcp_dead" "$_rcp_dead_list"
  [ "$_rcp_dead" -eq 0 ]
}

# --- install-network classifier (#54) -----------------------------------------
# Classifies the install network so the image wizard can pre-decide the image
# source and the split-horizon DNS variant without asking; anything short of a
# conclusive verdict stays 'unknown' -> the manual question. Endpoints stay
# hostname-based, neutral, and env-overridable (gstatic precedent); the variant
# VALUES are never here - the wizard derives them from .env.example.

# _scan_have TOOL - existence probe, split out as the test seam.
_scan_have() { command -v "$1" >/dev/null 2>&1; }

# _scan_http_204 URL TIMEOUT - probe URL dialed DIRECT and grade the answer.
# Asserting the code (not mere connect success) keeps captive portals and
# transparent proxies - which complete handshakes and answer 200-with-a-body -
# from faking an "unfiltered" verdict.
#   rc 0 = VERIFIED HTTP 204 (curl reads the status code)
#   rc 1 = failed / not a 204-shaped answer
#   rc 2 = no fetch tool (mirrors geodata.sh's curl-or-wget posture)
#   rc 3 = 204-SHAPED but unverifiable: BusyBox wget exposes no status code,
#          so an empty-body success is only evidence of a live path - callers
#          must never treat it as a conclusive 204.
_scan_http_204() {
  _sh_u="$1"; _sh_t="${2:-5}"
  if _scan_have curl; then
    [ "$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout "$_sh_t" \
         --max-time "$_sh_t" "$_sh_u" 2>/dev/null)" = 204 ]
  elif _scan_have wget; then
    _sh_body="$(wget -q -T "$_sh_t" -O - "$_sh_u" 2>/dev/null)" || return 1
    [ -z "$_sh_body" ] || return 1
    return 3
  else
    return 2
  fi
}

# _scan_http_any URL TIMEOUT - 0 iff URL answers ANY HTTP status; only a
# connect/TLS failure counts as blocked (docker.io answers 401 unauthenticated,
# which is still "reachable"). BusyBox wget treats non-2xx as failure, so a
# wget-only host may under-report reach - callers degrade to the manual menu.
_scan_http_any() {
  _sa_u="$1"; _sa_t="${2:-5}"
  if _scan_have curl; then
    curl -sS -o /dev/null --connect-timeout "$_sa_t" --max-time "$_sa_t" "$_sa_u" 2>/dev/null
  elif _scan_have wget; then
    wget -q -T "$_sa_t" -O /dev/null "$_sa_u" 2>/dev/null
  else
    return 2
  fi
}

# scan_network_filtering - print exactly one of: unfiltered | filtered | unknown.
#   foreign 204 direct                   -> unfiltered
#   foreign blocked + control 204 direct -> filtered (egress alive, foreign cut)
#   both dead, or no fetch tool          -> unknown (never guess without evidence)
# SMG_SCAN_FORCE=unfiltered|filtered|unknown skips probing (operator escape
# hatch for VPN'd/captive networks + the CI seam). Endpoint/timeout overrides:
# SMG_SCAN_FOREIGN_URL (default google's own generate_204 - the CN-blocked
# differential; gstatic's is served by CN edges and cannot differentiate),
# SMG_SCAN_CONTROL_URL (default gstatic generate_204 - reachable control),
# SMG_SCAN_TIMEOUT (seconds).
scan_network_filtering() {
  case "${SMG_SCAN_FORCE:-}" in
    unfiltered|filtered|unknown) printf '%s' "$SMG_SCAN_FORCE"; return 0 ;;
  esac
  _sn_t="${SMG_SCAN_TIMEOUT:-5}"
  _scan_http_204 "${SMG_SCAN_FOREIGN_URL:-https://www.google.com/generate_204}" "$_sn_t"
  _sn_rc=$?
  case "$_sn_rc" in
    0) printf 'unfiltered'; return 0 ;;
    # No tool, or wget's unverifiable 204-shape: 'unfiltered' silently flips
    # the DNS variant + registry, so it demands a VERIFIED 204 - everything
    # short of that stays inconclusive (the manual question is the fallback).
    2|3) printf 'unknown'; return 0 ;;
  esac
  _scan_http_204 "${SMG_SCAN_CONTROL_URL:-http://www.gstatic.com/generate_204}" "$_sn_t"
  _sn_ctl=$?
  # 'filtered' keeps the fail-safe shipped posture, so a live control path is
  # enough evidence either way (verified 204 or the wget 204-shape).
  if [ "$_sn_ctl" = 0 ] || [ "$_sn_ctl" = 3 ]; then
    printf 'filtered'
  else
    printf 'unknown'
  fi
}

# scan_registry_reachable - 0 iff the upstream registry answers at all
# (SMG_SCAN_REGISTRY_URL, default the Docker Hub registry API root). Consulted
# only after an 'unfiltered' verdict, before defaulting REGISTRY_MODE=docker.
scan_registry_reachable() {
  # The FORCE seam mirrors scan_network_filtering's complete case (#61c):
  # 'unknown' short-circuits conservatively (not reachable), never probes.
  case "${SMG_SCAN_FORCE:-}" in unfiltered) return 0 ;; filtered|unknown) return 1 ;; esac
  _scan_http_any "${SMG_SCAN_REGISTRY_URL:-https://registry-1.docker.io/v2/}" \
    "${SMG_SCAN_TIMEOUT:-5}"
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
# "IFACE IPV4" (both fields space-free so callers can split on the single space).
# Skips loopback and virtual/docker interfaces (lo, docker*, veth*, br-*,
# tproxy_network bridges) AND any interface that has no IPv4 address - an
# address-less NIC is never a valid macvlan parent here, so it only adds noise to
# the picker. Prefers `ip`, falls back to `ifconfig`; DSM BusyBox has one.
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
    [ -n "$_ip4" ] || continue
    printf '%s %s\n' "$_if" "$_ip4"
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

# next_free_ipv4 BASE SUBNET ROUTER [MAX] - suggest the first usable, free host
# IPv4 ABOVE base within SUBNET. Skips the network/broadcast edges and ROUTER,
# then probes each candidate with ip_in_use (arping->ping) and returns the first
# that is free, unverifiable, or already held by our own mihomo container (so a
# re-deploy reuses its address). Scans at most MAX candidates (default 10) to keep
# the arping sweep short. Prints the chosen IP, or nothing if none qualifies (the
# caller then falls back to a typed default). awk does the 32-bit integer math.
next_free_ipv4() {
  _nf_base="$1"; _nf_subnet="$2"; _nf_router="$3"; _nf_max="${4:-10}"
  [ -n "$_nf_base" ] && [ -n "$_nf_subnet" ] || return 0
  ipv4_in_cidr "$_nf_base" "$_nf_subnet" || return 0
  _nf_cands="$(awk -v base="$_nf_base" -v cidr="$_nf_subnet" \
                   -v router="$_nf_router" -v max="$_nf_max" 'BEGIN {
    split(base,b,"."); x=((b[1]*256+b[2])*256+b[3])*256+b[4]
    split(cidr,c,"/"); split(c[1],n,"."); m=c[2]+0
    y=((n[1]*256+n[2])*256+n[3])*256+n[4]; block=2^(32-m)
    net=int(y/block)*block; bcast=net+block-1
    ri=-1
    if (split(router,r,".")==4) ri=((r[1]*256+r[2])*256+r[3])*256+r[4]
    cnt=0; ip=x+1
    while (cnt<max && ip<bcast) {
      if (ip>net && ip!=ri) {
        printf "%d.%d.%d.%d\n", int(ip/16777216)%256, int(ip/65536)%256, int(ip/256)%256, ip%256
        cnt++
      }
      ip++
    }
  }')"
  for _nf_ip in $_nf_cands; do
    mihomo_owns_ip "$_nf_ip" && { printf '%s' "$_nf_ip"; return 0; }
    if ip_in_use "$_nf_ip"; then
      continue                          # answers on the LAN -> taken, try the next
    fi
    printf '%s' "$_nf_ip"; return 0     # free or unverifiable -> offer it
  done
  return 0
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

# iface_is_ovs IFACE - 0 if IFACE is an Open vSwitch port (Synology names it
# ovs_eth0 when OVS is enabled). On SOME OVS configurations a macvlan child's fresh
# MAC is not flooded to peer ports, so LAN peers can't reach it (the dashboard/gateway
# time out) - but this is config-dependent and many OVS setups work fine. It is a
# heads-up, not a guaranteed failure.
iface_is_ovs() {
  case "$1" in ovs*|*-ovs|ovs_*) return 0 ;; *) return 1 ;; esac
}

# warn_if_ovs_parent IFACE - emit a non-fatal heads-up when IFACE is an Open vSwitch
# port: on some OVS configs a macvlan child is not reachable by LAN peers. This is
# NOT a guaranteed failure (many OVS setups work). If LAN peers can't reach the
# gateway/dashboard, docs/troubleshooting.md covers it. Always returns 0. Called on
# every network-creation path (incl. the headless boot self-heal) so an OVS parent is
# surfaced consistently, not only on first-deploy.
warn_if_ovs_parent() {
  _wo_if="$1"; [ -n "$_wo_if" ] || return 0
  iface_is_ovs "$_wo_if" || return 0
  log_warn "parent '$_wo_if' is an Open vSwitch port: on some OVS configs a macvlan child is not reachable by LAN peers (dashboard/gateway time out). If a LAN device can't reach the gateway, see docs/troubleshooting.md."
  return 0
}

# BusyBox-compatible IPv4/CIDR relationship checks. awk uses exact integer
# arithmetic for the 32-bit values involved here and does not need ipcalc.
ipv4_in_cidr() {
  awk -v ip="$1" -v cidr="$2" 'BEGIN {
    na=split(ip,a,"."); nc=split(cidr,c,"/"); nn=split(c[1],n,"."); m=c[2]+0
    if (na!=4 || nc!=2 || nn!=4 || c[2] !~ /^[0-9]+$/ || m<0 || m>32) exit 1
    for (i=1;i<=4;i++) if (a[i] !~ /^[0-9]+$/ || n[i] !~ /^[0-9]+$/ || a[i]>255 || n[i]>255) exit 1
    x=((a[1]*256+a[2])*256+a[3])*256+a[4]
    y=((n[1]*256+n[2])*256+n[3])*256+n[4]
    block=2^(32-m); exit !(int(x/block)==int(y/block))
  }'
}

ipv4_is_edge_of_cidr() {
  awk -v ip="$1" -v cidr="$2" 'BEGIN {
    na=split(ip,a,"."); nc=split(cidr,c,"/"); nn=split(c[1],n,"."); m=c[2]+0
    if (na!=4 || nc!=2 || nn!=4 || c[2] !~ /^[0-9]+$/ || m<0 || m>32) exit 1
    for (i=1;i<=4;i++) if (a[i] !~ /^[0-9]+$/ || n[i] !~ /^[0-9]+$/ || a[i]>255 || n[i]>255) exit 1
    x=((a[1]*256+a[2])*256+a[3])*256+a[4]
    y=((n[1]*256+n[2])*256+n[3])*256+n[4]
    block=2^(32-m); base=int(y/block)*block
    exit !((x==base) || (x==base+block-1))
  }'
}

cidr_is_canonical() {
  awk -v cidr="$1" 'BEGIN {
    nc=split(cidr,c,"/"); nn=split(c[1],n,"."); m=c[2]+0
    if (nc!=2 || nn!=4 || c[2] !~ /^[0-9]+$/ || m<0 || m>32) exit 1
    for (i=1;i<=4;i++) if (n[i] !~ /^[0-9]+$/ || n[i]>255) exit 1
    y=((n[1]*256+n[2])*256+n[3])*256+n[4]; block=2^(32-m)
    exit !(y==int(y/block)*block)
  }'
}

validate_network_plan() {
  _vn_parent="$1"; _vn_subnet="$2"; _vn_router="$3"; _vn_mihomo="$4"
  interface_exists "$_vn_parent" || { log_error "parent interface not found: $_vn_parent"; return 1; }
  cidr_is_canonical "$_vn_subnet" || { log_error "SUBNET_CIDR must be a canonical network address: $_vn_subnet"; return 1; }
  ipv4_in_cidr "$_vn_router" "$_vn_subnet" || { log_error "ROUTER_IP=$_vn_router is outside SUBNET_CIDR=$_vn_subnet"; return 1; }
  ipv4_in_cidr "$_vn_mihomo" "$_vn_subnet" || { log_error "MIHOMO_IP=$_vn_mihomo is outside SUBNET_CIDR=$_vn_subnet"; return 1; }
  [ "$_vn_router" != "$_vn_mihomo" ] || { log_error "MIHOMO_IP must differ from ROUTER_IP"; return 1; }
  ! ipv4_is_edge_of_cidr "$_vn_router" "$_vn_subnet" || { log_error "ROUTER_IP cannot be the subnet network/broadcast address"; return 1; }
  ! ipv4_is_edge_of_cidr "$_vn_mihomo" "$_vn_subnet" || { log_error "MIHOMO_IP cannot be the subnet network/broadcast address"; return 1; }
  _vn_host="$(_iface_ipv4 "$_vn_parent")"
  if [ -n "$_vn_host" ] && ! ipv4_in_cidr "$_vn_host" "$_vn_subnet"; then
    log_error "parent $_vn_parent address $_vn_host is outside $_vn_subnet"
    return 1
  fi
  return 0
}

# network_exists [NAME] - 0 if the docker network exists. Defaults to tproxy_network.
network_exists() {
  _name="${1:-$TPROXY_NETWORK}"
  _d="$(_net_docker)"
  "$_d" network inspect "$_name" >/dev/null 2>&1
}

# macvlan_matches NAME PARENT SUBNET GATEWAY - 0 if the existing network matches the
# requested driver (TPROXY_DRIVER), parent, subnet, and gateway. A driver change
# (macvlan<->ipvlan) counts as a mismatch so the network is cleanly recreated.
macvlan_matches() {
  _mm_name="$1"; _mm_parent="$2"; _mm_subnet="$3"; _mm_gateway="$4"
  _mm_d="$(_net_docker)"
  _mm_have="$("$_mm_d" network inspect -f '{{.Driver}}|{{index .Options "parent"}}|{{(index .IPAM.Config 0).Subnet}}|{{(index .IPAM.Config 0).Gateway}}' "$_mm_name" 2>/dev/null)"
  [ "$_mm_have" = "${TPROXY_DRIVER:-macvlan}|$_mm_parent|$_mm_subnet|$_mm_gateway" ]
}

network_attachments() {
  _na_d="$(_net_docker)"
  "$_na_d" network inspect -f '{{range $id, $c := .Containers}}{{$c.Name}} {{end}}' "$1" 2>/dev/null
}

# recreate_macvlan PARENT [SUBNET] [GATEWAY] [NAME] - ensure the gateway L2 network
# exists on PARENT, using the TPROXY_DRIVER (macvlan default, or ipvlan L2 for an
# Open vSwitch parent). A mismatched same-named network is never removed here;
# interactive lifecycle preprocessing must first verify ownership and apply the
# operator's cleanup choice. SUBNET/GATEWAY/NAME default to
# $SUBNET_CIDR/$ROUTER_IP/$TPROXY_NETWORK from .env. Returns non-zero on failure.
recreate_macvlan() {
  _parent="$1"
  _subnet="${2:-$SUBNET_CIDR}"
  _gw="${3:-$ROUTER_IP}"
  _name="${4:-$TPROXY_NETWORK}"
  _driver="${TPROXY_DRIVER:-macvlan}"
  _d="$(_net_docker)"

  [ -n "$_parent" ] || { log_error "recreate_macvlan: no parent interface given"; return 1; }
  [ -n "$_subnet" ] || { log_error "recreate_macvlan: SUBNET_CIDR is empty (set it in .env)"; return 1; }
  [ -n "$_gw" ]     || { log_error "recreate_macvlan: ROUTER_IP is empty (set it in .env)"; return 1; }

  if macvlan_matches "$_name" "$_parent" "$_subnet" "$_gw"; then
    log_info "$_driver network '$_name' already matches requested configuration"
    return 0
  fi

  if network_exists "$_name"; then
    log_error "docker network '$_name' exists with different settings; refusing implicit removal"
    log_error "run ${INSTALLER_ENTRY:-install.sh} and choose automatic or manual network cleanup"
    return 1
  fi

  # ipvlan L2 takes an extra mode option; macvlan uses parent alone.
  if [ "$_driver" = ipvlan ]; then
    set -- -o ipvlan_mode=l2 -o parent="$_parent"
  else
    set -- -o parent="$_parent"
  fi
  if "$_d" network create -d "$_driver" \
       --subnet="$_subnet" --gateway="$_gw" "$@" "$_name" >/dev/null 2>&1; then
    log_info "$_driver network '$_name' created (parent=$_parent subnet=$_subnet gateway=$_gw)"
    return 0
  fi
  log_error "failed to create $_driver network '$_name' on parent '$_parent' (check: parent up? subnet/gateway match the LAN? need root?)"
  return 1
}
