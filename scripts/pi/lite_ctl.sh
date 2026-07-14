#!/bin/sh
# lite_ctl.sh - day-2 CLI for the bare-metal "lite" mode (#21):
#
#   sh scripts/pi/lite_ctl.sh {status|doctor|start|stop|update [--dry-run|--force]}
#
# Deliberately OUTSIDE gateway.sh and scripts/cli/spec.yaml: the 5 generated
# CLI-contract artifacts stay byte-identical (verb unification is a recorded
# follow-up in docs/brainstorms/raspberry-pi-port.md). Usage text is plain and
# bilingual via the pi i18n overlay, not spec-generated.
#
# doctor mirrors scripts/doctor.sh's vocabulary and exit codes exactly:
#   0 structurally healthy | 2 degraded | 3 broken - read-only throughout
# (the render check renders into a throwaway temp dir, never the live config).
# status is read-only; start/stop need root; update delegates to
# scripts/pi/auto_update_lite.sh, which owns its own lock and kill-switch.
#
# POSIX /bin/sh. No `set -e` - return codes are checked explicitly.

PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

# scripts/pi/ sits one level deeper than scripts/, so resolve REPO_ROOT before
# common.sh; the SELF_DIR override exists for the CI suite (which sources this
# file under LITE_CTL_SOURCE_ONLY=1).
SELF_DIR="${LITE_CTL_SELF_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(CDPATH='' cd -- "$SELF_DIR/../.." && pwd)}"

# Read-only CLI: never create log directories as a side effect (doctor.sh
# discipline). The update delegation re-enables init for its child.
NO_LOG_INIT=1
export NO_LOG_INIT

# Remember whether the caller chose a language BEFORE i18n.sh collapses an
# unset INSTALLER_LANG to en, so the .env preference can still win below.
_LC_LANG_ENV="${INSTALLER_LANG:-}"

# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/../lib/common.sh"
# shellcheck source=scripts/lib/resolve.sh
. "$SELF_DIR/../lib/resolve.sh"
# shellcheck source=scripts/lib/scheduler.sh
. "$SELF_DIR/../lib/scheduler.sh"
# shellcheck source=scripts/installer/i18n.sh
. "$SELF_DIR/../installer/i18n.sh"
# shellcheck source=scripts/pi/detect.sh
. "$SELF_DIR/detect.sh"
# shellcheck source=scripts/pi/lite.sh
. "$SELF_DIR/lite.sh"
# shellcheck source=scripts/pi/i18n_pi.sh
. "$SELF_DIR/i18n_pi.sh"

if [ -z "$_LC_LANG_ENV" ] && [ -f "$ENV_FILE" ]; then
  INSTALLER_LANG="$(dotenv_get INSTALLER_LANG 2>/dev/null)"
  [ -n "$INSTALLER_LANG" ] || INSTALLER_LANG=en
fi

lite_ctl_usage() {
  printf '%s\n' "$(msg pi_ctl_usage)"
  printf '%s\n' "$(msg pi_ctl_usage2)"
}

# --- doctor -------------------------------------------------------------------
# Accumulators + printers copy scripts/doctor.sh:31-35 (names prefixed so the
# CI suite's own ok()/fail() vocabulary is never shadowed when sourced).
_lc_broken=0
_lc_degraded=0
_lc_ok()   { printf 'ok    %s\n' "$*"; }
_lc_bad()  { printf 'ERROR %s\n' "$*" >&2; _lc_broken=1; }
_lc_warn() { printf 'WARN  %s\n' "$*" >&2; _lc_degraded=1; }

# _lc_render_check - prove config.yaml WOULD render from the live .env +
# subscription, without touching the live config dir: the same renderer the
# unit's ExecStartPre runs, pointed at a throwaway directory.
_lc_render_check() {
  _lrc_tmp="$(mktemp -d 2>/dev/null)" || {
    _lc_warn "cannot create a temp dir for the render check"
    return 0
  }
  cp "$SUBSCRIPTION_FILE" "$_lrc_tmp/subscription.txt" 2>/dev/null
  if MIHOMO_CONFIG_DIR="$_lrc_tmp" \
     MIHOMO_TEMPLATE="$REPO_ROOT/config/config.template.yaml" \
     CONTROLLER_PORT="${CONTROLLER_PORT:-9090}" \
     CONTROLLER_SECRET="${CONTROLLER_SECRET:-}" \
     DNS_DEFAULT_NAMESERVER="${DNS_DEFAULT_NAMESERVER:-}" \
     DNS_NAMESERVER="${DNS_NAMESERVER:-}" \
     DNS_CN_NAMESERVER="${DNS_CN_NAMESERVER:-}" \
     DNS_FOREIGN_NAMESERVER="${DNS_FOREIGN_NAMESERVER:-}" \
     TUN_ENABLE="${TUN_ENABLE:-true}" \
     TUN_AUTO_REDIRECT="${TUN_AUTO_REDIRECT:-false}" \
     EXTERNAL_UI_DIR="${EXTERNAL_UI_DIR:-}" \
     sh "$REPO_ROOT/scripts/render_config.sh" >/dev/null 2>&1; then
    _lc_ok "config renders cleanly (same renderer the service runs)"
  else
    _lc_bad "config does not render - check the .env DNS/controller values and the subscription"
  fi
  rm -rf "$_lrc_tmp"
}

# _lc_port53_check - G7: mihomo's DNS binds :53, and a stock resolver in the
# way is the most common lite-mode failure on Pi OS variants. Name the
# occupier so the warn is actionable; no listing tool = nothing searchable
# here, stay silent (the scheduler-check discipline).
_lc_port53_check() {
  command -v ss >/dev/null 2>&1 || return 0
  _lp_out="$(ss -lntup 2>/dev/null | grep '[:.]53[[:space:]]')"
  if [ -z "$_lp_out" ]; then
    _lc_ok "no foreign process holds port 53"
    return 0
  fi
  case "$_lp_out" in
    *mihomo*)
      _lc_ok "port 53 is served by mihomo" ;;
    *)
      _lp_name="$(printf '%s\n' "$_lp_out" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n1)"
      _lc_warn "port 53 is held by ${_lp_name:-another process} - mihomo DNS cannot bind; disable it or move it off port 53 (Raspberry Pi OS: systemd-resolved/dnsmasq), then restart mihomo-gateway" ;;
  esac
}

lite_ctl_doctor() {
  printf '%s\n' 'Mihomo Gateway lite diagnostics (read-only)'

  if [ ! -f "$ENV_FILE" ]; then
    _lc_bad ".env is missing: $ENV_FILE"
  else
    load_env
    _lc_ok ".env parsed safely"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    _lc_ok "systemd (systemctl) is available"
  else
    _lc_bad "systemctl not found - lite mode requires systemd"
  fi

  if [ "$_lc_broken" -eq 0 ]; then
    if [ -f "$(pi_lite_unit_path)" ]; then
      _lc_ok "unit file present: $(pi_lite_unit_path)"
    else
      _lc_bad "unit file missing: $(pi_lite_unit_path) - run the lite install"
    fi

    _lc_active=0
    if systemctl is-active --quiet mihomo-gateway 2>/dev/null; then
      _lc_active=1
      _lc_ok "mihomo-gateway.service is active"
    else
      _lc_bad "mihomo-gateway.service is not active - journalctl -u mihomo-gateway -n 50"
    fi

    if [ -x "$GATEWAY_DATA_DIR/bin/mihomo" ]; then
      _lc_ok "managed binary present: bin/mihomo"
    else
      _lc_bad "no managed binary at $GATEWAY_DATA_DIR/bin/mihomo - run the lite install"
    fi
    if [ -s "$GATEWAY_DATA_DIR/state/lite/version" ]; then
      _lc_ok "installed version: $(cat "$GATEWAY_DATA_DIR/state/lite/version")"
    else
      _lc_warn "version state missing - the updater cannot fast-exit (self-heals on the next successful update)"
    fi

    # Subscription parity with doctor.sh: missing = degraded, not broken; the
    # render check only makes sense once a subscription exists (the renderer
    # fails-closed without one by design).
    if [ -n "$(subscription_current 2>/dev/null)" ]; then
      _lc_ok "subscription URL is stored"
      _lc_render_check
    else
      _lc_warn "no subscription URL is stored - re-run the lite deploy to set one"
    fi

    if [ "$_lc_active" -eq 1 ]; then
      # Single-shot probe in a subshell (POSIX lets VAR=x func persist VAR).
      if ( PI_PROBE_RETRIES=1; PI_PROBE_INTERVAL=0; pi_lite_controller_probe ); then
        _lc_ok "controller API responds"
      else
        _lc_bad "controller API does not respond on 127.0.0.1:${CONTROLLER_PORT:-9090}"
      fi
      if [ "${TUN_ENABLE:-true}" != true ]; then
        _lc_ok "TUN transparent gateway disabled (TUN_ENABLE=false) - plain proxy + controller mode"
      elif ip link show "${TUN_DEVICE:-mihomo-tun}" >/dev/null 2>&1; then
        _lc_ok "TUN link ${TUN_DEVICE:-mihomo-tun} is present"
      else
        _lc_bad "TUN link ${TUN_DEVICE:-mihomo-tun} is absent while TUN_ENABLE=true"
      fi
    fi

    _lc_port53_check

    # Scheduler deployment (doctor.sh:107-113 discipline): rc 2 means nothing
    # searchable here - stay silent rather than warn about a surface this box
    # does not have.
    if [ "${UPDATE_ENABLED:-true}" = true ]; then
      scheduler_task_deployed "scripts/pi/auto_update_lite.sh"
      case "$?" in
        0) _lc_ok "auto-update task is scheduled" ;;
        1) _lc_warn "no scheduled task runs scripts/pi/auto_update_lite.sh - schedule it from the installer menu" ;;
      esac
    fi
  fi

  if [ "$_lc_broken" -ne 0 ]; then
    printf '%s\n' "Result: BROKEN. See: journalctl -u mihomo-gateway -n 50" >&2
    exit "$EXIT_CONFIG"
  fi
  if [ "$_lc_degraded" -ne 0 ]; then
    printf '%s\n' 'Result: DEGRADED.' >&2
    exit "$EXIT_PARTIAL"
  fi
  printf '%s\n' 'Result: HEALTHY.'
  exit "$EXIT_OK"
}

# --- status -------------------------------------------------------------------
lite_ctl_status() {
  [ -f "$ENV_FILE" ] && dotenv_load "$ENV_FILE" >/dev/null 2>&1
  printf 'mode:      %s\n' "$(cat "$GATEWAY_DATA_DIR/state/install-mode" 2>/dev/null || echo unknown)"
  printf 'version:   %s\n' "$(cat "$GATEWAY_DATA_DIR/state/lite/version" 2>/dev/null || echo unknown)"
  if systemctl is-active --quiet mihomo-gateway 2>/dev/null; then
    printf 'service:   active\n'
  else
    printf 'service:   inactive\n'
  fi
  printf 'last-run:  %s\n' "$(cat "$GATEWAY_DATA_DIR/state/lite/last-run.json" 2>/dev/null || echo '(no update run recorded yet)')"
  printf 'dashboard: http://<Pi-IP>:%s/ui\n' "${CONTROLLER_PORT:-9090}"
  return 0
}

# --- start / stop -------------------------------------------------------------
lite_ctl_start() {
  need_root || exit "$EXIT_ROOT"
  if systemctl start mihomo-gateway; then
    printf '%s\n' 'mihomo-gateway started'
    exit "$EXIT_OK"
  fi
  printf '%s\n' 'mihomo-gateway failed to start - journalctl -u mihomo-gateway -n 50' >&2
  exit "$EXIT_CONFIG"
}

lite_ctl_stop() {
  need_root || exit "$EXIT_ROOT"
  if systemctl stop mihomo-gateway; then
    printf '%s\n' 'mihomo-gateway stopped'
    exit "$EXIT_OK"
  fi
  printf '%s\n' 'mihomo-gateway failed to stop' >&2
  exit "$EXIT_CONFIG"
}

# --- update -------------------------------------------------------------------
# Pure delegation: auto_update_lite.sh owns the lock, kill-switch, dry-run
# semantics, last-run state and exit codes. NO_LOG_INIT is re-enabled for the
# child (it writes its own rotating log under the data dir).
lite_ctl_update() {
  NO_LOG_INIT=0 sh "$REPO_ROOT/scripts/pi/auto_update_lite.sh" "$@"
  exit $?
}

lite_ctl_main() {
  _lcm_verb="${1:-}"
  [ $# -gt 0 ] && shift
  case "$_lcm_verb" in
    status) lite_ctl_status ;;
    doctor) lite_ctl_doctor ;;
    start)  lite_ctl_start ;;
    stop)   lite_ctl_stop ;;
    update) lite_ctl_update "$@" ;;
    *)      lite_ctl_usage >&2; exit "$EXIT_CONFIG" ;;
  esac
}

# Guarded so the CI suite can source the definitions without running a verb.
if [ "${LITE_CTL_SOURCE_ONLY:-0}" != 1 ]; then
  lite_ctl_main "$@"
fi
