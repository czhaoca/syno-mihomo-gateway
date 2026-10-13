#!/bin/sh
# setup_network.sh - headless network self-heal for the mihomo gateway:
# ensure /dev/net/tun exists and (re)create the "tproxy_network" macvlan with an
# AUTO-detected parent interface. Idempotent; safe to run on every boot.
#
# Intended for a boot-time trigger as root (DSM Task Scheduler "Boot-up" on
# Synology; cron @reboot / a systemd unit on generic hosts) so the macvlan +
# TUN device survive a reboot. For first-time, INTERACTIVE setup
# (choosing/typing the interface, configuring .env, ACR login, deploy) run the
# guided installer instead:  sh ./install.sh (sh ./install-linux.sh generic)
#
# POSIX /bin/sh (DSM BusyBox). NO bashisms - the real logic lives in the shared,
# CI-shellchecked scripts/lib/network.sh. Needs root (mknod/chmod, docker network).
#
# Exit: 0 ok (incl. "stack not deployed here" skips) |
#       2 network ok but the deployed stack did not start, or is running
#         WITHOUT its TUN dataplane after one self-heal restart (DSM's
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

# 1. TUN device (mihomo needs it; baked into compose too, but self-heal here).
#    BEFORE the Docker wait, on purpose: the node needs nothing from Docker,
#    while dockerd's autostart (restart: always) races this task on every
#    boot. Waiting first meant the node appeared AFTER mihomo had already
#    started with an empty device bind - controller green, no TUN dataplane,
#    every LAN client silently off the gateway (the 2026-10-14 reboot
#    outage). This ordering prevents the race; step 4 repairs a lost one.
echo "[1/4] TUN device (/dev/net/tun)..."
ensure_tun_device || exit "$EXIT_CONFIG"

# DSM boot-up tasks can run before Container Manager is ready. Wait for both the
# Docker CLI/Compose plugin and daemon rather than racing network creation.
wait_for_docker_ready || exit "$EXIT_CONFIG"

# 2. Macvlan parent: prefer the interface the installer saved in .env
#    (PARENT_INTERFACE), else auto-detect the one that routes to ROUTER_IP.
echo "[2/4] Selecting LAN interface..."
PARENT_INTERFACE="${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}"
if [ -z "$PARENT_INTERFACE" ]; then
  log_error "could not auto-detect the LAN interface."
  log_error "Run the guided installer to pick/enter it:  sh ./${INSTALLER_ENTRY:-install.sh}"
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
  log_error "network settings are inconsistent; run sh ./${INSTALLER_ENTRY:-install.sh} and re-enter them"
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
    # Running is not routing: a mihomo that dockerd autostarted before step 1
    # created /dev/net/tun runs with an empty device bind and no TUN
    # dataplane. Verify, restart it once if that is the state, and alert
    # (rc 2 -> the DSM error mail) when the dataplane is still not ready.
    if mihomo_tun_self_heal; then
      echo "========================================"
      echo "Ready. The gateway stack is up."
      exit "$EXIT_OK"
    fi
    log_error "the gateway stack is running but its TUN dataplane is not ready - check: docker logs mihomo"
    exit "$EXIT_PARTIAL" ;;
  2)
    echo "      stack not deployed here (or deliberately stopped) - skipping."
    echo "========================================"
    echo "Ready. Start the stack with: docker compose up -d"
    exit "$EXIT_OK" ;;
  *)
    log_error "network is ready but the gateway stack did not start - check: docker logs mihomo"
    exit "$EXIT_PARTIAL" ;;
esac
