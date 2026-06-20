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
# Exit: 0 ok | 3 config/preflight error.

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/lib/common.sh"
# shellcheck source=scripts/lib/network.sh
. "$SELF_DIR/lib/network.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SELF_DIR/lib/registry.sh"

load_env   # FATAL (exit 3) if .env is missing; exports ROUTER_IP, SUBNET_CIDR, ...

echo "========================================"
echo " Mihomo Gateway - network self-heal"
echo "========================================"

# DSM boot-up tasks can run before Container Manager is ready. Wait for both the
# Docker CLI/Compose plugin and daemon rather than racing network creation.
wait_for_docker_ready || exit "$EXIT_CONFIG"

# 1. TUN device (mihomo needs it; baked into compose too, but self-heal here).
echo "[1/3] TUN device (/dev/net/tun)..."
ensure_tun_device || exit "$EXIT_CONFIG"

# 2. Macvlan parent: prefer the interface the installer saved in .env
#    (PARENT_INTERFACE), else auto-detect the one that routes to ROUTER_IP.
echo "[2/3] Selecting LAN interface..."
PARENT_INTERFACE="${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}"
if [ -z "$PARENT_INTERFACE" ]; then
  log_error "could not auto-detect the LAN interface."
  log_error "Run the guided installer to pick/enter it:  sh ./install.sh"
  exit "$EXIT_CONFIG"
fi
echo "      Using interface: $PARENT_INTERFACE"

if ! validate_network_plan "$PARENT_INTERFACE" "${SUBNET_CIDR:-}" \
    "${ROUTER_IP:-}" "${MIHOMO_IP:-}"; then
  log_error "network settings are inconsistent; run sh ./install.sh and re-enter them"
  exit "$EXIT_CONFIG"
fi

# 3. (Re)create the macvlan network.
echo "[3/3] Creating macvlan '${TPROXY_NETWORK}' (${SUBNET_CIDR:-?})..."
if recreate_macvlan "$PARENT_INTERFACE"; then
  echo "========================================"
  echo "Ready. Start the stack with: docker compose up -d"
  exit "$EXIT_OK"
fi
exit "$EXIT_CONFIG"
