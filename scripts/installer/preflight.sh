#!/bin/sh
# preflight.sh - location + environment checks the installer runs before doing
# anything (req #3 + the robust error model, req #6).
#
# Responsibilities:
#   - check_location : the bundle can be unpacked anywhere, but the Docker
#     daemon (DSM Container Manager) bind-mounts ./config and ./scripts from
#     wherever docker-compose.yml lives, so the bundle MUST sit under the Docker
#     shared folder (e.g. /volume1/docker). Detect it, verify we are under it and
#     can write, and otherwise print exact move instructions (sudo / File Station).
#   - privilege helpers : root is needed for mknod /dev/net/tun, the macvlan, and
#     (on DSM) docker. Detect and advise re-running with sudo rather than
#     half-failing mid-flow.
#   - runtime probes : docker/compose present, arch match, port free, stack state.
#
# Requires common.sh (EXIT_*), ui.sh, registry.sh (detect_compose/host_arch),
# network.sh (_net_docker/network_exists) sourced first. POSIX /bin/sh.

# --- privilege helpers --------------------------------------------------------
is_root()   { [ "$(id -u 2>/dev/null)" = "0" ]; }
have_sudo() { command -v sudo >/dev/null 2>&1; }

# sudo_rerun_hint - print the exact command to re-run the installer as root.
sudo_rerun_hint() {
  _cmd="sh ./install.sh"
  if have_sudo; then
    ui_say "      Re-run as root:  ${C_BOLD}sudo $_cmd${C_RESET}"
  else
    ui_say "      Re-run as the root user (no sudo found): ${C_BOLD}$_cmd${C_RESET}"
    ui_say "      On DSM: enable SSH, log in, then 'sudo -i' (admin) before running."
  fi
}

# --- location (req #3) --------------------------------------------------------
# find_docker_root - print the Docker shared folder, or return 1. Honors a
# DOCKER_ROOT override; otherwise probes the usual DSM volume layouts.
find_docker_root() {
  if [ -n "${DOCKER_ROOT:-}" ]; then
    [ -d "$DOCKER_ROOT" ] && { printf '%s' "$DOCKER_ROOT"; return 0; }
    return 1
  fi
  for _d in /volume1/docker /volume2/docker /volume3/docker /volume4/docker /volumeUSB1/docker /docker; do
    [ -d "$_d" ] && { printf '%s' "$_d"; return 0; }
  done
  for _d in /volume*/docker; do
    [ -d "$_d" ] && { printf '%s' "$_d"; return 0; }
  done
  return 1
}

# path_under CHILD PARENT - 0 if CHILD is at/under PARENT (trailing-slash safe).
path_under() {
  _c="$1"; _p="$2"
  case "$_p" in */) : ;; *) _p="$_p/" ;; esac
  case "$_c/" in "$_p"*) return 0 ;; *) return 1 ;; esac
}

# check_location - the req #3 gate. Returns 0 to proceed, non-zero to abort.
check_location() {
  _self="$(CDPATH='' cd -- "${REPO_ROOT:-.}" 2>/dev/null && pwd -P)"
  [ -n "$_self" ] || { diagnose "cannot resolve the installer's own folder" "re-extract the bundle and run 'sh ./install.sh' from inside it"; return 1; }

  if ! _root="$(find_docker_root)"; then
    diagnose "could not find a Docker shared folder (looked for /volume*/docker)" \
      "In DSM, install Container Manager (or Docker) so the 'docker' shared folder exists, then move this folder into it. Override the path with DOCKER_ROOT=/path sh ./install.sh"
    return 1
  fi
  ui_ok "Docker shared folder: $_root"

  if ! path_under "$_self" "$_root"; then
    ui_error "this folder is NOT under the Docker shared folder."
    ui_say "      here:   $_self"
    ui_say "      docker: $_root"
    ui_say "      Move it there, then re-run from the new location:"
    ui_say "        ${C_BOLD}sudo mv \"$_self\" \"$_root/\"${C_RESET}"
    ui_say "        ${C_BOLD}cd \"$_root/$(basename "$_self")\" && sh ./install.sh${C_RESET}"
    ui_say "      Or in File Station: move this folder into the 'docker' shared folder, then re-open it here."
    return 1
  fi

  if [ ! -w "$_self" ]; then
    ui_error "this folder is not writable by the current user ($(id -un 2>/dev/null))."
    ui_say "      Fix ownership/permissions, e.g.:"
    ui_say "        ${C_BOLD}sudo chown -R \"$(id -un 2>/dev/null)\" \"$_self\"${C_RESET}"
    sudo_rerun_hint
    return 1
  fi

  ui_ok "location OK: $_self"
  return 0
}

# --- runtime probes -----------------------------------------------------------
# pf_docker - ensure docker + a compose flavor exist (sets DOCKER_BIN/COMPOSE_CMD
# via registry.sh:detect_compose). Diagnose on failure.
pf_docker() {
  if detect_compose; then
    ui_ok "docker + compose detected"
    return 0
  fi
  diagnose "Docker or docker compose is not available" \
    "Install/enable Container Manager (DSM) and make sure 'docker' is on PATH; if docker needs root, re-run with sudo"
  return 1
}

# pf_arch - warn (non-fatal) if the NAS arch differs from EXPECTED_ARCH.
pf_arch() {
  _h="$(host_arch)"
  if [ "$_h" != "${EXPECTED_ARCH:-amd64}" ]; then
    ui_warn "this NAS is '$_h' but EXPECTED_ARCH=${EXPECTED_ARCH:-amd64} - mirror matching-arch images, or set EXPECTED_ARCH=$_h in .env"
  else
    ui_ok "architecture: $_h"
  fi
  return 0
}

# pf_port_free PORT - 0 free, 1 in use, 2 cannot determine (no ss/netstat).
pf_port_free() {
  _port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${_port}\$" && return 1
    return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${_port}\$" && return 1
    return 0
  fi
  return 2
}

# stack_state - print fresh | partial | deployed for the current host.
#   deployed = the mihomo container is running
#   partial  = the macvlan exists, or a mihomo container exists but isn't running
#   fresh    = none of the above
stack_state() {
  _d="$(_net_docker)"
  if [ "$("$_d" inspect -f '{{.State.Running}}' mihomo 2>/dev/null)" = "true" ]; then
    echo deployed; return 0
  fi
  if network_exists 2>/dev/null || "$_d" inspect mihomo >/dev/null 2>&1; then
    echo partial; return 0
  fi
  echo fresh
}
