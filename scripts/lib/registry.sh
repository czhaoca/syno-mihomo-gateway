#!/bin/sh
# registry.sh - preflight (compose flavor, arch, network, TUN), ACR login,
# image pull + change detection. Requires common.sh sourced first.
# Sets globals: DOCKER_BIN, COMPOSE_CMD.

detect_compose() {
  DOCKER_BIN="$(command -v docker 2>/dev/null)"
  if [ -z "$DOCKER_BIN" ]; then
    for _c in /usr/local/bin/docker /usr/bin/docker; do
      [ -x "$_c" ] && DOCKER_BIN="$_c" && break
    done
  fi
  [ -n "$DOCKER_BIN" ] || { log_error "docker binary not found in PATH"; return 1; }

  if "$DOCKER_BIN" compose version >/dev/null 2>&1; then
    COMPOSE_CMD="$DOCKER_BIN compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="$(command -v docker-compose)"
  elif [ -x /usr/local/bin/docker-compose ]; then
    COMPOSE_CMD="/usr/local/bin/docker-compose"
  else
    log_error "neither 'docker compose' (v2) nor 'docker-compose' (v1) is available"
    return 1
  fi
  log_info "docker=$DOCKER_BIN  compose=[$COMPOSE_CMD]"
}

host_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    armv7l|armv7)   echo arm ;;
    *)              uname -m ;;
  esac
}

# Best-effort: warn if the operator's EXPECTED_ARCH doesn't match the NAS.
check_arch_expectation() {
  _h="$(host_arch)"
  if [ "$_h" != "$EXPECTED_ARCH" ]; then
    log_error "EXPECTED_ARCH=$EXPECTED_ARCH but this NAS is $_h"
    return 1
  fi
  return 0
}

check_network() {
  _net="${TPROXY_NETWORK:-tproxy_network}"
  if ! "$DOCKER_BIN" network inspect "$_net" >/dev/null 2>&1; then
    log_error "docker network '$_net' not found. Run scripts/setup_network.sh (or add a DSM boot-up task)."
    return 1
  fi
  # Verify the macvlan parent still matches the live interface (best-effort; needs `ip`).
  if command -v ip >/dev/null 2>&1 && [ -n "${ROUTER_IP:-}" ]; then
    _parent_cfg="$("$DOCKER_BIN" network inspect -f '{{index .Options "parent"}}' "$_net" 2>/dev/null)"
    _parent_live="$(ip route get "$ROUTER_IP" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -n1)"
    if [ -n "$_parent_cfg" ] && [ -n "$_parent_live" ] && [ "$_parent_cfg" != "$_parent_live" ]; then
      log_error "macvlan parent mismatch: network='$_parent_cfg' live='$_parent_live'. Re-run setup_network.sh."
      return 1
    fi
  fi
  _parent_expected="${PARENT_INTERFACE:-${_parent_live:-}}"
  if [ -n "$_parent_expected" ] && [ -n "${SUBNET_CIDR:-}" ] && [ -n "${ROUTER_IP:-}" ]; then
    if ! macvlan_matches "$_net" "$_parent_expected" "$SUBNET_CIDR" "$ROUTER_IP"; then
      log_error "macvlan configuration drift: expected parent=$_parent_expected subnet=$SUBNET_CIDR gateway=$ROUTER_IP"
      return 1
    fi
  fi
  log_info "network '$_net' OK"
}

check_tun() {
  if [ ! -c /dev/net/tun ]; then
    log_error "/dev/net/tun missing. Run scripts/setup_network.sh (mknod) - required by mihomo."
    return 1
  fi
  log_info "/dev/net/tun OK"
}

acr_login() {
  if [ -z "${DOCKER_REGISTRY:-}" ]; then
    log_info "DOCKER_REGISTRY unset - assuming public images, skipping login."
    return 0
  fi
  if [ -z "${DOCKER_USERNAME:-}" ] || [ -z "${ACR_PASSWORD:-}" ]; then
    log_error "DOCKER_USERNAME / ACR_PASSWORD required for non-interactive login to $DOCKER_REGISTRY"
    return 1
  fi
  if printf '%s' "$ACR_PASSWORD" | "$DOCKER_BIN" login "$DOCKER_REGISTRY" -u "$DOCKER_USERNAME" --password-stdin >>"$LOG_FILE" 2>&1; then
    log_info "ACR login OK ($DOCKER_REGISTRY)"
    return 0
  fi
  log_error "ACR login FAILED for $DOCKER_REGISTRY (check ACR_PASSWORD / token expiry)"
  return 1
}

# --- image helpers ---
local_image_id()   { "$DOCKER_BIN" image inspect --format '{{.Id}}' "$1" 2>/dev/null; }
running_image_id() { "$DOCKER_BIN" inspect --format '{{.Image}}' "$1" 2>/dev/null; }
image_arch()       { "$DOCKER_BIN" image inspect --format '{{.Architecture}}' "$1" 2>/dev/null; }

pull_image() {
  _img="$1"; _n=0
  while [ "$_n" -lt "$PULL_RETRIES" ]; do
    if "$DOCKER_BIN" pull "$_img" >>"$LOG_FILE" 2>&1; then
      return 0
    fi
    _n=$((_n+1))
    [ "$_n" -lt "$PULL_RETRIES" ] && { log_warn "pull failed ($_img) attempt $_n/$PULL_RETRIES - retrying in ${PULL_RETRY_DELAY}s"; sleep "$PULL_RETRY_DELAY"; }
  done
  log_error "pull failed after $PULL_RETRIES attempts: $_img"
  return 1
}

# arch_ok IMAGE -> 0 if image arch matches EXPECTED_ARCH (never swap an unrunnable image)
arch_ok() {
  _a="$(image_arch "$1")"
  _h="$(host_arch)"
  if [ -z "$_a" ]; then
    log_warn "could not determine arch of $1"
    return 1
  fi
  if [ "$_a" != "$_h" ]; then
    log_error "arch mismatch for $1: image=$_a host=$_h - refusing to deploy."
    return 1
  fi
  return 0
}

# deploy_needed IMAGE CONTAINER -> 0 if the running container's image differs from
# the local (freshly-pulled) tag, OR the container does not exist yet. Robust to
# --dry-run (compares running-vs-local, not before-vs-after-pull).
deploy_needed() {
  _img="$1"; _cont="$2"
  _run="$(running_image_id "$_cont")"
  _loc="$(local_image_id "$_img")"
  [ -z "$_loc" ] && { log_warn "local image missing after pull: $_img"; return 1; }
  [ -z "$_run" ] && return 0          # container not running yet -> needs deploy
  [ "$_run" != "$_loc" ] && return 0  # running an older image -> needs deploy
  return 1                            # already current
}
