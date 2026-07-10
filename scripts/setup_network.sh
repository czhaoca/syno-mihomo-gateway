#!/bin/sh
# setup_network.sh - headless network self-heal for the mihomo gateway:
# ensure /dev/net/tun exists and (re)create the "tproxy_network" macvlan with an
# AUTO-detected parent interface. Idempotent; safe to run on every boot.
#
# Intended for the DSM Task Scheduler "Boot-up" trigger (User = root) so the
# macvlan + TUN device survive a reboot. For first-time, INTERACTIVE setup
# (choosing/typing the interface, configuring .env, ACR login, deploy) run the
# guided installer instead:  sh ./install.sh
#
# POSIX /bin/sh (DSM BusyBox). NO bashisms - the real logic lives in the shared,
# CI-shellchecked scripts/lib/network.sh. Needs root (mknod/chmod, docker network).
#
# Exit: 0 ok (incl. "stack not deployed here" skips) |
#       2 network ok but the deployed stack did not start (DSM's
#         send-run-details-on-error mail fires - that is the point) |
#       3 config/preflight error.

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/lib/common.sh"
# shellcheck source=scripts/lib/network.sh
. "$SELF_DIR/lib/network.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SELF_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/compose.sh
. "$SELF_DIR/lib/compose.sh"

ensure_persistent_state || {
  echo "FATAL: cannot create persistent data directory: $GATEWAY_DATA_DIR" >&2
  exit "$EXIT_CONFIG"
}
load_env   # FATAL (exit 3) if .env is missing; exports ROUTER_IP, SUBNET_CIDR, ...

echo "========================================"
echo " Mihomo Gateway - network self-heal"
echo "========================================"

# DSM boot-up tasks can run before Container Manager is ready. Wait for both the
# Docker CLI/Compose plugin and daemon rather than racing network creation.
wait_for_docker_ready || exit "$EXIT_CONFIG"

# 1. TUN device (mihomo needs it; baked into compose too, but self-heal here).
echo "[1/4] TUN device (/dev/net/tun)..."
ensure_tun_device || exit "$EXIT_CONFIG"

# 2. Macvlan parent: prefer the interface the installer saved in .env
#    (PARENT_INTERFACE), else auto-detect the one that routes to ROUTER_IP.
echo "[2/4] Selecting LAN interface..."
PARENT_INTERFACE="${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}"
if [ -z "$PARENT_INTERFACE" ]; then
  log_error "could not auto-detect the LAN interface."
  log_error "Run the guided installer to pick/enter it:  sh ./install.sh"
  exit "$EXIT_CONFIG"
fi
echo "      Using interface: $PARENT_INTERFACE"

# Flag an Open vSwitch parent here too (not only on the interactive first-deploy
# path). A macvlan child IS LAN-reachable on a typical OVS parent (verified
# empirically), but SOME OVS configurations do not flood the child's fresh MAC to
# peer ports - so this stays a non-fatal heads-up: the operator may also have
# deliberately accepted ipvlan (dashboard-only).
warn_if_ovs_parent "$PARENT_INTERFACE"

if ! validate_network_plan "$PARENT_INTERFACE" "${SUBNET_CIDR:-}" \
    "${ROUTER_IP:-}" "${MIHOMO_IP:-}"; then
  log_error "network settings are inconsistent; run sh ./install.sh and re-enter them"
  exit "$EXIT_CONFIG"
fi

# 3. (Re)create the macvlan network.
echo "[3/4] Creating macvlan '${TPROXY_NETWORK}' (${SUBNET_CIDR:-?})..."
recreate_macvlan "$PARENT_INTERFACE" || exit "$EXIT_CONFIG"

# 4. Ensure the deployed stack is actually up. `restart: always` normally
#    covers a reboot, but the observed failure mode is a container that stayed
#    down because the macvlan was not usable when dockerd started. A stack
#    that was never deployed here, or was deliberately taken down, is skipped
#    - the boot task never resurrects an operator's `compose down`.
echo "[4/4] Ensuring the gateway stack is up..."
compose_ensure_up
case "$?" in
  0)
    echo "========================================"
    echo "Ready. The gateway stack is up."
    exit "$EXIT_OK" ;;
  2)
    echo "      stack not deployed here (or deliberately stopped) - skipping."
    echo "========================================"
    echo "Ready. Start the stack with: docker compose up -d"
    exit "$EXIT_OK" ;;
  *)
    log_error "network is ready but the gateway stack did not start - check: docker logs mihomo"
    exit "$EXIT_PARTIAL" ;;
esac
