#!/bin/sh
# identity.sh - host-side device-alias import (#74).
#
# The panel's POST /v1/identities/import is deliberately vendor-agnostic:
# it takes {entries:[{ip,alias,source}], override} and nothing else. EVERY
# vendor-specific detail therefore lives HERE, on the host, so that no
# vendor code and no vendor credential ever ships inside the panel image
# or reaches the running panel process (DEC-7).
#
# Why a one-shot container: this repo never calls host python3 or jq - DSM
# cannot be assumed to have either, and every HTTP/JSON operation already
# runs inside a container (panel.sh:7, checks.sh:636 say so explicitly).
# The adapter therefore runs `docker run --rm -i --entrypoint python3
# "$PANEL_IMAGE"`: the panel IMAGE used purely as a python runtime, never
# the panel CONTAINER. The program text travels as an ARGUMENT (it is not
# a secret and full quoting freedom out here beats nested-quote soup); the
# credential travels on STDIN, because argv is visible in `ps` on both
# sides and `-e` would hand it to the container environment instead.
#
# Requires common.sh (EXIT_*, log_error) + compose.sh (DOCKER_BIN via
# detect_compose) sourced first, and load_env already run. POSIX/BusyBox sh.

# Adapters that exist. `file` is not a fallback - it is how a hand-written
# list and any future inventory export reach the same endpoint on equal
# terms, which is the promise the vendor-agnostic payload was designed
# around.
: "${IDENTITY_SOURCES:=unifi file}"

# identity_file - where `--from file` reads its document.
identity_file() {
  printf '%s' "${IDENTITY_FILE:-$GATEWAY_DATA_DIR/identity/aliases.json}"
}

# The adapter program. Single-quoted so nothing expands out here, which
# means it may not contain a single quote itself - every string below is
# double-quoted, exactly like panel.sh's embedded clients.
_ia_py='import json, ssl, sys, urllib.error, urllib.parse, urllib.request
from http.cookiejar import CookieJar

source = sys.argv[1]
override = sys.argv[2] == "true"


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(21)


def emit(entries):
    sys.stdout.write(json.dumps({"entries": entries, "override": override}))
    sys.exit(0)


if source == "file":
    try:
        doc = json.loads(sys.stdin.read())
    except ValueError as exc:
        die("the alias document is not valid JSON: %s" % exc)
    rows = doc.get("entries") if isinstance(doc, dict) else doc
    if not isinstance(rows, list):
        die("the alias document must be an object with an entries list")
    out = []
    for row in rows:
        if not isinstance(row, dict):
            die("every alias entry must be an object carrying ip and alias")
        ip = str(row.get("ip", "") or "").strip()
        alias = str(row.get("alias", "") or "").strip()
        # An entry may name its OWN origin (an inventory export routed
        # through a file keeps saying where it came from), otherwise it
        # inherits the adapter name.
        # Provenance is what the panel precedence rule keys on, so guessing
        # it wrong is what silently overwrites the wrong rows.
        src = str(row.get("source", "") or "").strip() or "file"
        if ip and alias:
            out.append({"ip": ip, "alias": alias, "source": src})
    emit(out)

# --- unifi ---------------------------------------------------------------
# Five lines on stdin, fixed order: url, user, password, site, insecure.
url = sys.stdin.readline().strip()
user = sys.stdin.readline().strip()
password = sys.stdin.readline().rstrip("\n")
site = sys.stdin.readline().strip() or "default"
insecure = sys.stdin.readline().strip() == "true"
base = url.rstrip("/")

# TLS is verified by DEFAULT. A UniFi console ships a self-signed
# certificate, so this refuses the common case on purpose: silently
# accepting any certificate would make a credential-bearing call
# interceptable on the LAN with nothing in the output to say so.
# UNIFI_INSECURE=true is the explicit, documented opt-out.
ctx = None
if insecure:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(CookieJar()),
    urllib.request.HTTPSHandler(context=ctx))

# UniFi OS (UDM / Cloud Key Gen2) and a self-hosted controller answer at
# different paths and put the network API behind different prefixes. Only a
# 404 on the OS route means "wrong family, try the other one" - a 401 is a
# rejected credential and must NOT fall through, or a wrong password would
# be reported as a missing endpoint.
prefix = None
login = json.dumps({"username": user, "password": password}).encode()
for path, pre, fallthrough in (("/api/auth/login", "/proxy/network", (404,)),
                               ("/api/login", "", ())):
    req = urllib.request.Request(
        base + path, data=login,
        headers={"Content-Type": "application/json"})
    try:
        opener.open(req, timeout=15).read()
        prefix = pre
        break
    except urllib.error.HTTPError as exc:
        if exc.code in fallthrough:
            continue
        die("the UniFi controller refused the login (HTTP %d) - check "
            "UNIFI_USER and UNIFI_PASSWORD in .env" % exc.code)
    except Exception as exc:
        die("cannot reach the UniFi controller at %s: %s" % (base, exc))
if prefix is None:
    die("no UniFi login endpoint answered at %s - check UNIFI_URL" % base)

api = base + prefix + "/api/s/" + urllib.parse.quote(site, safe="")


def fetch(path):
    try:
        raw = opener.open(urllib.request.Request(api + path),
                          timeout=30).read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        die("the UniFi controller rejected %s (HTTP %d) - check UNIFI_SITE"
            % (path, exc.code))
    except Exception as exc:
        die("the UniFi controller stopped answering %s: %s" % (path, exc))
    try:
        doc = json.loads(raw)
    except ValueError:
        die("the UniFi controller answered %s with something that is not JSON"
            % path)
    data = doc.get("data") if isinstance(doc, dict) else None
    return data if isinstance(data, list) else []


known = fetch("/rest/user")
active = fetch("/stat/sta")

# A DHCP lease moves, a reservation does not, so a fixed IP is the better
# key when there is one; the active list supplies an address for everything
# else. Merging on MAC is what lets the two lists agree on one device.
ip_by_mac = {}
for client in active:
    if not isinstance(client, dict):
        continue
    mac = str(client.get("mac", "") or "").lower()
    addr = str(client.get("ip", "") or "").strip()
    if mac and addr:
        ip_by_mac[mac] = addr

entries = []
seen_ip = set()
seen_mac = set()


def add(mac, alias, addr):
    # No name is nothing to import, and no address is nothing to key on -
    # the panel would reject both, but sending them would bury the rows
    # that matter in a ledger of rejections.
    if not alias or not addr or addr in seen_ip:
        return
    seen_ip.add(addr)
    if mac:
        seen_mac.add(mac)
    entries.append({"ip": addr, "alias": alias, "source": "unifi"})


for client in known:
    if not isinstance(client, dict):
        continue
    mac = str(client.get("mac", "") or "").lower()
    # The operator-set name outranks the device-reported hostname: it is the
    # one a human chose, and it is what they will look for in the panel.
    alias = str(client.get("name", "") or client.get("hostname", "") or "").strip()
    addr = ""
    if client.get("use_fixedip") and client.get("fixed_ip"):
        addr = str(client["fixed_ip"]).strip()
    if not addr:
        addr = ip_by_mac.get(mac, "")
    add(mac, alias, addr)

for client in active:
    if not isinstance(client, dict):
        continue
    mac = str(client.get("mac", "") or "").lower()
    if mac and mac in seen_mac:
        continue
    alias = str(client.get("name", "") or client.get("hostname", "") or "").strip()
    add(mac, alias, str(client.get("ip", "") or "").strip())

emit(entries)'

# _identity_adapter SOURCE OVERRIDE - run the adapter; stdin is its config.
_identity_adapter() {
  "$DOCKER_BIN" run --rm -i --entrypoint python3 "$PANEL_IMAGE" \
    -c "$_ia_py" "$1" "$2"
}

# _identity_err MESSAGE - log to STDERR specifically.
#
# The shared log() tees to STDOUT, and identity_fetch's stdout is the import
# payload the caller captures in a command substitution. An error logged the
# ordinary way would therefore be swallowed INTO the document instead of
# reaching the operator - the caller would see a failure with no reason
# attached. Everything still reaches logs/gateway.log either way.
_identity_err() { log_error "$@" >&2; }

# identity_fetch SOURCE OVERRIDE - the normalized import body on stdout.
# Returns EXIT_CONFIG when the source is unusable (and starts NO container:
# a half-run that fails after contacting a vendor is harder to reason about
# than one that never began), 21 when the adapter itself failed.
identity_fetch() {
  _if_src="$1"
  _if_over="$2"
  if [ -z "${PANEL_IMAGE:-}" ]; then
    _identity_err "PANEL_IMAGE is not set in $ENV_FILE - the alias adapter runs in a one-shot container built from the panel image"
    return "$EXIT_CONFIG"
  fi
  case "$_if_src" in
    unifi)
      _if_missing=''
      for _if_k in UNIFI_URL UNIFI_USER UNIFI_PASSWORD; do
        eval "_if_v=\${$_if_k:-}"
        [ -n "$_if_v" ] || _if_missing="$_if_missing $_if_k"
      done
      if [ -n "$_if_missing" ]; then
        _identity_err "the unifi alias source needs$_if_missing in $ENV_FILE (a credential is never accepted on the command line)"
        return "$EXIT_CONFIG"
      fi
      # Five lines, fixed order. stdin - not argv, not -e: argv is visible in
      # `ps` on the host AND inside the container, and -e would place the
      # password in the container environment.
      printf '%s\n' "$UNIFI_URL" "$UNIFI_USER" "$UNIFI_PASSWORD" \
        "${UNIFI_SITE:-default}" "${UNIFI_INSECURE:-false}" \
        | _identity_adapter "$_if_src" "$_if_over"
      ;;
    file)
      _if_path="$(identity_file)"
      if [ ! -f "$_if_path" ]; then
        _identity_err "no alias document at $_if_path - write an {\"entries\":[{\"ip\":\"...\",\"alias\":\"...\"}]} object there first"
        return "$EXIT_CONFIG"
      fi
      _identity_adapter "$_if_src" "$_if_over" < "$_if_path"
      ;;
    *)
      _identity_err "unknown alias source '$_if_src' - known sources: $IDENTITY_SOURCES"
      return "$EXIT_CONFIG"
      ;;
  esac
}
