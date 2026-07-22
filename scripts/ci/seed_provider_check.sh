#!/bin/sh
# seed_provider_check.sh - hermetic behavioral suite for
# scripts/seed_provider.sh (the provider-cache recovery tool: host-side
# subscription fetch -> the stable cache filename -> restart -> REAL-node
# verification). Asserts the documented contract:
#   rc 0 nodes restored (or already present) | 2 seeded but no nodes |
#   3 fetch or validation failed | 6 needs root
# plus the privacy/robustness properties: the subscription URL (token) never
# reaches stdout - not even via the docker-logs excerpt on the rc-2 path -
# the cache file lands mode 600 (the payload embeds node credentials), the
# legacy md5-of-URL cache name is never written (pre-1.3.8 adoption purged),
# the COMPATIBLE placeholder of an empty group is never counted as a node,
# and the already-has-nodes path fetches and restarts nothing.
#
# Every invocation is HERMETIC (env -i, tree copy, PATH-stub docker/curl/id)
# so the suite cannot mask an env-dependence bug. BusyBox-ash safe.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"

pass=0; failn=0
ok()   { pass=$((pass+1)); }
fail() { echo "FAIL: $*" >&2; failn=$((failn+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- hermetic tree copy: the default data-dir path lands inside $TMP ----------
TREE="$TMP/syno-mihomo-gateway"
DATA="$TMP/syno-mihomo-gateway-data"
mkdir -p "$TREE" "$DATA/config" "$DATA/logs"
cp -R "$ROOT/scripts" "$TREE/scripts"
cp -R "$ROOT/config" "$TREE/config"
rm -f "$TREE/config/subscription.txt" "$TREE/config/config.yaml"
SP="$TREE/scripts/seed_provider.sh"

cat > "$DATA/.env" <<'EOF'
MIHOMO_IP=192.0.2.2
CONTROLLER_PORT=9090
CONTROLLER_SECRET=
EOF
chmod 600 "$DATA/.env"
SUB="$DATA/config/subscription.txt"
printf 'https://panel.example.com/api/v1/sub?token=SECRETTOKEN\n' > "$SUB"
chmod 600 "$SUB"

# --- stub seams ----------------------------------------------------------------
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-u" ] && { echo "${FAKE_UID:-0}"; exit 0; }
exit 0
EOF
chmod +x "$STUB/id"

# docker: `compose version` ok (detect_compose); `restart` records itself;
# `logs` emits a provider error CARRYING the token URL (the suite asserts the
# script's excerpt redacts it); `exec ... wget ... URL` answers the controller
# from canned per-endpoint JSON, switching the All Nodes members after a
# restart (spaced names arrive %20-encoded: All%20Nodes / Routing%20Mode; the
# chain-walk hops arrive fully %XX-encoded, e.g. Exit Country =
# %45%78%69%74%20%43%6f%75%6e%74%72%79, JPX = %4a%50%58).
cat > "$STUB/docker" <<'EOF'
#!/bin/sh
STATE="${FAKE_STATE:?}"
case "${1:-}" in
  compose) exit 0 ;;
  restart) : > "$STATE/restarted"; exit 0 ;;
  logs)
    echo 'level=error msg="[Provider] my-airport pull error: Get https://panel.example.com/api/v1/sub?token=SECRETTOKEN: tls timeout"'
    exit 0 ;;
  exec) ;;
  *) exit 0 ;;
esac
URL=""
for _a in "$@"; do URL="$_a"; done
case "$URL" in
  */proxies/All%20Nodes*)
    if [ -f "$STATE/restarted" ]; then cat "$STATE/auto_after.json"
    else cat "$STATE/auto_before.json"; fi ;;
  */group/All%20Nodes/*) echo '{}' ;;
  */proxies/Routing%20Mode/delay*)
    if [ -f "$STATE/delay_ok" ]; then echo '{"delay":42}'
    else echo '{"message":"timeout"}'; fi ;;
  */proxies/Routing%20Mode*) echo '{"all":["Exit Country","DIRECT","REJECT"],"now":"Exit Country"}' ;;
  */proxies/%45%78%69%74%20%43%6f%75%6e%74%72%79*) echo '{"all":["JPX"],"now":"JPX"}' ;;
  */proxies/%4a%50%58*) echo '{"all":["n1","n2"],"now":"n1"}' ;;
  *) echo '{}' ;;
esac
exit 0
EOF
chmod +x "$STUB/docker"

# curl: consumes the -K - stdin config (the URL - never echoed), writes the
# canned payload to the -o target per FAKE_CURL_MODE, records being called.
cat > "$STUB/curl" <<'EOF'
#!/bin/sh
: > "${FAKE_STATE:?}/curl_called"
cat > /dev/null
OUT=""; prev=""
for _a in "$@"; do
  [ "$prev" = "-o" ] && OUT="$_a"
  prev="$_a"
done
big() { i=0; while [ $i -lt 900 ]; do printf '  - {name: n%s, server: s%s.example.com, port: 443}\n' "$i" "$i"; i=$((i+1)); done; }
case "${FAKE_CURL_MODE:-good}" in
  fail) exit 7 ;;
  small) printf 'proxies:\n' > "$OUT" ;;
  noproxies) big > "$OUT" ;;
  good) { printf 'proxies:\n'; big; } > "$OUT" ;;
esac
printf 'http_code=200 size_bytes=%s time=1.0s\n' "$(wc -c < "$OUT" | tr -d " ")"
exit 0
EOF
chmod +x "$STUB/curl"

EMPTY_AUTO='{"all":["COMPATIBLE"],"emptyFallback":"COMPATIBLE","now":"COMPATIBLE"}'
FULL_AUTO='{"all":["n1","n2","n3"],"now":"n1"}'

# run_sp STATE_DIR [ENV=VAL ...] - hermetic invocation; rc in $RC, output in $OUT_F
OUT_F="$TMP/out.txt"
run_sp() {
  _st="$1"; shift
  RC=0
  env -i PATH="$STUB:/usr/bin:/bin" HOME="$TMP" FAKE_STATE="$_st" "$@" \
    sh "$SP" > "$OUT_F" 2>&1 || RC=$?
}

new_state() {  # new_state NAME BEFORE_JSON AFTER_JSON -> prints dir
  _d="$TMP/state-$1"; mkdir -p "$_d"
  printf '%s' "$2" > "$_d/auto_before.json"
  printf '%s' "$3" > "$_d/auto_after.json"
  printf '%s' "$_d"
}
reset_caches() { rm -rf "$DATA/config/proxies"; }

# 1) non-root -> rc 6, nothing touched
ST=$(new_state root "$EMPTY_AUTO" "$FULL_AUTO")
run_sp "$ST" FAKE_UID=1000
if [ "$RC" = 6 ]; then ok; else fail "non-root rc=$RC, want 6"; fi
if [ ! -f "$ST/curl_called" ]; then ok; else fail "non-root run invoked curl"; fi

# 2) already has nodes -> rc 0 no-op: no fetch, no restart, no cache written
reset_caches
ST=$(new_state noop "$FULL_AUTO" "$FULL_AUTO")
run_sp "$ST"
if [ "$RC" = 0 ]; then ok; else fail "no-op rc=$RC, want 0"; fi
if [ ! -f "$ST/curl_called" ] && [ ! -f "$ST/restarted" ]; then ok; else fail "no-op run fetched or restarted"; fi
if [ ! -f "$DATA/config/proxies/my-airport.yaml" ]; then ok; else fail "no-op run wrote a cache"; fi

# 3) the recovery path: empty provider -> seed -> restart -> 3 real nodes
reset_caches
ST=$(new_state good "$EMPTY_AUTO" "$FULL_AUTO"); : > "$ST/delay_ok"
run_sp "$ST"
if [ "$RC" = 0 ]; then ok; else fail "seed rc=$RC, want 0"; fi
if [ -f "$ST/restarted" ]; then ok; else fail "seed did not restart mihomo"; fi
f="$DATA/config/proxies/my-airport.yaml"
if [ -f "$f" ] && grep -q '^proxies:' "$f"; then ok; else fail "cache $f missing or not the payload"; fi
_mode=$(ls -l "$f" | cut -c1-10)
if [ "$_mode" = "-rw-------" ]; then ok; else fail "cache $f mode $_mode, want -rw------- (600)"; fi
# The legacy md5-of-URL cache name is NEVER written - the pre-1.3.8
# adoption machinery was purged; only the stable `path:` name remains.
HASH=$(printf '%s' "https://panel.example.com/api/v1/sub?token=SECRETTOKEN" | md5sum | awk '{print $1}')
if [ ! -f "$DATA/config/proxies/$HASH" ]; then ok; else fail "legacy md5-named cache was written: proxies/$HASH"; fi
if grep -q 'provider loaded 3 nodes' "$OUT_F"; then ok; else fail "seed did not report 3 loaded nodes"; fi
if ! grep -q 'SECRETTOKEN' "$OUT_F"; then ok; else fail "subscription token leaked to output"; fi

# 4) payload too small -> rc 3, nothing planted, no restart
reset_caches
ST=$(new_state small "$EMPTY_AUTO" "$FULL_AUTO")
run_sp "$ST" FAKE_CURL_MODE=small
if [ "$RC" = 3 ]; then ok; else fail "small-payload rc=$RC, want 3"; fi
if [ ! -f "$DATA/config/proxies/my-airport.yaml" ] && [ ! -f "$ST/restarted" ]; then ok; else fail "small payload was planted or restarted"; fi

# 5) big payload without a proxies: key (error page) -> rc 3
reset_caches
ST=$(new_state noproxies "$EMPTY_AUTO" "$FULL_AUTO")
run_sp "$ST" FAKE_CURL_MODE=noproxies
if [ "$RC" = 3 ]; then ok; else fail "no-proxies-key rc=$RC, want 3"; fi

# 6) host fetch fails -> rc 3
reset_caches
ST=$(new_state curlfail "$EMPTY_AUTO" "$FULL_AUTO")
run_sp "$ST" FAKE_CURL_MODE=fail
if [ "$RC" = 3 ]; then ok; else fail "curl-fail rc=$RC, want 3"; fi

# 7) seeded but the provider still shows only the placeholder -> rc 2,
#    and the docker-logs excerpt REDACTS the token URL
reset_caches
ST=$(new_state stuck "$EMPTY_AUTO" "$EMPTY_AUTO")
run_sp "$ST"
if [ "$RC" = 2 ]; then ok; else fail "stuck rc=$RC, want 2"; fi
if ! grep -q 'SECRETTOKEN' "$OUT_F"; then ok; else fail "rc-2 log excerpt leaked the token"; fi
if grep -q 'URL_REDACTED' "$OUT_F"; then ok; else fail "rc-2 path did not show the redacted log line"; fi

# 8) no usable subscription URL -> rc 3
reset_caches
printf '# comment only\n' > "$SUB"
ST=$(new_state nosub "$EMPTY_AUTO" "$FULL_AUTO")
run_sp "$ST"
if [ "$RC" = 3 ]; then ok; else fail "no-subscription rc=$RC, want 3"; fi
printf 'https://panel.example.com/api/v1/sub?token=SECRETTOKEN\n' > "$SUB"

echo "seed_provider_check: $pass passed, $failn failed"
[ "$failn" -eq 0 ] || exit 1
echo "OK: seed_provider.sh contract (rc 0/2/3/6), 600-mode stable-path cache write (legacy md5 name never written), no-op path fetches nothing, COMPATIBLE never counted, token never printed (incl. redacted rc-2 log excerpt)"
