#!/bin/sh
# Execute installer primitives under BusyBox ash, matching DSM's shell closely.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/scripts/lib/common.sh"
. "$ROOT/scripts/lib/network.sh"
. "$ROOT/scripts/lib/registry.sh"
. "$ROOT/scripts/lib/compose.sh"
. "$ROOT/scripts/lib/cloudflared.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ui_error() { echo "ERROR: $*" >&2; }
. "$ROOT/scripts/installer/envedit.sh"
. "$ROOT/scripts/installer/ui.sh"

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT INT TERM
ENV_FILE="$TD/.env"
: > "$ENV_FILE"

SPECIAL='p@ ss&wo#rd$`"\tail'
env_set ACR_PASSWORD "$SPECIAL"
env_set UPDATE_SCHEDULE '0 2 * * *'
[ "$(env_get ACR_PASSWORD)" = "$SPECIAL" ] || fail "special dotenv value did not round-trip"
unset ACR_PASSWORD UPDATE_SCHEDULE
dotenv_load "$ENV_FILE"
[ "$ACR_PASSWORD" = "$SPECIAL" ] || fail "strict dotenv loader changed a secret"
[ "$UPDATE_SCHEDULE" = '0 2 * * *' ] || fail "strict dotenv loader changed a schedule"

# Existing .env files omit the v1.2.13 TUN knob; load_env must make that path
# explicitly DSM-safe without requiring an operator migration.
unset TUN_AUTO_REDIRECT
load_env
[ "$TUN_AUTO_REDIRECT" = false ] || fail "missing TUN_AUTO_REDIRECT did not default to false"

# shellcheck disable=SC2016 # Literal payload verifies dotenv values are never evaluated.
printf '%s\n' 'UNTRUSTED=$(touch SHOULD_NOT_EXIST)' >> "$ENV_FILE"
_oldpwd="$PWD"; cd "$TD"
dotenv_load "$ENV_FILE"
cd "$_oldpwd"
# shellcheck disable=SC2016 # Compare against the same literal malicious payload.
[ "$UNTRUSTED" = '$(touch SHOULD_NOT_EXIST)' ] || fail "dotenv value was evaluated"
[ ! -e "$TD/SHOULD_NOT_EXIST" ] || fail "dotenv content executed a command"
printf '%s\n' 'not-an-assignment' > "$ENV_FILE"
dotenv_load "$ENV_FILE" >/dev/null 2>&1 && fail "malformed dotenv line was accepted"

# `try` must preserve the command's real status; losing it as zero allowed the
# installer to continue pulling/deploying after an ACR authentication failure.
diagnose() { DIAGNOSIS="$1"; }
if try "login failed" "fix credentials" -- sh -c 'exit 5'; then
  fail "try accepted a failed command"
else
  _try_rc=$?
fi
[ "$_try_rc" -eq 5 ] || fail "try changed exit 5 to exit $_try_rc"
case "$DIAGNOSIS" in *'(exit 5)'*) : ;; *) fail "try reported the wrong exit status" ;; esac

# First run of the new layout imports legacy secrets without overwriting an
# already-persistent value.
LEGACY_APP="$TD/legacy-app"
LEGACY_DATA="$TD/legacy-data"
mkdir -p "$LEGACY_APP/config" "$LEGACY_DATA/config"
printf '%s\n' 'LEGACY_ENV=keep' > "$LEGACY_APP/.env"
printf '%s\n' 'Default=https://legacy.example/sub' > "$LEGACY_APP/config/subscription.txt"
(
  REPO_ROOT="$LEGACY_APP"
  GATEWAY_DATA_DIR="$LEGACY_DATA"
  ENV_FILE="$LEGACY_DATA/.env"
  CONFIG_STATE_DIR="$LEGACY_DATA/config"
  SUBSCRIPTION_FILE="$LEGACY_DATA/config/subscription.txt"
  ensure_persistent_state
)
grep -q '^LEGACY_ENV=keep$' "$LEGACY_DATA/.env" || fail "legacy .env was not migrated"
grep -q 'legacy.example' "$LEGACY_DATA/config/subscription.txt" || fail "legacy subscription was not migrated"
printf '%s\n' 'PERSISTENT=keep' > "$LEGACY_DATA/.env"
(
  REPO_ROOT="$LEGACY_APP"
  GATEWAY_DATA_DIR="$LEGACY_DATA"
  ENV_FILE="$LEGACY_DATA/.env"
  CONFIG_STATE_DIR="$LEGACY_DATA/config"
  SUBSCRIPTION_FILE="$LEGACY_DATA/config/subscription.txt"
  ensure_persistent_state
)
grep -q '^PERSISTENT=keep$' "$LEGACY_DATA/.env" || fail "persistent .env was overwritten"

ipv4_in_cidr 192.168.1.100 192.168.1.0/24 || fail "valid subnet member rejected"
! ipv4_in_cidr 192.168.2.100 192.168.1.0/24 || fail "outside IP accepted"
ipv4_is_edge_of_cidr 192.168.1.0 192.168.1.0/24 || fail "network edge not detected"
ipv4_is_edge_of_cidr 192.168.1.255 192.168.1.0/24 || fail "broadcast edge not detected"
! ipv4_is_edge_of_cidr 192.168.1.100 192.168.1.0/24 || fail "host IP treated as edge"
cidr_is_canonical 192.168.1.0/24 || fail "canonical subnet rejected"
! cidr_is_canonical 192.168.1.10/24 || fail "host address accepted as subnet"

# next_free_ipv4: suggest the first free host ABOVE the NAS IP, skipping the
# router, the subnet edges, and any address ip_in_use reports as taken.
mihomo_owns_ip() { return 1; }
ip_in_use() { case "$1" in 192.168.1.11) return 0 ;; *) return 1 ;; esac; }
[ "$(next_free_ipv4 192.168.1.10 192.168.1.0/24 192.168.1.1)" = 192.168.1.12 ] \
  || fail "next_free_ipv4 did not skip the in-use .11"
ip_in_use() { return 1; }
[ "$(next_free_ipv4 192.168.1.5 192.168.1.0/24 192.168.1.6)" = 192.168.1.7 ] \
  || fail "next_free_ipv4 did not skip the router address"
[ -z "$(next_free_ipv4 10.0.0.5 192.168.1.0/24 192.168.1.1)" ] \
  || fail "next_free_ipv4 accepted a base outside the subnet"

# scan_interfaces: list only NICs that carry an IPv4 (address-less ones are never
# valid macvlan parents); loopback/virtual interfaces stay filtered.
ip() { [ "$1 $2 $3" = "-o link show" ] && printf '1: lo: <LOOP>\n2: eth0: <UP>\n3: eth1: <UP>\n'; }
_iface_ipv4() { case "$1" in eth0) echo 192.168.1.10 ;; *) echo '' ;; esac; }
[ "$(scan_interfaces)" = 'eth0 192.168.1.10' ] \
  || fail "scan_interfaces kept an address-less or filtered NIC: $(scan_interfaces)"
unset -f ip

# cloudflared_token_present: reuse the token only when a container actually has one.
_net_docker() { echo _fake_cf_docker; }
_fake_cf_docker() {
  [ "$1" = inspect ] || return 0
  if [ "$2" = -f ]; then _cf_name="$4"; else _cf_name="$2"; fi
  case "$_cf_name" in
    has-token) [ "$2" = -f ] && printf 'PATH=/usr/bin\nTUNNEL_TOKEN=abc.def\n'; return 0 ;;
    no-token)  [ "$2" = -f ] && printf 'PATH=/usr/bin\n'; return 0 ;;
    *) return 1 ;;
  esac
}
CF_CONTAINER_NAME=has-token; cloudflared_token_present || fail "missed an existing tunnel token"
CF_CONTAINER_NAME=no-token;  ! cloudflared_token_present || fail "invented a tunnel token"
CF_CONTAINER_NAME=absent;    ! cloudflared_token_present || fail "saw a token on a missing container"

# iface_is_ovs: an Open vSwitch parent breaks a macvlan gateway; a plain NIC does not.
iface_is_ovs ovs_eth0 || fail "ovs_eth0 not detected as Open vSwitch"
! iface_is_ovs eth0 || fail "eth0 wrongly detected as Open vSwitch"

# warn_if_ovs_parent: warns (non-fatally) on an OVS parent and is silent on a plain
# NIC. On the default driver it must steer to a NON-OVS parent (NOT recommend ipvlan
# as a forwarding fix); with TPROXY_DRIVER=ipvlan it must flag the forwarding caveat.
_ovs_warn="$(warn_if_ovs_parent ovs_eth0 2>&1)"
printf '%s' "$_ovs_warn" | grep -q 'Open vSwitch' || fail "warn_if_ovs_parent did not warn on an OVS parent"
printf '%s' "$_ovs_warn" | grep -qi 'non-OVS\|disable Open vSwitch' || fail "warn_if_ovs_parent did not steer to a non-OVS parent"
[ -z "$(warn_if_ovs_parent eth0 2>&1)" ] || fail "warn_if_ovs_parent warned on a plain NIC"
TPROXY_DRIVER=ipvlan
printf '%s' "$(warn_if_ovs_parent ovs_eth0 2>&1)" | grep -qi 'forward' \
  || fail "warn_if_ovs_parent(ipvlan) did not flag the broken forwarding role"
TPROXY_DRIVER=macvlan

# recreate_macvlan honors TPROXY_DRIVER: macvlan by default, ipvlan L2 for OVS parents.
NET_CREATE_LOG="$TD/netcreate"
fake_net_docker() {
  if [ "$1 $2" = "network create" ]; then shift 2; echo "$*" >> "$NET_CREATE_LOG"; return 0; fi
  return 1   # inspect -> absent/no-match, so recreate proceeds to create
}
_net_docker() { printf '%s' fake_net_docker; }
SUBNET_CIDR=10.0.0.0/24
ROUTER_IP=10.0.0.1
: > "$NET_CREATE_LOG"
recreate_macvlan eth0 >/dev/null 2>&1 || fail "recreate_macvlan(macvlan) returned non-zero"
grep -q -- '-d macvlan' "$NET_CREATE_LOG" || fail "default driver was not macvlan"
! grep -q 'ipvlan_mode' "$NET_CREATE_LOG" || fail "macvlan create included ipvlan_mode"
: > "$NET_CREATE_LOG"
TPROXY_DRIVER=ipvlan
recreate_macvlan eth0 >/dev/null 2>&1 || fail "recreate_macvlan(ipvlan) returned non-zero"
grep -q -- '-d ipvlan' "$NET_CREATE_LOG" || fail "ipvlan driver not used under TPROXY_DRIVER=ipvlan"
grep -q 'ipvlan_mode=l2' "$NET_CREATE_LOG" || fail "ipvlan create missing ipvlan_mode=l2"
TPROXY_DRIVER=macvlan

interface_exists() { return 0; }
_iface_ipv4() { echo 192.168.1.10; }
validate_network_plan eth0 192.168.1.0/24 192.168.1.1 192.168.1.100 \
  || fail "valid network plan rejected"
! validate_network_plan eth0 192.168.1.0/24 192.168.2.1 192.168.1.100 >/dev/null 2>&1 \
  || fail "router outside subnet accepted"
! validate_network_plan eth0 192.168.1.0/24 192.168.1.1 192.168.1.255 >/dev/null 2>&1 \
  || fail "broadcast gateway IP accepted"

fake_docker() {
  case "$*" in
    *'/sys/class/net/'*) [ "${FAKE_TUN:-0}" = 1 ] ;;
    *'/proc/sys/net/ipv4/ip_forward'*) echo 1 ;;
    *) return 1 ;;
  esac
}
DOCKER_BIN=fake_docker
MIHOMO_CONTAINER=mihomo
FAKE_TUN=0
! mihomo_gateway_probe >/dev/null 2>&1 || fail "missing runtime TUN was accepted"
FAKE_TUN=1
mihomo_gateway_probe >/dev/null 2>&1 || fail "ready runtime TUN was rejected"

host_arch() { echo amd64; }
image_arch() { echo arm64; }
! arch_ok example.invalid/image:latest >/dev/null 2>&1 || fail "wrong image architecture was accepted"

# Deployment sequencing regression: the pre-deployment DECISION runs first (so
# interface + IP detection are clean), but no network/container mutation may occur
# before non-destructive image/config preparation succeeds (validate-before-teardown).
. "$ROOT/scripts/installer/flow_deploy.sh"
msg() { echo "$1"; }
ui_step() { :; }
is_root() { return 0; }
seed_config() { return 0; }
load_env() { return 0; }
wizard_env() { return 0; }
wizard_images() { return 0; }
wizard_subscription() { return 0; }
pf_docker() { return 0; }
pf_arch() { return 0; }
pf_web_port() { return 0; }
validate_selected_network() { return 0; }
plan_predeployment_cleanup() { echo plan >> "$TD/order"; }
scan_and_prefill() { echo scan >> "$TD/order"; }
apply_predeployment_cleanup() { echo cleanup >> "$TD/order"; }
create_network() { echo network >> "$TD/order"; }
deploy_stack() { echo deploy >> "$TD/order"; }
report_success() { :; }
prepare_stack() { return 1; }
: > "$TD/order"
flow_deploy >/dev/null 2>&1 && fail "deploy continued after preparation failure"
case "$(tr '\n' ' ' < "$TD/order")" in
  *cleanup*|*network*|*deploy*) fail "deploy mutated state before preparation succeeded" ;;
esac
prepare_stack() { echo prepare >> "$TD/order"; }
: > "$TD/order"
flow_deploy >/dev/null 2>&1 || fail "stubbed deployment sequence failed"
[ "$(tr '\n' ' ' < "$TD/order")" = 'plan scan prepare cleanup network deploy ' ] \
  || fail "unsafe deployment order: $(tr '\n' ' ' < "$TD/order")"

# The success report must turn the selected/auto-detected parent NIC's address
# into a usable dashboard URL, while retaining a readable fallback if the host
# address cannot be determined.
. "$ROOT/scripts/installer/i18n.sh"
. "$ROOT/scripts/installer/flow_deploy.sh"
ui_step() { :; }
ui_ok() { :; }
ui_warn() { :; }
ui_say() { printf '%s\n' "$*"; }
INSTALLER_LANG=en
WEB_UI_PORT=8080
CHOSEN_IFACE=eth0
PARENT_INTERFACE=''
_iface_ipv4() { [ "$1" = eth0 ] && printf '192.168.1.10'; }
_report="$(report_success)"
case "$_report" in
  *'http://192.168.1.10:8080'*) : ;;
  *) fail "success report did not use the selected parent IPv4: $_report" ;;
esac

CHOSEN_IFACE=''
PARENT_INTERFACE=''
detect_parent_interface() { printf 'eth9'; }
_iface_ipv4() { [ "$1" = eth9 ] && printf '10.20.30.40'; }
_report="$(report_success)"
case "$_report" in
  *'http://10.20.30.40:8080'*) : ;;
  *) fail "success report did not use the auto-detected parent IPv4: $_report" ;;
esac

_iface_ipv4() { :; }
_report="$(report_success)"
case "$_report" in
  *'http://<NAS-IP>:8080'*) : ;;
  *) fail "success report lost the NAS-IP fallback: $_report" ;;
esac

echo "OK: BusyBox dotenv/network/arch/TUN/cloudflared/report checks and decision-first, fail-before-mutation deployment order"
