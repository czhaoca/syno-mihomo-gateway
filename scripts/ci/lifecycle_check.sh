#!/bin/sh
# Regression tests for deployment inventory and scoped teardown.
# shellcheck disable=SC2016
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/smg-lifecycle-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
# shellcheck source=scripts/ci/lib/assert.sh
. "$ROOT/scripts/ci/lib/assert.sh"

# shellcheck source=scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/network.sh
. "$ROOT/scripts/lib/network.sh"
# shellcheck source=scripts/lib/compose.sh
. "$ROOT/scripts/lib/compose.sh"
# shellcheck source=scripts/lib/lifecycle.sh
. "$ROOT/scripts/lib/lifecycle.sh"

CALLS="$TMP/docker.calls"
export CALLS
MOCK="$TMP/docker"
cat >"$MOCK" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2" in
  'inspect mihomo') [ "${FAKE_MIHOMO:-0}" = 1 ] ;;
  'inspect mihomo-ui') [ "${FAKE_UI:-0}" = 1 ] ;;
  'network inspect')
    case "$*" in
      *"{{.Driver}}"*) printf '%s\n' "${FAKE_NET_SPEC:-macvlan|eth0|192.168.1.0/24|192.168.1.1}" ;;
      *'.Containers'*) printf '%s\n' "${FAKE_ATTACHMENTS:-}" ;;
      *) [ "${FAKE_NETWORK:-0}" = 1 ] ;;
    esac ;;
  'rm -f') exit "${FAKE_RM_RC:-0}" ;;
  'network rm') exit "${FAKE_NET_RM_RC:-0}" ;;
  *)
    case "$*" in
      *'com.docker.compose.project'*mihomo-ui*) printf '%s\n' "${FAKE_UI_PROJECT:-syno-mihomo-gateway}" ;;
      *'com.docker.compose.project'*mihomo*) printf '%s\n' "${FAKE_MIHOMO_PROJECT:-syno-mihomo-gateway}" ;;
      *'com.docker.compose.service'*mihomo-ui*) printf '%s\n' "${FAKE_UI_SERVICE:-metacubexd}" ;;
      *'com.docker.compose.service'*mihomo*) printf '%s\n' "${FAKE_MIHOMO_SERVICE:-mihomo}" ;;
    esac ;;
esac
EOF
chmod +x "$MOCK"
DOCKER_BIN="$MOCK"
LOG_FILE="$TMP/lifecycle.log"
MIHOMO_CONTAINER=mihomo
METACUBEXD_CONTAINER=mihomo-ui
TPROXY_NETWORK=tproxy_network
PARENT_INTERFACE=eth0
SUBNET_CIDR=192.168.1.0/24
ROUTER_IP=192.168.1.1

FAKE_MIHOMO=0 FAKE_UI=0 FAKE_NETWORK=0 FAKE_ATTACHMENTS=
export FAKE_MIHOMO FAKE_UI FAKE_NETWORK FAKE_ATTACHMENTS
lifecycle_inspect
[ "$LIFECYCLE_CONTAINERS_PRESENT:$LIFECYCLE_NETWORK_PRESENT" = 0:0 ] && ok || fail "fresh inventory"

FAKE_MIHOMO=1 FAKE_UI=1 FAKE_NETWORK=1 FAKE_ATTACHMENTS='mihomo mihomo-ui'
FAKE_MIHOMO_SERVICE=mihomo FAKE_UI_SERVICE=metacubexd
FAKE_MIHOMO_PROJECT=syno-mihomo-gateway FAKE_UI_PROJECT=syno-mihomo-gateway
export FAKE_MIHOMO FAKE_UI FAKE_NETWORK FAKE_ATTACHMENTS FAKE_MIHOMO_SERVICE FAKE_UI_SERVICE
export FAKE_MIHOMO_PROJECT FAKE_UI_PROJECT
lifecycle_inspect
[ "$LIFECYCLE_CONTAINERS_SAFE:$LIFECYCLE_NETWORK_SAFE:$LIFECYCLE_NETWORK_MATCHES" = 1:1:1 ] \
  && ok || fail "managed deployment inventory"

# Driver-aware match: an ipvlan network matches only when TPROXY_DRIVER=ipvlan, and a
# macvlan<->ipvlan driver change counts as drift so the network is cleanly recreated.
TPROXY_DRIVER=ipvlan FAKE_NET_SPEC='ipvlan|eth0|192.168.1.0/24|192.168.1.1'
export FAKE_NET_SPEC
lifecycle_inspect
[ "$LIFECYCLE_NETWORK_MATCHES" = 1 ] && ok || fail "ipvlan network not matched under TPROXY_DRIVER=ipvlan"
TPROXY_DRIVER=ipvlan FAKE_NET_SPEC='macvlan|eth0|192.168.1.0/24|192.168.1.1'
export FAKE_NET_SPEC
lifecycle_inspect
[ "$LIFECYCLE_NETWORK_MATCHES" = 0 ] && ok || fail "macvlan/ipvlan driver mismatch wrongly matched"
unset TPROXY_DRIVER
FAKE_NET_SPEC='macvlan|eth0|192.168.1.0/24|192.168.1.1'; export FAKE_NET_SPEC

FAKE_MIHOMO_SERVICE=other; export FAKE_MIHOMO_SERVICE
lifecycle_inspect
[ "$LIFECYCLE_CONTAINERS_SAFE" = 0 ] && ok || fail "ambiguous container classification"
expect_failure "ambiguous container blocks automatic cleanup" lifecycle_remove_containers

FAKE_MIHOMO_SERVICE=mihomo FAKE_UI_PROJECT=other-project
export FAKE_MIHOMO_SERVICE FAKE_UI_PROJECT
lifecycle_inspect
[ "$LIFECYCLE_CONTAINERS_SAFE" = 0 ] && ok || fail "mismatched Compose projects are ambiguous"
FAKE_UI_PROJECT=syno-mihomo-gateway; export FAKE_UI_PROJECT

FAKE_MIHOMO_SERVICE=mihomo FAKE_ATTACHMENTS='mihomo unrelated'; export FAKE_MIHOMO_SERVICE FAKE_ATTACHMENTS
lifecycle_inspect
[ "$LIFECYCLE_NETWORK_SAFE" = 0 ] && ok || fail "unrelated network attachment classification"
expect_failure "unrelated attachment blocks network cleanup" lifecycle_remove_network

FAKE_ATTACHMENTS=; export FAKE_ATTACHMENTS
: >"$CALLS"
expect_success "verified containers can be removed" lifecycle_remove_containers
REMOVALS="$(cat "$CALLS")"
case "$REMOVALS" in *'rm -f mihomo'*'rm -f mihomo-ui'*) ok ;; *) fail "scoped container removal commands" ;; esac
case "$REMOVALS" in *'down --remove-orphans'*) fail "automatic cleanup used project-wide orphan removal" ;; *) ok ;; esac
expect_success "empty verified macvlan can be removed" lifecycle_remove_network

if [ "$FAIL" -ne 0 ]; then
  printf 'FAILED: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'OK: %s lifecycle inventory/cleanup assertions passed\n' "$PASS"
