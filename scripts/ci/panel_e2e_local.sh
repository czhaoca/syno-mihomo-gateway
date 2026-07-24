#!/bin/sh
# panel_e2e_local.sh - the LOCAL real-stack e2e driver (#69, dev machine only;
# never a CI step - CI stays hermetic per DEC-3, and the NAS release gate is
# validate_release.sh A6).
#
# What it proves before a push, with real containers and the real images:
# the rendered TUN-off config boots mihomo; the panel (built from app/ right
# here - this is also the Dockerfile build proof) reaches the controller,
# writes the dynamic providers, and mihomo hot-reloads them; SRC-IP
# discrimination is real: with ZERO proxy nodes a full-tunnel source is
# fail-closed (Full-Tunnel Devices -> REJECT) while a full-direct source
# fetches DIRECT successfully - same destination, different source, opposite
# outcomes - and removing the full-direct entry re-routes that source back
# through Routing Mode (fail-closed again). Parity read-back stays ok.
#
# Needs internet (mihomo's first boot fetches the geo DBs, and the probe
# destination is the public 204 endpoint - a bridge-local target would sit
# behind GEOIP,LAN,DIRECT, which precedes the dynamic pair by design, and
# prove nothing). No subscription, no TUN, no macvlan: one docker bridge
# with pinned IPs.
#
# Usage: sh scripts/ci/panel_e2e_local.sh   (needs docker + internet; ~2-3 min)
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
NET=smg-e2e-net
SUBNET=172.29.87.0/24
IP_MIHOMO=172.29.87.10
IP_PANEL=172.29.87.20
IP_C1=172.29.87.31   # full-tunnel source
IP_C2=172.29.87.32   # full-direct source
G204="${SMG_E2E_TEST_URL:-http://www.gstatic.com/generate_204}"
MIHOMO_IMG="${SMG_E2E_MIHOMO_IMAGE:-docker.io/metacubex/mihomo:latest}"
PANEL_IMG=smg-panel-e2e
CTL_SECRET=e2e-controller-fixture
PANEL_TOKEN=e2e-panel-fixture

PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

WD="$(mktemp -d "${TMPDIR:-/tmp}/smg-panel-e2e.XXXXXX")" || exit 1
cleanup() {
  if [ "${SMG_E2E_HOLD:-0}" = 1 ]; then
    echo "SMG_E2E_HOLD=1: stack left up for post-mortem (workdir $WD)"
    echo "clean up with: docker rm -f smg-e2e-mihomo smg-e2e-panel smg-e2e-c1 smg-e2e-c2; docker network rm $NET"
    return 0
  fi
  docker rm -f smg-e2e-mihomo smg-e2e-panel smg-e2e-c1 smg-e2e-c2 >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$WD"
}
# INT/TERM must ABORT, not resume after the handler (POSIX trap semantics):
# clear the EXIT trap first so cleanup runs exactly once.
trap 'cleanup' EXIT
trap 'trap - EXIT; cleanup; exit 130' INT TERM

# pget PATH - GET the panel API from inside its container (bearer-authed).
pget() {
  docker exec smg-e2e-panel python3 -c '
import sys,urllib.request
r = urllib.request.Request("http://127.0.0.1:8090%s" % sys.argv[1],
                           headers={"Authorization": "Bearer %s" % sys.argv[2]})
sys.stdout.write(urllib.request.urlopen(r, timeout=8).read().decode())' "$1" "$PANEL_TOKEN" 2>/dev/null
}

# ppost METHOD PATH JSON - mutate the panel API; prints the response body.
ppost() {
  docker exec smg-e2e-panel python3 -c '
import sys,urllib.request
r = urllib.request.Request("http://127.0.0.1:8090%s" % sys.argv[2],
                           data=sys.argv[3].encode(), method=sys.argv[1],
                           headers={"Authorization": "Bearer %s" % sys.argv[4],
                                    "Content-Type": "application/json"})
sys.stdout.write(urllib.request.urlopen(r, timeout=8).read().decode())' \
    "$1" "$2" "${3:-}" "$PANEL_TOKEN" 2>/dev/null
}

# ctl_count NAME - the mihomo rule-provider's ruleCount, queried from the
# panel container (it already speaks to the controller; secret via argv is
# fine HERE: a dev fixture value, never a real credential).
ctl_count() {
  docker exec smg-e2e-panel python3 -c '
import json,sys,urllib.request
r = urllib.request.Request("http://'"$IP_MIHOMO"':9090/providers/rules",
                           headers={"Authorization": "Bearer %s" % sys.argv[2]})
d = json.load(urllib.request.urlopen(r, timeout=8))
p = d.get("providers", {}).get(sys.argv[1])
print(p.get("ruleCount", -1) if p else -1)' "$1" "$CTL_SECRET" 2>/dev/null
}

# cfetch NAME - fetch the public 204 endpoint THROUGH mihomo's mixed port
# from client NAME; rc 0 iff HTTP 204 arrived. The TCP source mihomo sees
# is the client's pinned bridge IP - what SRC-IP-CIDR discriminates on.
# The destination is PUBLIC on purpose: a LAN destination would match
# GEOIP,LAN,DIRECT ahead of the dynamic pair (the LAN exemption).
cfetch() {
  if [ "${SMG_E2E_DEBUG:-0}" = 1 ]; then
    docker exec "$1" python3 -c '
import urllib.request
h = urllib.request.ProxyHandler({"http": "http://'"$IP_MIHOMO"':7890"})
r = urllib.request.build_opener(h).open("'"$G204"'", timeout=6)
raise SystemExit(0 if r.status == 204 else 1)'
  else
    docker exec "$1" python3 -c '
import urllib.request
h = urllib.request.ProxyHandler({"http": "http://'"$IP_MIHOMO"':7890"})
r = urllib.request.build_opener(h).open("'"$G204"'", timeout=6)
raise SystemExit(0 if r.status == 204 else 1)' >/dev/null 2>&1
  fi
}

echo "=== render (TUN off, .env.example knobs via the strict dotenv loader) ==="
mkdir -p "$WD/cfg"
# .env.example values are dotenv, NOT shell (COUNTRY_GROUPS carries unquoted
# spaces/|/;) - only the repo's own loader may read it.
# shellcheck source=scripts/lib/common.sh disable=SC1091
. "$ROOT/scripts/lib/common.sh"
dotenv_load "$ROOT/.env.example"
# Fixture subscription: the provider URL never resolves - the #63 zero-byte
# seeds keep mihomo booting anyway (the panel layer under test is
# subscription-independent).
printf 'Default=https://sub.example.invalid/fixture?token=REPLACE_ME\n' > "$WD/cfg/subscription.txt"
# Both DNS horizons pin to the CN (direct) resolver list: the example's
# foreign horizon detours DoH through Routing Mode, which is fail-closed
# REJECT with zero nodes - resolution would die before the ROUTING layer
# this driver actually tests ever saw the flow.
if ! TUN_ENABLE=false CONTROLLER_SECRET="$CTL_SECRET" FULL_PROXY_SOURCES='' \
     DNS_FOREIGN_NAMESERVER="${DNS_CN_NAMESERVER:?}" \
     MIHOMO_TEMPLATE="$ROOT/config/config.template.yaml" \
     MIHOMO_CONFIG_DIR="$WD/cfg" sh "$ROOT/scripts/render_config.sh" >/dev/null 2>&1; then
  bad "render_config.sh failed with the .env.example fixture knobs"
  echo "FAILED: $PASS passed, $((FAIL)) failed"; exit 1
fi
# The zero-byte dyn seeds are the ENTRYPOINT's job in production
# (scripts/mihomo_entrypoint.sh, the #63 contract); this driver runs the
# raw image so it seeds them itself.
mkdir -p "$WD/cfg/providers"
: > "$WD/cfg/providers/dyn-full-direct.txt"
: > "$WD/cfg/providers/dyn-full-tunnel.txt"
# Pre-seed the geo DBs (the installer's prepare_stack does the same): an
# in-container first-boot download can arrive partial and is FATAL at
# config parse - the preseed makes boots deterministic.
# shellcheck source=scripts/lib/geodata.sh disable=SC1091
. "$ROOT/scripts/lib/geodata.sh"
geodata_preseed "$WD/cfg" >/dev/null 2>&1 \
  || echo "WARN: geodata preseed failed - mihomo will try its own download"
# shellcheck disable=SC2012 # fixture filenames are our own, newline-free
ok "config rendered (dyn providers seeded: $(ls "$WD/cfg/providers" | tr '\n' ' '))"

echo "=== build the panel image from app/ ==="
if docker build -q -t "$PANEL_IMG" "$ROOT/app" >/dev/null 2>&1; then
  ok "app/Dockerfile builds"
else
  bad "docker build app/ failed"; echo "FAILED: $PASS passed, $FAIL failed"; exit 1
fi

echo "=== stack up (bridge $SUBNET) ==="
docker network rm "$NET" >/dev/null 2>&1 || true
docker network create --subnet "$SUBNET" "$NET" >/dev/null || { bad "network create"; exit 1; }
# no --rm: a crashed mihomo must keep its logs for the failure path below.
docker run -d --name smg-e2e-mihomo --network "$NET" --ip "$IP_MIHOMO" \
  -v "$WD/cfg:/root/.config/mihomo" "$MIHOMO_IMG" \
  -d /root/.config/mihomo >/dev/null || { bad "mihomo container"; exit 1; }
mkdir -p "$WD/panelstate"
chmod 777 "$WD/panelstate" "$WD/cfg/providers"   # dev fixture: the panel runs uid 10001
docker run -d --rm --name smg-e2e-panel --network "$NET" --ip "$IP_PANEL" \
  -v "$WD/cfg/providers:/gw/config/providers" -v "$WD/panelstate:/gw/state" \
  -e GATEWAY_DATA_DIR=/gw -e PANEL_PROVIDERS_DIR=/gw/config/providers \
  -e PANEL_MIHOMO_URL="http://$IP_MIHOMO:9090" -e CONTROLLER_SECRET="$CTL_SECRET" \
  -e PANEL_SECRET="$PANEL_TOKEN" -e MIHOMO_IP="$IP_MIHOMO" -e PANEL_IP="$IP_PANEL" \
  "$PANEL_IMG" >/dev/null || { bad "panel container"; exit 1; }
for c in smg-e2e-c1 smg-e2e-c2; do
  case "$c" in *c1) _ip="$IP_C1" ;; *) _ip="$IP_C2" ;; esac
  docker run -d --rm --name "$c" --network "$NET" --ip "$_ip" \
    --entrypoint /bin/sh "$PANEL_IMG" -c 'sleep 600' >/dev/null \
    || { bad "client $c"; exit 1; }
done

_i=0
while [ "$_i" -lt 30 ]; do
  # FastAPI emits compact JSON - keep the matcher space-agnostic.
  pget /health | grep -Eq '"db_ok": ?true' && break
  _i=$((_i+1)); sleep 2
done
if [ "$_i" -lt 30 ]; then ok "panel healthy (db_ok)"; else
  bad "panel never reached db_ok"; docker logs smg-e2e-panel 2>&1 | tail -5
  echo "FAILED: $PASS passed, $FAIL failed"; exit 1
fi
# Controller readiness (first boot downloads the geo DBs before listening):
# the dynamic providers register at 0 rules once the config is live.
_i=0
while [ "$_i" -lt 45 ]; do
  [ "$(ctl_count dyn-full-tunnel)" = 0 ] && break
  _i=$((_i+1)); sleep 2
done
if [ "$_i" -lt 45 ]; then ok "mihomo controller up (dyn providers registered, 0 rules)"
else
  bad "mihomo controller/providers never became ready (geo DB download stuck?)"
  docker logs smg-e2e-mihomo 2>&1 | tail -5
  echo "FAILED: $PASS passed, $FAIL failed"; exit 1
fi

echo "=== policy flips (panel API is the single write path) ==="
_r1="$(ppost POST /v1/devices "{\"address\":\"$IP_C1/32\",\"mode\":\"full-tunnel\",\"name\":\"e2e-c1\"}")"
case "$_r1" in *'"applied": true'*|*'"applied":true'*) ok "c1 -> full-tunnel applied" ;;
  *) bad "c1 policy apply: $_r1" ;; esac
_r2="$(ppost POST /v1/devices "{\"address\":\"$IP_C2/32\",\"mode\":\"full-direct\",\"name\":\"e2e-c2\"}")"
case "$_r2" in *'"applied": true'*|*'"applied":true'*) ok "c2 -> full-direct applied" ;;
  *) bad "c2 policy apply: $_r2" ;; esac
if [ "$(ctl_count dyn-full-tunnel)" = 1 ]; then ok "mihomo hot-reloaded dyn-full-tunnel (ruleCount 1)"
else bad "dyn-full-tunnel ruleCount != 1 after apply"; fi
if [ "$(ctl_count dyn-full-direct)" = 1 ]; then ok "mihomo hot-reloaded dyn-full-direct (ruleCount 1)"
else bad "dyn-full-direct ruleCount != 1 after apply"; fi

echo "=== source discrimination (zero nodes: tunnel fail-closed, direct works) ==="
# Retry window: a fetch fired immediately after the provider PUT can race
# the rule engine's snapshot swap (observed live: a flow 200ms after the
# refresh still matched GEOSITE) - the engine settles within a second.
_i=0; _c2ok=0
while [ "$_i" -lt 10 ]; do
  if cfetch smg-e2e-c2; then _c2ok=1; break; fi
  _i=$((_i+1)); sleep 1
done
if [ "$_c2ok" = 1 ]; then ok "full-direct source fetches DIRECT through the mixed port"
else bad "full-direct source could not fetch within 10s (should bypass every group)"; fi
if cfetch smg-e2e-c1; then bad "full-tunnel source fetched with ZERO nodes (must be fail-closed REJECT)"
else
  # The failure must be for the RIGHT reason: the flow matched the dynamic
  # rule-set (not a vacuous DNS/proxy error - REASON-checked via the log).
  if docker logs smg-e2e-mihomo 2>&1 | grep "$IP_C1" | grep -q 'RuleSet(dyn-full-tunnel)'; then
    ok "full-tunnel source fail-closed via RuleSet(dyn-full-tunnel) (same dest, opposite outcome)"
  else
    bad "full-tunnel source failed, but no RuleSet(dyn-full-tunnel) match logged for $IP_C1"
  fi
fi

echo "=== removal re-routes ==="
_id2="$(pget /v1/devices | python3 -c '
import json,sys
d = json.load(sys.stdin)
for e in d.get("devices", []):
    if e.get("cidr") == "'"$IP_C2"'/32":
        print(e["id"]); break' 2>/dev/null)"
if [ -n "$_id2" ] && ppost DELETE "/v1/devices/$_id2" '' >/dev/null 2>&1; then
  ok "c2 entry removed via the panel API"
else
  bad "could not remove the c2 entry (id '${_id2:-none}')"
fi
_i=0; _c2gone=0
while [ "$_i" -lt 10 ]; do
  if ! cfetch smg-e2e-c2; then _c2gone=1; break; fi
  _i=$((_i+1)); sleep 1
done
if [ "$_c2gone" = 1 ]; then ok "removed source re-routes through Routing Mode (fail-closed again)"
else bad "removed full-direct source still bypasses Routing Mode after 10s"; fi
if pget /health | grep -Eq '"parity": ?"ok"'; then ok "panel parity ok after the full cycle"
else bad "panel parity not ok at the end"; fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "FAILED: $PASS passed, $FAIL failed"; exit 1
fi
echo "OK: $PASS panel local-e2e assertions passed (render -> build -> boot -> flip -> discriminate -> remove -> parity)"
