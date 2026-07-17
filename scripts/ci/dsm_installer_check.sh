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

# Existing .env files omit the v1.2.13 TUN knob; the shipped default (false -
# DSM-safe) must hold without an operator migration. Since the LOCK_DIR
# incident fix, optional-tunable defaults bind at SOURCE time in common.sh
# (not on every load_env call) - assert on a fresh source + load_env, the
# only shape a real process ever sees.
( unset TUN_AUTO_REDIRECT
  . "$ROOT/scripts/lib/common.sh"
  load_env
  [ "${TUN_AUTO_REDIRECT:-}" = false ] ) \
  || fail "missing TUN_AUTO_REDIRECT did not default to false"

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

  # foreign compose project: preserve would name-conflict inside compose up,
  # so it is rejected with its own reason; auto (replace) is the remedy and
  # stays accepted; a matching project or a label-less container passes.
  LIFECYCLE_COMPOSE_PROJECT=mihomo COMPOSE_PROJECT_NAME=syno-mihomo-gateway
  resolve_cleanup_containers preserve && fail "foreign-project containers accepted for preserve"
  [ "$RESOLVE_CLEANUP_REASON" = foreign_project ] \
    || fail "wrong reason for foreign-project preserve: $RESOLVE_CLEANUP_REASON"
  resolve_cleanup_containers auto || fail "foreign-project containers rejected for auto"
  LIFECYCLE_COMPOSE_PROJECT=syno-mihomo-gateway
  resolve_cleanup_containers preserve || fail "matching-project preserve rejected"
  LIFECYCLE_COMPOSE_PROJECT=''
  resolve_cleanup_containers preserve || fail "label-less preserve rejected"
  unset COMPOSE_PROJECT_NAME

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

# geodata pre-seed: cache detection, mirror fallback, size sanity - with the
# network fetch stubbed (the seam _geodata_fetch exists for exactly this).
(
  # shellcheck source=scripts/lib/geodata.sh
  . "$ROOT/scripts/lib/geodata.sh"
  _GD="$TD/geodata"; mkdir -p "$_GD"
  FETCH_LOG="$TD/geodata.fetch"; : >"$FETCH_LOG"
  GEODATA_MIN_BYTES=8

  # cache hit -> a no-op, no fetch attempted
  printf 'x' > "$_GD/GeoSite.dat"; printf 'x' > "$_GD/geoip.metadb"
  _geodata_fetch() { echo "$1" >>"$FETCH_LOG"; return 0; }
  geodata_preseed "$_GD" || fail "cached geodata treated as a miss"
  [ ! -s "$FETCH_LOG" ] || fail "cache hit still attempted a download"

  # full seed: the first mirror fails, the second delivers a size-sane payload
  rm -f "$_GD/GeoSite.dat" "$_GD/geoip.metadb"
  _geodata_fetch() {
    echo "$1" >>"$FETCH_LOG"
    case "$1" in *testingcf*) return 1 ;; esac
    printf 'PAYLOADPAYLOAD' > "$2"
  }
  geodata_preseed "$_GD" || fail "mirror-fallback seed failed"
  [ -s "$_GD/GeoSite.dat" ] || fail "GeoSite.dat was not seeded"
  [ -s "$_GD/geoip.metadb" ] || fail "geoip.metadb was not seeded"
  grep -q 'fastly' "$FETCH_LOG" || fail "the second mirror was never tried"

  # an undersized download (CDN error page) is rejected and leaves no partial file
  rm -f "$_GD/GeoSite.dat" "$_GD/geoip.metadb"
  _geodata_fetch() { printf 'x' > "$2"; }
  geodata_preseed "$_GD" && fail "undersized geodata was accepted"
  [ ! -f "$_GD/GeoSite.dat" ] || fail "undersized GeoSite.dat left in place"
  [ ! -f "$_GD/.geodata.tmp" ] || fail "temp download was not cleaned up"

  # alternate cached spellings (older cores) count as cached
  printf 'x' > "$_GD/geosite.dat"; printf 'x' > "$_GD/country.mmdb"
  geodata_cached "$_GD" || fail "alternate geodata spellings not honored"
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
wizard_express() { return 1; }
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

# --- closed-loop regressions --------------------------------------------------
# 1) teardown-then-fail: when pre-deployment cleanup already removed the old
#    stack (a cleanup mode was 'auto') and a LATER step fails, the operator must
#    be told the previous deployment is gone - and must NOT be told when nothing
#    was torn down.
. "$ROOT/scripts/installer/flow_deploy.sh"   # fresh copies of the flow functions
msg() { echo "$1"; }
msgf() { echo "$1"; }
ui_step() { :; }; ui_say() { :; }; ui_info() { :; }; ui_ok() { :; }
ui_warn() { printf '%s\n' "$*"; }
diagnose() { printf '%s\n' "$1"; }
is_root() { return 0; }
seed_config() { return 0; }
load_env() { return 0; }
pf_docker() { return 0; }; pf_arch() { return 0; }; pf_web_port() { return 0; }
wizard_express() { return 1; }
wizard_env() { return 0; }; wizard_images() { return 0; }; wizard_subscription() { return 0; }
validate_selected_network() { return 0; }
scan_and_prefill() { return 0; }
plan_predeployment_cleanup() { return 0; }
apply_predeployment_cleanup() { return 0; }
prepare_stack() { return 0; }
create_network() { return 1; }
deploy_stack() { return 0; }
report_success() { :; }

CLEANUP_CONTAINERS_MODE=preserve CLEANUP_NETWORK_MODE=auto
_out="$(flow_deploy 2>&1)" && fail "flow_deploy succeeded despite a network failure"
case "$_out" in
  *warn_prev_removed*) : ;;
  *) fail "teardown-then-fail did not warn that the previous deployment was removed" ;;
esac
CLEANUP_CONTAINERS_MODE=preserve CLEANUP_NETWORK_MODE=preserve
_out="$(flow_deploy 2>&1)" && fail "flow_deploy succeeded despite a network failure (preserve)"
case "$_out" in
  *warn_prev_removed*) fail "teardown notice printed although nothing was torn down" ;;
esac

# The redeploy flow shares the guard (the audit flagged it as inheriting the gap).
. "$ROOT/scripts/installer/flow_redeploy.sh"
precheck_deploy() { return 0; }
UI_MENU_SEQ="1"
ui_menu_select() {
  UI_MENU_INDEX="${UI_MENU_SEQ%% *}"
  case "$UI_MENU_SEQ" in *' '*) UI_MENU_SEQ="${UI_MENU_SEQ#* }" ;; *) UI_MENU_SEQ='' ;; esac
}
env_get() { echo ''; return 1; }
CLEANUP_CONTAINERS_MODE=auto CLEANUP_NETWORK_MODE=preserve
_out="$(flow_redeploy 2>&1)" && fail "flow_redeploy succeeded despite a network failure"
case "$_out" in
  *warn_prev_removed*) : ;;
  *) fail "redeploy teardown-then-fail did not warn about the removed deployment" ;;
esac

# 2) cron flow: choosing Done with updates enabled but NOTHING scheduled must
#    warn and offer to flip UPDATE_ENABLED=false - never report plain success.
. "$ROOT/scripts/lib/scheduler.sh"
. "$ROOT/scripts/lib/targets.sh"
. "$ROOT/scripts/installer/flow_targets.sh"
. "$ROOT/scripts/installer/flow_cron.sh"
ENV_FILE="$TD/cron.env"; : > "$ENV_FILE"
ui_error() { echo "ERROR: $*" >&2; }
. "$ROOT/scripts/installer/envedit.sh"
load_env() { return 0; }
ui_ask_validated() { eval "$1=02:30"; }
ui_ask() { eval "$1=UTC"; }
UI_MENU_SEQ="4 4"        # timezone: UTC, then how-to-schedule: Done
YESNO_SEQ="0 1 0"        # enable updates: yes, manage targets: no, disable-until-scheduled: yes
ui_yesno() {
  _yn="${YESNO_SEQ%% *}"
  case "$YESNO_SEQ" in *' '*) YESNO_SEQ="${YESNO_SEQ#* }" ;; *) YESNO_SEQ='' ;; esac
  return "$_yn"
}
_out="$(flow_cron 2>&1)" || fail "flow_cron returned non-zero"
case "$_out" in
  *warn_cron_none*) : ;;
  *) fail "cron Done with nothing scheduled did not warn" ;;
esac
case "$_out" in
  *ok_cron_complete*) fail "cron flow still reported unconditional success with nothing scheduled" ;;
esac
[ "$(dotenv_get UPDATE_ENABLED)" = false ] \
  || fail "declining an active schedule did not offer/flip UPDATE_ENABLED=false"

# 2a) octal regression: a daily time with 08/09 must round-trip exactly.
#     printf %d octal-parses "08"/"09" to 0 on POSIX shells, so 08:45 used to
#     persist as "45 0 * * *" (00:45) while confirming "08:45" to the operator.
ENV_FILE="$TD/cron-octal.env"; : > "$ENV_FILE"
ui_ask_validated() { eval "$1=08:45"; }
UI_MENU_SEQ="4 4"
YESNO_SEQ="0 1 0"
flow_cron >/dev/null 2>&1 || fail "flow_cron (octal regression) returned non-zero"
[ "$(dotenv_get UPDATE_SCHEDULE)" = '45 8 * * *' ] \
  || fail "08:45 corrupted to '$(dotenv_get UPDATE_SCHEDULE)' (octal printf regression)"

# 2b) targets flow: only standalone ACR containers are offerable; the trio is
#     never offered; compose-managed shows as excluded; decline removes.
TARGETS_FILE="$TD/update-targets"; rm -f "$TARGETS_FILE"
DOCKER_REGISTRY=acr.example ACR_NAMESPACE=myns
MIHOMO_CONTAINER=mihomo METACUBEXD_CONTAINER=mihomo-ui CF_CONTAINER_NAME=cloudflared
GATEWAY_DATA_DIR="$TD"
FT_DOCKER="$TD/ftdocker"
cat > "$FT_DOCKER" <<'FTEOF'
#!/bin/sh
case "$1" in
  info) exit 0 ;;
  ps) printf '%s\n' webctr composedctr hubapp mihomo dbctr; exit 0 ;;
  inspect)
    case "$*" in
      *"Config.Image"*hubapp) echo docker.io/library/nginx:latest ;;
      *"Config.Image"*dbctr) echo acr.example/myns/postgres:16 ;;
      *"Config.Image"*) echo acr.example/myns/web:latest ;;
      *"compose.service"*composedctr) echo 'web|smg' ;;
      *"compose.service"*) echo '|' ;;
    esac
    exit 0 ;;
esac
exit 0
FTEOF
chmod +x "$FT_DOCKER"
_net_docker() { echo "$FT_DOCKER"; }
ui_info() { printf '%s\n' "$*"; }
ui_ok() { printf '%s\n' "$*"; }
YESNO_SEQ="0 0 1"        # webctr: yes; dbctr: yes BUT decline the DB risk
_out="$(flow_targets 2>&1)" || fail "flow_targets returned non-zero"
grep -q '^webctr|recreate|' "$TARGETS_FILE" || fail "targets flow did not enroll webctr"
grep -q '^dbctr|' "$TARGETS_FILE" && fail "declining the DB risk still enrolled dbctr"
grep -q '^mihomo|' "$TARGETS_FILE" && fail "targets flow offered/enrolled a gateway container"
grep -q '^composedctr|' "$TARGETS_FILE" && fail "targets flow enrolled a compose-managed container"
case "$_out" in
  *warn_target_db*) : ;;
  *) fail "new database enrollment did not warn about the DEC-8 risk" ;;
esac
case "$_out" in
  *targets_excluded*) : ;;
  *) fail "compose-managed container was not shown as excluded" ;;
esac
case "$_out" in
  *hubapp*) fail "non-ACR container leaked into the targets flow" ;;
esac
YESNO_SEQ="1 0 0"        # webctr: decline -> removal; dbctr: yes + accept risk
_out="$(flow_targets 2>&1)" || fail "flow_targets re-run returned non-zero"
if grep -q '^webctr|' "$TARGETS_FILE"; then fail "declining did not remove webctr"; fi
grep -q '^dbctr|recreate|' "$TARGETS_FILE" || fail "accepting the DB risk did not enroll dbctr"
YESNO_SEQ="1 0"          # webctr: no; dbctr already enrolled: keep (Enter default)
_out="$(flow_targets 2>&1)" || fail "flow_targets third run returned non-zero"
case "$_out" in
  *warn_target_db*) fail "already-enrolled database was re-confirmed (defaults must be no-ops)" ;;
esac
grep -q '^dbctr|' "$TARGETS_FILE" || fail "keeping an enrolled database removed it"

# 3) modify flow: a failed apply must print a change-NOT-applied summary.
. "$ROOT/scripts/installer/flow_modify.sh"
stack_state() { echo deployed; }
apply_changes() { return 1; }
UI_MENU_SEQ="5 6"        # Apply (fails), then Back
_out="$(flow_modify 2>&1)" || fail "flow_modify should return 0 via Back"
case "$_out" in
  *warn_apply_failed*) : ;;
  *) fail "modify apply failure did not print the change-not-applied summary" ;;
esac

# 4) Ctrl-C notice: install.sh must trap INT/TERM with the partial-state notice.
#    (The 21-key both-catalogs spot-check that lived here was replaced by the
#    full-catalog i18n integrity sweeps below (#28) - count-based presence
#    could not even tell WHICH catalog a definition landed in; set equality
#    plus the used-key sweep can.)
grep -q '_on_int' "$ROOT/install.sh" || fail "install.sh lacks the INT/TERM notice handler"
grep -Eq 'trap +_on_int +INT +TERM' "$ROOT/install.sh" || fail "install.sh does not trap INT/TERM to _on_int"
for _f in flow_deploy.sh; do
  grep -n 'ui_warn "deployment failed\|ui_warn "previous images\|ui_error "automatic rollback' \
    "$ROOT/scripts/installer/$_f" >/dev/null \
    && fail "$_f still carries hardcoded-English rollback strings"
done

# --- express deploy + secret guard + verification table -------------------------
# All three run in an isolated subshell sourcing the real wizards + flow_deploy.
(
  set -eu
  fail() { echo "FAIL: $*" >&2; exit 1; }
  REPO_ROOT="$ROOT"   # wizard defaults resolve from .env.example (#27)
  ENV_FILE="$TD/express.env"; : > "$ENV_FILE"
  ui_error() { echo "ERROR: $*" >&2; }
  # shellcheck source=scripts/installer/envedit.sh
  . "$ROOT/scripts/installer/envedit.sh"
  # shellcheck source=scripts/lib/resolve.sh
  . "$ROOT/scripts/lib/resolve.sh"
  # shellcheck source=scripts/installer/wizards.sh
  . "$ROOT/scripts/installer/wizards.sh"
  msg() { echo "$1"; }
  msgf() { _mk="$1"; shift; echo "$_mk $*"; }
  ui_step() { :; }; ui_info() { :; }; ui_ok() { :; }
  ui_say() { printf '%s\n' "$*"; }
  ui_warn() { printf '%s\n' "$*"; }
  diagnose() { printf '%s\n' "$1"; }

  # express: everything detected/saved -> ONE confirmation, zero per-item prompts
  env_set ROUTER_IP 192.168.1.1
  env_set SUBNET_CIDR 192.168.1.0/24
  env_set MIHOMO_IP 192.168.1.100
  env_set CONTROLLER_SECRET presetsecret
  PARENT_INTERFACE=eth0 IFACE_MANUAL=0
  _iface_ipv4() { echo 192.168.1.10; }
  mihomo_owns_ip() { return 1; }
  ip_in_use() { return 1; }
  check_ip_conflict() { return 0; }
  ui_ask() { fail "express mode asked a per-item question ($2)"; }
  ui_ask_validated() { fail "express mode asked a per-item question ($2)"; }
  ui_ask_secret() { fail "express mode asked for a secret"; }
  ui_yesno() { return 0; }   # accept the express screen
  _out="$(wizard_express 2>&1)" || fail "wizard_express declined with complete detections"
  case "$_out" in
    *192.168.1.100*) : ;;
    *) fail "express screen does not show the resolved gateway IP: $_out" ;;
  esac
  [ "$(dotenv_get MIHOMO_IP)" = 192.168.1.100 ] || fail "express did not persist MIHOMO_IP"
  [ "$(dotenv_get WEB_UI_PORT)" = 8080 ] || fail "express did not persist the default web port"

  # declining the express screen falls back to the wizard chain (rc 1)
  ui_yesno() { return 1; }
  wizard_express >/dev/null 2>&1 && fail "declining express did not fall back"

  # incomplete detections (no subnet) -> express never offers
  ENV_FILE="$TD/express2.env"; : > "$ENV_FILE"
  env_set ROUTER_IP 192.168.1.1
  ui_yesno() { fail "express offered despite incomplete detections"; }
  wizard_express >/dev/null 2>&1 && fail "express accepted with no subnet"

  # secret guard: empty secret -> auto-generate (opt-out preserved)
  ENV_FILE="$TD/secret.env"; : > "$ENV_FILE"
  ui_yesno() { return 0; }   # yes, generate
  _secret_guard || fail "_secret_guard failed"
  _sg="$(dotenv_get CONTROLLER_SECRET)" || fail "no generated secret persisted"
  [ "${#_sg}" -ge 16 ] || fail "generated secret is too short: ${#_sg} chars"
  # a preset secret is never touched
  env_set CONTROLLER_SECRET keepme
  _secret_guard || fail "_secret_guard failed on a preset secret"
  [ "$(dotenv_get CONTROLLER_SECRET)" = keepme ] || fail "secret guard clobbered a preset secret"
  # explicit opt-out leaves it empty
  env_set CONTROLLER_SECRET ''
  ui_yesno() { return 1; }   # no, stay unauthenticated
  _out="$(_secret_guard 2>&1)" || fail "_secret_guard opt-out failed"
  [ -z "$(dotenv_get CONTROLLER_SECRET 2>/dev/null || echo '')" ] || fail "opt-out still generated a secret"
  case "$_out" in
    *warn_secret_none*) : ;;
    *) fail "opt-out did not warn about the unauthenticated dashboard" ;;
  esac

  # wizard_env secret idempotency: Enter keeps the saved secret; '-' clears it
  # (a re-run pressing Enter everywhere used to wipe and regenerate the secret,
  # silently disconnecting every configured dashboard).
  # shellcheck source=scripts/lib/network.sh
  . "$ROOT/scripts/lib/network.sh"   # real ipv4_in_cidr for the precheck test
  ENV_FILE="$TD/secret2.env"; : > "$ENV_FILE"
  env_set CONTROLLER_SECRET preexisting
  ui_ask_validated() {
    case "$1" in
      ROUTER_IP) eval "$1=192.168.1.1" ;;
      SUBNET_CIDR) eval "$1=192.168.1.0/24" ;;
      MIHOMO_IP) eval "$1=192.168.1.100" ;;
      WEB_UI_PORT) eval "$1=8080" ;;
      CONTROLLER_PORT) eval "$1=9090" ;;
      DNS_*) eval "$1=1.1.1.1" ;;
      *) eval "$1=x" ;;
    esac
  }
  ui_ask() { eval "$1=Asia/Shanghai"; }
  ui_ask_secret() { eval "$1=''"; }          # Enter -> empty answer
  pf_port_free() { return 0; }
  wizard_env >/dev/null 2>&1 || fail "wizard_env (keep-secret) failed"
  [ "$(dotenv_get CONTROLLER_SECRET)" = preexisting ] \
    || fail "Enter did not keep the saved controller secret"
  ui_ask_secret() { eval "$1='-'"; }         # explicit clear sentinel
  _out="$(wizard_env 2>&1)" || fail "wizard_env (clear-secret) failed"
  [ -z "$(dotenv_get CONTROLLER_SECRET 2>/dev/null || echo '')" ] \
    || fail "'-' did not clear the controller secret"
  case "$_out" in
    *warn_secret_none*) : ;;
    *) fail "explicit clear did not warn about the unauthenticated dashboard" ;;
  esac

  # precheck: a saved MIHOMO_IP outside the (re-picked) SUBNET_CIDR must be
  # re-asked here, not dead-end the flow in the later network validation.
  ENV_FILE="$TD/precheck.env"; : > "$ENV_FILE"
  env_set ROUTER_IP 10.0.0.1
  env_set SUBNET_CIDR 10.0.0.0/24
  env_set MIHOMO_IP 192.168.1.100
  env_set WEB_UI_PORT 8080; env_set CONTROLLER_PORT 9090
  env_set DNS_DEFAULT_NAMESERVER 1.1.1.1
  env_set DNS_NAMESERVER 1.1.1.1
  env_set MIHOMO_IMAGE img1; env_set METACUBEXD_IMAGE img2
  PC_ASKED=0
  ui_ask_validated() { PC_ASKED=1; eval "$1=10.0.0.100"; }
  precheck_env >/dev/null 2>&1 || fail "precheck_env (stale subnet) failed"
  [ "$PC_ASKED" = 1 ] || fail "stale-subnet MIHOMO_IP was not re-asked"
  [ "$(dotenv_get MIHOMO_IP)" = 10.0.0.100 ] \
    || fail "precheck did not persist the corrected MIHOMO_IP"

  # post-deploy verification table: rows reflect the stubbed probe results
  # shellcheck source=scripts/installer/flow_deploy.sh
  . "$ROOT/scripts/installer/flow_deploy.sh"
  ui_step() { :; }; ui_ok() { :; }
  ui_say() { printf '%s\n' "$*"; }
  DOCKER_BIN=true
  MIHOMO_CONTAINER=mihomo METACUBEXD_CONTAINER=mihomo-ui
  mihomo_controller_probe() { return 0; }
  mihomo_gateway_probe() { return 0; }
  TUN_ENABLE=true
  _ui_running() { echo true; }
  detect_parent_interface() { echo eth0; }
  _iface_ipv4() { echo 192.168.1.10; }
  CONTROLLER_SECRET=set WEB_UI_PORT=8080 MIHOMO_IP=192.168.1.100 CONTROLLER_PORT=9090
  _out="$(report_success 2>&1)"
  case "$_out" in
    *verify_title*) : ;;
    *) fail "report_success lacks the verification table" ;;
  esac
  case "$_out" in
    *verify_ok*) : ;;
    *) fail "verification table lacks passing rows: $_out" ;;
  esac
  mihomo_controller_probe() { return 1; }
  _out="$(report_success 2>&1)"
  case "$_out" in
    *verify_failed*) : ;;
    *) fail "verification table does not surface a failing controller probe" ;;
  esac
  exit 0
) || exit 1

# --- deploy-time country-group surfacing (#37, reworked for #45): the verify
# table carries a groups row (real chk_proxy_groups, reused never forked) and
# an empty Country Pick selection lands a correctly-attributed end-of-report
# diagnosis (names the COUNTRY_GROUPS knob, never the subscription) while the
# deploy still succeeds (DEC-A warn-and-continue). Sourcing flow_deploy
# WITHOUT checks.sh must keep report_success alive (guarded row -> skip).
(
  set -eu
  fail() { echo "FAIL: $*" >&2; exit 1; }
  REPO_ROOT="$ROOT"
  msg() { echo "$1"; }
  msgf() { _mk="$1"; shift; echo "$_mk $*"; }
  ui_step() { :; }; ui_info() { :; }; ui_ok() { :; }
  ui_say() { printf '%s\n' "$*"; }
  ui_warn() { printf '%s\n' "$*"; }
  ui_error() { printf '%s\n' "$*"; }
  diagnose() { printf 'DIAG %s | FIX %s\n' "$1" "${2:-}"; }
  # shellcheck source=scripts/installer/flow_deploy.sh
  . "$ROOT/scripts/installer/flow_deploy.sh"
  mihomo_controller_probe() { return 0; }
  mihomo_gateway_probe() { return 0; }
  _ui_running() { echo true; }
  detect_parent_interface() { echo eth0; }
  _iface_ipv4() { echo 192.168.1.10; }
  TUN_ENABLE=true CONTROLLER_SECRET='' WEB_UI_PORT=8080
  MIHOMO_IP=192.168.1.100 CONTROLLER_PORT=9090
  MIHOMO_CONTAINER=mihomo METACUBEXD_CONTAINER=mihomo-ui
  DOCKER_BIN=true

  # 0) checks.sh not sourced (standalone flow use): guarded row -> skip, alive
  _out="$(report_success 2>&1)" || fail "report_success died without checks.sh"
  case "$_out" in
    *'verify_skip verify_groups'*) : ;;
    *) fail "missing guarded skip row without checks.sh: $_out" ;;
  esac

  # The real check against a stub controller. Canned %XX answers copied from
  # gateway_cli_check.sh (All Nodes=%41%6c%6c%20%4e%6f%64%65%73,
  # Country Pick=%43%6f%75%6e%74%72%79%20%50%69%63%6b, JPX=%4a%50%58 -
  # spaces ride as %20). Country Pick's "now" is JPX, so default-empty =
  # JPX empty. DOCKER_BIN resolves to a shell function: only the URL
  # (always the last exec arg) matters.
  # shellcheck source=scripts/lib/checks.sh
  . "$ROOT/scripts/lib/checks.sh"
  fake_docker() {
    _fd_u=''; for _fd_a in "$@"; do _fd_u="$_fd_a"; done
    case "$_fd_u" in
      */group)
        printf '{"proxies":[{"name":"Proxy Mode","type":"Selector","all":["Country Pick","DIRECT","REJECT"]},{"name":"Streaming Sites","type":"Selector","all":["Proxy Mode","JPX","DIRECT"]},{"name":"Country Pick","type":"Selector","all":["JPX"]},{"name":"JPX","type":"URLTest","all":["n1"]},{"name":"All Nodes","type":"URLTest","hidden":true,"all":["n1","n2"]},{"name":"GLOBAL","type":"Selector","all":["All Nodes","Proxy Mode"]}]}' ;;
      */proxies/%43%6f%75%6e%74%72%79%20%50%69%63%6b*)
        printf '{"all":["JPX"],"now":"JPX"}' ;;
      */proxies/%4a%50%58*)
        if [ "${FAKE_PG_MODE:-healthy}" = default-empty ]; then
          printf '{"all":["REJECT"],"now":"REJECT"}'
        else
          printf '{"all":["n1"],"now":"n1"}'
        fi ;;
      */proxies/%41%6c%6c%20%4e%6f%64%65%73*) printf '{"all":["n1","n2"],"now":"n1"}' ;;
    esac
    return 0
  }
  DOCKER_BIN=fake_docker

  # 1) healthy: OK row, no filtered-group diagnosis
  FAKE_PG_MODE=healthy
  _out="$(report_success 2>&1)" || fail "healthy report_success failed"
  case "$_out" in
    *'verify_ok verify_groups'*) : ;;
    *) fail "healthy: missing groups OK row: $_out" ;;
  esac
  case "$_out" in
    *diag_pg_*) fail "healthy: unexpected filtered-group diagnosis: $_out" ;;
  esac

  # 2) empty Country Pick selection: FAILED row + end-of-report diagnosis
  #    attributing the COUNTRY_GROUPS knob (after rep_next, the operator's
  #    last screen); the report itself still succeeds (DEC-A
  #    warn-and-continue, deploy exit 0)
  FAKE_PG_MODE=default-empty
  _out="$(report_success 2>&1)" || fail "DEC-A violated: report_success failed on an empty Country Pick selection"
  case "$_out" in
    *'verify_failed verify_groups'*) : ;;
    *) fail "default-empty: missing FAILED groups row: $_out" ;;
  esac
  case "$_out" in
    *'DIAG diag_pg_default | FIX diag_pg_default_fix'*) : ;;
    *) fail "default-empty: missing correctly-attributed diagnosis: $_out" ;;
  esac
  case "$_out" in
    *rep_next*'DIAG diag_pg_default'*) : ;;
    *) fail "default-empty: diagnosis must land AFTER rep_next (end of report): $_out" ;;
  esac
  case "$_out" in
    *COUNTRY_GROUPS*) : ;;
    *) fail "default-empty: detail must name the COUNTRY_GROUPS knob: $_out" ;;
  esac
  exit 0
) || exit 1

# --- default-value parity: wizard defaults single-source from .env.example ------
# (#27) The pre-fills used to duplicate .env.example values as literals; the
# split-horizon release proved the drift mode (both DNS defaults changed in
# .env.example while the wizard literals kept the old values). Run wizard_env +
# precheck_env against an EMPTY .env with accept-the-default stubs and require
# every persisted default to equal the .env.example assignment, parsed by the
# same never-eval loader the installer uses.
(
  set -eu
  fail() { echo "FAIL: $*" >&2; exit 1; }
  REPO_ROOT="$ROOT"
  ENV_FILE="$TD/parity.env"; : > "$ENV_FILE"
  ui_error() { echo "ERROR: $*" >&2; }
  # shellcheck source=scripts/installer/envedit.sh
  . "$ROOT/scripts/installer/envedit.sh"
  # shellcheck source=scripts/lib/resolve.sh
  . "$ROOT/scripts/lib/resolve.sh"
  # shellcheck source=scripts/installer/wizards.sh
  . "$ROOT/scripts/installer/wizards.sh"
  # shellcheck source=scripts/lib/network.sh
  . "$ROOT/scripts/lib/network.sh"   # real is_ipv4/ipv4_in_cidr for the precheck run
  msg() { echo "$1"; }
  msgf() { _mk="$1"; shift; echo "$_mk $*"; }
  ui_step() { :; }; ui_info() { :; }; ui_ok() { :; }
  ui_say() { :; }; ui_warn() { :; }
  diagnose() { :; }
  # Reference values via the same never-eval loader, independent of the code
  # under test (subshell: a prefix assignment on a FUNCTION would persist).
  _example_ref() { ( ENV_FILE="$ROOT/.env.example"; dotenv_get "$1" ); }

  ui_ask_validated() { eval "$1=\"\$3\""; }   # Enter: accept the offered default
  ui_ask() { eval "$1=\"\$3\""; }
  ui_ask_secret() { eval "$1=''"; }
  ui_yesno() { return 1; }                    # decline secret generation
  pf_port_free() { return 0; }
  check_ip_conflict() { return 0; }
  mihomo_owns_ip() { return 1; }
  ip_in_use() { return 1; }
  IFACE_MANUAL=1                              # no scan: MIHOMO_IP falls to its default
  wizard_env >/dev/null 2>&1 || fail "wizard_env (parity run) failed"
  for _k in ROUTER_IP SUBNET_CIDR MIHOMO_IP WEB_UI_PORT CONTROLLER_PORT \
            DNS_DEFAULT_NAMESERVER DNS_NAMESERVER TZ; do
    _want="$(_example_ref "$_k")" || fail "$_k has no .env.example assignment"
    [ -n "$_want" ] || fail "$_k has an empty .env.example assignment"
    _got="$(dotenv_get "$_k" 2>/dev/null || echo '')"
    [ "$_got" = "$_want" ] \
      || fail "wizard_env default for $_k diverged from .env.example: got '$_got' want '$_want'"
  done

  # precheck: the re-ask defaults on an empty .env come from .env.example too
  ENV_FILE="$TD/parity2.env"; : > "$ENV_FILE"
  env_set MIHOMO_IMAGE img1; env_set METACUBEXD_IMAGE img2   # skip wizard_images
  precheck_env >/dev/null 2>&1 || fail "precheck_env (parity run) failed"
  for _k in ROUTER_IP SUBNET_CIDR MIHOMO_IP WEB_UI_PORT CONTROLLER_PORT \
            DNS_DEFAULT_NAMESERVER DNS_NAMESERVER; do
    _want="$(_example_ref "$_k")"
    _got="$(dotenv_get "$_k" 2>/dev/null || echo '')"
    [ "$_got" = "$_want" ] \
      || fail "precheck_env default for $_k diverged from .env.example: got '$_got' want '$_want'"
  done
  exit 0
) || exit 1

# Default literals belong in .env.example ONLY (#27): a reintroduced copy is
# exactly the drift CI could not see until it bit an operator.
grep -n '223\.5\.5\.5\|119\.29\.29\.29\|1\.1\.1\.1\|8\.8\.8\.8\|8080\|9090\|192\.168\.\|Asia/Shanghai' \
  "$ROOT/scripts/installer/wizards.sh" \
  && fail "wizards.sh carries default literals (single-source them in .env.example)"

# --- i18n integrity: full-catalog parity + used-key sweep (#28) -----------------
# Replaces BOTH hardcoded spot-check key lists (the 21-key both-catalogs count
# loop and the 44-key functional render loop): a `msg new_key` call site
# missing from the catalog prints the bare key in production while CI stays
# green. Three static sweeps, BusyBox-portable (sed/grep/sort/uniq only; set
# difference A-B spelled `A B B | sort | uniq -u`):
#   1. en/zh key-set equality over the full main catalog;
#   2. every literal `msg KEY`/`msgf KEY` call site in install.sh +
#      install-pi.sh + scripts/installer/*.sh + scripts/pi/*.sh resolves in
#      the main catalog or the Pi overlay (scripts/lib/*.sh is msg-free by
#      design - see the resolve.sh UI-free check above);
#   3. dead keys (catalog arms with zero swept call sites) are REPORTED as a
#      warning, not failed (#28 DEC-A: warn-only until the orphan list is
#      zeroed, then promote to fail).
# Comment lines are stripped before extraction; keys referenced only through a
# variable (e.g. _pc_need's prompt-key parameter) are invisible to the sweep,
# which is safe: they can only under-count "used", never hide a bogus literal.
_i18n_en="$(sed -n '/^_msg_en()/,/^}/p' "$ROOT/scripts/installer/i18n.sh" \
  | sed -n 's/^    \([a-z0-9_][a-z0-9_]*\)).*/\1/p' | sort -u)"
_i18n_zh="$(sed -n '/^_msg_zh()/,/^}/p' "$ROOT/scripts/installer/i18n.sh" \
  | sed -n 's/^    \([a-z0-9_][a-z0-9_]*\)).*/\1/p' | sort -u)"
[ -n "$_i18n_en" ] || fail "i18n sweep extracted zero en keys (catalog shape changed?)"
[ -n "$_i18n_zh" ] || fail "i18n sweep extracted zero zh keys (catalog shape changed?)"
if [ "$_i18n_en" != "$_i18n_zh" ]; then
  echo "en/zh symmetric difference:" >&2
  printf '%s\n%s\n' "$_i18n_en" "$_i18n_zh" | sort | uniq -u >&2
  fail "i18n en/zh key sets differ"
fi
_i18n_pi="$(sed -n '/^_msg_en_pi()/,/^}/p' "$ROOT/scripts/pi/i18n_pi.sh" \
  | sed -n 's/^    \([a-z0-9_][a-z0-9_]*\)).*/\1/p' | sort -u)"
[ -n "$_i18n_pi" ] || fail "i18n sweep extracted zero Pi overlay keys (overlay shape changed?)"
_i18n_used="$(cat "$ROOT/install.sh" "$ROOT/install-pi.sh" "$ROOT"/scripts/installer/*.sh "$ROOT"/scripts/pi/*.sh \
  | grep -v '^[[:space:]]*#' \
  | grep -o 'msgf\{0,1\} [a-z0-9_][a-z0-9_]*' \
  | sed 's/^msgf\{0,1\} //' | sort -u)"
[ -n "$_i18n_used" ] || fail "i18n sweep extracted zero call sites (call-site shape changed?)"
_i18n_all="$(printf '%s\n%s\n' "$_i18n_en" "$_i18n_pi" | sort -u)"
_i18n_unres="$(printf '%s\n%s\n%s\n' "$_i18n_used" "$_i18n_all" "$_i18n_all" | sort | uniq -u)"
if [ -n "$_i18n_unres" ]; then
  echo "unresolvable msg/msgf keys (no catalog or overlay entry):" >&2
  printf '%s\n' "$_i18n_unres" >&2
  fail "msg/msgf call sites reference keys missing from catalog+overlay"
fi
_i18n_dead="$(printf '%s\n%s\n%s\n' "$_i18n_en" "$_i18n_used" "$_i18n_used" | sort | uniq -u)"
if [ -n "$_i18n_dead" ]; then
  echo "WARN: $(printf '%s\n' "$_i18n_dead" | grep -c .) dead main-catalog keys (defined, zero swept call sites):" >&2
  printf '  %s\n' $_i18n_dead >&2
fi

# --- state banner + Status/Diagnose menu item -----------------------------------
# install.sh is sourceable (INSTALL_SOURCE_ONLY=1 + SMG_INSTALL_ROOT) so the
# banner, the adaptive deploy label, and the status flow are testable. This
# re-sources the REAL module set, so it must stay the LAST section.
(
  set -eu
  fail() { echo "FAIL: $*" >&2; exit 1; }
  INSTALL_SOURCE_ONLY=1
  SMG_INSTALL_ROOT="$ROOT"
  INSTALLER_LANG=en
  export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT INSTALLER_LANG
  # shellcheck source=install.sh
  . "$ROOT/install.sh"

  ENV_FILE="$TD/absent.env"    # no .env -> banner must not try to load one
  # deployed: banner shows the gateway IP and the dashboard URL
  stack_state() { echo deployed; }
  _iface_ipv4() { echo 192.168.1.10; }
  detect_parent_interface() { echo eth0; }
  MIHOMO_IP=192.168.1.100 WEB_UI_PORT=8080 PARENT_INTERFACE=eth0
  _out="$(_mm_banner 2>&1)"
  case "$_out" in
    *192.168.1.100*) : ;;
    *) fail "deployed banner lacks the gateway IP: $_out" ;;
  esac
  case "$_out" in
    *192.168.1.10:8080*) : ;;
    *) fail "deployed banner lacks the dashboard URL: $_out" ;;
  esac
  # fresh: banner says not deployed
  stack_state() { echo fresh; }
  case "$(_mm_banner 2>&1)" in
    *'not deployed'*) : ;;
    *) fail "fresh banner does not say 'not deployed'" ;;
  esac
  # partial: banner flags the partial state
  stack_state() { echo partial; }
  case "$(_mm_banner 2>&1)" in
    *PARTIAL*|*partial*) : ;;
    *) fail "partial banner does not flag the partial state" ;;
  esac

  # adaptive deploy label: with a saved .env the first menu item hints at reuse
  _lbl="$(_mm_deploy_label)"
  case "$_lbl" in *saved*) fail "deploy label hints at saved settings without a .env" ;; esac
  ENV_FILE="$TD/present.env"; : > "$ENV_FILE"
  _lbl="$(_mm_deploy_label)"
  case "$_lbl" in
    *saved*) : ;;
    *) fail "deploy label does not adapt when a saved .env exists: $_lbl" ;;
  esac

  # status flow: reports state + dashboard and offers doctor (declined here)
  stack_state() { echo deployed; }
  lifecycle_inspect() {
    LIFECYCLE_MIHOMO_STATUS=managed
    LIFECYCLE_UI_STATUS=managed
  }
  ui_yesno() { return 1; }
  _out="$(menu_status_flow 2>&1)" || fail "menu_status_flow returned non-zero"
  case "$_out" in
    *deployed*) : ;;
    *) fail "status flow does not report the stack state: $_out" ;;
  esac
  case "$_out" in
    *192.168.1.10:8080*) : ;;
    *) fail "status flow does not report the dashboard URL" ;;
  esac
  # doctor accepted -> the doctor script actually runs
  ui_yesno() { return 0; }
  DOCTOR_RAN="$TD/doctor.ran"
  rm -f "$DOCTOR_RAN"
  _run_doctor() { : > "$DOCTOR_RAN"; }
  menu_status_flow >/dev/null 2>&1 || fail "menu_status_flow failed with doctor accepted"
  [ -e "$DOCTOR_RAN" ] || fail "accepting the doctor offer did not run diagnostics"

  # the main menu carries the Status item and routes it (static assertions)
  grep -q 'menu_status' "$ROOT/install.sh" || fail "main menu lacks the Status/Diagnose item"

  # (The old hardcoded bilingual spot-check key list lived here; #28 replaced
  # it with the full-catalog i18n integrity sweeps in the top-level section
  # above - set equality catches a key landing in only one catalog.)
  exit 0
) || exit 1

echo "OK: BusyBox dotenv/network/arch/TUN/cloudflared/report checks, decision-first fail-before-mutation deployment order, closed-loop regressions (teardown notice, cron false-success, modify apply summary, INT trap), default-value parity, i18n catalog parity + used-key sweep, and the state banner + Status menu"
