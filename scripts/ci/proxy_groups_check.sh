#!/bin/sh
# proxy_groups_check.sh - hermetic behavioral suite for the doctor's
# proxy_groups check (scripts/lib/checks.sh chk_proxy_groups, issue #34):
# the zero-node guard for the epic's FILTERED url-test groups. Asserts the
# documented contract:
#   ok             - every filtered group has real nodes, or no filtered
#                    groups are rendered at all (pre-epic config)
#   default-empty  - auto-x (the routing default) has no real nodes -> bad
#   country-empty  - some generated country group(s) empty -> warn
#   provider-empty - EVERY url-test group is empty (cold provider, not a
#                    filter problem; DEC-A grace) -> warn + seed hint
#   unknown        - controller unreachable -> silent record
# plus the transport properties: group names ride the URL %XX-encoded byte
# by byte (CJK-safe; the expected encodings are HARDCODED here so the
# encoder is verified independently), real-node counting excludes BOTH
# placeholder adapters (COMPATIBLE - mihomo's default - and REJECT - the
# epic's empty-fallback), and the bearer token never appears on docker argv
# (stdin only, the repo rule).
#
# Every invocation is HERMETIC (env -i, tree copy, PATH-stub docker) so the
# suite cannot mask an env-dependence bug. BusyBox-ash safe.
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

# --- stub docker: answers the controller endpoints from canned per-state
# fixtures; records every argv line so the suite can assert the bearer
# token never rides argv. ---------------------------------------------------
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/docker" <<'EOF'
#!/bin/sh
STATE="${FAKE_STATE:?}"
printf '%s\n' "$*" >> "$STATE/argv.log"
case "${1:-}" in
  exec) ;;
  *) exit 0 ;;
esac
[ -f "$STATE/ctl_down" ] && exit 1
URL=""; for _a in "$@"; do URL="$_a"; done
case "$URL" in
  */group)
    cat "$STATE/group.json" ;;
  */proxies/*)
    _enc="${URL##*/proxies/}"
    if [ -f "$STATE/proxies-$_enc.json" ]; then
      cat "$STATE/proxies-$_enc.json"
    else
      echo '{}'
    fi ;;
  *) echo '{}' ;;
esac
exit 0
EOF
chmod +x "$STUB/docker"

# Hardcoded %XX byte encodings (independent check of the sh encoder):
#   auto   = %61%75%74%6f          auto-x = %61%75%74%6f%2d%78
#   日本   = %e6%97%a5%e6%9c%ac    美国   = %e7%be%8e%e5%9b%bd
ENC_AUTO='%61%75%74%6f'
ENC_AUTOX='%61%75%74%6f%2d%78'
ENC_JP='%e6%97%a5%e6%9c%ac'
ENC_US='%e7%be%8e%e5%9b%bd'

REAL3='{"all":["n1","n2","n3"],"now":"n1"}'
REAL1='{"all":["n2"],"now":"n2"}'
EMPTY_REJECT='{"all":["REJECT"],"emptyFallback":"REJECT","now":"REJECT"}'
EMPTY_COMPAT='{"all":["COMPATIBLE"],"now":"COMPATIBLE"}'

GROUPS_FULL='{"proxies":[{"name":"auto","type":"URLTest","all":["n1","n2","n3"]},{"name":"auto-x","type":"URLTest","all":["n2"]},{"name":"日本","type":"URLTest","all":["n2"]},{"name":"美国","type":"URLTest","all":["n2"]},{"name":"PROXY","type":"Selector","all":["auto-x","auto","日本","美国","DIRECT","REJECT"]},{"name":"STREAMING","type":"Selector","all":["PROXY","auto","日本","美国","DIRECT"]},{"name":"GLOBAL","type":"Selector","all":["auto","PROXY"]}]}'
GROUPS_PREEPIC='{"proxies":[{"name":"auto","type":"URLTest","all":["n1","n2","n3"]},{"name":"PROXY","type":"Selector","all":["auto","DIRECT","REJECT"]},{"name":"STREAMING","type":"Selector","all":["PROXY","auto","DIRECT"]},{"name":"GLOBAL","type":"Selector","all":["auto","PROXY"]}]}'

new_state() { # NAME GROUP_JSON -> prints dir; per-group fixtures added after
  _d="$TMP/state-$1"; mkdir -p "$_d"
  printf '%s' "$2" > "$_d/group.json"
  : > "$_d/argv.log"
  printf '%s' "$_d"
}

OUT_F="$TMP/out.txt"
run_pg() { # STATE [ENV=VAL ...] - emit the proxy_groups record hermetically
  _st="$1"; shift
  env -i PATH="$STUB:/usr/bin:/bin" FAKE_STATE="$_st" \
    DOCKER_BIN=docker MIHOMO_CONTAINER=mihomo \
    CONTROLLER_PORT=9090 CONTROLLER_SECRET= "$@" \
    sh -c '. "$1/scripts/lib/checks.sh" && _c_emit proxy_groups' _ "$TREE" \
    > "$OUT_F" 2>&1 || true
}

# 1) healthy: auto + auto-x + two country groups, all with real nodes -> ok
ST=$(new_state healthy "$GROUPS_FULL")
printf '%s' "$REAL3" > "$ST/proxies-$ENC_AUTO.json"
printf '%s' "$REAL1" > "$ST/proxies-$ENC_AUTOX.json"
printf '%s' "$REAL1" > "$ST/proxies-$ENC_JP.json"
printf '%s' "$REAL1" > "$ST/proxies-$ENC_US.json"
run_pg "$ST"
grep -q '^proxy_groups|ok|ok|' "$OUT_F" \
  && ok || fail "healthy: want ok record, got: $(cat "$OUT_F")"

# 2) one country group empty (REJECT placeholder only) -> country-empty warn,
#    detail names the group, remediation hint follows
ST=$(new_state cempty "$GROUPS_FULL")
printf '%s' "$REAL3" > "$ST/proxies-$ENC_AUTO.json"
printf '%s' "$REAL1" > "$ST/proxies-$ENC_AUTOX.json"
printf '%s' "$REAL1" > "$ST/proxies-$ENC_JP.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_US.json"
run_pg "$ST"
grep -q '^proxy_groups|country-empty|warn|.*美国' "$OUT_F" \
  && ok || fail "country-empty: want warn naming 美国, got: $(cat "$OUT_F")"
grep -q '^#hint|.*COUNTRY_GROUPS' "$OUT_F" \
  && ok || fail "country-empty: want a COUNTRY_GROUPS remediation hint"

# 3) auto-x empty -> default-empty bad; empty country groups ride the detail
ST=$(new_state dempty "$GROUPS_FULL")
printf '%s' "$REAL3" > "$ST/proxies-$ENC_AUTO.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_AUTOX.json"
printf '%s' "$REAL1" > "$ST/proxies-$ENC_JP.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_US.json"
run_pg "$ST"
grep -q '^proxy_groups|default-empty|bad|.*auto-x' "$OUT_F" \
  && ok || fail "default-empty: want bad record, got: $(cat "$OUT_F")"
grep -q '^proxy_groups|default-empty|bad|.*美国' "$OUT_F" \
  && ok || fail "default-empty: detail must also carry the empty country group"
grep -q '^#hint|.*AUTO_EXCLUDE_FILTER' "$OUT_F" \
  && ok || fail "default-empty: want an AUTO_EXCLUDE_FILTER remediation hint"

# 4) EVERY url-test group empty -> the DEC-A provider-empty condition (warn,
#    seed_provider hint), never per-group findings
ST=$(new_state pempty "$GROUPS_FULL")
printf '%s' "$EMPTY_COMPAT" > "$ST/proxies-$ENC_AUTO.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_AUTOX.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_JP.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_US.json"
run_pg "$ST"
grep -q '^proxy_groups|provider-empty|warn|' "$OUT_F" \
  && ok || fail "provider-empty: want warn record, got: $(cat "$OUT_F")"
grep -q '^#hint|.*seed_provider' "$OUT_F" \
  && ok || fail "provider-empty: want the seed_provider.sh hint"

# 5) pre-epic config (no filtered groups) with a healthy auto -> plain ok
ST=$(new_state preepic "$GROUPS_PREEPIC")
printf '%s' "$REAL3" > "$ST/proxies-$ENC_AUTO.json"
run_pg "$ST"
grep -q '^proxy_groups|ok|ok|.*no filtered' "$OUT_F" \
  && ok || fail "pre-epic: want ok/no-filtered record, got: $(cat "$OUT_F")"

# 6) pre-epic config with an EMPTY auto -> provider-empty (DEC-A extension)
ST=$(new_state preempty "$GROUPS_PREEPIC")
printf '%s' "$EMPTY_COMPAT" > "$ST/proxies-$ENC_AUTO.json"
run_pg "$ST"
grep -q '^proxy_groups|provider-empty|warn|' "$OUT_F" \
  && ok || fail "pre-epic empty: want provider-empty, got: $(cat "$OUT_F")"

# 7) controller unreachable -> unknown|silent record (json-only visibility)
ST=$(new_state ctldown "$GROUPS_FULL")
: > "$ST/ctl_down"
run_pg "$ST"
grep -q '^proxy_groups|unknown|silent|' "$OUT_F" \
  && ok || fail "ctl-down: want unknown|silent, got: $(cat "$OUT_F")"

# 8) bearer token rides stdin, NEVER docker argv (repo rule)
ST=$(new_state secret "$GROUPS_PREEPIC")
printf '%s' "$REAL3" > "$ST/proxies-$ENC_AUTO.json"
run_pg "$ST" CONTROLLER_SECRET=sekret-token-123
grep -q '^proxy_groups|ok|ok|' "$OUT_F" \
  && ok || fail "secret path: want ok record, got: $(cat "$OUT_F")"
if grep -q 'sekret-token-123' "$ST/argv.log"; then
  fail "bearer token leaked onto docker argv"
else
  ok
fi

echo "proxy_groups_check: $pass passed, $failn failed"
[ "$failn" = 0 ] || exit 1
echo "OK: proxy_groups doctor check - ok/default-empty/country-empty/provider-empty/unknown contract, CJK %XX-encoded per-group queries, COMPATIBLE+REJECT placeholder exclusion, DEC-A cold-start grace (all-empty -> provider-empty, pre-epic covered), token never on argv"
