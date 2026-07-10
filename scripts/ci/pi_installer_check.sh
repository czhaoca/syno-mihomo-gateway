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

# --- summary --------------------------------------------------------------------
printf 'pi_installer_check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: pi shared seams (scheduler systemctl branch + external-ui fence) verified"
