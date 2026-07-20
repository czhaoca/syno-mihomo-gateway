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
#     of which write ONLY the sandbox user .env, never a tracked file;
#   * (#50) the platform-conditional remediation phrasing (DEC-A plain vars):
#     both entries set + export INSTALLER_ENTRY/PLATFORM_LABEL, generic runs
#     of the shared hint/remediation surfaces name install-linux.sh with no
#     DSM UI wording, and the unset default keeps every DSM string
#     byte-identical (golden compares pin the literals);
#   * (#53) the stock-catalog DSM/NAS keys that transit the generic path
#     (preflight, wizards, flow_deploy diagnostics + report) resolve to
#     generic phrasing through the linux chain (en+zh, stock %s arity kept),
#     and flow_deploy's two hardcoded platform literals (the non-root rerun
#     hint, the report IP placeholder) follow the platform vars with the DSM
#     output golden-pinned.
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
_stock_en_keys="$(sed -n '/^_msg_en()/,/^}/p' "$ROOT/scripts/installer/i18n.sh" | sed -n 's/^    \([a-z0-9_]*\)).*/\1/p' | sort)"
[ -n "$_stock_en_keys" ] || die "could not extract the stock key list"
# lx_-prefixed keys are linux-NATIVE additions (#48 guard/wizard phrasing), not
# overrides - they are exempt from the membership check; every other key must
# exist in the pi table or the stock catalog (#53 widened the invariant: the
# DSM/NAS wording overrides target stock keys, which the pi table never
# carried) - a typo'd override would silently never fire.
_lx_orphans=''
for _k in $_lx_en_keys; do
  case "$_k" in lx_*) continue ;; esac
  printf '%s\n%s\n' "$_pi_en_keys" "$_stock_en_keys" | grep -qx "$_k" \
    || _lx_orphans="$_lx_orphans $_k"
done
[ -z "$_lx_orphans" ] \
  && ok || fail "delta overlay overrides keys absent from the pi + stock tables:$_lx_orphans"

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

# --- #53: reachable stock DSM/NAS keys resolve generic through the linux chain ---
# The reachability audit (work-order #53, Task 1 + panel cycle 1): stock-
# catalog keys with DSM/NAS wording OR an embedded DSM entry name that fire
# on flows the generic entry reaches - preflight (pf_docker/pf_arch, via
# deploy AND Modify), pi_check_location (diag_resolve_self_fix), the wizards
# (wizard_express / wizard_env), and flow_deploy's diagnostics + success
# report (incl. the filtered-group finding, diag_pg_default_fix). Verified
# NOT reachable from install-linux.sh, so deliberately absent:
# check_location's other keys (the entry calls pi_check_location),
# rerun_dsm_hint (sudo_rerun_hint is overlaid), ask_unfiltered (the overlay
# wizard_images drops the stock scare-fallback, #48 DEC-4), and the whole
# flow_cron.sh cluster (pi_flow_cron is crontab-only). The stock catalog
# legitimately keeps DSM wording for the DSM-only keys, so the sweep is
# scoped to exactly this audited set.
_53_keys='diag_no_docker_fix diag_resolve_self_fix warn_arch
info_ip_suggest_scan q_web_port diag_pull_fail_fix diag_arch_mismatch_fix
diag_auto_redirect rep_dashboard rep_warn_isolation rep_reach_test
diag_pg_default_fix'
_blob53_en=''; _blob53_zh=''
for _k in $_53_keys; do
  _r_en="$( (INSTALLER_LANG=en; msg "$_k") )"
  _r_zh="$( (INSTALLER_LANG=zh; msg "$_k") )"
  { [ -n "$_r_en" ] && [ "$_r_en" != "$_k" ] && [ -n "$_r_zh" ] && [ "$_r_zh" != "$_k" ]; } \
    && ok || fail "#53 reachable key resolves in both languages: $_k"
  # %s arity must match the stock template - the call sites pass stock-arity args
  _n_en="$(printf '%s' "$_r_en" | grep -o '%s' | wc -l | tr -d ' 	')"
  _n_zh="$(printf '%s' "$_r_zh" | grep -o '%s' | wc -l | tr -d ' 	')"
  _n_st="$(printf '%s' "$( (INSTALLER_LANG=en; _msg_en "$_k") )" | grep -o '%s' | wc -l | tr -d ' 	')"
  { [ "$_n_en" = "$_n_st" ] && [ "$_n_zh" = "$_n_st" ]; } \
    && ok || fail "#53 $_k: %s arity drifted (en=$_n_en zh=$_n_zh stock=$_n_st)"
  _blob53_en="$_blob53_en
$_r_en"
  _blob53_zh="$_blob53_zh
$_r_zh"
done
for _needle in 'DSM' 'NAS' 'Container Manager' './install.sh'; do
  assert_not_contains "en reachable stock keys clean of: $_needle" "$_blob53_en" "$_needle"
done
for _needle in 'DSM' 'NAS' '群晖' 'Container Manager' './install.sh'; do
  assert_not_contains "zh reachable stock keys clean of: $_needle" "$_blob53_zh" "$_needle"
done
# One real call site end to end: pf_arch's diagnose rides the overridden key.
_out="$( (INSTALLER_LANG=en; EXPECTED_ARCH=mips; host_arch() { echo amd64; }; pf_arch) 2>&1 )" || :
assert_contains "pf_arch (generic chain): host wording" "$_out" "this host is 'amd64'"
assert_not_contains "pf_arch (generic chain): no NAS wording" "$_out" 'NAS'

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
# Anchor to the full echo text: the bare 'sh ./install-linux.sh' needle also
# lives in the entry's header comment, which made this check tautological
# (review round: deleting the runtime hint still passed).
expect_success "non-TTY hint names install-linux.sh" \
  grep -q 'interactive - run it in a terminal:  sh ./install-linux.sh' "$ROOT/install-linux.sh"

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

# =============================================================================
# Ticket #50 - platform-conditional remediation phrasing (INSTALLER_ENTRY +
# PLATFORM_LABEL, DEC-A: plain vars). Vars set to the linux entry -> the
# shared runtime hints name install-linux.sh and drop the DSM UI wording;
# vars UNSET -> byte-identical DSM text (golden compares pin the literals).
# =============================================================================

# --- the entries set + export both platform vars ---------------------------------
run_entry_vars() {  # $1 = entry file; prints parent|child views of both vars
  sh -c '
    cd "$1" || exit 9
    INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
    export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
    . "./$2" || exit 9
    printf "%s|%s|" "${INSTALLER_ENTRY:-}" "${PLATFORM_LABEL:-}"
    sh -c "printf \"%s|%s\" \"\${INSTALLER_ENTRY:-}\" \"\${PLATFORM_LABEL:-}\""
  ' _ "$ROOT" "$1" 2>/dev/null
}
_out="$(run_entry_vars install-linux.sh)" || _out=''
[ "$_out" = 'install-linux.sh|linux|install-linux.sh|linux' ] \
  && ok || fail "install-linux.sh sets + exports the platform vars (got: $_out)"
_out="$(run_entry_vars install-pi.sh)" || _out=''
[ "$_out" = 'install-pi.sh|pi|install-pi.sh|pi' ] \
  && ok || fail "install-pi.sh sets + exports the platform vars (got: $_out)"

# --- the menu loop persists the platform vars into an existing user .env ---------
run_persist_menu() {  # $1 = ENV_FILE for the sandboxed menu run
  sh -c '
    cd "$1" || exit 9
    INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
    export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
    . ./install-linux.sh || exit 9
    ENV_FILE="$2"
    _lm_banner() { :; }
    ui_say() { :; }
    ui_menu_select() { UI_MENU_INDEX=6; }
    main_menu_linux
  ' _ "$ROOT" "$1" >/dev/null 2>&1
}
printf 'TUN_ENABLE=true\n' > "$TD/pv50.env"
run_persist_menu "$TD/pv50.env" || :
grep -q '^INSTALLER_ENTRY="install-linux.sh"' "$TD/pv50.env" \
  && ok || fail "menu loop persists INSTALLER_ENTRY into the user .env"
grep -q '^PLATFORM_LABEL="linux"' "$TD/pv50.env" \
  && ok || fail "menu loop persists PLATFORM_LABEL into the user .env"
grep -q '^TUN_ENABLE=true' "$TD/pv50.env" \
  && ok || fail "persistence keeps the existing .env content"
run_persist_menu "$TD/pv50-none.env" || :
[ ! -f "$TD/pv50-none.env" ] \
  && ok || fail "persistence never creates a missing .env (seed_config owns that)"

# --- checks.sh hint family: generic phrasing with the vars set -------------------
mkdir -p "$TD/p50-cfg"
printf 'reason: render-failed\ntime: 2026-07-17T00:00:00\n' > "$TD/p50-cfg/.config.yaml.rejected"
_out="$( (
  . "$ROOT/scripts/lib/checks.sh"
  INSTALLER_ENTRY=install-linux.sh PLATFORM_LABEL=linux
  ENV_FILE="$TD/p50-absent.env"
  chk_env; printf '%s\n%s\n' "$CHECK_DETAIL" "$CHECK_HINT"
  resolv_conf_probe() { printf 'no-answer 192.0.2.53'; return 1; }
  chk_host_dns; printf '%s\n' "$CHECK_DETAIL"
  CONFIG_STATE_DIR="$TD/p50-cfg"
  chk_config_rejected; printf '%s\n' "$CHECK_HINT"
  scheduler_task_deployed() { return 1; }
  chk_update_task; printf '%s\n' "$CHECK_DETAIL"
  chk_boot_task; printf '%s\n' "$CHECK_DETAIL"
) 2>/dev/null )" || _out=''
assert_contains "chk_env (generic): hint names the linux entry" "$_out" 'run: sudo sh ./install-linux.sh'
assert_not_contains "chk_env (generic): no DSM entry name" "$_out" './install.sh'
assert_contains "chk_host_dns (generic): points at the host resolver config" "$_out" '/etc/resolv.conf'
assert_contains "chk_config_rejected (generic): redeploy hint names the linux entry" "$_out" 'redeploy: sudo sh ./install-linux.sh (Redeploy)'
assert_contains "chk_update_task (generic): points at the CLI crontab path" "$_out" 'gateway.sh cron --apply-crontab'
assert_not_contains "chk_update_task (generic): no install_scheduler pointer" "$_out" 'install_scheduler'
assert_contains "chk_boot_task (generic): boot task wording" "$_out" 'no boot task runs scripts/setup_network.sh'
assert_not_contains "checks.sh (generic): hint family clean of DSM" "$_out" 'DSM'
assert_not_contains "checks.sh (generic): no Boot-up branding" "$_out" 'Boot-up'

# --- checks.sh golden: vars unset = byte-identical DSM text ----------------------
_g="$( (
  . "$ROOT/scripts/lib/checks.sh"
  unset INSTALLER_ENTRY PLATFORM_LABEL
  ENV_FILE="$TD/p50-absent.env"
  chk_env; printf '%s' "$CHECK_HINT"
) 2>/dev/null )" || _g=''
[ "$_g" = '      the release tree is unpacked but not configured - run: sudo sh ./install.sh' ] \
  && ok || fail "golden: chk_env DSM hint byte-identical (got: $_g)"
_g="$( (
  . "$ROOT/scripts/lib/checks.sh"
  unset INSTALLER_ENTRY PLATFORM_LABEL
  resolv_conf_probe() { printf 'no-answer 192.0.2.53'; return 1; }
  chk_host_dns; printf '%s' "$CHECK_DETAIL"
) 2>/dev/null )" || _g=''
[ "$_g" = 'host DNS resolver(s) not answering: 192.0.2.53 - set reachable resolvers in DSM Control Panel > Network (domestic ones on a filtered network)' ] \
  && ok || fail "golden: chk_host_dns DSM detail byte-identical (got: $_g)"
_g="$( (
  . "$ROOT/scripts/lib/checks.sh"
  unset INSTALLER_ENTRY PLATFORM_LABEL
  scheduler_task_deployed() { return 1; }
  chk_update_task; printf '%s\n' "$CHECK_DETAIL"
  chk_boot_task; printf '%s' "$CHECK_DETAIL"
) 2>/dev/null )" || _g=''
[ "$_g" = 'no scheduled task runs scripts/auto_update.sh - see: sh scripts/install_scheduler.sh
no Boot-up task runs scripts/setup_network.sh - TUN/macvlan will not self-heal after a reboot' ] \
  && ok || fail "golden: chk_update_task/chk_boot_task DSM details byte-identical (got: $_g)"
_g="$( (
  . "$ROOT/scripts/lib/checks.sh"
  unset INSTALLER_ENTRY PLATFORM_LABEL
  CONFIG_STATE_DIR="$TD/p50-cfg"
  chk_config_rejected; printf '%s' "$CHECK_HINT"
) 2>/dev/null )" || _g=''
[ "$_g" = '      read the scrubbed marker: cat <data-dir>/config/.config.yaml.rejected - fix the named value in .env, then redeploy: sudo sh ./install.sh (Redeploy); a green render clears this automatically' ] \
  && ok || fail "golden: chk_config_rejected DSM hint byte-identical (got: $_g)"

# --- the remaining redeploy-hint sites (panel cycle-1 advisory: revert-proof) ----
# chk_dns_privacy (v1 residual), chk_full_proxy (parity drift) and
# chk_proxy_groups (default-empty) each carry the ${INSTALLER_ENTRY} hint;
# cover every one so a revert of any single site fails CI.
mkdir -p "$TD/p50-dnsv1"
printf "    'geosite:cn':\n  fallback:\n" > "$TD/p50-dnsv1/config.yaml"
run_hint_trio() {  # $1 = 'set'|'unset'; prints the three hints
  (
    . "$ROOT/scripts/lib/checks.sh"
    if [ "$1" = set ]; then
      INSTALLER_ENTRY=install-linux.sh PLATFORM_LABEL=linux
    else
      unset INSTALLER_ENTRY PLATFORM_LABEL
    fi
    CONFIG_STATE_DIR="$TD/p50-dnsv1"
    chk_dns_privacy; printf '%s\n' "$CHECK_HINT"
    FULL_PROXY_SOURCES='192.0.2.10'
    chk_full_proxy; printf '%s\n' "$CHECK_HINT"
    _pg_ctl() {
      case "$1" in
        /group) printf '{"proxies":[{"name":"Country Pick"},{"name":"JP Auto"},{"name":"US Auto"}]}' ;;
        *) printf '{"now":"JP Auto","all":["REJECT"]}' ;;
      esac
    }
    _pg_real() { case "$1" in 'JP Auto') echo 0 ;; *) echo 3 ;; esac; }
    chk_proxy_groups; printf '%s\n' "$CHECK_HINT"
  ) 2>/dev/null
}
_out="$(run_hint_trio set)" || _out=''
assert_contains "chk_dns_privacy (generic): v1 hint names the linux entry" "$_out" 're-render onto the v2 core: sudo sh ./install-linux.sh (Redeploy)'
assert_contains "chk_full_proxy (generic): drift hint names the linux entry" "$_out" 're-render: sudo sh ./install-linux.sh (Redeploy)'
assert_contains "chk_proxy_groups (generic): default-empty hint names the linux entry" "$_out" 'redeploy: sudo sh ./install-linux.sh (Redeploy)'
assert_not_contains "hint trio (generic): no DSM entry name" "$_out" './install.sh'
_g="$(run_hint_trio unset)" || _g=''
assert_contains "golden: chk_dns_privacy DSM v1 hint" "$_g" 're-render onto the v2 core: sudo sh ./install.sh (Redeploy)'
assert_contains "golden: chk_full_proxy DSM drift hint" "$_g" 're-render: sudo sh ./install.sh (Redeploy); if the render was refused, config_rejected names the reason'
assert_contains "golden: chk_proxy_groups DSM default-empty hint" "$_g" 'redeploy: sudo sh ./install.sh (Redeploy); stopgap: pick another country in the dashboard Country Pick selector'

# --- checks.sh remaining hint sites: parse-fail .env + legacy DNS profile --------
# (review round: neither branch was exercised in either platform mode - a
# revert of either hint to a hardcoded install.sh shipped silently)
printf 'THIS LINE DOES NOT PARSE\n' > "$TD/p50-bad.env"
mkdir -p "$TD/p50-legacy"
printf 'rules:\n' > "$TD/p50-legacy/config.yaml"
run_hint_pair() {  # $1 = 'set'|'unset'; prints chk_env detail + dns hint
  (
    . "$ROOT/scripts/lib/checks.sh"
    if [ "$1" = set ]; then
      INSTALLER_ENTRY=install-linux.sh PLATFORM_LABEL=linux
    else
      unset INSTALLER_ENTRY PLATFORM_LABEL
    fi
    ENV_FILE="$TD/p50-bad.env"
    chk_env; printf '%s\n' "$CHECK_DETAIL"
    CONFIG_STATE_DIR="$TD/p50-legacy"
    chk_dns_privacy; printf '%s\n' "$CHECK_HINT"
  ) 2>/dev/null
}
_out="$(run_hint_pair set)" || _out=''
assert_contains "chk_env parse-fail (generic): re-run names the linux entry" "$_out" 'does not parse - fix the reported line or re-run: sudo sh ./install-linux.sh'
assert_contains "chk_dns_privacy legacy (generic): re-render names the linux entry" "$_out" 'stale pre-v2 render is on disk - re-render onto the v2 core: sudo sh ./install-linux.sh (Redeploy)'
assert_not_contains "parse-fail/legacy pair (generic): no DSM entry name" "$_out" './install.sh'
_g="$(run_hint_pair unset)" || _g=''
assert_contains "golden: chk_env parse-fail DSM re-run hint" "$_g" 'does not parse - fix the reported line or re-run: sudo sh ./install.sh'
assert_contains "golden: chk_dns_privacy legacy DSM hint" "$_g" 're-render onto the v2 core: sudo sh ./install.sh (Redeploy)'
assert_not_contains "golden: parse-fail/legacy pair clean of linux entry" "$_g" 'install-linux.sh'

# --- registry.sh phrase sites: generic wording (functions are in-process) --------
_out="$( (
  PLATFORM_LABEL=linux
  LOG_FILE=/dev/null
  DOCKER_BIN=/nonexistent-docker
  docker_daemon_ready || :
  detect_compose() { return 1; }
  wait_for_docker_ready 1 1 || :
  check_network || :
  EXPECTED_ARCH=mips
  check_arch_expectation || :
  TUN_AUTO_REDIRECT=true MIHOMO_IMAGE=reg.example/m:l
  mihomo_auto_redirect_probe || :
) 2>&1 )" || _out=''
assert_contains "docker_daemon_ready (generic): names the Docker service" "$_out" 'start the Docker service and run this task as root'
assert_contains "wait_for_docker_ready (generic): waits for Docker" "$_out" 'waiting for Docker (0s/1s)'
assert_contains "check_network (generic): boot wording" "$_out" '(or schedule it at boot)'
assert_contains "check_arch_expectation (generic): host wording" "$_out" 'but this host is'
assert_contains "auto_redirect probe (generic): host kernel wording" "$_out" 'incompatible with this host kernel/image'
assert_not_contains "registry.sh (generic): clean of Container Manager" "$_out" 'Container Manager'
assert_not_contains "registry.sh (generic): clean of DSM" "$_out" 'DSM'
assert_not_contains "registry.sh (generic): clean of NAS" "$_out" 'NAS'

# --- registry.sh golden: vars unset = byte-identical DSM text --------------------
_g="$( (
  unset INSTALLER_ENTRY PLATFORM_LABEL
  LOG_FILE=/dev/null
  DOCKER_BIN=/nonexistent-docker
  docker_daemon_ready || :
  detect_compose() { return 1; }
  wait_for_docker_ready 1 1 || :
  check_network || :
  EXPECTED_ARCH=mips
  check_arch_expectation || :
  TUN_AUTO_REDIRECT=true MIHOMO_IMAGE=reg.example/m:l
  mihomo_auto_redirect_probe || :
) 2>&1 )" || _g=''
assert_contains "golden: docker_daemon_ready DSM text" "$_g" 'Docker daemon is unavailable; start Container Manager and run this task as root'
assert_contains "golden: wait_for_docker_ready DSM text" "$_g" 'waiting for Container Manager/Docker (0s/1s)'
assert_contains "golden: check_network DSM text" "$_g" "docker network 'tproxy_network' not found. Run scripts/setup_network.sh (or add a DSM boot-up task)."
assert_contains "golden: check_arch_expectation DSM text" "$_g" 'EXPECTED_ARCH=mips but this NAS is'
assert_contains "golden: auto_redirect probe DSM text" "$_g" 'TUN auto-redirect is incompatible with this DSM kernel/image; set TUN_AUTO_REDIRECT=false'
# Additive-leak pins (review round): the goldens above are substring checks,
# so a generic line ADDED to the DSM branch would pass them - prove the unset
# run is also clean of every generic-only needle.
for _needle in 'start the Docker service' 'waiting for Docker (' \
    '(or schedule it at boot)' 'but this host is' 'this host kernel/image'; do
  assert_not_contains "golden: registry.sh DSM output clean of: $_needle" "$_g" "$_needle"
done

# --- installer preflight pf_docker: diagnose text follows the platform -----------
_out="$( (
  PLATFORM_LABEL=linux INSTALLER_LANG=en
  detect_compose() { DOCKER_BIN=/nonexistent-docker; return 0; }
  pf_docker || :
) 2>&1 )" || _out=''
assert_contains "pf_docker (generic): names the Docker service" "$_out" 'start the Docker service and run this installer as root'
assert_not_contains "pf_docker (generic): no Container Manager" "$_out" 'Container Manager'
_g="$( (
  unset INSTALLER_ENTRY PLATFORM_LABEL
  INSTALLER_LANG=en
  detect_compose() { DOCKER_BIN=/nonexistent-docker; return 0; }
  pf_docker || :
) 2>&1 )" || _g=''
assert_contains "golden: pf_docker DSM text" "$_g" 'start Container Manager and run this installer as root'
assert_not_contains "golden: pf_docker DSM clean of generic phrasing" "$_g" 'start the Docker service'

# --- notify.sh: the undelivered-notification warn follows the platform -----------
_out="$( (
  . "$ROOT/scripts/lib/notify.sh"
  PLATFORM_LABEL=linux LOG_FILE=/dev/null NOTIFY_WEBHOOK_URL=''
  notify 'T50' 'body' || :
) 2>&1 )" || _out=''
assert_contains "notify (generic): undelivered warn keeps the webhook advice" "$_out" 'set NOTIFY_WEBHOOK_URL'
assert_not_contains "notify (generic): no DSM Task Scheduler advice" "$_out" 'DSM'
_g="$( (
  . "$ROOT/scripts/lib/notify.sh"
  unset INSTALLER_ENTRY PLATFORM_LABEL
  LOG_FILE=/dev/null NOTIFY_WEBHOOK_URL=''
  notify 'T50' 'body' || :
) 2>&1 )" || _g=''
assert_contains "golden: notify undelivered DSM advice" "$_g" \
  "notification NOT delivered - enable DSM Task Scheduler 'send run details' email or set NOTIFY_WEBHOOK_URL in .env"
assert_not_contains "golden: notify DSM clean of generic scheduler advice" "$_g" 'cron MAILTO'

# --- gateway.sh CLI: cron print, crontab hint, missing-.env hint, status IP ------
mkdir -p "$TD/gw50-data"
printf 'PARENT_INTERFACE="nonexist0"\n' > "$TD/gw50.env"
printf 'PARENT_INTERFACE="nonexist0"\nPLATFORM_LABEL="linux"\nINSTALLER_ENTRY="install-linux.sh"\n' > "$TD/gw50b.env"
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50.env" \
    INSTALLER_ENTRY=install-linux.sh PLATFORM_LABEL=linux \
    sh "$ROOT/scripts/gateway.sh" cron 2>&1)" || :
assert_contains "gateway cron (generic env vars): scheduler-neutral print" "$_out" 'Scheduled-task command:'
assert_not_contains "gateway cron (generic): no DSM Task Scheduler" "$_out" 'DSM Task Scheduler'
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50b.env" \
    sh "$ROOT/scripts/gateway.sh" cron 2>&1)" || :
assert_contains "gateway cron (.env-borne vars): the persisted keys drive the text" "$_out" 'Scheduled-task command:'
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50.env" \
    sh "$ROOT/scripts/gateway.sh" cron 2>&1)" || :
assert_contains "golden: gateway cron DSM print" "$_out" 'DSM Task Scheduler command: '
assert_not_contains "golden: gateway cron DSM clean of generic print" "$_out" 'Scheduled-task command:'
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50b.env" CRONTAB_FILE="$TD/no-such-crontab" \
    sh "$ROOT/scripts/gateway.sh" cron --apply-crontab --yes 2>&1)" || :
assert_contains "gateway --apply-crontab (generic): cron/systemd hint" "$_out" 'schedule scripts/auto_update.sh'
assert_not_contains "gateway --apply-crontab (generic): no DSM Task Scheduler" "$_out" 'DSM Task Scheduler'
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50.env" CRONTAB_FILE="$TD/no-such-crontab" \
    sh "$ROOT/scripts/gateway.sh" cron --apply-crontab --yes 2>&1)" || :
assert_contains "golden: gateway --apply-crontab DSM hint" "$_out" 'use DSM Task Scheduler (sh scripts/install_scheduler.sh)'
assert_not_contains "golden: gateway --apply-crontab DSM clean of generic hint" "$_out" 'schedule scripts/auto_update.sh'
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50-none.env" INSTALLER_ENTRY=install-linux.sh \
    sh "$ROOT/scripts/gateway.sh" deploy --dry-run 2>&1)" || :
assert_contains "gateway missing-.env (generic): names the linux entry" "$_out" "run 'sh ./install-linux.sh' once"
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50-none.env" \
    sh "$ROOT/scripts/gateway.sh" deploy --dry-run 2>&1)" || :
assert_contains "golden: gateway missing-.env DSM hint" "$_out" "run 'sh ./install.sh' once, or create it from .env.example"
assert_not_contains "golden: gateway missing-.env DSM clean of linux entry" "$_out" 'install-linux.sh'
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50.env" PLATFORM_LABEL=linux \
    sh "$ROOT/scripts/gateway.sh" status 2>&1)" || :
assert_contains "gateway status (generic): host-IP placeholder" "$_out" '<host-IP>'
assert_not_contains "gateway status (generic): no NAS-IP placeholder" "$_out" '<NAS-IP>'
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50.env" \
    sh "$ROOT/scripts/gateway.sh" status 2>&1)" || :
assert_contains "golden: gateway status NAS-IP placeholder" "$_out" '<NAS-IP>'
assert_not_contains "golden: gateway status DSM clean of host-IP placeholder" "$_out" '<host-IP>'
# _gw_report (the deploy-path placeholder twin; gateway_cli_check stubs it, so
# it gets its own sourced-mode coverage here - panel cycle-1 advisory)
run_gw_report() {  # $1 = 'set'|'unset'
  (
    GATEWAY_SOURCE_ONLY=1
    GATEWAY_SELF_DIR="$ROOT/scripts"
    export GATEWAY_SOURCE_ONLY GATEWAY_SELF_DIR
    . "$ROOT/scripts/gateway.sh"
    if [ "$1" = set ]; then PLATFORM_LABEL=linux; else unset PLATFORM_LABEL INSTALLER_ENTRY; fi
    LOG_FILE=/dev/null
    detect_parent_interface() { :; }
    _iface_ipv4() { :; }
    PARENT_INTERFACE='' MIHOMO_IP=192.0.2.2
    _gw_report
  ) 2>/dev/null
}
_out="$(run_gw_report set)" || _out=''
assert_contains "_gw_report (generic): host-IP placeholder" "$_out" '<host-IP>'
assert_not_contains "_gw_report (generic): no NAS-IP placeholder" "$_out" '<NAS-IP>'
_g="$(run_gw_report unset)" || _g=''
assert_contains "golden: _gw_report NAS-IP placeholder" "$_g" 'dashboard: http://<NAS-IP>:8080'
assert_not_contains "golden: _gw_report DSM clean of host-IP placeholder" "$_g" '<host-IP>'

# --- doctor.sh end to end: the generic run is clean of every DSM needle ----------
# CONFIG_STATE_DIR/SUBSCRIPTION_FILE are pinned to an empty sandbox: the suite
# process exports its own (common.sh:28), and a dev machine's real data dir
# would otherwise leak state into the doctor output.
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50-none.env" \
    CONFIG_STATE_DIR="$TD/gw50-cfg" SUBSCRIPTION_FILE="$TD/gw50-cfg/subscription.txt" \
    INSTALLER_ENTRY=install-linux.sh PLATFORM_LABEL=linux \
    sh "$ROOT/scripts/doctor.sh" 2>&1)" || :
assert_contains "doctor (generic): entry hint names install-linux.sh" "$_out" 'run: sudo sh ./install-linux.sh'
for _needle in 'DSM Control Panel' 'Container Manager' 'DSM Task Scheduler' 'this NAS' 'Boot-up task'; do
  assert_not_contains "doctor (generic): clean of: $_needle" "$_out" "$_needle"
done
_out="$(GATEWAY_DATA_DIR="$TD/gw50-data" ENV_FILE="$TD/gw50-none.env" \
    CONFIG_STATE_DIR="$TD/gw50-cfg" SUBSCRIPTION_FILE="$TD/gw50-cfg/subscription.txt" \
    sh "$ROOT/scripts/doctor.sh" 2>&1)" || :
assert_contains "golden: doctor DSM entry hint" "$_out" 'run: sudo sh ./install.sh'
assert_not_contains "golden: doctor DSM clean of linux entry" "$_out" 'install-linux.sh'

# --- auto_update.sh abort notice: the notify body follows the platform -----------
# The webhook payload is the only place the notify BODY surfaces; a PATH-
# appended fake curl records it (auto_update.sh PREPENDS the system dirs, and
# the alpine CI adjudicator ships no real curl - same environment assumption
# as the fake-ss case above). DOCKER_READY_TIMEOUT=0 + no docker binary makes
# the preflight abort at wait_for_docker_ready deterministically.
mkdir -p "$TD/au50-data" "$TD/au50-bin"
cat > "$TD/au50-bin/curl" <<'EOF'
#!/bin/sh
_prev=''
for _a in "$@"; do
  [ "$_prev" = '-d' ] && printf '%s\n' "$_a" >> "${SMG_T50_PAYLOAD:?}"
  _prev="$_a"
done
cat >/dev/null
exit 0
EOF
chmod +x "$TD/au50-bin/curl"
au50_env() {  # $1 = extra .env lines appended to the valid updater fixture
  {
    printf 'UPDATE_ENABLED=true\nPULL_RETRIES=1\nPULL_RETRY_DELAY=0\n'
    printf 'DOCKER_READY_TIMEOUT=0\nDOCKER_READY_INTERVAL=1\n'
    printf 'HEALTH_RETRIES=1\nHEALTH_INTERVAL=0\nHEALTH_MAX_RESTARTS=1\n'
    printf 'CF_HEALTH_TIMEOUT=1\nLOG_KEEP=1\nLOG_MAX_BYTES=99999\n'
    printf 'TUN_AUTO_REDIRECT=false\nEXPECTED_ARCH=amd64\n'
    printf 'MIHOMO_IMAGE="reg.example/m:l"\nMETACUBEXD_IMAGE="reg.example/u:l"\n'
    printf 'UPDATE_IMAGES="reg.example/m:l reg.example/u:l"\n'
    printf 'NOTIFY_WEBHOOK_URL="http://127.0.0.1:9/hook"\n'
    printf '%s' "$1"
  } > "$TD/au50-data/.env"
}
au50_env 'PLATFORM_LABEL="linux"
INSTALLER_ENTRY="install-linux.sh"
'
: > "$TD/au50-payload-gx"
( GATEWAY_DATA_DIR="$TD/au50-data" ENV_FILE="$TD/au50-data/.env" \
  SMG_T50_PAYLOAD="$TD/au50-payload-gx" \
  PATH="$PATH:$TD/au50-bin" sh "$ROOT/scripts/auto_update.sh" --dry-run ) >/dev/null 2>&1 || :
grep -q 'Docker did not become ready.' "$TD/au50-payload-gx" 2>/dev/null \
  && ok || fail "auto_update (generic .env): abort notice drops Container Manager"
grep -q 'Container Manager' "$TD/au50-payload-gx" 2>/dev/null \
  && fail "auto_update (generic .env): notify body still names Container Manager" || ok
au50_env ''
: > "$TD/au50-payload-dsm"
( GATEWAY_DATA_DIR="$TD/au50-data" ENV_FILE="$TD/au50-data/.env" \
  SMG_T50_PAYLOAD="$TD/au50-payload-dsm" \
  PATH="$PATH:$TD/au50-bin" sh "$ROOT/scripts/auto_update.sh" --dry-run ) >/dev/null 2>&1 || :
grep -q 'Container Manager/Docker did not become ready.' "$TD/au50-payload-dsm" 2>/dev/null \
  && ok || fail "golden: auto_update DSM abort notice byte-identical"
# The EXPECTED_ARCH abort notice (panel cycle-1 advisory): a fake docker that
# satisfies the readiness gate lets the run reach check_arch_expectation,
# where EXPECTED_ARCH=mips can never match a real host.
cat > "$TD/au50-bin/docker" <<'EOF'
#!/bin/sh
case "$1" in compose) exit 0 ;; info) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$TD/au50-bin/docker"
au50_env 'EXPECTED_ARCH=mips
PLATFORM_LABEL="linux"
INSTALLER_ENTRY="install-linux.sh"
'
: > "$TD/au50-payload-arch-gx"
( GATEWAY_DATA_DIR="$TD/au50-data" ENV_FILE="$TD/au50-data/.env" \
  SMG_T50_PAYLOAD="$TD/au50-payload-arch-gx" \
  PATH="$PATH:$TD/au50-bin" sh "$ROOT/scripts/auto_update.sh" --dry-run ) >/dev/null 2>&1 || :
grep -q 'EXPECTED_ARCH does not match this host.' "$TD/au50-payload-arch-gx" 2>/dev/null \
  && ok || fail "auto_update (generic .env): arch abort notice says host"
grep -q 'this NAS' "$TD/au50-payload-arch-gx" 2>/dev/null \
  && fail "auto_update (generic .env): arch abort notice still says NAS" || ok
au50_env 'EXPECTED_ARCH=mips
'
: > "$TD/au50-payload-arch-dsm"
( GATEWAY_DATA_DIR="$TD/au50-data" ENV_FILE="$TD/au50-data/.env" \
  SMG_T50_PAYLOAD="$TD/au50-payload-arch-dsm" \
  PATH="$PATH:$TD/au50-bin" sh "$ROOT/scripts/auto_update.sh" --dry-run ) >/dev/null 2>&1 || :
grep -q 'EXPECTED_ARCH does not match this NAS.' "$TD/au50-payload-arch-dsm" 2>/dev/null \
  && ok || fail "golden: auto_update DSM arch abort notice byte-identical"
rm -f "$TD/au50-bin/docker"

# --- setup_network.sh: the inconsistency abort names the platform entry ----------
# The fake docker (PATH-prepended) satisfies detect_compose + daemon_ready, and
# the invalid subnet/router pair forces the validate_network_plan abort. The
# end-to-end run must first pass ensure_tun_device, which needs a REAL
# /dev/net/tun: local docker grants CAP_MKNOD, but Woodpecker step containers
# do not - so best-effort create the device and SKIP when the environment
# cannot (gateway_cli_check doctor-parity precedent); the local docker
# adjudicator (docs/development.md) keeps full coverage.
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net 2>/dev/null || :
  mknod /dev/net/tun c 10 200 2>/dev/null || :
fi
if [ -c /dev/net/tun ]; then

mkdir -p "$TD/sn50-data" "$TD/sn50-bin"
cat > "$TD/sn50-bin/docker" <<'EOF'
#!/bin/sh
case "$1" in compose) exit 0 ;; info) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$TD/sn50-bin/docker"
printf 'PARENT_INTERFACE="nonexist0"\nSUBNET_CIDR="299.0.0.0/33"\nROUTER_IP="not-an-ip"\nPLATFORM_LABEL="linux"\nINSTALLER_ENTRY="install-linux.sh"\n' \
  > "$TD/sn50-data/.env"
_out="$( ( GATEWAY_DATA_DIR="$TD/sn50-data" ENV_FILE="$TD/sn50-data/.env" \
  PATH="$TD/sn50-bin:$PATH" \
  sh "$ROOT/scripts/setup_network.sh" ) 2>&1 )" || :
assert_contains "setup_network (generic .env): abort names the linux entry" "$_out" 'sh ./install-linux.sh'
assert_not_contains "setup_network (generic .env): no DSM entry name" "$_out" './install.sh'
printf 'PARENT_INTERFACE="nonexist0"\nSUBNET_CIDR="299.0.0.0/33"\nROUTER_IP="not-an-ip"\n' \
  > "$TD/sn50-data/.env"
_out="$( ( GATEWAY_DATA_DIR="$TD/sn50-data" ENV_FILE="$TD/sn50-data/.env" \
  PATH="$TD/sn50-bin:$PATH" \
  sh "$ROOT/scripts/setup_network.sh" ) 2>&1 )" || :
assert_contains "golden: setup_network DSM abort hint" "$_out" 'sh ./install.sh'
assert_not_contains "golden: setup_network DSM clean of linux entry" "$_out" 'install-linux.sh'

else
  echo "SKIP: setup_network platform-entry aborts need mknod for /dev/net/tun - adjudicate in local docker (docs/development.md)" >&2
fi

# =============================================================================
# Ticket #53 rider - the hardcoded platform literals in the shared flows
# follow the platform vars (#50 pattern): the non-root rerun hints of
# flow_deploy / flow_redeploy / apply_changes (panel cycle-1 C2: all three
# are reachable from the linux menu) and flow_deploy's success-report IP
# placeholder. DSM output (vars unset) stays byte-identical.
# =============================================================================

run_fd_nonroot() {  # $1 = 'set'|'unset' platform vars  $2 = flow function
  sh -c '
    cd "$1" || exit 9
    INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
    export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
    . ./install-linux.sh || exit 9
    if [ "$2" = unset ]; then unset INSTALLER_ENTRY PLATFORM_LABEL; fi
    INSTALLER_LANG=en
    ui_step() { :; }
    is_root() { return 1; }
    "$3"
  ' _ "$ROOT" "$1" "$2" 2>&1
}
for _fn in flow_deploy flow_redeploy apply_changes; do
  _out="$(run_fd_nonroot set "$_fn")" || :
  assert_contains "$_fn non-root (generic): names the linux entry" "$_out" 're-run: sudo sh ./install-linux.sh'
  assert_not_contains "$_fn non-root (generic): no DSM entry name" "$_out" './install.sh'
  _g="$(run_fd_nonroot unset "$_fn")" || :
  assert_contains "golden: $_fn non-root DSM hint" "$_g" 're-run: sudo sh ./install.sh'
  assert_not_contains "golden: $_fn non-root DSM clean of linux entry" "$_g" 'install-linux.sh'
done

# network.sh's stale-network refusal follows the platform (panel cycle-2 D1);
# the message serves gateway.sh/setup_network.sh/netscan.sh, which all read
# the #50 vars from the persisted user .env. Functions run in-process.
run_net_refusal() {  # $1 = 'set'|'unset' platform vars
  (
    if [ "$1" = set ]; then INSTALLER_ENTRY=install-linux.sh; else unset INSTALLER_ENTRY PLATFORM_LABEL; fi
    LOG_FILE=/dev/null
    SUBNET_CIDR=192.0.2.0/24 ROUTER_IP=192.0.2.1 TPROXY_NETWORK=t53net
    macvlan_matches() { return 1; }
    network_exists() { return 0; }
    recreate_macvlan eth0
  ) 2>&1
}
_rc=0; _out="$(run_net_refusal set)" || _rc=$?
[ "$_rc" != 0 ] \
  && ok || fail "stale-network refusal (generic): recreate_macvlan really refuses (rc=$_rc)"
assert_contains "stale-network refusal (generic): the refusal branch fired" "$_out" 'refusing implicit removal'
assert_contains "stale-network refusal (generic): names the linux entry" "$_out" 'run install-linux.sh and choose'
assert_not_contains "stale-network refusal (generic): no DSM entry name" "$_out" 'run install.sh and'
_rc=0; _g="$(run_net_refusal unset)" || _rc=$?
[ "$_rc" != 0 ] \
  && ok || fail "stale-network refusal (golden): recreate_macvlan really refuses (rc=$_rc)"
assert_contains "golden: stale-network refusal DSM text" "$_g" 'run install.sh and choose automatic or manual network cleanup'
assert_not_contains "golden: stale-network refusal DSM clean of linux entry" "$_g" 'install-linux.sh'

# CLI help summary (GENERATED from scripts/cli/spec.yaml) names the platform
# entries alongside install.sh - static prose, same on every platform.
expect_success "CLI help summary names the platform entries" \
  grep -q 'install-linux.sh / install-pi.sh' "$ROOT/scripts/lib/help.sh"

run_fd_report() {  # $1 = 'set'|'unset' platform vars; prints report_success
  sh -c '
    cd "$1" || exit 9
    INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1"
    export INSTALL_SOURCE_ONLY SMG_INSTALL_ROOT
    . ./install-linux.sh || exit 9
    if [ "$2" = unset ]; then unset INSTALLER_ENTRY PLATFORM_LABEL; fi
    INSTALLER_LANG=en
    ui_step() { :; }; ui_ok() { :; }
    detect_parent_interface() { :; }
    _iface_ipv4() { :; }
    _report_verify_table() { :; }
    CHOSEN_IFACE='' PARENT_INTERFACE='' MIHOMO_IP=192.0.2.2
    report_success
  ' _ "$ROOT" "$1" 2>&1
}
_out="$(run_fd_report set)" || _out=''
assert_contains "report_success (generic): host-IP placeholder" "$_out" 'http://<host-IP>:'
assert_not_contains "report_success (generic): no NAS-IP placeholder" "$_out" '<NAS-IP>'
_g="$(run_fd_report unset)" || _g=''
assert_contains "golden: report_success NAS-IP placeholder" "$_g" 'http://<NAS-IP>:'
assert_not_contains "golden: report_success DSM clean of host-IP placeholder" "$_g" '<host-IP>'

# --- summary --------------------------------------------------------------------
printf 'linux_installer_check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: install-linux entry + i18n delta overlay + pi-engine dispatch + macvlan guard/auto-pin/registry wizard + platform-conditional phrasing verified"
