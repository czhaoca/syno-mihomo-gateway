#!/bin/sh
# mihomo_entrypoint_check.sh - hermetic behavioral suite for the container
# entrypoint gate (scripts/mihomo_entrypoint.sh, issue #36): render to a TEMP
# config, `mihomo -t` it, swap over the live config.yaml ONLY on green, and
# keep the last-known-good config running when a hand-edited .env poisons the
# render. Asserts the owner-ratified contract (2026-07-13, issue #36):
#   green            - temp swapped in whole-file, any stale rejection marker
#                      cleared, mihomo exec'd; output identical to a direct
#                      render (the gate adds nothing to a valid config)
#   config-test-failed + last-good  - live config.yaml byte-UNCHANGED, marker
#                      written (reason/time header + scrubbed -t output,
#                      0600), mihomo started on the last-good config
#   render-failed  + last-good      - same fallback, cause-distinct reason
#   first boot + either failure     - hard fail (nonzero, mihomo NOT started),
#                      marker still written for post-mortem
# plus the hygiene properties: the subscription URL and CONTROLLER_SECRET
# never appear in the marker OR the container log (rider 1), temp files never
# linger, and the -t invocation carries -d CFG_DIR -f TEMP (DEC-C).
#
# Every invocation is HERMETIC (env -i, tree copy, PATH-stub mihomo whose -t
# rc/output are fixture-driven). BusyBox-ash safe; adjudicate in alpine:3.22.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"

pass=0; failn=0
ok()   { pass=$((pass+1)); }
fail() { echo "FAIL: $*" >&2; failn=$((failn+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

TREE="$TMP/syno-mihomo-gateway"
mkdir -p "$TREE"
cp -R "$ROOT/scripts" "$TREE/scripts"

# DNS fixture values come from .env.example so the suite hardcodes no
# nameserver (CLAUDE.md rule); the renderer only needs them non-empty.
DNSD=$(sed -n 's/^DNS_DEFAULT_NAMESERVER=//p' "$ROOT/.env.example")
DNSN=$(sed -n 's/^DNS_NAMESERVER=//p' "$ROOT/.env.example")
DNSF=$(sed -n 's/^DNS_FALLBACK=//p' "$ROOT/.env.example")
[ -n "$DNSD" ] && [ -n "$DNSN" ] && [ -n "$DNSF" ] \
  || { echo "FAIL: could not read DNS fixtures from .env.example" >&2; exit 1; }

SUB_URL='https://air.example.com/api/v1/sub?token=hunter2secret'
SECRET='ctlsek-9x-fixture'

# --- stub mihomo: `-t` answers the fixture's rc/output; any other argv is
# the real start - recorded so the suite can assert exec was (not) reached.
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/mihomo" <<'EOF'
#!/bin/sh
STATE="${FAKE_STATE:?}"
printf '%s\n' "$*" >> "$STATE/argv.log"
case " $* " in
  *" -t "*)
    [ -f "$STATE/t_out" ] && cat "$STATE/t_out"
    _rc=$(cat "$STATE/t_rc" 2>/dev/null || true)
    exit "${_rc:-0}" ;;
esac
printf '%s\n' "$*" >> "$STATE/started.log"
env >> "$STATE/started.env"
exit 0
EOF
chmod +x "$STUB/mihomo"

new_state() { # NAME -> prints dir; cfg/ seeded with a subscription
  _d="$TMP/state-$1"; mkdir -p "$_d/cfg"
  printf '%s\n' "$SUB_URL" > "$_d/cfg/subscription.txt"
  : > "$_d/argv.log"
  printf '%s' "$_d"
}

OUT_F="$TMP/out.txt"
run_ep() { # STATE [ENV=VAL ...] - run the entrypoint hermetically; rc in $EP_RC
  _st="$1"; shift
  EP_RC=0
  env -i PATH="$STUB:/usr/bin:/bin" FAKE_STATE="$_st" \
    MIHOMO_CONFIG_DIR="$_st/cfg" MIHOMO_BIN=mihomo \
    MIHOMO_TEMPLATE="$ROOT/config/config.template.yaml" \
    CONTROLLER_PORT=9090 CONTROLLER_SECRET="$SECRET" \
    DNS_DEFAULT_NAMESERVER="$DNSD" DNS_NAMESERVER="$DNSN" DNS_FALLBACK="$DNSF" \
    "$@" \
    sh "$TREE/scripts/mihomo_entrypoint.sh" > "$OUT_F" 2>&1 || EP_RC=$?
}

no_temps() { # STATE - neither the temp render nor the stage capture lingers
  [ ! -f "$1/cfg/.config.yaml.next" ] && [ ! -f "$1/cfg/.config.yaml.stageout" ]
}

# Reference render: what a direct (ungated) render of the same inputs yields.
REF="$TMP/ref"; mkdir -p "$REF"
printf '%s\n' "$SUB_URL" > "$REF/subscription.txt"
env -i PATH="/usr/bin:/bin" MIHOMO_CONFIG_DIR="$REF" \
  MIHOMO_TEMPLATE="$ROOT/config/config.template.yaml" \
  CONTROLLER_PORT=9090 CONTROLLER_SECRET="$SECRET" \
  DNS_DEFAULT_NAMESERVER="$DNSD" DNS_NAMESERVER="$DNSN" DNS_FALLBACK="$DNSF" \
  sh "$TREE/scripts/render_config.sh" > /dev/null 2>&1 \
  || { echo "FAIL: reference render failed" >&2; exit 1; }

# 1) green + previous config + STALE marker: swap, clear marker, exec
ST=$(new_state green)
printf 'OLD SENTINEL\n' > "$ST/cfg/config.yaml"
printf 'stale rejection\n' > "$ST/cfg/.config.yaml.rejected"
run_ep "$ST"
[ "$EP_RC" = 0 ] && ok || fail "green: want rc 0, got $EP_RC: $(cat "$OUT_F")"
cmp -s "$ST/cfg/config.yaml" "$REF/config.yaml" \
  && ok || fail "green: swapped config must equal a direct render"
[ ! -f "$ST/cfg/.config.yaml.rejected" ] \
  && ok || fail "green: stale rejection marker must be cleared"
[ -f "$ST/started.log" ] && grep -q -- "-d $ST/cfg" "$ST/started.log" \
  && ok || fail "green: mihomo must be exec'd with -d CFG_DIR"
no_temps "$ST" && ok || fail "green: temp files must not linger"
grep -q 'hunter2secret' "$ST/started.env" \
  && fail "green: subscription token leaked into the exec'd mihomo environment" || ok

# 2) DEC-C invocation shape: -t ran against the TEMP file, not the live one
grep -q -- "-t -d $ST/cfg -f $ST/cfg/.config.yaml.next" "$ST/argv.log" \
  && ok || fail "green: want '-t -d CFG_DIR -f .config.yaml.next' on argv, got: $(cat "$ST/argv.log")"

# 3) green first boot (no previous config): rendered + exec'd
ST=$(new_state greenboot)
run_ep "$ST"
[ "$EP_RC" = 0 ] && [ -f "$ST/started.log" ] && cmp -s "$ST/cfg/config.yaml" "$REF/config.yaml" \
  && ok || fail "green first boot: want rendered config + start, rc=$EP_RC"

# 4) -t rejects + last-good exists: config untouched, marker, still starts
ST=$(new_state trej)
printf 'OLD SENTINEL\n' > "$ST/cfg/config.yaml"
printf '2\n' > "$ST/t_rc"
{ printf 'panic: regexp2: Compile\n'; printf 'offending url: "%s"\n' "$SUB_URL"; \
  printf 'secret: "%s"\n' "$SECRET"; } > "$ST/t_out"
run_ep "$ST"
[ "$EP_RC" = 0 ] && ok || fail "t-reject: want rc 0 (running on last-good), got $EP_RC: $(cat "$OUT_F")"
printf 'OLD SENTINEL\n' | cmp -s - "$ST/cfg/config.yaml" \
  && ok || fail "t-reject: live config.yaml must be byte-unchanged"
[ -f "$ST/started.log" ] && ok || fail "t-reject: mihomo must start on the last-good config"
REJ="$ST/cfg/.config.yaml.rejected"
[ -f "$REJ" ] && sed -n 1p "$REJ" | grep -q '^reason: config-test-failed$' \
  && ok || fail "t-reject: marker first line must be 'reason: config-test-failed'"
sed -n 2p "$REJ" | grep -q '^time: 20' \
  && ok || fail "t-reject: marker second line must be a UTC time header"
grep -q 'CONFIG REJECTED' "$OUT_F" \
  && ok || fail "t-reject: container log must shout CONFIG REJECTED"
no_temps "$ST" && ok || fail "t-reject: temp files must not linger"

# 5) rider 1 - hygiene: 0600 marker, secrets scrubbed from marker AND log
case "$(ls -l "$REJ")" in
  -rw-------*) ok ;;
  *) fail "t-reject: marker must be 0600, got: $(ls -l "$REJ")" ;;
esac
grep -q '<redacted>' "$REJ" \
  && ok || fail "t-reject: marker must carry the <redacted> mask"
if grep -q 'hunter2secret' "$REJ" || grep -q "$SECRET" "$REJ"; then
  fail "t-reject: subscription token / controller secret leaked into the marker"
else
  ok
fi
if grep -q 'hunter2secret' "$OUT_F" || grep -q "$SECRET" "$OUT_F"; then
  fail "t-reject: subscription token / controller secret leaked into the container log"
else
  ok
fi
# ... and never into the exec'd mihomo process's ENVIRONMENT: the masking
# vars must live only in the awk child, or the fallback-started mihomo
# would carry the raw subscription URL in /proc/1/environ.
if grep -q '^EP_MASK_SUB=' "$ST/started.env" || grep -q '^EP_MASK_SEC=' "$ST/started.env"; then
  fail "t-reject: masking variables leaked into the exec'd mihomo environment"
else
  ok
fi
grep -q 'hunter2secret' "$ST/started.env" \
  && fail "t-reject: subscription token leaked into the exec'd mihomo environment" || ok

# 6) rider 2 - renderer rejects (backtick knob) + last-good: cause-distinct
ST=$(new_state rrej)
printf 'OLD SENTINEL\n' > "$ST/cfg/config.yaml"
run_ep "$ST" AUTO_EXCLUDE_FILTER='bad`tick'
[ "$EP_RC" = 0 ] && ok || fail "render-reject: want rc 0 (running on last-good), got $EP_RC: $(cat "$OUT_F")"
printf 'OLD SENTINEL\n' | cmp -s - "$ST/cfg/config.yaml" \
  && ok || fail "render-reject: live config.yaml must be byte-unchanged"
[ -f "$ST/started.log" ] && ok || fail "render-reject: mihomo must start on the last-good config"
sed -n 1p "$ST/cfg/.config.yaml.rejected" | grep -q '^reason: render-failed$' \
  && ok || fail "render-reject: marker first line must be 'reason: render-failed'"
no_temps "$ST" && ok || fail "render-reject: temp files must not linger"

# 7) first boot + -t reject: hard fail, NO start, marker for post-mortem
ST=$(new_state bootrej)
printf '2\n' > "$ST/t_rc"
printf 'panic: regexp2\n' > "$ST/t_out"
run_ep "$ST"
[ "$EP_RC" != 0 ] && ok || fail "first-boot t-reject: want nonzero rc"
[ ! -f "$ST/started.log" ] && ok || fail "first-boot t-reject: mihomo must NOT start"
[ ! -f "$ST/cfg/config.yaml" ] && ok || fail "first-boot t-reject: no config.yaml may appear"
sed -n 1p "$ST/cfg/.config.yaml.rejected" | grep -q '^reason: config-test-failed$' \
  && ok || fail "first-boot t-reject: marker must still be written"

# 8) first boot + renderer reject: hard fail, cause-distinct marker
ST=$(new_state bootrrej)
run_ep "$ST" AUTO_EXCLUDE_FILTER='bad`tick'
[ "$EP_RC" != 0 ] && [ ! -f "$ST/started.log" ] \
  && ok || fail "first-boot render-reject: want nonzero rc and no start"
sed -n 1p "$ST/cfg/.config.yaml.rejected" | grep -q '^reason: render-failed$' \
  && ok || fail "first-boot render-reject: marker must say render-failed"

echo "mihomo_entrypoint_check: $pass passed, $failn failed"
[ "$failn" = 0 ] || exit 1
echo "OK: entrypoint gate - render-to-temp + mihomo -t, whole-file swap on green only, last-good fallback with cause-distinct 0600 scrubbed marker (render-failed/config-test-failed), first-boot hard fail, secrets never in marker/log/exec'd-mihomo-env, temps never linger"
