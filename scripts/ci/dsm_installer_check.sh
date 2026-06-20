#!/bin/sh
# Execute installer primitives under BusyBox ash, matching DSM's shell closely.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/scripts/lib/common.sh"
. "$ROOT/scripts/lib/network.sh"
. "$ROOT/scripts/lib/registry.sh"
. "$ROOT/scripts/lib/compose.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ui_error() { echo "ERROR: $*" >&2; }
. "$ROOT/scripts/installer/envedit.sh"

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

ipv4_in_cidr 192.168.1.100 192.168.1.0/24 || fail "valid subnet member rejected"
! ipv4_in_cidr 192.168.2.100 192.168.1.0/24 || fail "outside IP accepted"
ipv4_is_edge_of_cidr 192.168.1.0 192.168.1.0/24 || fail "network edge not detected"
ipv4_is_edge_of_cidr 192.168.1.255 192.168.1.0/24 || fail "broadcast edge not detected"
! ipv4_is_edge_of_cidr 192.168.1.100 192.168.1.0/24 || fail "host IP treated as edge"
cidr_is_canonical 192.168.1.0/24 || fail "canonical subnet rejected"
! cidr_is_canonical 192.168.1.10/24 || fail "host address accepted as subnet"

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

# Deployment sequencing regression: no network/container mutation may occur
# before non-destructive image/config preparation succeeds.
. "$ROOT/scripts/installer/flow_deploy.sh"
msg() { echo "$1"; }
ui_step() { :; }
is_root() { return 0; }
seed_config() { return 0; }
load_env() { return 0; }
scan_and_prefill() { return 0; }
wizard_env() { return 0; }
wizard_images() { return 0; }
wizard_subscription() { return 0; }
pf_docker() { return 0; }
pf_arch() { return 0; }
pf_web_port() { return 0; }
validate_selected_network() { return 0; }
plan_predeployment_cleanup() { return 0; }
apply_predeployment_cleanup() { echo cleanup >> "$TD/order"; }
create_network() { echo network >> "$TD/order"; }
deploy_stack() { echo deploy >> "$TD/order"; }
report_success() { :; }
prepare_stack() { return 1; }
: > "$TD/order"
flow_deploy >/dev/null 2>&1 && fail "deploy continued after preparation failure"
[ ! -s "$TD/order" ] || fail "deploy mutated state before preparation succeeded"
prepare_stack() { echo prepare >> "$TD/order"; }
flow_deploy >/dev/null 2>&1 || fail "stubbed deployment sequence failed"
[ "$(tr '\n' ' ' < "$TD/order")" = 'prepare cleanup network deploy ' ] \
  || fail "unsafe deployment order: $(tr '\n' ' ' < "$TD/order")"

echo "OK: BusyBox dotenv/network/arch/TUN checks and fail-before-mutation deployment order"
