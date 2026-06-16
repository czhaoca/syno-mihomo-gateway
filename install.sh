#!/bin/sh
# install.sh - guided, menu-driven installer for the Mihomo transparent-proxy
# gateway on Synology DSM. Run it from inside the unpacked folder:
#
#     sh ./install.sh
#
# It walks you through one of three actions:
#   1. Deploy the gateway end-to-end (config -> network -> images -> start)
#   2. Set up the automatic image-update schedule (cron)
#   3. Modify an existing deployment
#
# The script is modular: this entry point only wires the modules together and
# runs the menu. Each capability lives in scripts/installer/*.sh and reuses the
# shared runtime libraries in scripts/lib/*.sh.
#
# POSIX /bin/sh, BusyBox-safe (DSM). Root is required for the deploy/network
# steps (TUN device, macvlan, docker); the installer detects this and tells you
# how to re-run with sudo rather than failing halfway.

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LIB="$REPO_ROOT/scripts/lib"
INST="$REPO_ROOT/scripts/installer"

# --- source the runtime libraries and installer modules (fixed order) ---------
# ui.sh is kept out of common.sh so the unattended updater never sources TTY code.
# shellcheck source=scripts/lib/common.sh
. "$LIB/common.sh"
# shellcheck source=scripts/installer/ui.sh
. "$INST/ui.sh"
# shellcheck source=scripts/lib/notify.sh
. "$LIB/notify.sh"
# shellcheck source=scripts/lib/registry.sh
. "$LIB/registry.sh"
# shellcheck source=scripts/lib/compose.sh
. "$LIB/compose.sh"
# shellcheck source=scripts/lib/cloudflared.sh
. "$LIB/cloudflared.sh"
# shellcheck source=scripts/lib/network.sh
. "$LIB/network.sh"
# shellcheck source=scripts/installer/envedit.sh
. "$INST/envedit.sh"
# shellcheck source=scripts/installer/preflight.sh
. "$INST/preflight.sh"
# shellcheck source=scripts/installer/netscan.sh
. "$INST/netscan.sh"
# shellcheck source=scripts/installer/wizards.sh
. "$INST/wizards.sh"
# shellcheck source=scripts/installer/flow_deploy.sh
. "$INST/flow_deploy.sh"
# shellcheck source=scripts/installer/flow_cron.sh
. "$INST/flow_cron.sh"
# shellcheck source=scripts/installer/flow_modify.sh
. "$INST/flow_modify.sh"

# Rotating-free install log for diagnostics (referenced by diagnose()).
INSTALL_LOG="${INSTALL_LOG:-$REPO_ROOT/logs/install.log}"
mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null
export INSTALL_LOG

# Restore terminal echo if a secret prompt or Ctrl-C left it off.
# shellcheck disable=SC2329  # invoked indirectly via trap
_on_exit() { stty echo </dev/tty 2>/dev/null; }
trap _on_exit EXIT INT TERM

# This installer is interactive: it reads choices from the terminal even when
# stdin is piped. Bail clearly if there is no controlling terminal.
if [ ! -r /dev/tty ]; then
  echo "install.sh is interactive - run it in a terminal:  sh ./install.sh" >&2
  exit "${EXIT_CONFIG:-3}"
fi

main_menu() {
  _choice=""
  while :; do
    ui_say ""
    ui_say "${C_BOLD}Mihomo Gateway - guided installer${C_RESET}"
    ui_menu_select _choice "Select an action" \
      "Deploy the gateway (end-to-end)" \
      "Set up automatic updates (cron)" \
      "Modify an existing deployment" \
      "Quit"
    case "$_choice" in
      "Deploy"*)            flow_deploy || ui_warn "deploy did not finish - fix the issue above, then choose Deploy again" ;;
      "Set up automatic"*)  flow_cron   || ui_warn "cron setup did not finish" ;;
      "Modify"*)            flow_modify ;;
      "Quit"*)              ui_say "Bye."; return 0 ;;
    esac
  done
}

# --- entry --------------------------------------------------------------------
ui_step "Mihomo Gateway installer"

# req #3: the bundle can be unpacked anywhere, but it must live under the Docker
# shared folder. Check that FIRST and stop with guidance if it doesn't.
ui_info "checking this folder's location..."
if ! check_location; then
  ui_error "cannot continue until the folder location is fixed (see above)."
  exit "${EXIT_CONFIG:-3}"
fi

if ! is_root; then
  ui_warn "you are not root. The deploy and network steps need root"
  ui_warn "(create /dev/net/tun, the macvlan network, and run docker)."
  sudo_rerun_hint
fi

main_menu
exit "${EXIT_OK:-0}"
