#!/bin/sh
# proxy_groups_check.sh - hermetic behavioral suite for the doctor's
# proxy_groups check (scripts/lib/checks.sh chk_proxy_groups, issue #34,
# reworked for the group-model streamline #45): the zero-node guard for the
# generated "<Country> Auto" url-test groups. Asserts the documented contract:
#   ok             - every country group has real nodes (detail names the
#                    Exit Country selection), or no country groups are live
#                    at all (a pre-streamline config still running)
#   default-empty  - the country group Exit Country is RIDING has no real
#                    nodes (the routing default is dead) -> bad; other empty
#                    country groups ride the detail
#   country-empty  - some non-selected country group(s) empty -> warn
#   provider-empty - EVERY url-test group is empty (cold provider, not a
#                    filter problem; DEC-A grace) -> warn + seed hint
#   unknown        - controller unreachable -> silent record
# plus the transport properties: group names ride the URL %XX-encoded byte
# by byte (CJK-safe; the expected encodings are HARDCODED here so the
# encoder is verified independently), real-node counting excludes BOTH
# placeholder adapters (COMPATIBLE - mihomo's default - and REJECT - the
# generated groups' empty-fallback), and the bearer token never appears on
# docker argv (stdin only, the repo rule).
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

# Hardcoded %XX byte encodings (independent check of the sh encoder; the
# every-byte encoder carries SPACES as %20, which is what makes the spaced
# group names URL-safe):
#   All Nodes    = %41%6c%6c%20%4e%6f%64%65%73
#   Exit Country = %45%78%69%74%20%43%6f%75%6e%74%72%79
#   日本         = %e6%97%a5%e6%9c%ac    美国 = %e7%be%8e%e5%9b%bd
ENC_ALL='%41%6c%6c%20%4e%6f%64%65%73'
ENC_PICK='%45%78%69%74%20%43%6f%75%6e%74%72%79'
ENC_JP='%e6%97%a5%e6%9c%ac'
ENC_US='%e7%be%8e%e5%9b%bd'

REAL3='{"all":["n1","n2","n3"],"now":"n1"}'
REAL1='{"all":["n2"],"now":"n2"}'
EMPTY_REJECT='{"all":["REJECT"],"emptyFallback":"REJECT","now":"REJECT"}'
EMPTY_COMPAT='{"all":["COMPATIBLE"],"now":"COMPATIBLE"}'
PICK_JP='{"all":["日本","美国"],"now":"日本"}'
PICK_US='{"all":["日本","美国"],"now":"美国"}'

GROUPS_FULL='{"proxies":[{"name":"Routing Mode","type":"Selector","all":["Exit Country","DIRECT","REJECT"]},{"name":"Streaming Unlock","type":"Selector","all":["Routing Mode","日本","美国","DIRECT"]},{"name":"Exit Country","type":"Selector","all":["日本","美国"]},{"name":"日本","type":"URLTest","all":["n2"]},{"name":"美国","type":"URLTest","all":["n2"]},{"name":"All Nodes","type":"URLTest","hidden":true,"all":["n1","n2","n3"]},{"name":"GLOBAL","type":"Selector","all":["All Nodes","Routing Mode"]}]}'
GROUPS_PRESTREAM='{"proxies":[{"name":"All Nodes","type":"URLTest","all":["n1","n2","n3"]},{"name":"PROXY","type":"Selector","all":["All Nodes","DIRECT","REJECT"]},{"name":"STREAMING","type":"Selector","all":["PROXY","All Nodes","DIRECT"]},{"name":"GLOBAL","type":"Selector","all":["All Nodes","PROXY"]}]}'

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

# 1) healthy: two country groups with real nodes, Exit Country riding 日本 -> ok
ST=$(new_state healthy "$GROUPS_FULL")
printf '%s' "$REAL3" > "$ST/proxies-$ENC_ALL.json"
printf '%s' "$PICK_JP" > "$ST/proxies-$ENC_PICK.json"
printf '%s' "$REAL1" > "$ST/proxies-$ENC_JP.json"
printf '%s' "$REAL1" > "$ST/proxies-$ENC_US.json"
run_pg "$ST"
grep -q '^proxy_groups|ok|ok|' "$OUT_F" \
  && ok || fail "healthy: want ok record, got: $(cat "$OUT_F")"
grep -q '^proxy_groups|ok|ok|.*日本' "$OUT_F" \
  && ok || fail "healthy: detail must name the Exit Country selection"

# 2) a NON-selected country group empty (REJECT placeholder only) ->
#    country-empty warn, detail names the group, remediation hint follows
ST=$(new_state cempty "$GROUPS_FULL")
printf '%s' "$REAL3" > "$ST/proxies-$ENC_ALL.json"
printf '%s' "$PICK_JP" > "$ST/proxies-$ENC_PICK.json"
printf '%s' "$REAL1" > "$ST/proxies-$ENC_JP.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_US.json"
run_pg "$ST"
grep -q '^proxy_groups|country-empty|warn|.*美国' "$OUT_F" \
  && ok || fail "country-empty: want warn naming 美国, got: $(cat "$OUT_F")"
grep -q '^#hint|.*COUNTRY_GROUPS' "$OUT_F" \
  && ok || fail "country-empty: want a COUNTRY_GROUPS remediation hint"

# 3) the SELECTED country group empty -> default-empty bad naming the
#    selection; other empty country groups ride the detail; hint names the
#    knob AND the dashboard stopgap
ST=$(new_state dempty "$GROUPS_FULL")
printf '%s' "$REAL3" > "$ST/proxies-$ENC_ALL.json"
printf '%s' "$PICK_US" > "$ST/proxies-$ENC_PICK.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_JP.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_US.json"
run_pg "$ST"
grep -q '^proxy_groups|default-empty|bad|.*美国' "$OUT_F" \
  && ok || fail "default-empty: want bad record naming the selection, got: $(cat "$OUT_F")"
grep -q '^proxy_groups|default-empty|bad|.*日本' "$OUT_F" \
  && ok || fail "default-empty: detail must also carry the other empty country group"
grep -q '^#hint|.*COUNTRY_GROUPS' "$OUT_F" \
  && ok || fail "default-empty: want a COUNTRY_GROUPS remediation hint"
grep -q '^#hint|.*Exit Country' "$OUT_F" \
  && ok || fail "default-empty: hint must name the Exit Country stopgap"

# 4) EVERY url-test group empty -> the DEC-A provider-empty condition (warn,
#    seed_provider hint), never per-group findings
ST=$(new_state pempty "$GROUPS_FULL")
printf '%s' "$EMPTY_COMPAT" > "$ST/proxies-$ENC_ALL.json"
printf '%s' "$PICK_JP" > "$ST/proxies-$ENC_PICK.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_JP.json"
printf '%s' "$EMPTY_REJECT" > "$ST/proxies-$ENC_US.json"
run_pg "$ST"
grep -q '^proxy_groups|provider-empty|warn|' "$OUT_F" \
  && ok || fail "provider-empty: want warn record, got: $(cat "$OUT_F")"
grep -q '^#hint|.*seed_provider' "$OUT_F" \
  && ok || fail "provider-empty: want the seed_provider.sh hint"

# 5) pre-streamline config (no Exit Country / country groups) with a healthy
#    All Nodes -> ok with the redeploy note
ST=$(new_state prestream "$GROUPS_PRESTREAM")
printf '%s' "$REAL3" > "$ST/proxies-$ENC_ALL.json"
run_pg "$ST"
grep -q '^proxy_groups|ok|ok|.*pre-streamline' "$OUT_F" \
  && ok || fail "pre-streamline: want ok/redeploy-note record, got: $(cat "$OUT_F")"

# 6) pre-streamline config with an EMPTY All Nodes -> provider-empty (DEC-A)
ST=$(new_state preempty "$GROUPS_PRESTREAM")
printf '%s' "$EMPTY_COMPAT" > "$ST/proxies-$ENC_ALL.json"
run_pg "$ST"
grep -q '^proxy_groups|provider-empty|warn|' "$OUT_F" \
  && ok || fail "pre-streamline empty: want provider-empty, got: $(cat "$OUT_F")"

# 7) controller unreachable -> unknown|silent record (json-only visibility)
ST=$(new_state ctldown "$GROUPS_FULL")
: > "$ST/ctl_down"
run_pg "$ST"
grep -q '^proxy_groups|unknown|silent|' "$OUT_F" \
  && ok || fail "ctl-down: want unknown|silent, got: $(cat "$OUT_F")"

# 8) bearer token rides stdin, NEVER docker argv (repo rule)
ST=$(new_state secret "$GROUPS_PRESTREAM")
printf '%s' "$REAL3" > "$ST/proxies-$ENC_ALL.json"
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
echo "OK: proxy_groups doctor check - ok/default-empty/country-empty/provider-empty/unknown contract keyed on the Exit Country selection, CJK %XX-encoded per-group queries, COMPATIBLE+REJECT placeholder exclusion, DEC-A cold-start grace (all-empty -> provider-empty, pre-streamline covered), token never on argv"
