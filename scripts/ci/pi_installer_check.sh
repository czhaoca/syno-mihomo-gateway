#!/bin/sh
# pi_installer_check.sh - suite for the Raspberry Pi port (epic raspberry-pi-port).
# Seeded by work-order #17 with the SHARED seams every later Pi ticket builds on:
#   * scheduler_reload_crond: generic-Linux systemctl branch (cron/crond/cronie),
#     tried only after the DSM syno tools, with rc=1 still benign;
#   * config.template.yaml {{EXTUI_BEGIN}}/{{EXTUI_END}} fence: external-ui is
#     rendered ONLY when EXTERNAL_UI_DIR is set, and an unset var renders
#     byte-identically to a template without the fence (the DSM path is inert).
# Later tickets (#18-#21) extend this file with detect/preflight/lite behaviors.
# Style matches dsm_installer_check.sh: BusyBox ash, mktemp sandbox, PATH fakes;
# never mutates the host (real service managers are always shadowed or absent).
# shellcheck disable=SC1091 # sources resolve via $ROOT at runtime
# shellcheck disable=SC2016 # single-quoted sh -c bodies expand via their own $1/$2
# shellcheck disable=SC2015 # `[ ] && ok || fail` is safe: ok() cannot fail
# shellcheck disable=SC2034 # subshell-scoped fixtures are read by the functions under test
# shellcheck disable=SC2329 # subshell function overrides are invoked indirectly
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT/scripts/ci/lib/assert.sh"

# die - infrastructure failure (broken fixture/renderer), distinct from the
# assert.sh counters which record behavior expectations.
die() { echo "FATAL: $*" >&2; exit 1; }

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT INT TERM

. "$ROOT/scripts/lib/scheduler.sh"

# --- scheduler_reload_crond: systemctl branch ----------------------------------
# Each case runs in a subshell with PATH pointing ONLY at that case's fake bin,
# so a real systemctl/synosystemctl on the host can never be reached.

# Case A: generic Linux, `systemctl restart cron` succeeds (Debian/Raspberry Pi OS).
mkdir -p "$TD/bin-a"
cat > "$TD/bin-a/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$TD/log-a"
[ "\$1 \$2" = "restart cron" ] && exit 0
exit 1
EOF
chmod +x "$TD/bin-a/systemctl"
expect_success "systemctl branch: restart cron succeeds -> rc 0" \
  sh -c 'PATH="$1"; . "$2/scripts/lib/scheduler.sh"; scheduler_reload_crond' _ "$TD/bin-a" "$ROOT"
[ -f "$TD/log-a" ] || : > "$TD/log-a"
assert_contains "systemctl branch: cron unit attempted" "$(cat "$TD/log-a")" "restart cron"

# Case B: cron and crond units missing, cronie succeeds (unit-name fallback order).
mkdir -p "$TD/bin-b"
cat > "$TD/bin-b/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$TD/log-b"
[ "\$1 \$2" = "restart cronie" ] && exit 0
exit 1
EOF
chmod +x "$TD/bin-b/systemctl"
expect_success "systemctl branch: falls through cron -> crond -> cronie" \
  sh -c 'PATH="$1"; . "$2/scripts/lib/scheduler.sh"; scheduler_reload_crond' _ "$TD/bin-b" "$ROOT"
printf 'restart cron\nrestart crond\nrestart cronie\n' > "$TD/expect-b"
expect_success "systemctl branch: unit order is cron, crond, cronie" \
  cmp -s "$TD/log-b" "$TD/expect-b"

# Case C: systemctl exists but no cron unit at all -> rc 1 (callers only warn;
# Debian vixie-cron re-reads /etc/crontab by mtime, so rc 1 stays benign).
mkdir -p "$TD/bin-c"
printf '#!/bin/sh\nexit 1\n' > "$TD/bin-c/systemctl"
chmod +x "$TD/bin-c/systemctl"
expect_failure "systemctl branch: no restartable unit -> rc 1" \
  sh -c 'PATH="$1"; . "$2/scripts/lib/scheduler.sh"; scheduler_reload_crond' _ "$TD/bin-c" "$ROOT"

# Case D: nothing available anywhere (no syno tools, no systemctl) -> rc 1.
mkdir -p "$TD/bin-d"
expect_failure "reload: no service manager available -> rc 1" \
  sh -c 'PATH="$1"; . "$2/scripts/lib/scheduler.sh"; scheduler_reload_crond' _ "$TD/bin-d" "$ROOT"

# Case E: DSM stays first-class - when a syno tool answers, systemctl is never
# consulted (regression guard for the existing DSM behavior).
mkdir -p "$TD/bin-e"
cat > "$TD/bin-e/synosystemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$TD/log-e-syno"
exit 0
EOF
cat > "$TD/bin-e/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$TD/log-e-sysd"
exit 0
EOF
chmod +x "$TD/bin-e/synosystemctl" "$TD/bin-e/systemctl"
expect_success "DSM-first: synosystemctl answers -> rc 0" \
  sh -c 'PATH="$1"; . "$2/scripts/lib/scheduler.sh"; scheduler_reload_crond' _ "$TD/bin-e" "$ROOT"
expect_success "DSM-first: synosystemctl was the tool used" test -s "$TD/log-e-syno"
expect_failure "DSM-first: systemctl never consulted when syno answered" test -e "$TD/log-e-sysd"

# --- external-ui render fence ---------------------------------------------------
# Drive the REAL renderer (same one the container entrypoint and render_check.py
# run). DNS fixture values use the RFC 5737 TEST-NET range - fixtures only, the
# committed template itself stays free of address literals.
CFG="$TD/cfg"
mkdir -p "$CFG"
printf 'Default=https://sub.example.com/api?token=abc&x=1\n' > "$CFG/subscription.txt"
TEMPLATE="$ROOT/config/config.template.yaml"

# render_tpl TEMPLATE EXTUI_DIR TUN_ENABLE OUT - run render_config.sh with the
# fixture env; empty EXTUI_DIR means the variable is UNSET (the DSM path).
render_tpl() {
  _rt_tpl="$1"; _rt_extui="$2"; _rt_tun="$3"; _rt_out="$4"
  rm -f "$CFG/config.yaml"
  (
    MIHOMO_CONFIG_DIR="$CFG" MIHOMO_TEMPLATE="$_rt_tpl" \
    CONTROLLER_PORT=9090 CONTROLLER_SECRET='' \
    DNS_DEFAULT_NAMESERVER='192.0.2.53' DNS_NAMESERVER='192.0.2.53' \
    DNS_FALLBACK='192.0.2.54' TUN_ENABLE="$_rt_tun"
    export MIHOMO_CONFIG_DIR MIHOMO_TEMPLATE CONTROLLER_PORT CONTROLLER_SECRET \
      DNS_DEFAULT_NAMESERVER DNS_NAMESERVER DNS_FALLBACK TUN_ENABLE
    unset EXTERNAL_UI_DIR
    if [ -n "$_rt_extui" ]; then EXTERNAL_UI_DIR="$_rt_extui"; export EXTERNAL_UI_DIR; fi
    sh "$ROOT/scripts/render_config.sh" >/dev/null
  ) || return 1
  mv "$CFG/config.yaml" "$_rt_out"
}

# The committed template must carry the fence markers at all.
expect_success "template carries {{EXTUI_BEGIN}}" grep -q '{{EXTUI_BEGIN}}' "$TEMPLATE"
expect_success "template carries {{EXTUI_END}}" grep -q '{{EXTUI_END}}' "$TEMPLATE"

# Unset EXTERNAL_UI_DIR (the DSM compose path): no external-ui key, no residue,
# and byte-identical to rendering a template with the fenced range stripped -
# the mechanical proof the fence is inert.
render_tpl "$TEMPLATE" '' true "$TD/out-default.yaml" || die "default render failed"
_out_default="$(cat "$TD/out-default.yaml")"
assert_not_contains "unset: no external-ui key" "$_out_default" 'external-ui'
assert_not_contains "unset: no fence residue" "$_out_default" '{{EXTUI'
sed -e '/{{EXTUI_BEGIN}}/,/{{EXTUI_END}}/d' "$TEMPLATE" > "$TD/stripped-template.yaml"
render_tpl "$TD/stripped-template.yaml" '' true "$TD/out-stripped.yaml" \
  || die "stripped-template render failed"
expect_success "unset: byte-identical to a fence-less template render" \
  cmp -s "$TD/out-default.yaml" "$TD/out-stripped.yaml"
# The stripped comparison above cannot see spacing mistakes (both sides pass
# through the same sed), so pin the seam directly: fence removal must not leave
# a doubled blank line anywhere (the pre-fence render had none).
has_double_blank() {
  awk 'NR>1 && prev=="" && $0=="" {found=1; exit} {prev=$0} END {exit !found}' "$1"
}
expect_failure "unset: no doubled blank line where the fence was removed" \
  has_double_blank "$TD/out-default.yaml"

# Set EXTERNAL_UI_DIR: the key renders, YAML-quoted, exact value.
render_tpl "$TEMPLATE" '/data/ui/metacubexd' true "$TD/out-extui.yaml" \
  || die "external-ui render failed"
expect_success "set: external-ui renders the exact dir, quoted" \
  grep -q '^external-ui: "/data/ui/metacubexd"$' "$TD/out-extui.yaml"
assert_not_contains "set: no fence residue" "$(cat "$TD/out-extui.yaml")" '{{EXTUI'

# A path with a space must survive the YAML double-quoted scalar path.
render_tpl "$TEMPLATE" '/data/u i/metacubexd' true "$TD/out-space.yaml" \
  || die "space-path render failed"
expect_success "set: space-containing dir renders quoted and intact" \
  grep -q '^external-ui: "/data/u i/metacubexd"$' "$TD/out-space.yaml"

# TUN off + EXTUI unset is the most common alternate DSM config: the inertness
# guarantee (byte-identity + no doubled blank) must hold there too.
render_tpl "$TEMPLATE" '' false "$TD/out-default-tunoff.yaml" \
  || die "default TUN-off render failed"
render_tpl "$TD/stripped-template.yaml" '' false "$TD/out-stripped-tunoff.yaml" \
  || die "stripped-template TUN-off render failed"
expect_success "unset + TUN off: byte-identical to a fence-less template render" \
  cmp -s "$TD/out-default-tunoff.yaml" "$TD/out-stripped-tunoff.yaml"
expect_failure "unset + TUN off: no doubled blank line" \
  has_double_blank "$TD/out-default-tunoff.yaml"

# The two fences are independent: TUN off + external-ui on must yield a config
# with no tun block but with the dashboard line.
render_tpl "$TEMPLATE" '/data/ui/metacubexd' false "$TD/out-tunoff.yaml" \
  || die "tun-off render failed"
_out_tunoff="$(cat "$TD/out-tunoff.yaml")"
assert_not_contains "tun off + extui: no tun block" "$_out_tunoff" 'mihomo-tun'
assert_contains "tun off + extui: external-ui still present" "$_out_tunoff" 'external-ui: "/data/ui/metacubexd"'

# =============================================================================
# Ticket #18 - install-pi.sh entry, hardware detect, compose-parity mode
# =============================================================================
# The pi modules build on the shared installer stack; bring it up the same way
# dsm_installer_check.sh does (REPO_ROOT set first so common.sh respects it).
REPO_ROOT="$ROOT"
. "$ROOT/scripts/lib/common.sh"
. "$ROOT/scripts/lib/network.sh"
. "$ROOT/scripts/lib/registry.sh"
. "$ROOT/scripts/installer/ui.sh"
. "$ROOT/scripts/installer/i18n.sh"
. "$ROOT/scripts/installer/envedit.sh"
. "$ROOT/scripts/installer/preflight.sh"
. "$ROOT/scripts/installer/wizards.sh"
for _pi_mod in detect preflight i18n_pi flow_compose lite flow_lite; do
  [ -f "$ROOT/scripts/pi/$_pi_mod.sh" ] || die "scripts/pi/$_pi_mod.sh missing"
done
. "$ROOT/scripts/pi/detect.sh"
. "$ROOT/scripts/pi/preflight.sh"
. "$ROOT/scripts/pi/i18n_pi.sh"
. "$ROOT/scripts/pi/flow_compose.sh"
. "$ROOT/scripts/pi/lite.sh"
. "$ROOT/scripts/pi/flow_lite.sh"

# --- detect: model / memory / arch readers (env-overridable for CI) -----------
printf 'Raspberry Pi 3 Model B Plus Rev 1.3\0' > "$TD/dt-model"
[ "$( (SMG_PI_MODEL_FILE="$TD/dt-model"; pi_model) )" = 'Raspberry Pi 3 Model B Plus Rev 1.3' ] \
  && ok || fail "pi_model reads the override file and strips the trailing NUL"
[ "$( (SMG_PI_MODEL_FILE="$TD/absent"; pi_model) )" = unknown ] \
  && ok || fail "pi_model degrades to 'unknown' when unreadable"
printf 'MemTotal:         948304 kB\nMemFree:            1000 kB\n' > "$TD/mi-1g"
[ "$( (SMG_PI_MEMINFO="$TD/mi-1g"; pi_mem_mb) )" = 926 ] \
  && ok || fail "pi_mem_mb converts MemTotal kB to MB"
[ "$( (SMG_PI_MEMINFO="$TD/absent"; pi_mem_mb) )" = 0 ] \
  && ok || fail "pi_mem_mb degrades to 0 when unreadable"
arch_of() { ( SMG_PI_ARCH="$1"; pi_lite_asset_arch ); }
[ "$(arch_of aarch64)" = arm64 ] && ok || fail "arch map: aarch64 -> arm64"
[ "$(arch_of armv7l)" = armv7 ] && ok || fail "arch map: armv7l -> armv7"
[ "$(arch_of armv6l)" = armv6 ] && ok || fail "arch map: armv6l -> armv6"
[ "$(arch_of x86_64)" = amd64 ] && ok || fail "arch map: x86_64 -> amd64 (dev box)"

# --- detect: the owner-decided mode table (DEC-5 + DEC-A) ----------------------
# Fixtures mirror REAL reported sizes: boards reserve GPU/firmware memory, so a
# nominal 2 GB reports ~1870 MB and 1 GB ~926 MB - the table keys on the class.
printf 'MemTotal:        3884300 kB\n' > "$TD/mi-4g"     # 3793 MB
printf 'MemTotal:        1914896 kB\n' > "$TD/mi-2g"     # 1870 MB
printf 'MemTotal:        1048576 kB\n' > "$TD/mi-1gn"    # 1024 MB nominal
printf 'MemTotal:         524288 kB\n' > "$TD/mi-512n"   #  512 MB nominal
printf 'MemTotal:         441548 kB\n' > "$TD/mi-512"    #  431 MB real 512-board
rec_of() { ( SMG_PI_ARCH="$1"; SMG_PI_MEMINFO="$2"; pi_recommend_mode ); }
[ "$(rec_of armv6l "$TD/mi-512")" = lite ] && ok || fail "mode table: armv6 -> lite"
[ "$(rec_of armv7l "$TD/mi-4g")" = lite ] && ok || fail "mode table: armv7 -> lite even with RAM (DEC-A)"
[ "$(rec_of aarch64 "$TD/mi-4g")" = compose ] && ok || fail "mode table: arm64 4GB -> compose"
[ "$(rec_of aarch64 "$TD/mi-2g")" = compose ] && ok || fail "mode table: arm64 real-2GB -> compose"
[ "$(rec_of aarch64 "$TD/mi-1gn")" = compose-tuned ] && ok || fail "mode table: arm64 1GB -> compose-tuned"
[ "$(rec_of aarch64 "$TD/mi-1g")" = compose-tuned ] && ok || fail "mode table: arm64 real-1GB -> compose-tuned"
[ "$(rec_of aarch64 "$TD/mi-512n")" = lite ] && ok || fail "mode table: arm64 512MB -> lite"
[ "$(rec_of aarch64 "$TD/mi-512")" = lite ] && ok || fail "mode table: arm64 real-512MB -> lite"
modes_of() { ( SMG_PI_ARCH="$1"; pi_available_modes ); }
[ "$(modes_of armv6l)" = lite ] && ok || fail "compose refused on armv6 (no arm/v6 images)"
[ "$(modes_of armv7l)" = lite ] && ok || fail "compose refused on armv7 (DEC-A: no metacubexd arm/v7)"
[ "$(modes_of aarch64)" = 'compose lite' ] && ok || fail "arm64 offers compose and lite"

# --- detect: mode marker --------------------------------------------------------
( GATEWAY_DATA_DIR="$TD/pi-data"; pi_write_mode_marker pi-compose ) \
  && [ "$(cat "$TD/pi-data/state/install-mode")" = pi-compose ] \
  && ok || fail "mode marker written under the data dir"
( GATEWAY_DATA_DIR="$TD/pi-data"; pi_write_mode_marker pi-compose ) \
  && [ "$(wc -l < "$TD/pi-data/state/install-mode" | tr -d ' ')" = 1 ] \
  && ok || fail "mode marker idempotent on re-run"

# --- pi preflight: ACR arch notice (DEC-3 firing rules) -------------------------
_out="$( ( host_arch() { echo arm64; }; REGISTRY_MODE=acr; pi_acr_arch_notice ) 2>&1 )"
assert_contains "acr + arm64 host: notice fires, names the arch" "$_out" 'arm64'
_out="$( ( host_arch() { echo amd64; }; REGISTRY_MODE=acr; pi_acr_arch_notice ) 2>&1 )"
[ -z "$_out" ] && ok || fail "acr + amd64 host: silent"
_out="$( ( host_arch() { echo arm64; }; REGISTRY_MODE=docker; pi_acr_arch_notice ) 2>&1 )"
[ -z "$_out" ] && ok || fail "docker mode: silent regardless of arch"

# --- pi preflight: wireless macvlan parent guard --------------------------------
( PARENT_INTERFACE=wlan0; pi_wlan_guard >/dev/null 2>&1 ) && fail "wlan0 parent accepted" || ok
( PARENT_INTERFACE=eth0; pi_wlan_guard >/dev/null 2>&1 ) && ok || fail "eth0 parent refused"
( PARENT_INTERFACE=''; detect_parent_interface() { echo wlan1; }; pi_wlan_guard >/dev/null 2>&1 ) \
  && fail "detected wlan1 parent accepted" || ok
( PARENT_INTERFACE=''; detect_parent_interface() { echo end0; }; pi_wlan_guard >/dev/null 2>&1 ) \
  && ok || fail "detected wired end0 parent refused"

# --- pi preflight: guarded create_network (the choke point every path hits) ------
# The Modify menu and the redeploy re-pick branch call create_network directly,
# bypassing pi_flow_*'s early guard - the interposition must refuse wl* there.
( CHOSEN_IFACE=wlan0; pi_stock_create_network() { echo REACHED >> "$TD/cn-log1"; }
  create_network >/dev/null 2>&1 ) && fail "guarded create_network accepted wlan0" || ok
[ ! -e "$TD/cn-log1" ] && ok || fail "stock body reached despite the wireless refusal"
( CHOSEN_IFACE=eth0; pi_stock_create_network() { echo REACHED >> "$TD/cn-log2"; }
  create_network >/dev/null 2>&1 ) && ok || fail "guarded create_network refused wired eth0"
[ -e "$TD/cn-log2" ] && ok || fail "wired call did not delegate to the stock body"
# The CAPTURED stock body is the real one: with a wired parent and no root it
# must take netscan.sh's own not-root branch (proves genuine delegation).
_out="$( ( CHOSEN_IFACE=eth0; is_root() { return 1; }; create_network ) 2>&1 )" || true
assert_contains "captured stock body runs netscan.sh's not-root branch" \
  "$_out" "$( (INSTALLER_LANG=en; msg warn_net_need_root) )"

# --- pi preflight: ARMv6 acknowledgment gate (DEC-5) -----------------------------
( ui_yesno() { return 1; }; pi_armv6_ack >/dev/null 2>&1 ) && fail "declined ack proceeded" || ok
( ui_yesno() { return 0; }; pi_armv6_ack >/dev/null 2>&1 ) && ok || fail "accepted ack refused"

# --- pi preflight: EXPECTED_ARCH aligned to the host before the deploy flow -----
mkdir -p "$TD/pi-app" "$TD/pi-align/config"
cp "$ROOT/.env.example" "$TD/pi-app/.env.example"
(
  REPO_ROOT="$TD/pi-app"; GATEWAY_DATA_DIR="$TD/pi-align"
  ENV_FILE="$TD/pi-align/.env"; CONFIG_STATE_DIR="$TD/pi-align/config"
  SUBSCRIPTION_FILE="$TD/pi-align/config/subscription.txt"
  host_arch() { echo arm64; }
  pi_align_expected_arch >/dev/null 2>&1
) && [ "$( (unset EXPECTED_ARCH; dotenv_load "$TD/pi-align/.env" >/dev/null 2>&1; printf '%s' "$EXPECTED_ARCH") )" = arm64 ] \
  && ok || fail "pi_align_expected_arch seeds .env and pins EXPECTED_ARCH to the host"

# --- pi i18n overlay -------------------------------------------------------------
_pi_en_keys="$(sed -n '/^_msg_en_pi()/,/^}/p' "$ROOT/scripts/pi/i18n_pi.sh" | sed -n 's/^    \([a-z0-9_]*\)).*/\1/p' | sort)"
_pi_zh_keys="$(sed -n '/^_msg_zh_pi()/,/^}/p' "$ROOT/scripts/pi/i18n_pi.sh" | sed -n 's/^    \([a-z0-9_]*\)).*/\1/p' | sort)"
[ -n "$_pi_en_keys" ] && [ "$_pi_en_keys" = "$_pi_zh_keys" ] \
  && ok || fail "pi i18n en/zh key sets are identical"
[ "$( (INSTALLER_LANG=en; msg menu_modify) )" = 'Modify an existing deployment' ] \
  && ok || fail "overlay msg() falls back to the stock catalog"
_zh_mode="$( (INSTALLER_LANG=zh; msg pi_ask_mode) )"
[ -n "$_zh_mode" ] && [ "$_zh_mode" != pi_ask_mode ] \
  && ok || fail "pi keys resolve in zh (not the bare key)"

# =============================================================================
# Ticket #19 - lite runtime: download/verify, external-ui, systemd unit
# =============================================================================

# --- pi_gh_url: GH_MIRROR prefixing (DEC-4) --------------------------------------
[ "$( (unset GH_MIRROR; pi_gh_url 'https://github.com/x/y') )" = 'https://github.com/x/y' ] \
  && ok || fail "pi_gh_url: empty mirror -> direct URL"
[ "$( (GH_MIRROR='https://m.example'; pi_gh_url 'https://github.com/x/y') )" = 'https://m.example/https://github.com/x/y' ] \
  && ok || fail "pi_gh_url: mirror prefix applied"
[ "$( (GH_MIRROR='https://m.example/'; pi_gh_url 'https://github.com/x/y') )" = 'https://m.example/https://github.com/x/y' ] \
  && ok || fail "pi_gh_url: trailing slash normalized"

# --- pi_resolve_tag: pin wins; redirect resolves through the mirror (G5) ---------
[ "$( (pi_resolve_tag MetaCubeX/mihomo v9.9.9) )" = v9.9.9 ] \
  && ok || fail "pi_resolve_tag: pinned version wins without network"
_out="$( (
  GH_MIRROR='https://m.example'
  curl() { printf '%s\n' "$*" >> "$TD/tag-curl-log"; printf 'https://github.com/MetaCubeX/mihomo/releases/tag/v1.2.3'; }
  pi_resolve_tag MetaCubeX/mihomo ''
) )"
[ "$_out" = v1.2.3 ] && ok || fail "pi_resolve_tag: redirect tag extracted (got: $_out)"
grep -q 'm.example/https://github.com/MetaCubeX/mihomo/releases/latest' "$TD/tag-curl-log" 2>/dev/null \
  && ok || fail "pi_resolve_tag: resolution went through the GH_MIRROR prefix"

# --- binary install: the verify ladder, fail-closed ------------------------------
# A fake "binary": a shell script that answers -v with a version containing the
# tag, so exec-smoke + version-match exercise the real ladder mechanics.
cat > "$TD/fake-mihomo" <<'EOF'
#!/bin/sh
[ "${1:-}" = -v ] && { echo "Mihomo Meta v9.9.9 linux test build"; exit 0; }
exit 0
EOF
chmod +x "$TD/fake-mihomo"
gzip -c "$TD/fake-mihomo" > "$TD/good.gz"
printf 'not a gzip archive' > "$TD/bad.gz"
cat > "$TD/broken-bin" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TD/broken-bin"
gzip -c "$TD/broken-bin" > "$TD/smokefail.gz"

# happy path: fetch fake copies the good archive; version file + executable land
( GATEWAY_DATA_DIR="$TD/lite-ok"; SMG_PI_ARCH=aarch64
  pi_fetch() { cp "$TD/good.gz" "$2"; }
  pi_lite_install_binary v9.9.9 >/dev/null 2>&1 ) \
  && [ -x "$TD/lite-ok/bin/mihomo" ] \
  && [ "$(cat "$TD/lite-ok/state/lite/version")" = v9.9.9 ] \
  && ok || fail "binary ladder: happy path installs binary + version state"
# corrupt gzip: fail closed, nothing installed
( GATEWAY_DATA_DIR="$TD/lite-bad"; SMG_PI_ARCH=aarch64
  pi_fetch() { cp "$TD/bad.gz" "$2"; }
  pi_lite_install_binary v9.9.9 >/dev/null 2>&1 ) && fail "corrupt gzip accepted" || ok
[ ! -e "$TD/lite-bad/bin/mihomo" ] && [ ! -e "$TD/lite-bad/bin/mihomo.next" ] \
  && ok || fail "corrupt gzip left partial install artifacts"
# smoke/version failure: fail closed, cleanup
( GATEWAY_DATA_DIR="$TD/lite-smoke"; SMG_PI_ARCH=aarch64
  pi_fetch() { cp "$TD/smokefail.gz" "$2"; }
  pi_lite_install_binary v9.9.9 >/dev/null 2>&1 ) && fail "failed smoke accepted" || ok
[ ! -e "$TD/lite-smoke/bin/mihomo" ] && ok || fail "failed smoke left a binary behind"
# wrong version string (tag mismatch): refused, nothing left behind
( GATEWAY_DATA_DIR="$TD/lite-ver"; SMG_PI_ARCH=aarch64
  pi_fetch() { cp "$TD/good.gz" "$2"; }
  pi_lite_install_binary v8.0.0 >/dev/null 2>&1 ) && fail "version mismatch accepted" || ok
[ ! -e "$TD/lite-ver/bin/mihomo" ] && [ ! -e "$TD/lite-ver/bin/mihomo.next" ] \
  && ok || fail "version mismatch left partial artifacts"

# --- optional pinned sha (DEC-C): enforced when set, inert when empty ------------
_good_sha="$(pi_sha256 "$TD/good.gz")"
[ -n "$_good_sha" ] || die "pi_sha256 unavailable on this host"
( GATEWAY_DATA_DIR="$TD/lite-sha-ok"; SMG_PI_ARCH=aarch64; MIHOMO_SHA256="$_good_sha"
  pi_fetch() { cp "$TD/good.gz" "$2"; }
  pi_lite_install_binary v9.9.9 >/dev/null 2>&1 ) \
  && ok || fail "pinned sha: matching checksum passes"
( GATEWAY_DATA_DIR="$TD/lite-sha-bad"; SMG_PI_ARCH=aarch64
  MIHOMO_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
  pi_fetch() { cp "$TD/good.gz" "$2"; }
  pi_lite_install_binary v9.9.9 >/dev/null 2>&1 ) && fail "sha mismatch accepted" || ok
[ ! -e "$TD/lite-sha-bad/bin/mihomo" ] && ok || fail "sha mismatch left a binary behind"

# --- sideload: a pre-placed asset skips the download entirely --------------------
mkdir -p "$TD/lite-side/bin"
cp "$TD/good.gz" "$TD/lite-side/bin/mihomo-linux-arm64-v9.9.9.gz"
( GATEWAY_DATA_DIR="$TD/lite-side"; SMG_PI_ARCH=aarch64
  pi_fetch() { echo FETCHED >> "$TD/side-fetch-log"; return 1; }
  pi_lite_install_binary v9.9.9 >/dev/null 2>&1 ) \
  && [ ! -e "$TD/side-fetch-log" ] \
  && ok || fail "sideloaded archive did not bypass the download"

# --- dashboard install: layout-agnostic extraction (DEC-B, G6) -------------------
mkdir -p "$TD/dash-nested/dist" "$TD/dash-root" "$TD/dash-none"
echo '<html>ui</html>' > "$TD/dash-nested/dist/index.html"
echo '<html>ui</html>' > "$TD/dash-root/index.html"
echo 'no ui here' > "$TD/dash-none/readme.txt"
tar -czf "$TD/ui-nested.tgz" -C "$TD/dash-nested" dist
tar -czf "$TD/ui-root.tgz" -C "$TD/dash-root" index.html
tar -czf "$TD/ui-none.tgz" -C "$TD/dash-none" readme.txt
( GATEWAY_DATA_DIR="$TD/lite-ui1"
  pi_fetch() { cp "$TD/ui-nested.tgz" "$2"; }
  pi_resolve_tag() { echo v1.0.0; }
  pi_lite_install_dashboard >/dev/null 2>&1 ) \
  && [ -f "$TD/lite-ui1/ui/metacubexd/index.html" ] \
  && ok || fail "dashboard: nested dist/ layout installed"
( GATEWAY_DATA_DIR="$TD/lite-ui2"
  pi_fetch() { cp "$TD/ui-root.tgz" "$2"; }
  pi_resolve_tag() { echo v1.0.0; }
  pi_lite_install_dashboard >/dev/null 2>&1 ) \
  && [ -f "$TD/lite-ui2/ui/metacubexd/index.html" ] \
  && ok || fail "dashboard: root layout installed"
( GATEWAY_DATA_DIR="$TD/lite-ui3"
  pi_fetch() { cp "$TD/ui-none.tgz" "$2"; }
  pi_resolve_tag() { echo v1.0.0; }
  pi_lite_install_dashboard >/dev/null 2>&1 ) && fail "layout without index.html accepted" || ok
mkdir -p "$TD/lite-ui4/ui"
cp "$TD/ui-nested.tgz" "$TD/lite-ui4/ui/compressed-dist.tgz"
( GATEWAY_DATA_DIR="$TD/lite-ui4"
  pi_fetch() { echo FETCHED >> "$TD/ui-fetch-log"; return 1; }
  pi_lite_install_dashboard >/dev/null 2>&1 ) \
  && [ ! -e "$TD/ui-fetch-log" ] && [ -f "$TD/lite-ui4/ui/metacubexd/index.html" ] \
  && ok || fail "dashboard: sideloaded tgz did not bypass the download"

# --- systemd unit: rendered, correct anchors, idempotent -------------------------
( REPO_ROOT="$ROOT"; GATEWAY_DATA_DIR="$TD/lite-unit"; CONFIG_STATE_DIR="$TD/lite-unit/config"
  ENV_FILE="$TD/lite-unit/.env"; SMG_PI_UNIT_FILE="$TD/unit.service"
  pi_lite_render_unit >/dev/null 2>&1 ) \
  && grep -q 'ExecStartPre=.*render_config.sh' "$TD/unit.service" \
  && grep -q 'ExecStartPre=.*load_env' "$TD/unit.service" \
  && grep -q "ExecStart=$TD/lite-unit/bin/mihomo -d $TD/lite-unit/config" "$TD/unit.service" \
  && grep -q 'Restart=always' "$TD/unit.service" \
  && ok || fail "unit render: anchors missing"
grep -q '^EnvironmentFile=' "$TD/unit.service" \
  && fail "unit hands .env to systemd's parser (compose-escaping mismatch)" || ok
cp "$TD/unit.service" "$TD/unit.service.first"
( REPO_ROOT="$ROOT"; GATEWAY_DATA_DIR="$TD/lite-unit"; CONFIG_STATE_DIR="$TD/lite-unit/config"
  ENV_FILE="$TD/lite-unit/.env"; SMG_PI_UNIT_FILE="$TD/unit.service"
  pi_lite_render_unit >/dev/null 2>&1 ) \
  && cmp -s "$TD/unit.service" "$TD/unit.service.first" \
  && ok || fail "unit render: not idempotent"

# --- ExecStartPre decodes .env with the APP's parser, not systemd's --------------
# env_set writes a literal '$' as '$$' (compose convention); systemd's
# EnvironmentFile would NOT reverse that. Run the REAL ExecStartPre payload
# from the rendered unit against a '$'-containing secret and prove the
# rendered config carries the secret verbatim.
mkdir -p "$TD/lite-rt/config"
printf 'Default=https://sub.example.com/api?token=abc\n' > "$TD/lite-rt/config/subscription.txt"
(
  REPO_ROOT="$ROOT"; GATEWAY_DATA_DIR="$TD/lite-rt"; CONFIG_STATE_DIR="$TD/lite-rt/config"
  ENV_FILE="$TD/lite-rt/.env"; SMG_PI_UNIT_FILE="$TD/unit-rt.service"
  : > "$ENV_FILE"
  env_set CONTROLLER_SECRET 'pa$word'
  env_set DNS_DEFAULT_NAMESERVER 192.0.2.53
  env_set DNS_NAMESERVER 192.0.2.53
  env_set DNS_FALLBACK 192.0.2.54
  pi_lite_render_unit
) >/dev/null 2>&1 || die "round-trip fixture setup failed"
grep -qF 'pa$$word' "$TD/lite-rt/.env" || die "env_set did not compose-escape the fixture secret"
_rt_pre="$(sed -n 's/^ExecStartPre=//p' "$TD/unit-rt.service")"
( MIHOMO_CONFIG_DIR="$TD/lite-rt/config"; MIHOMO_TEMPLATE="$ROOT/config/config.template.yaml"
  export MIHOMO_CONFIG_DIR MIHOMO_TEMPLATE
  eval "$_rt_pre" ) >/dev/null 2>&1 \
  && grep -qF 'secret: "pa$word"' "$TD/lite-rt/config/config.yaml" \
  && ok || fail "ExecStartPre round-trip: a \$-containing secret must decode via the app parser"

# --- install-pi.sh entry: sources cleanly under the CI guard ---------------------
expect_success "install-pi.sh sources cleanly (INSTALL_SOURCE_ONLY=1)" \
  sh -c 'cd "$1" && INSTALL_SOURCE_ONLY=1 SMG_INSTALL_ROOT="$1" sh -c ". ./install-pi.sh"' _ "$ROOT"

# =============================================================================
# Ticket #20 - lite binary auto-updater with rollback + cron wiring
# =============================================================================

# --- pi_lite_update_command: quoted absolute exec form (space-safe) --------------
[ "$( (REPO_ROOT='/opt/a b'; pi_lite_update_command) )" = "cd '/opt/a b' && exec /bin/sh '/opt/a b/scripts/pi/auto_update_lite.sh'" ] \
  && ok || fail "pi_lite_update_command quotes the root and targets the lite updater"

# --- managed crontab writer: append once, rewrite on change, CRONTAB_FILE --------
CT="$TD/crontab"
printf '# host entry kept as-is\n*/5 * * * *\troot\t/usr/bin/other-job\n' > "$CT"
( CRONTAB_FILE="$CT"; UPDATE_SCHEDULE='30 4 * * *'; REPO_ROOT='/opt/app'
  scheduler_reload_crond() { : >> "$TD/ct-reload"; }
  pi_install_lite_crontab ) >/dev/null 2>&1 \
  && [ "$(grep -c 'scripts/pi/auto_update_lite.sh' "$CT")" = 1 ] \
  && [ "$(grep 'scripts/pi/auto_update_lite.sh' "$CT")" = "$(printf "30 4 * * *\troot\tcd '/opt/app' && exec /bin/sh '/opt/app/scripts/pi/auto_update_lite.sh'")" ] \
  && ok || fail "crontab writer: exactly one entry, schedule + root + quoted command"
[ -f "$TD/ct-reload" ] && ok || fail "crontab writer: crond reload attempted after the write"
cp "$CT" "$CT.first"
( CRONTAB_FILE="$CT"; UPDATE_SCHEDULE='30 4 * * *'; REPO_ROOT='/opt/app'
  scheduler_reload_crond() { :; }
  pi_install_lite_crontab ) >/dev/null 2>&1 \
  && cmp -s "$CT" "$CT.first" \
  && ok || fail "crontab writer: idempotent on an unchanged schedule"
( CRONTAB_FILE="$CT"; UPDATE_SCHEDULE='0 5 * * *'; REPO_ROOT='/opt/app'
  scheduler_reload_crond() { :; }
  pi_install_lite_crontab ) >/dev/null 2>&1 \
  && [ "$(grep -c 'scripts/pi/auto_update_lite.sh' "$CT")" = 1 ] \
  && grep -qF "0 5 * * *" "$CT" \
  && ok || fail "crontab writer: managed rewrite replaces our line on schedule change"
grep -Fq '30 4 * * *' "$CT" && fail "crontab writer: stale schedule left behind" || ok
grep -q '/usr/bin/other-job' "$CT" && ok || fail "crontab writer: foreign entries preserved"
expect_failure "crontab writer: missing crontab file refused" \
  sh -c 'CRONTAB_FILE="$1/absent-ct" UPDATE_SCHEDULE="0 2 * * *" REPO_ROOT=/opt sh -c "
    . \"$2/scripts/lib/common.sh\"; . \"$2/scripts/lib/scheduler.sh\"; . \"$2/scripts/pi/lite.sh\"
    pi_install_lite_crontab" >/dev/null 2>&1' _ "$TD" "$ROOT"
( CRONTAB_FILE="$CT"; UPDATE_SCHEDULE='not a schedule'; REPO_ROOT='/opt/app'
  scheduler_reload_crond() { :; }
  pi_install_lite_crontab ) >/dev/null 2>&1 && fail "invalid UPDATE_SCHEDULE accepted" || ok

# --- lite_health_gate: unit active -> restarts stable -> probe -> TUN link -------
# systemctl/probe/ip are shell-function fakes (a real systemctl can never be
# reached), HEALTH_INTERVAL=0 keeps the retry window instant.
( HEALTH_RETRIES=2; HEALTH_INTERVAL=0; HEALTH_MAX_RESTARTS=3; TUN_ENABLE=false
  systemctl() { case "${1:-}" in is-active) return 0 ;; show) printf '0\n' ;; esac; return 0; }
  pi_lite_controller_probe() { return 0; }
  lite_health_gate ) >/dev/null 2>&1 \
  && ok || fail "gate: active + stable restarts + probe -> pass"
( HEALTH_RETRIES=2; HEALTH_INTERVAL=0; HEALTH_MAX_RESTARTS=3; TUN_ENABLE=false
  systemctl() { case "${1:-}" in is-active) return 1 ;; show) printf '0\n' ;; esac; return 0; }
  pi_lite_controller_probe() { return 0; }
  lite_health_gate ) >/dev/null 2>&1 && fail "gate passed with an inactive unit" || ok
( HEALTH_RETRIES=2; HEALTH_INTERVAL=0; HEALTH_MAX_RESTARTS=9; TUN_ENABLE=false
  systemctl() {
    case "${1:-}" in
      is-active) return 0 ;;
      show) _g3="$(cat "$TD/g3-n" 2>/dev/null || echo 0)"; echo $((_g3 + 1)) > "$TD/g3-n"; printf '%s\n' "$_g3" ;;
    esac
    return 0
  }
  pi_lite_controller_probe() { return 0; }
  lite_health_gate ) >/dev/null 2>&1 && fail "gate passed with a climbing NRestarts" || ok
# (output captured to a file: bash 3.2 - the macOS /bin/sh - cannot parse a
# `case` statement inside $(...), so no command substitution around this one)
( HEALTH_RETRIES=3; HEALTH_INTERVAL=0; HEALTH_MAX_RESTARTS=3; TUN_ENABLE=false
  systemctl() {
    case "${1:-}" in
      is-active) return 0 ;;
      show) if [ -f "$TD/g4-first" ]; then printf '5\n'; else : > "$TD/g4-first"; printf '0\n'; fi ;;
    esac
    return 0
  }
  pi_lite_controller_probe() { return 0; }
  lite_health_gate ) > "$TD/g4-out" 2>&1 && fail "gate passed a crash-looping service" || ok
assert_contains "gate: crash-loop ceiling gives up early and says so" "$(cat "$TD/g4-out")" 'crash-looping'
( HEALTH_RETRIES=2; HEALTH_INTERVAL=0; HEALTH_MAX_RESTARTS=3; TUN_ENABLE=false
  systemctl() { case "${1:-}" in is-active) return 0 ;; show) printf '0\n' ;; esac; return 0; }
  pi_lite_controller_probe() { return 1; }
  lite_health_gate ) >/dev/null 2>&1 && fail "gate passed with a dead controller" || ok
( HEALTH_RETRIES=2; HEALTH_INTERVAL=0; HEALTH_MAX_RESTARTS=3; TUN_ENABLE=true
  systemctl() { case "${1:-}" in is-active) return 0 ;; show) printf '0\n' ;; esac; return 0; }
  pi_lite_controller_probe() { return 0; }
  ip() { return 1; }
  lite_health_gate ) >/dev/null 2>&1 && fail "gate passed with the TUN link absent" || ok
( HEALTH_RETRIES=2; HEALTH_INTERVAL=0; HEALTH_MAX_RESTARTS=3; TUN_ENABLE=true
  systemctl() { case "${1:-}" in is-active) return 0 ;; show) printf '0\n' ;; esac; return 0; }
  pi_lite_controller_probe() { return 0; }
  ip() { [ "${1:-} ${2:-} ${3:-}" = 'link show mihomo-tun' ]; }
  lite_health_gate ) >/dev/null 2>&1 \
  && ok || fail "gate: TUN on queries 'ip link show mihomo-tun' and passes when present"

# --- the updater end-to-end (sourced with fakes; sideload keeps it offline) ------
cat > "$TD/upd-old" <<'EOF'
#!/bin/sh
[ "${1:-}" = -v ] && { echo "Mihomo Meta v9.9.9 linux test build"; exit 0; }
exit 0
EOF
cat > "$TD/upd-new" <<'EOF'
#!/bin/sh
[ "${1:-}" = -v ] && { echo "Mihomo Meta v9.9.10 linux test build"; exit 0; }
exit 0
EOF
chmod +x "$TD/upd-old" "$TD/upd-new"
gzip -c "$TD/upd-new" > "$TD/upd-new.gz"

# mk_upd_sandbox DIR - an installed lite deployment: old binary, version state,
# unit file, pinned .env (pin v9.9.10 = DEC-D pin path; no network anywhere).
mk_upd_sandbox() {
  _mus="$1"
  rm -rf "$_mus"
  mkdir -p "$_mus/bin" "$_mus/state/lite" "$_mus/config"
  cp "$TD/upd-old" "$_mus/bin/mihomo"
  chmod +x "$_mus/bin/mihomo"
  printf 'v9.9.9\n' > "$_mus/state/lite/version"
  printf '# fixture unit\n' > "$_mus/unit.service"
  {
    printf 'UPDATE_ENABLED=true\n'
    printf 'MIHOMO_VERSION=v9.9.10\n'
    printf 'HEALTH_RETRIES=2\nHEALTH_INTERVAL=0\nHEALTH_MAX_RESTARTS=3\n'
    printf 'TUN_ENABLE=false\n'
  } > "$_mus/.env"
}

# run_lite_updater DIR PROBE_TAG [args...] - source the REAL updater in an
# isolated subshell and run its main. Fakes: systemctl logs + always succeeds;
# curl/pi_fetch fail loudly and log (any network attempt is a test failure);
# the controller probe succeeds only while the INSTALLED binary reports
# PROBE_TAG - one knob scripts both gate outcomes ('v9.9.10' = new binary
# healthy, 'v9.9.9' = new fails + rollback re-gate passes, 'none' = all fail).
run_lite_updater() {
  _rlu_d="$1"; _rlu_probe="$2"; shift 2
  (
    GATEWAY_DATA_DIR="$_rlu_d"; ENV_FILE="$_rlu_d/.env"
    CONFIG_STATE_DIR="$_rlu_d/config"; LOCK_DIR="$_rlu_d/lock"
    SUBSCRIPTION_FILE="$_rlu_d/config/subscription.txt"
    SMG_PI_UNIT_FILE="$_rlu_d/unit.service"; SMG_PI_ARCH=aarch64
    AUTO_UPDATE_LITE_SELF_DIR="$ROOT/scripts/pi"
    AUTO_UPDATE_SOURCE_ONLY=1
    . "$ROOT/scripts/pi/auto_update_lite.sh" || exit 97
    systemctl() {
      printf '%s\n' "$*" >> "$GATEWAY_DATA_DIR/systemctl.log"
      case "${1:-}" in is-active) return 0 ;; show) printf '0\n' ;; esac
      return 0
    }
    curl() { printf 'CURL %s\n' "$*" >> "$GATEWAY_DATA_DIR/net.log"; return 6; }
    pi_fetch() { printf 'FETCH %s\n' "$1" >> "$GATEWAY_DATA_DIR/net.log"; return 1; }
    RLU_PROBE="$_rlu_probe"
    pi_lite_controller_probe() {
      [ "$RLU_PROBE" = none ] && return 1
      "$GATEWAY_DATA_DIR/bin/mihomo" -v 2>/dev/null | grep -q "$RLU_PROBE"
    }
    auto_update_lite_main "$@"
  )
}

# happy path: swap + restart + gate pass; .prev and version state both persist
mk_upd_sandbox "$TD/upd-ok"
cp "$TD/upd-new.gz" "$TD/upd-ok/bin/mihomo-linux-arm64-v9.9.10.gz"
_rc=0; run_lite_updater "$TD/upd-ok" v9.9.10 >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] \
  && "$TD/upd-ok/bin/mihomo" -v | grep -q v9.9.10 \
  && "$TD/upd-ok/bin/mihomo.prev" -v | grep -q v9.9.9 \
  && [ "$(cat "$TD/upd-ok/state/lite/version")" = v9.9.10 ] \
  && grep -q 'restart mihomo-gateway' "$TD/upd-ok/systemctl.log" \
  && ok || fail "updater happy path: swap + .prev + version state + restart (rc=$_rc)"
[ ! -e "$TD/upd-ok/net.log" ] && ok || fail "updater happy path went to the network despite the sideload"
_lr="$TD/upd-ok/state/lite/last-run.json"
_lr_missing=''
for _k in ts exit_code dry_run updated unchanged failed rolled_back updated_names failed_names rolled_back_names; do
  grep -q "\"$_k\":" "$_lr" 2>/dev/null || _lr_missing="$_lr_missing $_k"
done
[ -z "$_lr_missing" ] && ok || fail "last-run.json shape matches auto_update.sh (missing:$_lr_missing)"
grep -q '"exit_code":0' "$_lr" 2>/dev/null && grep -q '"updated":1' "$_lr" \
  && grep -q '"updated_names":"mihomo"' "$_lr" \
  && ok || fail "last-run.json records the applied update"

# no-change fast exit: version already matches the pin; nothing downloaded/touched
mk_upd_sandbox "$TD/upd-same"
printf 'v9.9.10\n' > "$TD/upd-same/state/lite/version"
_rc=0; run_lite_updater "$TD/upd-same" none >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] \
  && [ ! -e "$TD/upd-same/bin/mihomo.prev" ] \
  && [ ! -e "$TD/upd-same/net.log" ] \
  && grep -q '"unchanged":1' "$TD/upd-same/state/lite/last-run.json" \
  && ok || fail "updater no-change: fast exit without touching anything (rc=$_rc)"

# dry-run: detection only - no backup, no swap, no restart, dry_run recorded
mk_upd_sandbox "$TD/upd-dry"
cp "$TD/upd-new.gz" "$TD/upd-dry/bin/mihomo-linux-arm64-v9.9.10.gz"
_rc=0; run_lite_updater "$TD/upd-dry" none --dry-run >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] \
  && "$TD/upd-dry/bin/mihomo" -v | grep -q v9.9.9 \
  && [ ! -e "$TD/upd-dry/bin/mihomo.prev" ] \
  && [ "$(cat "$TD/upd-dry/state/lite/version")" = v9.9.9 ] \
  && grep -q '"dry_run":1' "$TD/upd-dry/state/lite/last-run.json" \
  && ok || fail "updater dry-run: reports without writing (rc=$_rc)"
grep -q 'restart' "$TD/upd-dry/systemctl.log" 2>/dev/null \
  && fail "dry-run restarted the service" || ok

# kill-switch: UPDATE_ENABLED=false no-ops; --force overrides it
mk_upd_sandbox "$TD/upd-off"
printf 'v9.9.10\n' > "$TD/upd-off/state/lite/version"
sed 's/^UPDATE_ENABLED=true$/UPDATE_ENABLED=false/' "$TD/upd-off/.env" > "$TD/upd-off/.env.next" \
  && mv "$TD/upd-off/.env.next" "$TD/upd-off/.env"
_rc=0; run_lite_updater "$TD/upd-off" none >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] && grep -q '"unchanged":0' "$TD/upd-off/state/lite/last-run.json" \
  && grep -q 'disabled' "$TD/upd-off/logs/auto-update.log" \
  && ok || fail "updater kill-switch: disabled run exits 0 before detection (rc=$_rc)"
_rc=0; run_lite_updater "$TD/upd-off" none --force >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] && grep -q '"unchanged":1' "$TD/upd-off/state/lite/last-run.json" \
  && ok || fail "updater --force: overrides the kill-switch and reaches detection (rc=$_rc)"

# verify-ladder failure: corrupt sideload -> partial exit, binary untouched
mk_upd_sandbox "$TD/upd-corrupt"
printf 'not a gzip archive' > "$TD/upd-corrupt/bin/mihomo-linux-arm64-v9.9.10.gz"
_rc=0; run_lite_updater "$TD/upd-corrupt" none >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] \
  && "$TD/upd-corrupt/bin/mihomo" -v | grep -q v9.9.9 \
  && [ "$(cat "$TD/upd-corrupt/state/lite/version")" = v9.9.9 ] \
  && grep -q '"failed":1' "$TD/upd-corrupt/state/lite/last-run.json" \
  && ok || fail "updater ladder failure: partial exit, running binary untouched (rc=$_rc)"
grep -q 'restart' "$TD/upd-corrupt/systemctl.log" 2>/dev/null \
  && fail "ladder failure still restarted the service" || ok

# health-gate failure: rollback restores .prev + version, restarts, re-gates -> 2
mk_upd_sandbox "$TD/upd-roll"
cp "$TD/upd-new.gz" "$TD/upd-roll/bin/mihomo-linux-arm64-v9.9.10.gz"
_rc=0; run_lite_updater "$TD/upd-roll" v9.9.9 >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] \
  && "$TD/upd-roll/bin/mihomo" -v | grep -q v9.9.9 \
  && [ "$(cat "$TD/upd-roll/state/lite/version")" = v9.9.9 ] \
  && [ "$(grep -c 'restart mihomo-gateway' "$TD/upd-roll/systemctl.log")" -ge 2 ] \
  && grep -q '"rolled_back":1' "$TD/upd-roll/state/lite/last-run.json" \
  && grep -q '"rolled_back_names":"mihomo"' "$TD/upd-roll/state/lite/last-run.json" \
  && ok || fail "updater rollback: .prev restored + version reverted + re-gated (rc=$_rc)"

# gate fails even after the restore -> manual-attention partial, not a fake 'rolled back'
mk_upd_sandbox "$TD/upd-manual"
cp "$TD/upd-new.gz" "$TD/upd-manual/bin/mihomo-linux-arm64-v9.9.10.gz"
_out="$(run_lite_updater "$TD/upd-manual" none 2>&1)" && _rc=0 || _rc=$?
[ "$_rc" = 2 ] \
  && grep -q '"rolled_back":0' "$TD/upd-manual/state/lite/last-run.json" \
  && grep -q '"failed":1' "$TD/upd-manual/state/lite/last-run.json" \
  && ok || fail "updater rollback-incomplete: failed (not rolled_back) + partial (rc=$_rc)"
assert_contains "updater rollback-incomplete: flags manual attention" "$_out" 'MANUAL ATTENTION'

# locked: a live holder wins; the second run must NOT clobber last-run.json
mk_upd_sandbox "$TD/upd-lock"
mkdir -p "$TD/upd-lock/lock"
echo "$$" > "$TD/upd-lock/lock/pid"
printf '{"seeded":1}\n' > "$TD/upd-lock/state/lite/last-run.json"
_rc=0; run_lite_updater "$TD/upd-lock" none >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 4 ] && [ "$(cat "$TD/upd-lock/state/lite/last-run.json")" = '{"seeded":1}' ] \
  && ok || fail "updater locked: exits 4 and leaves the live run's record alone (rc=$_rc)"

# unpinned resolve failure through the mirror: a classified partial, never silent
mk_upd_sandbox "$TD/upd-res"
sed '/^MIHOMO_VERSION=/d' "$TD/upd-res/.env" > "$TD/upd-res/.env.next" \
  && mv "$TD/upd-res/.env.next" "$TD/upd-res/.env"
_rc=0; run_lite_updater "$TD/upd-res" none >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] && grep -q '"failed":1' "$TD/upd-res/state/lite/last-run.json" \
  && ok || fail "updater resolve failure: classified partial exit (rc=$_rc)"

# --- pi_flow_cron: crontab-only, dispatches by the install-mode marker -----------
# Prompt/UI primitives are stubbed (defaults accepted, yesno answers with its
# own default); the assertion surface is the crontab file the flow writes.
pfc_stubs() {
  ui_step() { :; }; ui_say() { :; }; ui_ok() { :; }; ui_warn() { :; }; ui_info() { :; }
  diagnose() { :; }; pi_sudo_rerun_hint() { :; }
  ui_ask_validated() { eval "$1=\"\$3\""; }
  ui_ask() { eval "$1=\"\$3\""; }
  ui_yesno() { [ "${2:-n}" = y ]; }
  scheduler_reload_crond() { :; }
}
mk_flow_cron_env() {
  rm -rf "$1"
  mkdir -p "$1/state"
  printf '%s\n' "$2" > "$1/state/install-mode"
  : > "$1/ct"
  printf 'UPDATE_SCHEDULE="0 2 * * *"\nUPDATE_TZ=UTC\n' > "$1/.env"
}
mk_flow_cron_env "$TD/fc-lite" pi-lite
( GATEWAY_DATA_DIR="$TD/fc-lite"; ENV_FILE="$TD/fc-lite/.env"; CRONTAB_FILE="$TD/fc-lite/ct"
  pfc_stubs; is_root() { return 0; }
  pi_flow_cron ) >/dev/null 2>&1 \
  && grep -q 'scripts/pi/auto_update_lite.sh' "$TD/fc-lite/ct" \
  && ok || fail "pi_flow_cron: pi-lite marker schedules the lite updater"
( unset UPDATE_ENABLED; dotenv_load "$TD/fc-lite/.env" >/dev/null 2>&1
  [ "${UPDATE_ENABLED:-}" = true ] ) \
  && ok || fail "pi_flow_cron: persists UPDATE_ENABLED=true on an accepted default"
mk_flow_cron_env "$TD/fc-comp" pi-compose
( GATEWAY_DATA_DIR="$TD/fc-comp"; ENV_FILE="$TD/fc-comp/.env"; CRONTAB_FILE="$TD/fc-comp/ct"
  pfc_stubs; is_root() { return 0; }
  pi_flow_cron ) >/dev/null 2>&1 \
  && grep -q 'scripts/auto_update.sh' "$TD/fc-comp/ct" \
  && ok || fail "pi_flow_cron: pi-compose marker schedules the stock compose updater"
grep -q 'auto_update_lite' "$TD/fc-comp/ct" \
  && fail "pi_flow_cron: compose install got the lite updater scheduled" || ok
mk_flow_cron_env "$TD/fc-root" pi-lite
( GATEWAY_DATA_DIR="$TD/fc-root"; ENV_FILE="$TD/fc-root/.env"; CRONTAB_FILE="$TD/fc-root/ct"
  pfc_stubs; is_root() { return 1; }
  pi_flow_cron ) >/dev/null 2>&1 && fail "pi_flow_cron proceeded without root" || ok
[ ! -s "$TD/fc-root/ct" ] && ok || fail "pi_flow_cron wrote a crontab entry without root"

# --- menu wiring: the Pi menu now carries the cron item -----------------------
grep -q 'pi_flow_cron' "$ROOT/install-pi.sh" \
  && grep -q 'msg menu_cron' "$ROOT/install-pi.sh" \
  && ok || fail "install-pi.sh menu wires the cron item to pi_flow_cron"

# --- #27 default-value parity: lite wizard defaults single-source from .env.example
# Same drift mode the DSM wizards had: flow_lite duplicated the .env.example
# defaults as literals. Accept-the-default run against an empty .env; every
# persisted value must equal the .env.example assignment (never-eval parse;
# the reference read runs in a subshell so pointing ENV_FILE at the example
# cannot leak into the suite).
( REPO_ROOT="$ROOT"; ENV_FILE="$TD/parity.env"; : > "$ENV_FILE"
  GATEWAY_DATA_DIR="$TD/parity-data"
  ui_step() { :; }; ui_say() { :; }; ui_ok() { :; }; ui_warn() { :; }; ui_info() { :; }
  ui_ask_validated() { eval "$1=\"\$3\""; }
  ui_ask() { eval "$1=\"\$3\""; }
  ui_ask_secret() { eval "$1=''"; }
  ui_yesno() { return 1; }
  pi_lite_wizard >/dev/null 2>&1 || { echo "parity: pi_lite_wizard failed" >&2; exit 1; }
  for _k in CONTROLLER_PORT DNS_DEFAULT_NAMESERVER DNS_NAMESERVER DNS_FALLBACK TZ; do
    _want="$( (ENV_FILE="$ROOT/.env.example"; dotenv_get "$_k") )"
    [ -n "$_want" ] || { echo "parity: $_k missing from .env.example" >&2; exit 1; }
    _got="$(dotenv_get "$_k" 2>/dev/null || echo '')"
    [ "$_got" = "$_want" ] \
      || { echo "parity: $_k got '$_got' want '$_want'" >&2; exit 1; }
  done ) \
  && ok || fail "pi_lite_wizard defaults diverge from .env.example"

# Default literals belong in .env.example ONLY (#27).
grep -n '223\.5\.5\.5\|119\.29\.29\.29\|1\.1\.1\.1\|8\.8\.8\.8\|8080\|9090\|192\.168\.\|Asia/Shanghai' \
  "$ROOT/scripts/pi/flow_lite.sh" >/dev/null \
  && fail "flow_lite.sh carries default literals (single-source them in .env.example)" || ok

# =============================================================================
# Ticket #21 - lite_ctl status/doctor + scheduler coverage
# =============================================================================

# mk_ctl_sandbox DIR - a healthy lite install for lite_ctl: binary + version +
# unit + marker + subscription + a .env whose DNS fixtures are RFC 5737.
mk_ctl_sandbox() {
  _mcs="$1"
  rm -rf "$_mcs"
  mkdir -p "$_mcs/bin" "$_mcs/state/lite" "$_mcs/config" "$_mcs/logs"
  cp "$TD/upd-old" "$_mcs/bin/mihomo"
  chmod +x "$_mcs/bin/mihomo"
  printf 'v9.9.9\n' > "$_mcs/state/lite/version"
  printf '%s\n' pi-lite > "$_mcs/state/install-mode"
  printf '# fixture unit\n' > "$_mcs/unit.service"
  printf 'Default=https://sub.example.com/api?token=abc\n' > "$_mcs/config/subscription.txt"
  printf '{"ts":"fixture","exit_code":0,"dry_run":0}\n' > "$_mcs/state/lite/last-run.json"
  : > "$_mcs/crontab"
  {
    printf 'UPDATE_ENABLED=true\n'
    printf 'MIHOMO_VERSION=v9.9.10\n'
    printf 'HEALTH_RETRIES=2\nHEALTH_INTERVAL=0\nHEALTH_MAX_RESTARTS=3\n'
    printf 'TUN_ENABLE=false\n'
    printf 'CONTROLLER_PORT=9090\n'
    printf 'DNS_DEFAULT_NAMESERVER=192.0.2.53\nDNS_NAMESERVER=192.0.2.53\nDNS_FALLBACK=192.0.2.54\n'
  } > "$_mcs/.env"
}

# run_lite_ctl DIR FLAGS VERB [args...] - source the REAL lite_ctl in an
# isolated subshell with systemd/probe/net fakes and run its main. FLAGS is a
# comma-separated fake-behavior list: active (unit is-active ok), probe (the
# controller answers), tun (ip link succeeds), ss53 (a fake dnsmasq owns :53).
# Host schedulers are never reachable: crontab -l is stubbed out and the
# SMG_SCHED_* stores point into the sandbox.
run_lite_ctl() {
  _rlc_d="$1"; _rlc_flags="$2"; shift 2
  (
    GATEWAY_DATA_DIR="$_rlc_d"; ENV_FILE="$_rlc_d/.env"
    CONFIG_STATE_DIR="$_rlc_d/config"; LOCK_DIR="$_rlc_d/lock"
    SUBSCRIPTION_FILE="$_rlc_d/config/subscription.txt"
    SMG_PI_UNIT_FILE="$_rlc_d/unit.service"; SMG_PI_ARCH=aarch64
    SMG_SCHED_TASK_DIR="$_rlc_d/absent-taskdir"
    SMG_SCHED_EVENT_DB="$_rlc_d/absent-db"
    SMG_SCHED_CRONTAB="$_rlc_d/crontab"
    LITE_CTL_SELF_DIR="$ROOT/scripts/pi"
    LITE_CTL_SOURCE_ONLY=1
    . "$ROOT/scripts/pi/lite_ctl.sh" || exit 97
    RLC_FLAGS=",$_rlc_flags,"
    systemctl() {
      printf '%s\n' "$*" >> "$GATEWAY_DATA_DIR/systemctl.log"
      case "${1:-}" in
        is-active) case "$RLC_FLAGS" in *,active,*) return 0 ;; *) return 1 ;; esac ;;
        show) printf '0\n' ;;
      esac
      return 0
    }
    pi_lite_controller_probe() { case "$RLC_FLAGS" in *,probe,*) return 0 ;; *) return 1 ;; esac; }
    ip() { case "$RLC_FLAGS" in *,tun,*) return 0 ;; *) return 1 ;; esac; }
    ss() {
      case "$RLC_FLAGS" in
        *,ss53,*) printf 'udp   UNCONN 0 0  0.0.0.0:53  0.0.0.0:*  users:(("dnsmasq",pid=419,fd=4))\n' ;;
      esac
      return 0
    }
    crontab() { return 1; }
    is_root() { return 0; }
    lite_ctl_main "$@"
  )
}

# --- usage: bilingual, plain (not spec-generated), config exit code -------------
_rc=0; run_lite_ctl "$TD/ctl-any" '' >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 3 ] && ok || fail "lite_ctl with no verb exits with the config code (rc=$_rc)"
mk_ctl_sandbox "$TD/ctl-use"
( INSTALLER_LANG=en; run_lite_ctl "$TD/ctl-use" '' bogus-verb ) > "$TD/ctl-use-out" 2>&1 || :
grep -q 'status' "$TD/ctl-use-out" && grep -q 'doctor' "$TD/ctl-use-out" \
  && ok || fail "usage names the verbs"
( INSTALLER_LANG=zh; run_lite_ctl "$TD/ctl-use" '' bogus-verb ) > "$TD/ctl-use-zh" 2>&1 || :
grep -q 'pi_ctl_usage' "$TD/ctl-use-zh" && fail "zh usage prints the bare i18n key" || ok

# --- doctor: all-green -> HEALTHY 0 (crontab seeded via the CRONTAB_FILE writer,
# then FOUND by scheduler_task_deployed through SMG_SCHED_CRONTAB - the lite
# scheduler-coverage acceptance criterion) -----------------------------------
mk_ctl_sandbox "$TD/ctl-ok"
( CRONTAB_FILE="$TD/ctl-ok/crontab"; UPDATE_SCHEDULE='0 2 * * *'; REPO_ROOT="$ROOT"
  scheduler_reload_crond() { :; }
  pi_install_lite_crontab ) >/dev/null 2>&1 || fail "seeding the lite crontab entry failed"
( SMG_SCHED_CRONTAB="$TD/ctl-ok/crontab"; SMG_SCHED_TASK_DIR="$TD/absent"
  SMG_SCHED_EVENT_DB="$TD/absent"; crontab() { return 1; }
  scheduler_task_deployed "scripts/pi/auto_update_lite.sh" ) \
  && ok || fail "scheduler_task_deployed finds the CRONTAB_FILE-written lite entry"
_rc=0; run_lite_ctl "$TD/ctl-ok" 'active,probe' doctor > "$TD/ctl-ok-out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] && grep -q 'Result: HEALTHY' "$TD/ctl-ok-out" \
  && ok || fail "doctor all-green exits 0 HEALTHY (rc=$_rc)"
grep -q 'auto-update task is scheduled' "$TD/ctl-ok-out" \
  && ok || fail "doctor reports the scheduled lite update task"

# --- doctor: unit inactive -> BROKEN 3 -------------------------------------------
mk_ctl_sandbox "$TD/ctl-down"
_rc=0; run_lite_ctl "$TD/ctl-down" 'probe' doctor > "$TD/ctl-down-out" 2>&1 || _rc=$?
[ "$_rc" = 3 ] && grep -q 'Result: BROKEN' "$TD/ctl-down-out" \
  && ok || fail "doctor with an inactive unit exits 3 BROKEN (rc=$_rc)"

# --- doctor: managed binary missing -> BROKEN 3; version state missing -> warn 2 --
mk_ctl_sandbox "$TD/ctl-nobin"
rm -f "$TD/ctl-nobin/bin/mihomo"
_rc=0; run_lite_ctl "$TD/ctl-nobin" 'active,probe' doctor >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 3 ] && ok || fail "doctor without the managed binary exits 3 (rc=$_rc)"
mk_ctl_sandbox "$TD/ctl-nover"
rm -f "$TD/ctl-nover/state/lite/version"
( CRONTAB_FILE="$TD/ctl-nover/crontab"; UPDATE_SCHEDULE='0 2 * * *'; REPO_ROOT="$ROOT"
  scheduler_reload_crond() { :; }
  pi_install_lite_crontab ) >/dev/null 2>&1
_rc=0; run_lite_ctl "$TD/ctl-nover" 'active,probe' doctor > "$TD/ctl-nover-out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] && grep -q 'Result: DEGRADED' "$TD/ctl-nover-out" \
  && ok || fail "doctor without version state degrades to 2 (rc=$_rc)"

# --- doctor: update task missing -> warn 2; UPDATE_ENABLED=false -> no check -----
mk_ctl_sandbox "$TD/ctl-nosched"
_rc=0; run_lite_ctl "$TD/ctl-nosched" 'active,probe' doctor > "$TD/ctl-nosched-out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] && grep -q 'auto_update_lite' "$TD/ctl-nosched-out" \
  && ok || fail "doctor warns (2) when no task runs the lite updater (rc=$_rc)"
mk_ctl_sandbox "$TD/ctl-schedoff"
sed 's/^UPDATE_ENABLED=true$/UPDATE_ENABLED=false/' "$TD/ctl-schedoff/.env" > "$TD/ctl-schedoff/.env.next" \
  && mv "$TD/ctl-schedoff/.env.next" "$TD/ctl-schedoff/.env"
_rc=0; run_lite_ctl "$TD/ctl-schedoff" 'active,probe' doctor > "$TD/ctl-schedoff-out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] && ok || fail "doctor skips the scheduler check when updates are disabled (rc=$_rc)"

# --- doctor: scheduler rc 2 (nothing searchable) stays SILENT, not a warn --------
mk_ctl_sandbox "$TD/ctl-unk"
rm -f "$TD/ctl-unk/crontab"
_rc=0; run_lite_ctl "$TD/ctl-unk" 'active,probe' doctor > "$TD/ctl-unk-out" 2>&1 || _rc=$?
[ "$_rc" = 0 ] && ok || fail "doctor stays healthy when no scheduler store is searchable (rc=$_rc)"
grep -q 'auto-update task' "$TD/ctl-unk-out" \
  && fail "doctor printed a scheduler verdict despite rc 2 (unknown)" || ok

# --- doctor: TUN enabled but link absent -> BROKEN 3 ------------------------------
mk_ctl_sandbox "$TD/ctl-tun"
sed 's/^TUN_ENABLE=false$/TUN_ENABLE=true/' "$TD/ctl-tun/.env" > "$TD/ctl-tun/.env.next" \
  && mv "$TD/ctl-tun/.env.next" "$TD/ctl-tun/.env"
( CRONTAB_FILE="$TD/ctl-tun/crontab"; UPDATE_SCHEDULE='0 2 * * *'; REPO_ROOT="$ROOT"
  scheduler_reload_crond() { :; }
  pi_install_lite_crontab ) >/dev/null 2>&1
_rc=0; run_lite_ctl "$TD/ctl-tun" 'active,probe' doctor >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 3 ] && ok || fail "doctor: TUN enabled without the link exits 3 (rc=$_rc)"
_rc=0; run_lite_ctl "$TD/ctl-tun" 'active,probe,tun' doctor >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] && ok || fail "doctor: TUN link present -> the same box goes HEALTHY (rc=$_rc)"

# --- doctor: port 53 held by a foreign resolver -> actionable warn naming it (G7) -
mk_ctl_sandbox "$TD/ctl-53"
( CRONTAB_FILE="$TD/ctl-53/crontab"; UPDATE_SCHEDULE='0 2 * * *'; REPO_ROOT="$ROOT"
  scheduler_reload_crond() { :; }
  pi_install_lite_crontab ) >/dev/null 2>&1
_rc=0; run_lite_ctl "$TD/ctl-53" 'active,probe,ss53' doctor > "$TD/ctl-53-out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] && grep -q 'dnsmasq' "$TD/ctl-53-out" \
  && ok || fail "doctor warns naming the foreign port-53 resolver (rc=$_rc)"

# --- doctor: missing subscription degrades (parity with doctor.sh) ---------------
mk_ctl_sandbox "$TD/ctl-nosub"
rm -f "$TD/ctl-nosub/config/subscription.txt"
( CRONTAB_FILE="$TD/ctl-nosub/crontab"; UPDATE_SCHEDULE='0 2 * * *'; REPO_ROOT="$ROOT"
  scheduler_reload_crond() { :; }
  pi_install_lite_crontab ) >/dev/null 2>&1
_rc=0; run_lite_ctl "$TD/ctl-nosub" 'active,probe' doctor > "$TD/ctl-nosub-out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] && grep -qi 'subscription' "$TD/ctl-nosub-out" \
  && ok || fail "doctor degrades on a missing subscription (rc=$_rc)"

# --- status: surfaces mode, version, and the last-run record ---------------------
mk_ctl_sandbox "$TD/ctl-st"
run_lite_ctl "$TD/ctl-st" 'active' status > "$TD/ctl-st-out" 2>&1 || :
grep -q 'v9.9.9' "$TD/ctl-st-out" && grep -q 'pi-lite' "$TD/ctl-st-out" \
  && grep -q '"ts":"fixture"' "$TD/ctl-st-out" \
  && ok || fail "status surfaces version + mode + last-run.json"

# --- update: delegates to the REAL updater (lock/kill-switch/dry-run intact) -----
# The delegation is a real subprocess, so the sandbox rides EXPORTED env and a
# PATH-appended systemctl fake (nothing real shadows it on CI or dev boxes);
# dry-run exits before any restart or probe, so no other fake is needed.
mk_ctl_sandbox "$TD/ctl-upd"
mkdir -p "$TD/ctl-fakebin"
printf '#!/bin/sh\nexit 0\n' > "$TD/ctl-fakebin/systemctl"
chmod +x "$TD/ctl-fakebin/systemctl"
_rc=0
(
  GATEWAY_DATA_DIR="$TD/ctl-upd"; ENV_FILE="$TD/ctl-upd/.env"
  CONFIG_STATE_DIR="$TD/ctl-upd/config"; LOCK_DIR="$TD/ctl-upd/lock"
  SUBSCRIPTION_FILE="$TD/ctl-upd/config/subscription.txt"
  SMG_PI_UNIT_FILE="$TD/ctl-upd/unit.service"; SMG_PI_ARCH=aarch64
  PATH="$PATH:$TD/ctl-fakebin"
  export GATEWAY_DATA_DIR ENV_FILE CONFIG_STATE_DIR LOCK_DIR SUBSCRIPTION_FILE \
    SMG_PI_UNIT_FILE SMG_PI_ARCH PATH
  LITE_CTL_SELF_DIR="$ROOT/scripts/pi"; LITE_CTL_SOURCE_ONLY=1
  . "$ROOT/scripts/pi/lite_ctl.sh" || exit 97
  lite_ctl_main update --dry-run
) >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] && grep -q '"dry_run":1' "$TD/ctl-upd/state/lite/last-run.json" 2>/dev/null \
  && ok || fail "update verb delegates to auto_update_lite.sh (dry-run recorded, rc=$_rc)"

# --- start/stop: root-gated, drive systemctl -------------------------------------
mk_ctl_sandbox "$TD/ctl-ss"
run_lite_ctl "$TD/ctl-ss" '' start >/dev/null 2>&1 || :
grep -q 'start mihomo-gateway' "$TD/ctl-ss/systemctl.log" 2>/dev/null \
  && ok || fail "start verb drives systemctl start"
run_lite_ctl "$TD/ctl-ss" '' stop >/dev/null 2>&1 || :
grep -q 'stop mihomo-gateway' "$TD/ctl-ss/systemctl.log" 2>/dev/null \
  && ok || fail "stop verb drives systemctl stop"
_rc=0
( GATEWAY_DATA_DIR="$TD/ctl-ss"; ENV_FILE="$TD/ctl-ss/.env"
  LITE_CTL_SELF_DIR="$ROOT/scripts/pi"; LITE_CTL_SOURCE_ONLY=1
  . "$ROOT/scripts/pi/lite_ctl.sh" || exit 97
  is_root() { return 1; }
  lite_ctl_main start ) >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 6 ] && ok || fail "start without root exits with the root code (rc=$_rc)"

# --- install-pi.sh status menu: dispatches on the install-mode marker ------------
# Overrides land AFTER sourcing (the modules would otherwise redefine them);
# INSTALL_SOURCE_ONLY keeps the interactive entry from running.
mk_ctl_sandbox "$TD/ctl-menu"
( GATEWAY_DATA_DIR="$TD/ctl-menu"; ENV_FILE="$TD/ctl-menu/.env"
  INSTALL_SOURCE_ONLY=1; SMG_INSTALL_ROOT="$ROOT"
  . "$ROOT/install-pi.sh" || exit 97
  ui_step() { :; }; ui_say() { :; }; ui_ok() { :; }; ui_warn() { :; }
  ui_yesno() { [ "${2:-n}" = y ]; }
  _run_lite_status() { echo LITE >> "$TD/ctl-menu/dispatch.log"; }
  lifecycle_inspect() { echo COMPOSE >> "$TD/ctl-menu/dispatch.log"; }
  pi_menu_status_flow ) >/dev/null 2>&1 || :
grep -q 'LITE' "$TD/ctl-menu/dispatch.log" 2>/dev/null \
  && ok || fail "status menu: pi-lite marker routes to the lite status"
grep -q 'COMPOSE' "$TD/ctl-menu/dispatch.log" 2>/dev/null \
  && fail "status menu: lite install still ran the compose inspection" || ok
printf '%s\n' pi-compose > "$TD/ctl-menu/state/install-mode"
( GATEWAY_DATA_DIR="$TD/ctl-menu"; ENV_FILE="$TD/ctl-menu/.env"
  INSTALL_SOURCE_ONLY=1; SMG_INSTALL_ROOT="$ROOT"
  . "$ROOT/install-pi.sh" || exit 97
  ui_step() { :; }; ui_say() { :; }; ui_ok() { :; }; ui_warn() { :; }
  ui_yesno() { [ "${2:-n}" = y ]; }
  _run_lite_status() { echo LITE2 >> "$TD/ctl-menu/dispatch.log"; }
  lifecycle_inspect() { echo COMPOSE2 >> "$TD/ctl-menu/dispatch.log"; }
  pi_menu_status_flow ) >/dev/null 2>&1 || :
grep -q 'COMPOSE2' "$TD/ctl-menu/dispatch.log" 2>/dev/null \
  && ok || fail "status menu: pi-compose marker keeps the compose inspection"

# --- summary --------------------------------------------------------------------
printf 'pi_installer_check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: pi shared seams + install-pi entry + lite runtime + updater + lite_ctl (doctor/status/dispatch) verified"
