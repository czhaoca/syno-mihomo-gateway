#!/bin/sh
# linux_installer_check.sh - suite for the generic-Linux installer entry (epic
# generic-linux-port, #47 + #48). install-linux.sh is a thin ADDITIVE layer: it
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
#     filter seam (<Pi-IP>, "Raspberry Pi OS:") with its exit code preserved;
#   * (#48) the macvlan-viability preflight in scripts/linux/preflight_linux.sh:
#     virt/cloud detection (PATH-faked systemd-detect-virt, env-injected DMI
#     fixtures), the warn+ack gate (ack proceeds to macvlan, decline steers to
#     lite, bare metal never asks), its choke-point enforcement at BOTH
#     apply_predeployment_cleanup (ack resolves before any teardown) and
#     create_network, the EXPECTED_ARCH auto-pin riding the generic compose
#     flow, the fresh-seed image-ref blanking that closes the express-path
#     wizard bypass, and the docker-default registry wizard (acr selectable +
#     arch notice, with a tail-parity tripwire against the stock wizard) - all
#     of which write ONLY the sandbox user .env, never a tracked file.
# Style matches pi_installer_check.sh: BusyBox ash, mktemp sandbox, function
# fakes; never mutates the host. Later epic tickets (#49+) extend this file.
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
[ -f "$ROOT/scripts/linux/preflight_linux.sh" ] || die "scripts/linux/preflight_linux.sh missing"

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
. "$ROOT/scripts/lib/resolve.sh"
. "$ROOT/scripts/pi/detect.sh"
. "$ROOT/scripts/pi/preflight.sh"
. "$ROOT/scripts/pi/i18n_pi.sh"
. "$ROOT/scripts/pi/flow_compose.sh"
. "$ROOT/scripts/pi/lite.sh"
. "$ROOT/scripts/pi/flow_lite.sh"
. "$ROOT/scripts/linux/i18n_linux.sh"
. "$ROOT/scripts/linux/preflight_linux.sh"

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
# lx_-prefixed keys are linux-NATIVE additions (#48 guard/wizard phrasing), not
# overrides - they are exempt from the pi-table membership check; every other
# key must exist in the pi table (a typo'd override would silently never fire).
_lx_orphans=''
for _k in $_lx_en_keys; do
  case "$_k" in lx_*) continue ;; esac
  printf '%s\n' "$_pi_en_keys" | grep -qx "$_k" || _lx_orphans="$_lx_orphans $_k"
done
[ -z "$_lx_orphans" ] \
  && ok || fail "delta overlay overrides keys absent from the pi table:$_lx_orphans"

# --- branding sweep: every pi key resolved through the linux chain is clean ------
# The pi catalog is the full user-facing surface the generic path transits;
# resolve every key in both languages and scan the blobs for Pi branding and
# for the wrong entry name (acceptance criterion #5 of work-order #47). The
# linux-native lx_* keys (#48) join the sweep - they must be generic too.
_blob_en=''; _blob_zh=''
for _k in $_pi_en_keys $_lx_en_keys; do
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

# =============================================================================
# Ticket #48 - macvlan-viability guard, EXPECTED_ARCH auto-pin, registry wizard
# =============================================================================

# Snapshot the committed defaults the #48 surfaces read: the guard + wizard may
# only ever write the SANDBOX user .env (acceptance criterion #4).
cp "$ROOT/.env.example" "$TD/snap.env.example"
cp "$ROOT/docker-compose.yml" "$TD/snap.docker-compose.yml"

# --- virt/cloud detection (DEC-A: systemd-detect-virt first, DMI fallback) -------
# The fake systemd-detect-virt is PATH-PREPENDED so it wins even where a real
# one exists; the DMI-fallback fixtures rely on the alpine adjudicator shipping
# NO systemd-detect-virt (same environment assumption as the fake-ss case).
mkdir -p "$TD/virt-bin" "$TD/virt-bin-none" "$TD/dmi-cloud" "$TD/dmi-metal"
printf '#!/bin/sh\necho kvm\nexit 0\n' > "$TD/virt-bin/systemd-detect-virt"
printf '#!/bin/sh\necho none\nexit 1\n' > "$TD/virt-bin-none/systemd-detect-virt"
chmod +x "$TD/virt-bin/systemd-detect-virt" "$TD/virt-bin-none/systemd-detect-virt"
printf 'Amazon EC2\n'     > "$TD/dmi-cloud/sys_vendor"
printf 't3.micro\n'       > "$TD/dmi-cloud/product_name"
printf 'Dell Inc.\n'      > "$TD/dmi-metal/sys_vendor"
printf 'PowerEdge R250\n' > "$TD/dmi-metal/product_name"

_out="$( (PATH="$TD/virt-bin:$PATH"; linux_virt_detect) )" && _rc=0 || _rc=$?
[ "$_rc" = 0 ] && [ "$_out" = kvm ] \
  && ok || fail "virt detect: faked systemd-detect-virt reports kvm (rc=$_rc out=$_out)"
( PATH="$TD/virt-bin-none:$PATH"; linux_virt_detect >/dev/null 2>&1 ) \
  && fail "virt detect: systemd-detect-virt 'none' still flagged virt" || ok
_out="$( (SMG_LX_DMI_DIR="$TD/dmi-cloud"; linux_virt_detect) )" && _rc=0 || _rc=$?
[ "$_rc" = 0 ] && [ -n "$_out" ] \
  && ok || fail "virt detect: DMI fallback flags the Amazon EC2 fixture (rc=$_rc)"
( SMG_LX_DMI_DIR="$TD/dmi-metal"; linux_virt_detect >/dev/null 2>&1 ) \
  && fail "virt detect: bare-metal DMI fixture flagged as virt" || ok

# --- the guard: warn + recommend lite + explicit ack (default No) ----------------
_out="$( (PATH="$TD/virt-bin:$PATH"; INSTALLER_LANG=en
  ui_yesno() { return 0; }
  linux_macvlan_guard 2>&1 && echo GUARD_PROCEEDED) )" || :
assert_contains "guard (virt, acked): proceeds to macvlan" "$_out" 'GUARD_PROCEEDED'
assert_contains "guard: the warning recommends lite mode" "$_out" 'lite'
_out="$( (PATH="$TD/virt-bin:$PATH"; INSTALLER_LANG=en
  ui_yesno() { return 1; }
  linux_macvlan_guard 2>&1 && echo GUARD_PROCEEDED) )" || :
assert_not_contains "guard (virt, declined): does not proceed" "$_out" 'GUARD_PROCEEDED'
_out="$( (SMG_LX_DMI_DIR="$TD/dmi-metal"; INSTALLER_LANG=en
  ui_yesno() { echo ACK_ASKED; return 0; }
  linux_macvlan_guard 2>&1 && echo GUARD_PROCEEDED) )" || :
assert_contains "guard (bare metal): proceeds" "$_out" 'GUARD_PROCEEDED'
assert_not_contains "guard (bare metal): never asks for an ack" "$_out" 'ACK_ASKED'
_out="$( (PATH="$TD/virt-bin:$PATH"; SMG_LX_MACVLAN_ACK=1
  ui_yesno() { echo ACK_ASKED; return 0; }
  linux_macvlan_guard 2>&1 && echo GUARD_PROCEEDED) )" || :
assert_contains "guard (session ack memo): proceeds without re-asking" "$_out" 'GUARD_PROCEEDED'
assert_not_contains "guard (session ack memo): no second ask" "$_out" 'ACK_ASKED'
# write side of the memo: an ACCEPTED ack must itself set SMG_LX_MACVLAN_ACK -
# the guard is called twice in one shell; losing the assignment would re-ask.
_out="$( (PATH="$TD/virt-bin:$PATH"; INSTALLER_LANG=en
  ui_yesno() { echo ACK_ASKED; return 0; }
  linux_macvlan_guard >/dev/null 2>&1
  linux_macvlan_guard 2>&1 && echo GUARD_PROCEEDED) )" || :
assert_contains "guard (memo write side): second call proceeds" "$_out" 'GUARD_PROCEEDED'
assert_not_contains "guard (memo write side): accepted ack sets the memo itself" "$_out" 'ACK_ASKED'

# --- deploy entry: guard wired after the mode wizard; decline steers to lite -----
run_guard_dispatch() {  # $1 = ack answer rc; prints the reached-flow marker
  sh -c '
    PATH="$2/virt-bin:$PATH"; export PATH
    cd "$1" || exit 9
    INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
    export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
    . ./install-linux.sh || exit 9
    ui_say() { :; }; ui_warn() { :; }; ui_info() { :; }; ui_step() { :; }
    _ack="$3"
    ui_yesno() { return "$_ack"; }
    pi_mode_wizard() { PI_MODE=compose; }
    pi_flow_compose() { echo COMPOSE_REACHED; }
    pi_flow_lite() { echo LITE_REACHED; }
    pi_flow_deploy_entry
  ' _ "$ROOT" "$TD" "$1" 2>/dev/null
}
_out="$(run_guard_dispatch 0)" || _out=''
assert_contains "deploy entry (virt, acked): proceeds to the compose flow" "$_out" 'COMPOSE_REACHED'
_out="$(run_guard_dispatch 1)" || _out=''
assert_contains "deploy entry (virt, declined): steers into the lite flow" "$_out" 'LITE_REACHED'
assert_not_contains "deploy entry (virt, declined): compose never runs" "$_out" 'COMPOSE_REACHED'

# --- create_network choke point: redeploy/modify paths funnel through the guard --
# The linux interposition wraps the CAPTURED pi create_network (which itself
# wraps the stock body), so the pi wlan refusal must keep enforcing unchanged.
run_choke() {  # $1 = ack answer rc  $2 = parent iface
  sh -c '
    PATH="$2/virt-bin:$PATH"; export PATH
    cd "$1" || exit 9
    INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
    export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
    . ./install-linux.sh || exit 9
    ui_say() { :; }; ui_warn() { :; }; ui_error() { :; }; ui_info() { :; }
    _ack="$3"
    ui_yesno() { return "$_ack"; }
    pi_stock_create_network() { echo NET_CREATED; }
    CHOSEN_IFACE="$4"
    create_network
  ' _ "$ROOT" "$TD" "$1" "$2" 2>/dev/null
}
_out="$(run_choke 0 eth0)" || _out=''
assert_contains "create_network (virt, acked): delegates to the captured pi body" "$_out" 'NET_CREATED'
_out="$(run_choke 1 eth0)" || _out=''
assert_not_contains "create_network (virt, declined): macvlan creation blocked" "$_out" 'NET_CREATED'
_out="$(run_choke 0 wlan0)" || _out=''
assert_not_contains "create_network: the pi wlan refusal still enforces" "$_out" 'NET_CREATED'

# --- apply_predeployment_cleanup choke point: ack resolves BEFORE any teardown ---
# flow_redeploy, flow_modify's apply branch and setup_network_interactive all
# run apply_predeployment_cleanup first, so a decline here must abort with the
# existing deployment untouched (nothing torn down, no stranding).
run_cleanup_gate() {  # $1 = ack answer rc; prints the reached-cleanup marker
  sh -c '
    PATH="$2/virt-bin:$PATH"; export PATH
    cd "$1" || exit 9
    INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
    export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
    . ./install-linux.sh || exit 9
    ui_say() { :; }; ui_warn() { :; }; ui_info() { :; }
    _ack="$3"
    ui_yesno() { return "$_ack"; }
    lx_stock_apply_predeployment_cleanup() { echo CLEANUP_RAN; }
    apply_predeployment_cleanup
  ' _ "$ROOT" "$TD" "$1" 2>/dev/null
}
_out="$(run_cleanup_gate 0)" || _out=''
assert_contains "predeployment cleanup (virt, acked): delegates to the stock cleanup" "$_out" 'CLEANUP_RAN'
_out="$(run_cleanup_gate 1)" || _out=''
assert_not_contains "predeployment cleanup (virt, declined): nothing is torn down" "$_out" 'CLEANUP_RAN'

# --- one ack covers the real chained choke sequence ------------------------------
# Every deploy-shaped flow runs apply_predeployment_cleanup then create_network
# back to back; a single accepted ack (the session memo) must cover both -
# exactly one ask across the chain, both delegates reached.
_out="$(sh -c '
  PATH="$2/virt-bin:$PATH"; export PATH
  cd "$1" || exit 9
  INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
  export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
  . ./install-linux.sh || exit 9
  ui_say() { :; }; ui_warn() { :; }; ui_error() { :; }; ui_info() { :; }
  ui_yesno() { echo ACK_ASKED; return 0; }
  lx_stock_apply_predeployment_cleanup() { echo CLEANUP_RAN; }
  pi_stock_create_network() { echo NET_CREATED; }
  CHOSEN_IFACE=eth0
  apply_predeployment_cleanup && create_network
' _ "$ROOT" "$TD" 2>/dev/null)" || _out=''
assert_contains "chained choke points: cleanup ran" "$_out" 'CLEANUP_RAN'
assert_contains "chained choke points: network created" "$_out" 'NET_CREATED'
[ "$(printf '%s\n' "$_out" | grep -c ACK_ASKED)" = 1 ] \
  && ok || fail "chained choke points: exactly one ack across cleanup+create_network"

# --- wizard tail drift tripwire: the overlay mirrors the stock body --------------
# wizard_images past the mode pick is deliberately a mirrored copy (the mode
# pick itself is the DEC-4 divergence, and the acr branch adds only the
# pi_acr_arch_notice call); this parity check normalizes both tails - from the
# first REGISTRY_MODE="$_mode" assignment to the closing brace, comments,
# blank lines and the linux-only notice stripped - and fails the moment a
# stock-tail change (creds, tags, cloudflared, update targets) fails to
# propagate to the generic path.
_wt_stock="$(sed -n '/^wizard_images() {$/,/^}$/p' "$ROOT/scripts/installer/wizards.sh" \
  | awk '/^  REGISTRY_MODE="\$_mode"$/ { on = 1 } on { print }' \
  | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e '/pi_acr_arch_notice/d')"
_wt_linux="$(sed -n '/^wizard_images() {$/,/^}$/p' "$ROOT/scripts/linux/preflight_linux.sh" \
  | awk '/^  REGISTRY_MODE="\$_mode"$/ { on = 1 } on { print }' \
  | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e '/pi_acr_arch_notice/d')"
[ -n "$_wt_stock" ] || die "could not extract the stock wizard_images tail (layout changed?)"
[ "$_wt_stock" = "$_wt_linux" ] \
  && ok || fail "overlay wizard_images tail drifted from the stock wizard (normalize + diff them)"

# --- fresh-seed image-ref blanking closes the express-path wizard bypass ---------
# The committed .env.example ships nonempty placeholder ACR refs; unblanked,
# wizard_express + flow_deploy's image gate would treat a fresh seed as
# "already configured" and skip the registry wizard entirely. A JUST-created
# .env must carry blank refs (so env_get fails and the gate falls through to
# wizard_images); an existing .env is never touched.
rm -rf "$TD/seed-data" "$TD/seed-app"
mkdir -p "$TD/seed-data/config" "$TD/seed-app"
cp "$ROOT/.env.example" "$TD/seed-app/.env.example"
( REPO_ROOT="$TD/seed-app"; GATEWAY_DATA_DIR="$TD/seed-data"
  ENV_FILE="$TD/seed-data/.env"
  SUBSCRIPTION_FILE="$TD/seed-data/config/subscription.txt"
  ui_step() { :; }; ui_ok() { :; }
  seed_config ) >/dev/null 2>&1 || :
grep -q '^MIHOMO_IMAGE=""' "$TD/seed-data/.env" 2>/dev/null \
  && ok || fail "fresh seed blanks the placeholder MIHOMO_IMAGE (express-path bypass)"
grep -q '^METACUBEXD_IMAGE=""' "$TD/seed-data/.env" 2>/dev/null \
  && ok || fail "fresh seed blanks the placeholder METACUBEXD_IMAGE"
grep -q '^REGISTRY_MODE=acr' "$TD/seed-data/.env" 2>/dev/null \
  && ok || fail "fresh seed keeps the committed acr default in the seeded copy"
printf 'MIHOMO_IMAGE="docker.io/metacubex/mihomo:v1.19"\n' > "$TD/seed-data/.env"
( REPO_ROOT="$TD/seed-app"; GATEWAY_DATA_DIR="$TD/seed-data"
  ENV_FILE="$TD/seed-data/.env"
  SUBSCRIPTION_FILE="$TD/seed-data/config/subscription.txt"
  ui_step() { :; }; ui_ok() { :; }
  seed_config ) >/dev/null 2>&1 || :
grep -q '^MIHOMO_IMAGE="docker.io/metacubex/mihomo:v1.19"' "$TD/seed-data/.env" 2>/dev/null \
  && ok || fail "seed_config never clobbers an existing configured .env"

# --- EXPECTED_ARCH auto-pin rides the generic compose flow -----------------------
# REPO_ROOT is re-pointed at a sandbox app dir (pi_installer_check precedent) so
# the REAL seed_config + pi_align_expected_arch run without touching the repo;
# the flow_deploy fake snapshots .env at hand-off time, proving the pin lands
# BEFORE the arch gate (pf_arch runs inside flow_deploy).
mkdir -p "$TD/lx-app" "$TD/lx-pin/config"
cp "$ROOT/.env.example" "$TD/lx-app/.env.example"
_out="$( (
  REPO_ROOT="$TD/lx-app"; GATEWAY_DATA_DIR="$TD/lx-pin"
  ENV_FILE="$TD/lx-pin/.env"; CONFIG_STATE_DIR="$TD/lx-pin/config"
  SUBSCRIPTION_FILE="$TD/lx-pin/config/subscription.txt"
  ui_step() { :; }; ui_ok() { :; }; ui_say() { :; }; ui_info() { :; }; ui_warn() { :; }
  host_arch() { echo arm64; }
  pi_wlan_guard() { return 0; }
  linux_macvlan_guard() { return 0; }
  load_env() { :; }
  flow_deploy() { grep "^EXPECTED_ARCH=" "$ENV_FILE"; }
  pi_write_mode_marker() { :; }
  pi_flow_compose
) 2>/dev/null )" || _out=''
case "$_out" in
  *'EXPECTED_ARCH="arm64"'*) ok ;;
  *) fail "generic compose flow pins EXPECTED_ARCH to the host before flow_deploy (got: $_out)" ;;
esac

# --- registry wizard: docker default lands in the USER .env ----------------------
# ui_yesno answers No throughout: on the docker path that also proves the linux
# wizard has NO China-blocked scare-fallback silently flipping back to acr (the
# stock DSM wizard's ask_unfiltered behavior, deliberately dropped by DEC-4).
run_wizard() {  # $1 = menu pick (1 docker | 2 acr); caller pre-seeds the .env
  sh -c '
    cd "$1" || exit 9
    INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
    export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
    . ./install-linux.sh || exit 9
    ENV_FILE="$2/wz-data/.env"
    INSTALLER_LANG=en
    ui_step() { :; }; ui_say() { :; }; ui_ok() { :; }; ui_info() { :; }
    _pick="$3"
    ui_menu_select() { UI_MENU_INDEX="$_pick"; }
    ui_ask() { _wd="$3"; [ -n "$_wd" ] || _wd=testns; eval "$1=\"\$_wd\""; }
    ui_ask_secret() { eval "$1=\"\""; }
    ui_yesno() { return 1; }
    host_arch() { echo arm64; }
    wizard_images
  ' _ "$ROOT" "$TD" "$1" 2>&1
}
rm -rf "$TD/wz-data"; mkdir -p "$TD/wz-data"
cp "$ROOT/.env.example" "$TD/wz-data/.env"
_out="$(run_wizard 1)" || _out=''
grep -q '^REGISTRY_MODE="docker"' "$TD/wz-data/.env" \
  && ok || fail "wizard default: REGISTRY_MODE=docker written to the user .env"
grep -q '^MIHOMO_IMAGE="docker.io/metacubex/mihomo:latest"' "$TD/wz-data/.env" \
  && ok || fail "wizard default: upstream multi-arch mihomo ref derived"
assert_not_contains "wizard default: no acr arch notice on the docker path" "$_out" 'must mirror'
rm -rf "$TD/wz-data"; mkdir -p "$TD/wz-data"
cp "$ROOT/.env.example" "$TD/wz-data/.env"
_out="$(run_wizard 2)" || _out=''
grep -q '^REGISTRY_MODE="acr"' "$TD/wz-data/.env" \
  && ok || fail "wizard acr choice: REGISTRY_MODE=acr written to the user .env"
assert_contains "wizard acr choice on arm64: the arch notice fires" "$_out" 'must mirror'
grep -q '/testns/mihomo:latest' "$TD/wz-data/.env" \
  && ok || fail "wizard acr choice: acr-derived mihomo ref written"

# --- #48 surfaces never modify tracked files -------------------------------------
cmp -s "$ROOT/.env.example" "$TD/snap.env.example" \
  && ok || fail "guard/wizard runs modified the committed .env.example"
cmp -s "$ROOT/docker-compose.yml" "$TD/snap.docker-compose.yml" \
  && ok || fail "guard/wizard runs modified the committed docker-compose.yml"

# --- summary --------------------------------------------------------------------
printf 'linux_installer_check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: install-linux entry + i18n delta overlay + pi-engine dispatch + macvlan guard/auto-pin/registry wizard verified"
