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

# --- summary --------------------------------------------------------------------
printf 'pi_installer_check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: pi shared seams + install-pi entry + lite runtime (detect/mode-table/preflight/i18n/ladder/unit) verified"
