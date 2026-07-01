#!/bin/sh
# Execute installer primitives under BusyBox ash, matching DSM's shell closely.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/scripts/lib/common.sh"
. "$ROOT/scripts/lib/network.sh"
. "$ROOT/scripts/lib/registry.sh"
. "$ROOT/scripts/lib/compose.sh"
. "$ROOT/scripts/lib/cloudflared.sh"
. "$ROOT/scripts/lib/resolve.sh"

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

# --- resolve.sh: UI-free config resolution -------------------------------------
# Every resolve_* function must be callable with env/args only. Prove it by
# unsetting every ui.sh/i18n widget inside the subshell before exercising them
# (ui_error stays: it is envedit.sh's error channel, and headless callers
# provide their own). The whole block runs in a subshell so its ENV_FILE and
# LIFECYCLE_* stubs cannot leak into later tests.
grep -v '^[[:space:]]*#' "$ROOT/scripts/lib/resolve.sh" \
  | grep -E '\bui_(say|info|ok|warn|step|menu|ask|yesno)|\bmsgf? ' \
  && fail "resolve.sh calls interactive ui/i18n helpers"
(
  unset -f ui_info ui_ok ui_warn ui_say ui_step ui_menu_select \
           ui_ask ui_ask_validated ui_ask_secret ui_yesno msg msgf 2>/dev/null

  # resolve_mihomo_ip: a saved value that is still a usable host in the subnet
  # is kept verbatim; no scan happens.
  rm -f "$TD/hooked"
  resolve_notify_scan() { : > "$TD/hooked"; }
  mihomo_owns_ip() { return 1; }
  ip_in_use() { return 1; }
  _iface_ipv4() { echo 192.168.1.10; }
  [ "$(resolve_mihomo_ip 192.168.1.100 192.168.1.0/24 192.168.1.1 eth0)" = 192.168.1.100 ] \
    || fail "resolve_mihomo_ip discarded a still-valid saved IP"
  [ ! -e "$TD/hooked" ] || fail "resolve_mihomo_ip scanned despite a valid saved IP"

  # Saved value collides with the router -> rescan above the NAS IP, and the
  # scan-notify hook fires exactly once on this path.
  [ "$(resolve_mihomo_ip 192.168.1.1 192.168.1.0/24 192.168.1.1 eth0)" = 192.168.1.11 ] \
    || fail "resolve_mihomo_ip kept a router-colliding IP"
  [ -e "$TD/hooked" ] || fail "resolve_mihomo_ip scan did not fire the notify hook"

  # No interface (manual entry) or NAS IP outside the subnet -> empty, so the
  # caller applies its own fallback.
  [ -z "$(resolve_mihomo_ip 10.0.0.5 192.168.1.0/24 192.168.1.1 '')" ] \
    || fail "resolve_mihomo_ip suggested without an interface"
  _iface_ipv4() { echo 10.9.9.9; }
  [ -z "$(resolve_mihomo_ip '' 192.168.1.0/24 192.168.1.1 eth0)" ] \
    || fail "resolve_mihomo_ip scanned from a NAS IP outside the subnet"

  # resolve_images + resolve_update_images: env-file driven, no prompts.
  ENV_FILE="$TD/resolve.env"
  : > "$ENV_FILE"
  env_set DOCKER_REGISTRY registry.example
  env_set ACR_NAMESPACE ns
  env_set MIHOMO_TAG v1
  env_set METACUBEXD_TAG v2
  REGISTRY_MODE=acr
  resolve_images || fail "resolve_images failed with a complete acr config"
  [ "$MIHOMO_IMAGE" = registry.example/ns/mihomo:v1 ] \
    || fail "resolve_images derived the wrong mihomo ref: $MIHOMO_IMAGE"
  [ "$(env_get METACUBEXD_IMAGE)" = registry.example/ns/metacubexd:v2 ] \
    || fail "resolve_images did not persist the metacubexd ref"
  resolve_update_images || fail "resolve_update_images failed"
  [ "$(env_get UPDATE_IMAGES)" = 'registry.example/ns/mihomo:v1 registry.example/ns/metacubexd:v2' ] \
    || fail "UPDATE_IMAGES wrong without cloudflared: $(env_get UPDATE_IMAGES)"
  env_set CF_IMAGE registry.example/ns/cloudflared:v3
  resolve_update_images || fail "resolve_update_images failed with CF_IMAGE"
  case "$(env_get UPDATE_IMAGES)" in
    *cloudflared:v3) : ;;
    *) fail "UPDATE_IMAGES did not append the cloudflared ref" ;;
  esac
  ( REGISTRY_MODE=acr; env_set ACR_NAMESPACE ''; resolve_images >/dev/null 2>&1 ) \
    && fail "resolve_images accepted acr mode without a namespace"
  REGISTRY_MODE=docker
  resolve_images || fail "resolve_images failed in docker mode"
  [ "$MIHOMO_IMAGE" = docker.io/metacubex/mihomo:v1 ] \
    || fail "docker mode did not derive the upstream mihomo ref: $MIHOMO_IMAGE"

  # resolve_subscription_url: cleans paste artifacts, validates the scheme.
  [ "$(resolve_subscription_url '"https://sub.example/token"')" = 'https://sub.example/token' ] \
    || fail "resolve_subscription_url did not strip quotes"
  _raw="$(printf '\033[200~https://sub.example/p\033[201~')"
  [ "$(resolve_subscription_url "$_raw")" = 'https://sub.example/p' ] \
    || fail "resolve_subscription_url did not strip bracketed-paste markers"
  [ "$(resolve_subscription_url 'Airport=https://sub.example/q')" = 'https://sub.example/q' ] \
    || fail "resolve_subscription_url did not strip the label prefix"
  resolve_subscription_url 'ftp://sub.example/x' >/dev/null \
    && fail "resolve_subscription_url accepted a non-http scheme"
  resolve_subscription_url '' >/dev/null \
    && fail "resolve_subscription_url accepted an empty URL"

  # subscription_current: '' for missing file or the shipped placeholder,
  # else the first real line.
  _APP="$TD/subapp"
  mkdir -p "$_APP/config"
  printf '%s\n' 'Default=https://example.invalid/CHANGE_ME' > "$_APP/config/subscription.txt.example"
  REPO_ROOT="$_APP"
  SUBSCRIPTION_FILE="$_APP/config/subscription.txt"
  [ -z "$(subscription_current)" ] || fail "subscription_current invented a URL for a missing file"
  cp "$_APP/config/subscription.txt.example" "$SUBSCRIPTION_FILE"
  [ -z "$(subscription_current)" ] || fail "subscription_current returned the shipped placeholder"
  printf '%s\n' 'https://sub.example/real' > "$SUBSCRIPTION_FILE"
  [ "$(subscription_current)" = 'https://sub.example/real' ] \
    || fail "subscription_current missed the stored URL"

  # resolve_cleanup_*: validate a requested plan against the lifecycle
  # inventory, with machine-readable reasons (no menus).
  LIFECYCLE_CONTAINERS_PRESENT=1 LIFECYCLE_CONTAINERS_SAFE=0
  resolve_cleanup_containers preserve && fail "ambiguous containers accepted for preserve"
  [ "$RESOLVE_CLEANUP_REASON" = ambiguous ] || fail "wrong reason for ambiguous preserve: $RESOLVE_CLEANUP_REASON"
  resolve_cleanup_containers auto && fail "ambiguous containers accepted for auto"
  LIFECYCLE_CONTAINERS_SAFE=1
  resolve_cleanup_containers auto || fail "safe containers rejected for auto"
  [ "$CLEANUP_CONTAINERS_MODE" = auto ] || fail "containers mode not recorded"
  LIFECYCLE_CONTAINERS_PRESENT=0
  resolve_cleanup_containers auto || fail "absent containers rejected"
  [ "$CLEANUP_CONTAINERS_MODE" = preserve ] || fail "absent containers not normalized to preserve"
  LIFECYCLE_NETWORK_PRESENT=1 LIFECYCLE_NETWORK_MATCHES=0 LIFECYCLE_NETWORK_SAFE=1 LIFECYCLE_ATTACHMENTS=''
  resolve_cleanup_network preserve && fail "drifted network accepted for preserve"
  [ "$RESOLVE_CLEANUP_REASON" = drift ] || fail "wrong reason for drifted preserve: $RESOLVE_CLEANUP_REASON"
  LIFECYCLE_NETWORK_SAFE=0
  resolve_cleanup_network auto && fail "unrelated network accepted for auto"
  [ "$RESOLVE_CLEANUP_REASON" = unrelated ] || fail "wrong reason for unrelated auto: $RESOLVE_CLEANUP_REASON"
  LIFECYCLE_NETWORK_SAFE=1 LIFECYCLE_ATTACHMENTS='mihomo'
  CLEANUP_CONTAINERS_MODE=preserve
  resolve_cleanup_network auto && fail "attached network removal accepted without container cleanup"
  [ "$RESOLVE_CLEANUP_REASON" = needs_containers ] || fail "wrong reason: $RESOLVE_CLEANUP_REASON"
  CLEANUP_CONTAINERS_MODE=auto
  resolve_cleanup_network auto || fail "network auto rejected despite container auto"
  [ "$CLEANUP_NETWORK_MODE" = auto ] || fail "network mode not recorded"
  LIFECYCLE_CONTAINERS_PRESENT=1 LIFECYCLE_CONTAINERS_SAFE=1
  LIFECYCLE_NETWORK_PRESENT=1 LIFECYCLE_NETWORK_MATCHES=1 LIFECYCLE_ATTACHMENTS=''
  resolve_cleanup_plan preserve preserve || fail "a fully-valid preserve plan was rejected"
  resolve_cleanup_plan bogus preserve && fail "an unknown cleanup mode was accepted"
  [ "$RESOLVE_CLEANUP_REASON" = invalid ] || fail "wrong reason for unknown mode: $RESOLVE_CLEANUP_REASON"
  exit 0
) || exit 1

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

# iface_is_ovs: detects an Open vSwitch parent (a heads-up; reachability is config-dependent).
iface_is_ovs ovs_eth0 || fail "ovs_eth0 not detected as Open vSwitch"
! iface_is_ovs eth0 || fail "eth0 wrongly detected as Open vSwitch"

# warn_if_ovs_parent: non-fatal heads-up on an OVS parent, silent on a plain NIC, and
# points at the troubleshooting guide rather than asserting a guaranteed failure.
_ovs_warn="$(warn_if_ovs_parent ovs_eth0 2>&1)"
printf '%s' "$_ovs_warn" | grep -q 'Open vSwitch' || fail "warn_if_ovs_parent did not warn on an OVS parent"
printf '%s' "$_ovs_warn" | grep -q 'troubleshooting' || fail "warn_if_ovs_parent did not point at troubleshooting"
[ -z "$(warn_if_ovs_parent eth0 2>&1)" ] || fail "warn_if_ovs_parent warned on a plain NIC"

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
# TUN is opt-in: the gateway probe only requires the in-container TUN when TUN_ENABLE=true.
TUN_ENABLE=true
FAKE_TUN=0
! mihomo_gateway_probe >/dev/null 2>&1 || fail "missing runtime TUN was accepted (TUN on)"
FAKE_TUN=1
mihomo_gateway_probe >/dev/null 2>&1 || fail "ready runtime TUN was rejected (TUN on)"
# Default (TUN off): the probe is a no-op even when no tun interface exists.
TUN_ENABLE=false
FAKE_TUN=0
mihomo_gateway_probe >/dev/null 2>&1 || fail "TUN-off gateway probe must pass without a tun interface"

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
