#!/bin/sh
# full_proxy_check.sh - hermetic behavioral suite for the doctor's
# full_proxy check (scripts/lib/checks.sh chk_full_proxy, issue #46): the
# per-device full-proxy band guard. Asserts the documented contract:
#   disabled        - knob unset AND no rendered band lines -> silent record
#   unknown         - knob set but no readable rendered config -> silent
#   parity-drift    - rendered SRC-IP-CIDR set != normalized knob (stale
#                     render; either direction) -> warn + redeploy hint
#   ok              - parity holds; controller down degrades to static-only,
#                     controller up scans /connections (band flows must
#                     carry 'Full Proxy' in their chain)
#   chain-violation - a non-LAN flow from a band source bypasses Full Proxy
#                     (the DEC-A UDP/QUIC fallthrough class) -> warn naming
#                     the flow, the UDP residual, and ipv6_bypass
# plus the transport/scoping properties: bare knob IPs compare /32-
# normalized, LAN-destination band flows are exempt (the GEOIP,LAN rule
# keeps them DIRECT by design), non-band sources are ignored, and the
# bearer token never appears on docker argv (stdin only, the repo rule).
# Also carries the #45 advisory sibling fixture: chk_proxy_groups
# short-circuits to unknown when /group succeeds but the Country Pick
# "now" fetch fails (never misclassifies default-empty as country-empty).
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
  */connections)
    cat "$STATE/connections.json" 2>/dev/null || echo '{}' ;;
  */group)
    cat "$STATE/group.json" 2>/dev/null || echo '{}' ;;
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

# Band fixture: 192.0.2.16/28 (TEST-NET-1 slice, .16-.31) + a /32 device.
BAND='192.0.2.16/28,192.0.2.5'
CFG_LINES="  - 'SRC-IP-CIDR,192.0.2.16/28,Full Proxy'
  - 'SRC-IP-CIDR,192.0.2.5/32,Full Proxy'"

new_state() { # NAME -> prints dir
  _d="$TMP/state-$1"; mkdir -p "$_d/config"
  : > "$_d/argv.log"
  printf '%s' "$_d"
}
write_cfg() { # STATE BODY - a minimal rendered config with the given rules
  cat > "$1/config/config.yaml" <<CFGEOF
mode: rule
rules:
  - 'GEOIP,LAN,DIRECT,no-resolve'
$2
  - 'MATCH,Proxy Mode'
CFGEOF
}

OUT_F="$TMP/out.txt"
run_fp() { # STATE [ENV=VAL ...] - emit the full_proxy record hermetically
  _st="$1"; shift
  env -i PATH="$STUB:/usr/bin:/bin" FAKE_STATE="$_st" \
    DOCKER_BIN=docker MIHOMO_CONTAINER=mihomo \
    CONFIG_STATE_DIR="$_st/config" \
    CONTROLLER_PORT=9090 CONTROLLER_SECRET= "$@" \
    sh -c '. "$1/scripts/lib/checks.sh" && _c_emit full_proxy' _ "$TREE" \
    > "$OUT_F" 2>&1 || true
}
run_pg() { # STATE [ENV=VAL ...] - emit the proxy_groups record (advisory fixture)
  _st="$1"; shift
  env -i PATH="$STUB:/usr/bin:/bin" FAKE_STATE="$_st" \
    DOCKER_BIN=docker MIHOMO_CONTAINER=mihomo \
    CONTROLLER_PORT=9090 CONTROLLER_SECRET= "$@" \
    sh -c '. "$1/scripts/lib/checks.sh" && _c_emit proxy_groups' _ "$TREE" \
    > "$OUT_F" 2>&1 || true
}

# 1) knob unset + no rendered band lines -> disabled|silent
ST=$(new_state disabled)
write_cfg "$ST" "  - 'GEOSITE,CN,DIRECT'"
run_fp "$ST"
grep -q '^full_proxy|disabled|silent|' "$OUT_F" \
  && ok || fail "disabled: want disabled|silent, got: $(cat "$OUT_F")"

# 2) knob set but no readable config -> unknown|silent
ST=$(new_state noconfig)
rm -rf "$ST/config"; mkdir -p "$ST/config"
run_fp "$ST" FULL_PROXY_SOURCES="$BAND"
grep -q '^full_proxy|unknown|silent|' "$OUT_F" \
  && ok || fail "no-config: want unknown|silent, got: $(cat "$OUT_F")"

# 3) parity ok + controller DOWN -> ok, static-only detail, names ipv6_bypass
ST=$(new_state ctldown)
write_cfg "$ST" "$CFG_LINES"
: > "$ST/ctl_down"
run_fp "$ST" FULL_PROXY_SOURCES="$BAND"
grep -q '^full_proxy|ok|ok|.*controller unreachable' "$OUT_F" \
  && ok || fail "ctl-down: want static-only ok, got: $(cat "$OUT_F")"
grep -q '^full_proxy|ok|ok|.*ipv6_bypass' "$OUT_F" \
  && ok || fail "ctl-down: detail must reference ipv6_bypass"

# 4) parity drift: knob has an entry the render lacks -> parity-drift|warn
ST=$(new_state drift)
write_cfg "$ST" "  - 'SRC-IP-CIDR,192.0.2.16/28,Full Proxy'"
run_fp "$ST" FULL_PROXY_SOURCES="$BAND"
grep -q '^full_proxy|parity-drift|warn|.*NOT live' "$OUT_F" \
  && ok || fail "drift: want parity-drift|warn, got: $(cat "$OUT_F")"
grep -q '^#hint|.*Redeploy' "$OUT_F" \
  && ok || fail "drift: want a redeploy hint"

# 5) stale band lines with the knob UNSET -> parity-drift (either direction)
ST=$(new_state stale)
write_cfg "$ST" "$CFG_LINES"
run_fp "$ST"
grep -q '^full_proxy|parity-drift|warn|' "$OUT_F" \
  && ok || fail "stale: want parity-drift on knob-unset+lines-present, got: $(cat "$OUT_F")"

# 6) runtime ok: /32-normalized parity + band flows all riding Full Proxy;
#    LAN-destination band flow without the chain is EXEMPT; non-band
#    source without the chain is IGNORED
ST=$(new_state runtimeok)
write_cfg "$ST" "$CFG_LINES"
cat > "$ST/connections.json" <<'EOF'
{"downloadTotal":1,"uploadTotal":2,"connections":[
{"id":"a1","metadata":{"network":"tcp","type":"tun","sourceIP":"192.0.2.20","destinationIP":"93.184.216.34","host":"example.com"},"chains":["JP01","Japan Auto","Country Pick","Proxy Mode","Full Proxy"],"rule":"SrcIPCIDR"},
{"id":"a2","metadata":{"network":"udp","type":"tun","sourceIP":"192.0.2.5","destinationIP":"93.184.216.35","host":""},"chains":["JP01","Japan Auto","Country Pick","Proxy Mode","Full Proxy"],"rule":"SrcIPCIDR"},
{"id":"a3","metadata":{"network":"tcp","type":"tun","sourceIP":"192.0.2.20","destinationIP":"192.168.1.5","host":""},"chains":["DIRECT"],"rule":"GeoIP"},
{"id":"a4","metadata":{"network":"tcp","type":"tun","sourceIP":"192.0.2.50","destinationIP":"93.184.216.34","host":""},"chains":["Proxy Mode","Country Pick","Japan Auto","JP01"],"rule":"Match"},
{"id":"a5","metadata":{"network":"udp","type":"tun","sourceIP":"192.0.2.20","destinationIP":"239.255.255.250","host":""},"chains":["DIRECT"],"rule":"GeoIP"}
]}
EOF
run_fp "$ST" FULL_PROXY_SOURCES="$BAND"
grep -q '^full_proxy|ok|ok|.*2 band flow(s) scanned' "$OUT_F" \
  && ok || fail "runtime-ok: want ok with 2 scanned (LAN + multicast dst exempt, non-band ignored), got: $(cat "$OUT_F")"

# 7) chain violation: band source, non-LAN destination, chain lacks Full
#    Proxy -> chain-violation|warn naming the flow + UDP residual + ipv6_bypass
ST=$(new_state viol)
write_cfg "$ST" "$CFG_LINES"
cat > "$ST/connections.json" <<'EOF'
{"connections":[
{"id":"b1","metadata":{"network":"udp","type":"tun","sourceIP":"192.0.2.21","destinationIP":"120.232.145.144","host":""},"chains":["DIRECT"],"rule":"GeoIP"},
{"id":"b2","metadata":{"network":"tcp","type":"tun","sourceIP":"192.0.2.21","destinationIP":"93.184.216.34","host":""},"chains":["JP01","Japan Auto","Country Pick","Proxy Mode","Full Proxy"],"rule":"SrcIPCIDR"},
{"id":"b3","metadata":{"network":"tcp","type":"tun","sourceIP":"192.0.2.21","destinationIP":"240.0.0.1","host":""},"chains":["DIRECT"],"rule":"Match"}
]}
EOF
run_fp "$ST" FULL_PROXY_SOURCES="$BAND"
grep -q '^full_proxy|chain-violation|warn|.*2 of 3' "$OUT_F" \
  && ok || fail "violation: want chain-violation naming 2 of 3 (240/4 is NOT LAN - mihomo's isLan stops at multicast), got: $(cat "$OUT_F")"
grep -q '^full_proxy|chain-violation|warn|.*192.0.2.21' "$OUT_F" \
  && ok || fail "violation: detail must carry the example flow"
grep -q '^full_proxy|chain-violation|warn|.*UDP' "$OUT_F" \
  && ok || fail "violation: detail must name the UDP/QUIC residual"
grep -q '^full_proxy|chain-violation|warn|.*ipv6_bypass' "$OUT_F" \
  && ok || fail "violation: detail must reference ipv6_bypass"

# 8) bearer token rides stdin, NEVER docker argv (repo rule)
ST=$(new_state secret)
write_cfg "$ST" "$CFG_LINES"
cat > "$ST/connections.json" <<'EOF'
{"connections":[]}
EOF
run_fp "$ST" FULL_PROXY_SOURCES="$BAND" CONTROLLER_SECRET=sekret-token-123
grep -q '^full_proxy|ok|ok|' "$OUT_F" \
  && ok || fail "secret path: want ok record, got: $(cat "$OUT_F")"
if grep -q 'sekret-token-123' "$ST/argv.log"; then
  fail "bearer token leaked onto docker argv"
else
  ok
fi

# 9) #45 advisory sibling fixture: /group answers (Country Pick present)
#    but the Country Pick "now" fetch fails -> proxy_groups short-circuits
#    to unknown|silent (never misclassifies default-empty as country-empty)
ST=$(new_state pgflake)
printf '%s' '{"proxies":[{"name":"Country Pick","type":"Selector","all":["日本"]},{"name":"日本","type":"URLTest","all":["n1"]},{"name":"All Nodes","type":"URLTest","all":["n1"]}]}' \
  > "$ST/group.json"
run_pg "$ST"
grep -q '^proxy_groups|unknown|silent|' "$OUT_F" \
  && ok || fail "pg-flake: want unknown|silent short-circuit, got: $(cat "$OUT_F")"

echo "full_proxy_check: $pass passed, $failn failed"
[ "$failn" = 0 ] || exit 1
echo "OK: full_proxy doctor check - disabled/unknown/parity-drift/ok/chain-violation contract, /32-normalized knob parity both directions, LAN-destination exemption, non-band sources ignored, UDP-residual + ipv6_bypass wording, token never on argv; plus the proxy_groups unknown short-circuit on a failed Country Pick now-fetch"
