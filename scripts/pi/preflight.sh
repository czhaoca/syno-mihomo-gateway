#!/bin/sh
# preflight.sh (scripts/pi) - Raspberry Pi preflight gates (#18). Replaces the
# DSM volume-location gate and adds the Pi-only guards; the DSM installer and
# its scripts/installer/preflight.sh stay untouched. Requires common.sh, ui.sh,
# i18n.sh (+ the i18n_pi overlay), envedit.sh, registry.sh (host_arch),
# network.sh (detect_parent_interface), wizards.sh (seed_config), and the
# installer preflight (have_sudo) sourced first. POSIX /bin/sh.

# pi_check_location - any WRITABLE install dir is fine on a Pi: there is no
# /volume* shared-folder concept to probe. Docker presence for compose mode is
# pf_docker's job inside the deploy flow, not a location concern.
pi_check_location() {
  _pl_self="$(CDPATH='' cd -- "${REPO_ROOT:-.}" 2>/dev/null && pwd -P)"
  [ -n "$_pl_self" ] || {
    diagnose "$(msg diag_resolve_self)" "$(msg diag_resolve_self_fix)"
    return 1
  }
  if [ ! -w "$_pl_self" ]; then
    ui_error "$(msgf err_not_writable "$(id -un 2>/dev/null)")"
    ui_say "      $(msg loc_fix_perm)"
    ui_say "        ${C_BOLD}sudo chown -R \"$(id -un 2>/dev/null)\" \"$_pl_self\"${C_RESET}"
    pi_sudo_rerun_hint
    return 1
  fi
  ui_ok "$(msgf ok_location "$_pl_self")"
  return 0
}

# pi_sudo_rerun_hint - the stock hint names install.sh; print the Pi entry
# instead (no DSM control-panel pointer on generic Linux).
pi_sudo_rerun_hint() {
  _pr_cmd="sh ./install-pi.sh"
  if have_sudo; then
    ui_say "      $(msgf rerun_root_sudo "$C_BOLD" "$_pr_cmd" "$C_RESET")"
  else
    ui_say "      $(msgf rerun_root_nosudo "$C_BOLD" "$_pr_cmd" "$C_RESET")"
  fi
}

# pi_acr_arch_notice - DEC-3 (#18): acr stays the Pi default, but the default
# mirror pipeline publishes amd64 only, so a non-amd64 host must mirror its
# arch BEFORE the first pull. Fires only for acr + non-amd64; informational
# (never blocks) - the flow's own arch guard still fail-closes on a bad image.
pi_acr_arch_notice() {
  [ "${REGISTRY_MODE:-acr}" = acr ] || return 0
  _pa_h="$(host_arch)"
  [ "$_pa_h" = amd64 ] && return 0
  ui_warn "$(msgf pi_warn_acr_arch "$_pa_h" "$_pa_h")"
  ui_say "      $(msgf pi_warn_acr_arch_fix "$_pa_h")"
  return 0
}

# pi_refuse_wlan IFACE - the wireless refusal itself, shared by the early
# fail-fast guard below and the create_network interposition at the bottom.
pi_refuse_wlan() {
  case "$1" in
    wl*)
      ui_error "$(msgf pi_err_wlan_parent "$1")"
      ui_say "      $(msg pi_err_wlan_parent_fix)"
      return 1 ;;
  esac
  return 0
}

# pi_wlan_guard - refuse a WIRELESS macvlan parent for compose mode: Wi-Fi
# drivers and AP client isolation typically break macvlan children (pre-decided
# constraint, #18). Lite mode binds the host directly and will work over Wi-Fi.
# This is the fail-fast check at flow entry; the guarded create_network below
# is the enforcement every path funnels through.
pi_wlan_guard() {
  _pw_p="${PARENT_INTERFACE:-}"
  [ -n "$_pw_p" ] || _pw_p="$(detect_parent_interface "${ROUTER_IP:-}" 2>/dev/null)"
  pi_refuse_wlan "$_pw_p"
}

# pi_armv6_ack - DEC-5 gate: ARMv6 (Pi 1 / Zero / Zero W) is best-effort only;
# require the explicit acknowledgment before anything proceeds. Default No.
pi_armv6_ack() {
  ui_warn "$(msg pi_warn_armv6)"
  ui_warn "$(msg pi_warn_armv6_2)"
  ui_yesno "$(msg pi_ask_armv6_ack)" n
}

# pi_align_expected_arch - the seeded .env carries the DSM default
# EXPECTED_ARCH=amd64, which would fail pf_arch on every Pi. Seed the config
# (idempotent, never clobbers) and pin EXPECTED_ARCH to this host BEFORE the
# deploy flow's arch gate runs; the auto-updater's arch guard inherits it too.
pi_align_expected_arch() {
  seed_config || return 1
  env_set EXPECTED_ARCH "$(host_arch)" || return 1
  return 0
}

# --- create_network interposition ------------------------------------------------
# The Modify menu and the redeploy "re-pick the interface" branch reach the
# stock create_network WITHOUT passing pi_flow_* (so the early pi_wlan_guard
# never fires) - the stock body's own comment calls that spot the safety net
# for exactly these paths. The stock installer modules are frozen for the Pi
# epic, so interpose at the choke point instead: capture the stock definition
# verbatim from netscan.sh at source time, then redefine create_network to
# refuse a wireless parent (resolved the same way the stock body resolves it)
# before delegating. Every caller - deploy, redeploy re-pick, modify - now
# funnels through the refusal. The capture fails CLOSED: if netscan.sh's
# function layout ever changes, the eval below fails or defines nothing and
# sourcing aborts loudly - which the CI sourcing test catches immediately.
_pi_ncn_src="$REPO_ROOT/scripts/installer/netscan.sh"
if ! eval "pi_stock_create_network() {
$(sed -n '/^create_network() {$/,/^}$/p' "$_pi_ncn_src" | sed '1d;$d')
}" || ! command -v pi_stock_create_network >/dev/null 2>&1; then
  echo "FATAL: could not capture create_network from $_pi_ncn_src (layout changed?)" >&2
  exit "${EXIT_CONFIG:-3}"
fi

create_network() {
  _pcn_pi="${CHOSEN_IFACE:-$(env_get PARENT_INTERFACE 2>/dev/null || detect_parent_interface "${ROUTER_IP:-}")}"
  pi_refuse_wlan "$_pcn_pi" || return 1
  pi_stock_create_network
}
