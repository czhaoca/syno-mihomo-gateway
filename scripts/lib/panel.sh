#!/bin/sh
# panel.sh - thin client for the gateway panel's HTTP API (#67).
#
# The panel container sits on its own macvlan seat, and a macvlan child is
# unreachable from its own host - so every call runs INSIDE the panel
# container via docker exec (the seed_provider.sh reach pattern). The
# panel image is python-slim: python3/urllib is the only HTTP client in
# there, and the program text travels as an ARGUMENT to the in-container
# shell (full quoting freedom out here, no nested-quote soup).
#
# Token discipline (repo rule): PANEL_SECRET rides stdin -> in-container
# env - NEVER argv on either side (host and container ps are both real
# surfaces). GET requests send no token (panel reads are LAN-open).
#
# Exit codes: 0 HTTP 2xx (body on stdout) | 22 HTTP error (the panel's
# JSON error body on stdout) | anything else: unreachable.
#
# Requires common.sh + compose.sh sourced first (DOCKER_BIN via
# detect_compose). POSIX/BusyBox sh.

: "${PANEL_CONTAINER:=mihomo-panel}"
: "${PANEL_PORT:=8090}"

# panel_api METHOD PATH [JSON_BODY] - one HTTP call against the panel.
panel_api() {
  _pa_py='import json,os,sys,urllib.request,urllib.error
m, u, b = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(u, method=m, data=b.encode() if b else None)
if b:
    req.add_header("Content-Type", "application/json")
t = os.environ.get("SMG_PANEL_TOKEN", "")
if t and m != "GET":
    req.add_header("Authorization", "Bearer " + t)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode())
    sys.exit(22)'
  # shellcheck disable=SC2016 # $1..$4 expand in the container shell
  printf '%s\n' "${PANEL_SECRET:-}" | "$DOCKER_BIN" exec -i "$PANEL_CONTAINER" \
    sh -c 'IFS= read -r SMG_PANEL_TOKEN; export SMG_PANEL_TOKEN; exec python3 -c "$1" "$2" "$3" "$4"' \
    _ "$_pa_py" "$1" "http://127.0.0.1:${PANEL_PORT}$2" "${3:-}"
}

# panel_policy_set ADDRESS MODE NAME NOTE - resolve the existing entry by
# canonical CIDR and act: absent+mode -> POST, present+mode -> PATCH,
# present+default -> DELETE, absent+default -> a no-op result. One docker
# exec; the resolve logic lives next to the data (same-engine principle).
panel_policy_set() {
  _pps_py='import json,os,sys,urllib.error,urllib.parse,urllib.request
base, addr, mode, name, note = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
t = os.environ.get("SMG_PANEL_TOKEN", "")
def call(m, p, b=None):
    data = json.dumps(b).encode() if b is not None else None
    req = urllib.request.Request(base + p, method=m, data=data)
    if b is not None:
        req.add_header("Content-Type", "application/json")
    if t and m != "GET":
        req.add_header("Authorization", "Bearer " + t)
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode() or "null")
try:
    devices = call("GET", "/v1/devices").get("devices") or []
    canonical = addr if "/" in addr else addr + "/32"
    hit = next((d for d in devices if d.get("cidr") in (canonical, addr)), None)
    if mode == "default":
        if hit is None:
            sys.stdout.write(json.dumps({"action": "none", "detail": "no policy entry for " + addr}))
            sys.exit(0)
        suffix = ("?note=" + urllib.parse.quote(note)) if note else ""
        out = call("DELETE", "/v1/devices/%d%s" % (hit["id"], suffix))
        out["action"] = "remove"
    elif hit is None:
        body = {"address": addr, "mode": mode}
        if name:
            body["name"] = name
        if note:
            body["note"] = note
        out = call("POST", "/v1/devices", body)
        out["action"] = "add"
    else:
        body = {"mode": mode}
        if name:
            body["name"] = name
        if note:
            body["note"] = note
        out = call("PATCH", "/v1/devices/%d" % hit["id"], body)
        out["action"] = "update"
    sys.stdout.write(json.dumps(out))
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode())
    sys.exit(22)'
  # shellcheck disable=SC2016 # $1..$6 expand in the container shell
  printf '%s\n' "${PANEL_SECRET:-}" | "$DOCKER_BIN" exec -i "$PANEL_CONTAINER" \
    sh -c 'IFS= read -r SMG_PANEL_TOKEN; export SMG_PANEL_TOKEN; exec python3 -c "$1" "$2" "$3" "$4" "$5" "$6"' \
    _ "$_pps_py" "http://127.0.0.1:${PANEL_PORT}" "$1" "$2" "${3:-}" "${4:-}"
}
