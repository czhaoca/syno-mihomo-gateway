#!/bin/sh
# seed_provider.sh - restore airport nodes when mihomo's own subscription
# fetch is failing, by fetching the node list ON THE HOST and planting it as
# the provider's on-disk cache. mihomo loads that file at startup and KEEPS
# loaded nodes when a background pull fails, so this survives restarts until
# the fetch path heals (proven in the 2026-07-12 provider outage: the host
# fetch succeeded while the in-container fetch died at TLS).
#
#   sudo sh scripts/seed_provider.sh
#
# Writes the cache under the data dir only (never a world-readable location -
# the payload embeds your node credentials), at BOTH names mihomo may read:
# proxies/my-airport.yaml (the stable `path:` since v1.3.8) and the
# md5-of-URL default filename (configs rendered by older releases). The
# subscription URL itself is never printed. Then restarts mihomo and verifies
# real provider nodes appear (built-ins and the COMPATIBLE placeholder of an
# empty group are never counted).
#
# Exit: 0 nodes restored | 2 seeded but no nodes appeared | 3 fetch or
#       validation failed | 6 needs root
# POSIX /bin/sh (BusyBox-safe). English-only output (house rule for the
# non-interactive entry points, like doctor.sh and migrate_legacy.sh).

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/lib/common.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SELF_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/compose.sh
. "$SELF_DIR/lib/compose.sh"

NO_LOG_INIT=1
export NO_LOG_INIT

[ "$(id -u)" = 0 ] || { echo "ERROR: run with sudo (docker socket is root-only)" >&2; exit 6; }
# The fetched payload embeds node credentials: every file this script creates
# (the staging tmp and both cache names) must be owner-only, like the repo's
# .env/subscription.txt convention. mihomo runs as root and reads 600 fine.
umask 077
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found on the host" >&2; exit 3; }
command -v md5sum >/dev/null 2>&1 || { echo "ERROR: md5sum not found on the host" >&2; exit 3; }

load_env || { echo "ERROR: load_env failed (is the gateway configured?)" >&2; exit 3; }
detect_compose >/dev/null 2>&1 || { echo "ERROR: docker not detected" >&2; exit 3; }

# Controller API from INSIDE the container (a macvlan child is not reachable
# from its own host); bearer token over stdin, never argv (repo rule).
ctl_get() {
  _url="http://127.0.0.1:${CONTROLLER_PORT:-9090}$1"
  if [ -n "${CONTROLLER_SECRET:-}" ]; then
    # shellcheck disable=SC2016 # $SMG_AUTH expands in the container shell
    printf 'Authorization: Bearer %s\n' "$CONTROLLER_SECRET" | \
      "$DOCKER_BIN" exec -i "$MIHOMO_CONTAINER" \
      sh -c 'IFS= read -r SMG_AUTH; exec wget -q -T 15 -O - --header "$SMG_AUTH" "$1"' _ "$_url" 2>/dev/null
  else
    "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 15 -O - "$_url" 2>/dev/null
  fi
}

# Provider nodes in the `auto` group: its members come from the provider only,
# and an EMPTY group degrades to the COMPATIBLE placeholder - never a node.
real_nodes() {
  ctl_get /proxies/auto | sed -n 's/.*"all":\[\([^]]*\)\].*/\1/p' \
    | tr ',' '\n' | sed -n 's/^"\(.*\)"$/\1/p' | grep -c -v '^COMPATIBLE$'
}

SUB_URL=$(grep -v '^#' "$SUBSCRIPTION_FILE" 2>/dev/null \
  | grep -v '^[[:space:]]*$' | head -n1 \
  | sed -e 's/^[A-Za-z0-9_.-]*=//' -e 's/[[:space:]]*$//')
[ -n "$SUB_URL" ] || { echo "ERROR: no usable URL in ${SUBSCRIPTION_FILE:-<unset>}" >&2; exit 3; }

N0=$(real_nodes); N0=${N0:-0}
echo "provider nodes now: $N0"
if [ "$N0" -gt 0 ]; then
  echo "OK: the provider already has nodes - nothing to seed"
  exit 0
fi

PDIR="$GATEWAY_DATA_DIR/config/proxies"
TMP="$GATEWAY_DATA_DIR/config/.seed.fetch.tmp"
HASH=$(printf '%s' "$SUB_URL" | md5sum | awk '{print $1}')

echo "fetching the subscription on the host (URL stays hidden) ..."
if ! printf 'url = "%s"\n' "$SUB_URL" | curl -sS -K - -m 40 -o "$TMP" \
  -w 'http_code=%{http_code} size_bytes=%{size_download} time=%{time_total}s\n'; then
  echo "ERROR: host fetch failed - is the panel reachable from the NAS?" >&2
  rm -f "$TMP"; exit 3
fi
_sz=$(wc -c < "$TMP" | tr -d ' ')
if [ "$_sz" -lt 10240 ] || ! grep -q 'proxies:' "$TMP"; then
  echo "ERROR: payload does not look like a clash node list (size=$_sz bytes)" >&2
  echo "       (an expired subscription or an error page is smaller / has no proxies: key)" >&2
  rm -f "$TMP"; exit 3
fi
echo "payload OK: $_sz bytes, ~$(grep -c 'server:' "$TMP") node entries"

mkdir -p "$PDIR"
cat "$TMP" > "$PDIR/my-airport.yaml" && chmod 600 "$PDIR/my-airport.yaml"
cat "$TMP" > "$PDIR/$HASH" && chmod 600 "$PDIR/$HASH"
rm -f "$TMP"
echo "planted: proxies/my-airport.yaml and proxies/$HASH"

echo "restarting $MIHOMO_CONTAINER (loads the cache at startup) ..."
"$DOCKER_BIN" restart "$MIHOMO_CONTAINER" >/dev/null || { echo "ERROR: docker restart failed" >&2; exit 2; }
sleep 15
N=0
for _i in 1 2 3 4 5 6; do
  N=$(real_nodes); N=${N:-0}
  echo "  t+$((_i*10+5))s provider nodes: $N"
  [ "$N" -gt 0 ] && break
  sleep 10
done
if [ "$N" -eq 0 ]; then
  echo "ERROR: still no nodes after seeding - recent mihomo log lines:" >&2
  "$DOCKER_BIN" logs --tail 30 "$MIHOMO_CONTAINER" 2>&1 \
    | grep -iE 'provider|error|parse' | sed -e 's|https\{0,1\}://[^"[:space:]]*|<URL_REDACTED>|g' -e 's/^/    /' >&2
  exit 2
fi
echo "OK: provider loaded $N nodes from the seeded cache"

# Informational egress check through the group (after a url-test round). The
# effective member must be a REAL node: an empty group degrades to COMPATIBLE
# (= DIRECT), and gstatic's generate_204 answers direct from CN.
GSTATIC="http://www.gstatic.com/generate_204"
ctl_get "/group/auto/delay?timeout=8000&url=$GSTATIC" >/dev/null 2>&1 || true
_now=$(ctl_get /proxies/PROXY | sed -n 's/.*"now":"\([^"]*\)".*/\1/p')
[ "$_now" = auto ] && _now=$(ctl_get /proxies/auto | sed -n 's/.*"now":"\([^"]*\)".*/\1/p')
case "$(ctl_get "/proxies/PROXY/delay?timeout=5000&url=$GSTATIC")" in
  *'"delay"'*)
    case "$_now" in
      ''|COMPATIBLE|DIRECT|REJECT|REJECT-DROP|PASS)
        echo "WARN: probe answered but the effective member is '$_now' - pick a node in the dashboard" ;;
      *) echo "OK: foreign egress via $_now - test a foreign site from a LAN device" ;;
    esac ;;
  *)
    echo "WARN: nodes loaded but the group probe failed - pick a node in the"
    echo "      dashboard (Proxies -> PROXY) and retest from a LAN device" ;;
esac
exit 0
