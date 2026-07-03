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
  # Explicit success: log() pipes through tee, so an unwritable log file must
  # not turn this healthy predicate into a bogus "Docker not ready" abort.
  return 0
}

docker_daemon_ready() {
  if "$DOCKER_BIN" info >/dev/null 2>&1; then
    return 0
  fi
  log_error "Docker daemon is unavailable; start Container Manager and run this task as root"
  return 1
}

wait_for_docker_ready() {
  _wr_timeout="${1:-${DOCKER_READY_TIMEOUT:-120}}"
  _wr_interval="${2:-${DOCKER_READY_INTERVAL:-5}}"
  case "$_wr_timeout:$_wr_interval" in
    *[!0-9:]*|:*) log_error "invalid Docker readiness timeout/interval"; return 1 ;;
  esac
  _wr_elapsed=0
  while :; do
    if detect_compose && docker_daemon_ready; then
      return 0
    fi
    [ "$_wr_elapsed" -ge "$_wr_timeout" ] && break
    log_warn "waiting for Container Manager/Docker (${_wr_elapsed}s/${_wr_timeout}s)"
    sleep "$_wr_interval"
    _wr_elapsed=$((_wr_elapsed + _wr_interval))
  done
  log_error "Docker did not become ready within ${_wr_timeout}s"
  return 1
}

_config_uint() {
  _cu_name="$1"; _cu_value="$2"; _cu_min="$3"
  case "$_cu_value" in ''|*[!0-9]*)
    log_error "$_cu_name must be an integer (got '$_cu_value')"; return 1 ;;
  esac
  if [ "$_cu_value" -lt "$_cu_min" ]; then
    log_error "$_cu_name must be >= $_cu_min (got $_cu_value)"
    return 1
  fi
  return 0
}

_update_list_has() {
  _ul_want="$1"
  for _ul_image in ${UPDATE_IMAGES:-}; do
    [ "$_ul_image" = "$_ul_want" ] && return 0
  done
  return 1
}

validate_update_switch() {
  case "${UPDATE_ENABLED:-}" in true|false) : ;; *)
    log_error "UPDATE_ENABLED must be true or false"; return 1 ;;
  esac
  return 0
}

validate_update_config() {
  validate_update_switch || return 1
  case "${TUN_AUTO_REDIRECT:-}" in true|false) : ;; *)
    log_error "TUN_AUTO_REDIRECT must be true or false"; return 1 ;;
  esac
  _config_uint PULL_RETRIES "${PULL_RETRIES:-}" 1 || return 1
  _config_uint PULL_RETRY_DELAY "${PULL_RETRY_DELAY:-}" 0 || return 1
  _config_uint DOCKER_READY_TIMEOUT "${DOCKER_READY_TIMEOUT:-}" 0 || return 1
  _config_uint DOCKER_READY_INTERVAL "${DOCKER_READY_INTERVAL:-}" 1 || return 1
  _config_uint HEALTH_RETRIES "${HEALTH_RETRIES:-}" 1 || return 1
  _config_uint HEALTH_INTERVAL "${HEALTH_INTERVAL:-}" 0 || return 1
  _config_uint HEALTH_MAX_RESTARTS "${HEALTH_MAX_RESTARTS:-}" 1 || return 1
  _config_uint CF_HEALTH_TIMEOUT "${CF_HEALTH_TIMEOUT:-}" 1 || return 1
  _config_uint LOG_KEEP "${LOG_KEEP:-}" 1 || return 1
  _config_uint LOG_MAX_BYTES "${LOG_MAX_BYTES:-}" 1 || return 1

  [ -n "${MIHOMO_IMAGE:-}" ] || { log_error "MIHOMO_IMAGE is empty"; return 1; }
  [ -n "${METACUBEXD_IMAGE:-}" ] || { log_error "METACUBEXD_IMAGE is empty"; return 1; }
  [ -n "${UPDATE_IMAGES:-}" ] || { log_error "UPDATE_IMAGES is empty"; return 1; }
  case "$UPDATE_IMAGES" in
    *'*'*|*'?'*|*'['*|*']'*)
      log_error "UPDATE_IMAGES contains shell wildcard characters"; return 1 ;;
  esac
  for _vc_image in $UPDATE_IMAGES; do
    case "$_vc_image" in
      -*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'"'*|*"'"*)
        log_error "unsafe image reference in UPDATE_IMAGES: $_vc_image"; return 1 ;;
    esac
  done
  _update_list_has "$MIHOMO_IMAGE" || {
    log_error "UPDATE_IMAGES does not include MIHOMO_IMAGE exactly"; return 1;
  }
  _update_list_has "$METACUBEXD_IMAGE" || {
    log_error "UPDATE_IMAGES does not include METACUBEXD_IMAGE exactly"; return 1;
  }
  if [ -n "${CF_IMAGE:-}" ]; then
    _update_list_has "$CF_IMAGE" || {
      log_error "CF_IMAGE is configured but UPDATE_IMAGES does not include it exactly"; return 1;
    }
  fi
  return 0
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
  return 0
}

check_tun() {
  if [ ! -c /dev/net/tun ]; then
    log_error "/dev/net/tun missing. Run scripts/setup_network.sh (mknod) - required by mihomo."
    return 1
  fi
  log_info "/dev/net/tun OK"
  return 0
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
  PULL_LAST_ERROR=""
  while [ "$_n" -lt "$PULL_RETRIES" ]; do
    _pull_out="$("$DOCKER_BIN" pull "$_img" 2>&1)"
    _pull_rc=$?
    [ -n "$_pull_out" ] && printf '%s\n' "$_pull_out" >>"$LOG_FILE" 2>/dev/null
    if [ "$_pull_rc" -eq 0 ]; then
      if [ -n "$(local_image_id "$_img")" ]; then
        return 0
      fi
      log_warn "pull returned success but no local image is inspectable: $_img"
    fi
    PULL_LAST_ERROR="$_pull_out"
    _n=$((_n+1))
    [ "$_n" -lt "$PULL_RETRIES" ] && { log_warn "pull failed ($_img) attempt $_n/$PULL_RETRIES - retrying in ${PULL_RETRY_DELAY}s"; sleep "$PULL_RETRY_DELAY"; }
  done
  log_error "pull failed after $PULL_RETRIES attempts: $_img"
  return 1
}

# pull_failure_hint - classify the last pull error. Only the unambiguous
# missing-manifest signals get the mirroring hint: docker's access-denied text
# ("repository does not exist or may require 'docker login'") also mentions a
# missing repo, and mislabeling an ACR auth/ACL problem as a mirroring gap
# would send the operator to the wrong fix.
pull_failure_hint() {
  case "${PULL_LAST_ERROR:-}" in
    *"pull access denied"*|*"denied"*|*unauthorized*) : ;;
    *"manifest unknown"*|*"manifest for"*)
      printf '%s' " (not mirrored in ACR? mirror the upstream image into your ACR namespace first)" ;;
  esac
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

# mihomo_auto_redirect_probe IMAGE
# auto-redirect asks the image's iptables frontend to program the host kernel.
# Older DSM kernels reject the nft-backed frontend used by current Mihomo images.
# Exercise the same NAT-chain operation in a disposable network namespace before
# recreating a healthy gateway. Disabled mode deliberately performs no Docker call.
mihomo_auto_redirect_probe() {
  case "${TUN_AUTO_REDIRECT:-false}" in
    false) return 0 ;;
    true) : ;;
    *) log_error "TUN_AUTO_REDIRECT must be true or false"; return 1 ;;
  esac
  _arp_image="${1:-${MIHOMO_IMAGE:-}}"
  [ -n "$_arp_image" ] || { log_error "cannot probe TUN auto-redirect: MIHOMO_IMAGE is empty"; return 1; }
  log_info "probing TUN auto-redirect compatibility with $_arp_image"
  if "$DOCKER_BIN" run --rm --privileged --network none --entrypoint /bin/sh \
      "$_arp_image" -c \
      'iptables -t nat -N smg-auto-redirect-probe && iptables -t nat -X smg-auto-redirect-probe' \
      >>"$LOG_FILE" 2>&1; then
    log_info "TUN auto-redirect compatibility probe passed"
    return 0
  fi
  log_error "TUN auto-redirect is incompatible with this DSM kernel/image; set TUN_AUTO_REDIRECT=false"
  return 1
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
