#!/bin/sh
# linux_installer_check.sh - suite for the generic-Linux installer entry (epic
# generic-linux-port, #47). install-linux.sh is a thin ADDITIVE layer: it
# sources the same shared libraries + installer modules as install-pi.sh, the
# UNCHANGED scripts/pi/ engine, and then the scripts/linux/ overlay - a DELTA
# i18n catalog (DEC-A) that overrides only the Pi-branded keys plus the
# rerun-hint entry name. This suite proves:
#   * the entry sources cleanly under the CI guard and its menu dispatch
#     reaches the pi engine flows (pi_flow_compose / pi_flow_lite);
#   * the delta overlay resolves linux -> pi -> stock, keeps en/zh key parity,
#     overrides only keys that exist in the pi table, and leaves NO Raspberry
#     Pi branding (or install-pi.sh entry names) in the resolved i18n catalog;
#   * the status menu reuses the pi-lite/pi-compose install-mode marker as-is,
#     and the frozen lite_ctl SUBPROCESS output is rebranded by the entry's
#     filter seam (<Pi-IP>, "Raspberry Pi OS:") with its exit code preserved.
# Style matches pi_installer_check.sh: BusyBox ash, mktemp sandbox, function
# fakes; never mutates the host. Later epic tickets (#48+) extend this file.
# shellcheck disable=SC1091 # sources resolve via $ROOT at runtime
# shellcheck disable=SC2016 # single-quoted sh -c bodies expand via their own $1/$2
# shellcheck disable=SC2015 # `[ ] && ok || fail` is safe: ok() cannot fail
# shellcheck disable=SC2329 # subshell function overrides are invoked indirectly
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/scripts/ci/lib/assert.sh"

# die - infrastructure failure (missing file/broken fixture), distinct from the
# assert.sh counters which record behavior expectations.
die() { echo "FATAL: $*" >&2; exit 1; }

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT INT TERM

[ -f "$ROOT/install-linux.sh" ] || die "install-linux.sh missing"
[ -f "$ROOT/scripts/linux/i18n_linux.sh" ] || die "scripts/linux/i18n_linux.sh missing"

# --- entry sources cleanly under the CI guard -----------------------------------
expect_success "install-linux.sh sources cleanly (INSTALL_SOURCE_ONLY=1)" \
  sh -c 'cd "$1" && INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1" sh -c ". ./install-linux.sh"' _ "$ROOT"

# --- bring up the module stack in-process (same set install-linux.sh sources) ---
REPO_ROOT="$ROOT"
. "$ROOT/scripts/lib/common.sh"
. "$ROOT/scripts/lib/network.sh"
. "$ROOT/scripts/lib/registry.sh"
. "$ROOT/scripts/installer/ui.sh"
. "$ROOT/scripts/installer/i18n.sh"
. "$ROOT/scripts/installer/envedit.sh"
. "$ROOT/scripts/installer/preflight.sh"
. "$ROOT/scripts/installer/wizards.sh"
. "$ROOT/scripts/pi/detect.sh"
. "$ROOT/scripts/pi/preflight.sh"
. "$ROOT/scripts/pi/i18n_pi.sh"
. "$ROOT/scripts/pi/flow_compose.sh"
. "$ROOT/scripts/pi/lite.sh"
. "$ROOT/scripts/pi/flow_lite.sh"
. "$ROOT/scripts/linux/i18n_linux.sh"

# --- delta overlay: resolution order linux -> pi -> stock ------------------------
_t_en="$( (INSTALLER_LANG=en; msg pi_title) )"
assert_contains "overlay wins: en title is the Linux installer" "$_t_en" 'Linux'
assert_not_contains "overlay wins: en title carries no Pi branding" "$_t_en" 'Raspberry'
_t_zh="$( (INSTALLER_LANG=zh; msg pi_title) )"
[ -n "$_t_zh" ] && [ "$_t_zh" != pi_title ] \
  && ok || fail "overlay: zh title resolves (not the bare key)"
assert_not_contains "overlay wins: zh title carries no Pi branding" "$_t_zh" 'Raspberry'
[ "$( (INSTALLER_LANG=en; msg pi_hw_title) )" = 'Detected hardware' ] \
  && ok || fail "overlay falls back to the pi table for non-overridden pi keys"
[ "$( (INSTALLER_LANG=en; msg menu_modify) )" = 'Modify an existing deployment' ] \
  && ok || fail "overlay falls back to the stock catalog"

# --- delta overlay: en/zh key parity + delta-only invariant ----------------------
_lx_en_keys="$(sed -n '/^_msg_en_linux()/,/^}/p' "$ROOT/scripts/linux/i18n_linux.sh" | sed -n 's/^    \([a-z0-9_]*\)).*/\1/p' | sort)"
_lx_zh_keys="$(sed -n '/^_msg_zh_linux()/,/^}/p' "$ROOT/scripts/linux/i18n_linux.sh" | sed -n 's/^    \([a-z0-9_]*\)).*/\1/p' | sort)"
[ -n "$_lx_en_keys" ] && [ "$_lx_en_keys" = "$_lx_zh_keys" ] \
  && ok || fail "linux i18n en/zh key sets are identical"
_pi_en_keys="$(sed -n '/^_msg_en_pi()/,/^}/p' "$ROOT/scripts/pi/i18n_pi.sh" | sed -n 's/^    \([a-z0-9_]*\)).*/\1/p' | sort)"
[ -n "$_pi_en_keys" ] || die "could not extract the pi key list"
_lx_orphans=''
for _k in $_lx_en_keys; do
  printf '%s\n' "$_pi_en_keys" | grep -qx "$_k" || _lx_orphans="$_lx_orphans $_k"
done
[ -z "$_lx_orphans" ] \
  && ok || fail "delta overlay overrides keys absent from the pi table:$_lx_orphans"

# --- branding sweep: every pi key resolved through the linux chain is clean ------
# The pi catalog is the full user-facing surface the generic path transits;
# resolve every key in both languages and scan the blobs for Pi branding and
# for the wrong entry name (acceptance criterion #5 of work-order #47).
_blob_en=''; _blob_zh=''
for _k in $_pi_en_keys; do
  _blob_en="$_blob_en
$( (INSTALLER_LANG=en; msg "$_k") )"
  _blob_zh="$_blob_zh
$( (INSTALLER_LANG=zh; msg "$_k") )"
done
for _needle in 'Raspberry' 'install-pi.sh' 'this Pi' 'the Pi' 'Pi 1' 'Pi 3' 'Pi OS' 'Pi guide'; do
  assert_not_contains "en generic catalog clean of: $_needle" "$_blob_en" "$_needle"
done
for _needle in 'Raspberry' 'install-pi.sh' '本 Pi' 'Pi 指南' '连接 Pi' 'Pi 3' 'Pi 1' 'Raspberry Pi OS'; do
  assert_not_contains "zh generic catalog clean of: $_needle" "$_blob_zh" "$_needle"
done

# --- rerun hints name install-linux.sh -------------------------------------------
# The pi overlay's sudo_rerun_hint delegates to pi_sudo_rerun_hint BY NAME at
# runtime; the linux overlay (sourced last) redefines the latter, so every
# hint - including the ones inside captured/stock bodies - retargets without
# touching scripts/pi/.
_out="$( (have_sudo() { return 0; }; sudo_rerun_hint) 2>&1 )"
case "$_out" in
  *install-linux.sh*) ok ;;
  *) fail "sudo_rerun_hint (sudo present) does not name install-linux.sh" ;;
esac
assert_not_contains "sudo_rerun_hint never names install-pi.sh" "$_out" 'install-pi.sh'
_out="$( (have_sudo() { return 1; }; sudo_rerun_hint) 2>&1 )"
case "$_out" in
  *install-linux.sh*) ok ;;
  *) fail "sudo_rerun_hint (no sudo) does not name install-linux.sh" ;;
esac

# --- entry: sourcing lands the overlay (title resolves through linux table) ------
_out="$(sh -c '
  cd "$1" || exit 9
  INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
  export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
  . ./install-linux.sh || exit 9
  INSTALLER_LANG=en
  msg pi_title
' _ "$ROOT" 2>/dev/null)" || _out=''
assert_contains "sourced entry resolves the linux overlay title" "$_out" 'Linux'
assert_not_contains "sourced entry title carries no Pi branding" "$_out" 'Raspberry'

# --- entry: menu dispatch reaches the pi engine flows ----------------------------
# Drive main_menu_linux with a scripted menu (item 1 = deploy, then quit) and
# the mode wizard pinned; the pi flows are fakes that log. This proves the
# generic entry funnels into the unchanged pi engine (compose AND lite).
run_dispatch() {  # $1 = pinned PI_MODE; prints the reached-flow marker
  sh -c '
    cd "$1" || exit 9
    INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
    export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
    . ./install-linux.sh || exit 9
    _lm_banner() { :; }
    ui_say() { :; }
    _mode="$2"
    pi_mode_wizard() { PI_MODE="$_mode"; }
    pi_flow_compose() { echo COMPOSE_REACHED; }
    pi_flow_lite() { echo LITE_REACHED; }
    _n=0
    ui_menu_select() {
      _n=$((_n + 1))
      if [ "$_n" = 1 ]; then UI_MENU_INDEX=1; else UI_MENU_INDEX=6; fi
    }
    main_menu_linux
  ' _ "$ROOT" "$1" 2>/dev/null
}
_out="$(run_dispatch compose)" || _out=''
assert_contains "menu deploy dispatches to pi_flow_compose" "$_out" 'COMPOSE_REACHED'
_out="$(run_dispatch lite)" || _out=''
assert_contains "menu deploy dispatches to pi_flow_lite" "$_out" 'LITE_REACHED'

# --- entry: status menu reuses the pi install-mode marker ------------------------
# A pi-lite marker routes to the lite status surface; pi-compose keeps the
# compose inspection (the install-pi.sh:pi_menu_status_flow pattern, reused
# as-is - marker tokens stay pi-compose/pi-lite per the epic constraints).
mkdir -p "$TD/lx-data/state"
printf 'pi-lite\n' > "$TD/lx-data/state/install-mode"
( GATEWAY_DATA_DIR="$TD/lx-data"; ENV_FILE="$TD/lx-data/.env"
  INSTALL_SOURCE_ONLY=1; SMG_INSTALL_ROOT="$ROOT"
  . "$ROOT/install-linux.sh" || exit 97
  ui_step() { :; }; ui_say() { :; }; ui_ok() { :; }; ui_warn() { :; }
  ui_yesno() { return 1; }
  _run_lite_status() { echo LITE >> "$TD/lx-data/dispatch.log"; }
  lifecycle_inspect() { echo COMPOSE >> "$TD/lx-data/dispatch.log"; }
  linux_menu_status_flow ) >/dev/null 2>&1 || :
grep -q 'LITE' "$TD/lx-data/dispatch.log" 2>/dev/null \
  && ok || fail "status menu: pi-lite marker routes to the lite status"
grep -q 'COMPOSE' "$TD/lx-data/dispatch.log" 2>/dev/null \
  && fail "status menu: lite install still ran the compose inspection" || ok
printf 'pi-compose\n' > "$TD/lx-data/state/install-mode"
( GATEWAY_DATA_DIR="$TD/lx-data"; ENV_FILE="$TD/lx-data/.env"
  INSTALL_SOURCE_ONLY=1; SMG_INSTALL_ROOT="$ROOT"
  . "$ROOT/install-linux.sh" || exit 97
  ui_step() { :; }; ui_say() { :; }; ui_ok() { :; }; ui_warn() { :; }
  ui_yesno() { return 1; }
  _run_lite_status() { echo LITE2 >> "$TD/lx-data/dispatch.log"; }
  lifecycle_inspect() { echo COMPOSE2 >> "$TD/lx-data/dispatch.log"; }
  linux_menu_status_flow ) >/dev/null 2>&1 || :
grep -q 'COMPOSE2' "$TD/lx-data/dispatch.log" 2>/dev/null \
  && ok || fail "status menu: pi-compose marker keeps the compose inspection"

# --- entry: user-facing literals name the right entry ----------------------------
expect_success "non-TTY hint names install-linux.sh" \
  grep -q 'sh ./install-linux.sh' "$ROOT/install-linux.sh"

# --- lite_ctl subprocess output: Pi literals rebranded, exit code preserved ------
# lite_ctl.sh is frozen and runs as a CHILD process (it sources its own
# catalogs), so install-linux.sh filters its OUTPUT instead: <Pi-IP> becomes
# <host-IP> and the "(Raspberry Pi OS: ...)" port-53 hint goes generic. Drive
# the REAL lite_ctl in a sandbox through the entry's seams and prove both the
# rebranding and that the child's doctor exit code survives the filter.
mkdir -p "$TD/lc-data/bin" "$TD/lc-data/state/lite" "$TD/lc-data/config" "$TD/lc-bin"
cat > "$TD/lc-data/bin/mihomo" <<'EOF'
#!/bin/sh
[ "${1:-}" = -v ] && { echo "Mihomo Meta v9.9.9 linux test build"; exit 0; }
exit 0
EOF
chmod +x "$TD/lc-data/bin/mihomo"
printf 'v9.9.9\n' > "$TD/lc-data/state/lite/version"
printf 'pi-lite\n' > "$TD/lc-data/state/install-mode"
printf 'Default=https://sub.example.com/api?token=abc\n' > "$TD/lc-data/config/subscription.txt"
{
  printf 'TUN_ENABLE=false\nCONTROLLER_PORT=9090\n'
  printf 'DNS_DEFAULT_NAMESERVER=192.0.2.53\nDNS_NAMESERVER=192.0.2.53\n'
  printf 'DNS_CN_NAMESERVER=192.0.2.53\nDNS_FOREIGN_NAMESERVER=192.0.2.54\n'
  printf 'COUNTRY_GROUPS=JPX=jp\n'
} > "$TD/lc-data/.env"
# fake ss reporting dnsmasq on :53 (lite_ctl PATH-prepends the system dirs, so
# this only wins where no real ss exists - true in the alpine CI adjudicator)
cat > "$TD/lc-bin/ss" <<'EOF'
#!/bin/sh
printf 'udp   UNCONN 0 0  0.0.0.0:53  0.0.0.0:*  users:(("dnsmasq",pid=419,fd=4))\n'
EOF
chmod +x "$TD/lc-bin/ss"
# fake systemctl (always succeeds): without it the doctor goes broken at the
# systemd gate and never reaches the deeper block holding the port-53 check
printf '#!/bin/sh\nexit 0\n' > "$TD/lc-bin/systemctl"
chmod +x "$TD/lc-bin/systemctl"
run_lite_seam() {  # $1 = seam function; sandbox env EXPORTED for the child
  sh -c '
    GATEWAY_DATA_DIR="$1/lc-data"; ENV_FILE="$1/lc-data/.env"
    CONFIG_STATE_DIR="$1/lc-data/config"; LOCK_DIR="$1/lc-data/lock"
    SUBSCRIPTION_FILE="$1/lc-data/config/subscription.txt"
    SMG_PI_UNIT_FILE="$1/lc-data/unit.service"
    PATH="$PATH:$1/lc-bin"
    export GATEWAY_DATA_DIR ENV_FILE CONFIG_STATE_DIR LOCK_DIR \
      SUBSCRIPTION_FILE SMG_PI_UNIT_FILE PATH
    cd "$2" || exit 9
    INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$2"
    export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
    . ./install-linux.sh || exit 9
    "$3"
  ' _ "$TD" "$ROOT" "$1"
}
_out="$(run_lite_seam _run_lite_status)" || :
assert_contains "lite status: dashboard placeholder rebranded to <host-IP>" "$_out" '<host-IP>'
assert_not_contains "lite status: no <Pi-IP> literal" "$_out" '<Pi-IP>'
assert_not_contains "lite status: no Raspberry branding" "$_out" 'Raspberry'
_out="$(run_lite_seam _run_lite_doctor)" || :
assert_contains "lite doctor: port-53 hint keeps its generic remedy" "$_out" 'systemd-resolved/dnsmasq'
assert_not_contains "lite doctor: no Raspberry branding" "$_out" 'Raspberry'
# exit-code preservation: the wrapper must return exactly the child's rc
_direct_rc=0
sh -c '
  GATEWAY_DATA_DIR="$1/lc-data"; ENV_FILE="$1/lc-data/.env"
  CONFIG_STATE_DIR="$1/lc-data/config"; LOCK_DIR="$1/lc-data/lock"
  SUBSCRIPTION_FILE="$1/lc-data/config/subscription.txt"
  SMG_PI_UNIT_FILE="$1/lc-data/unit.service"
  PATH="$PATH:$1/lc-bin"
  export GATEWAY_DATA_DIR ENV_FILE CONFIG_STATE_DIR LOCK_DIR \
    SUBSCRIPTION_FILE SMG_PI_UNIT_FILE PATH
  sh "$2/scripts/pi/lite_ctl.sh" doctor
' _ "$TD" "$ROOT" >/dev/null 2>&1 || _direct_rc=$?
_wrap_rc=0
run_lite_seam _run_lite_doctor >/dev/null 2>&1 || _wrap_rc=$?
[ "$_wrap_rc" = "$_direct_rc" ] \
  && ok || fail "wrapper preserves the doctor exit code (wrap=$_wrap_rc direct=$_direct_rc)"

# --- summary --------------------------------------------------------------------
printf 'linux_installer_check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: install-linux entry + linux i18n delta overlay + pi-engine dispatch verified"
