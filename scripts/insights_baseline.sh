#!/bin/sh
# insights_baseline.sh - read-only production baseline for Gateway Insights (#90).
#
# Prints the numbers the gateway-insights epic sizes itself on, as flat
# key=value lines: attribution coverage share, stats db size, the live
# /connections count, the running mihomo version, whether the build exposes
# destination geo fields, and the domains opt-in state. Nothing is written,
# restarted or reconfigured: five GETs, then exit. Paste the lines into the
# brief's "Measured baseline" section as-is - every value is a number, a
# bare word or a version string; no address, hostname or path ever appears.
#
# Reach: the panel is a macvlan child (unreachable from its own host), so the
# probe runs INSIDE the panel container via docker exec - the doctor's
# _panel_health path (scripts/lib/checks.sh). The python program travels on
# STDIN, never argv, and reads PANEL_MIHOMO_URL, CONTROLLER_SECRET and
# PANEL_PORT from the container's own environment: the controller secret is
# never handled host-side and never printed. A failed probe names the STAGE
# (health, coverage, domains, version, connections, parse, exec, docker,
# container), never the exception text (which could carry the controller
# URL).
#
# Record keys (required = the contract the live path enforces, non-empty
# except coverage_window_days, which is blank on an empty store):
#   measured_at panel_collector stats_db_bytes coverage_hostname_share
#   coverage_window_days coverage_truncated domains_enabled mihomo_version
#   connections_len connections_inner geo_fields
# geo_fields is present|absent|unknown - unknown means zero connections at
# that moment, so presence could not be judged (a live TUN gateway is
# practically never there). Extra, informational keys: panel_day_framing,
# coverage_ip_only_share, coverage_total_bytes, coverage_retention_days,
# connections_host_share, geo_populated_share (share of flows whose geo
# fields are non-empty - a build can carry the keys and still fill them
# rarely), mihomo_memory_bytes.
#
# Usage (root - docker exec needs the socket; DSM keeps docker in
# /usr/local/bin, which the PATH prelude below covers under sudo):
#   sh scripts/insights_baseline.sh              # live probe, key=value lines
#   sh scripts/insights_baseline.sh --self-test  # hermetic controls, no docker
# Knobs: DOCKER_BIN (docker) | PANEL_CONTAINER (mihomo-panel) | PANEL_PORT
# (8090; the container's own PANEL_PORT wins when set)
# Exit: 0 every key printed | 1 usage or self-test failure | 2 a probe failed
# POSIX/BusyBox sh, ASCII only.
set -u
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

: "${DOCKER_BIN:=docker}"
: "${PANEL_CONTAINER:=mihomo-panel}"
: "${PANEL_PORT:=8090}"

# The key contract: every key the brief's "Measured baseline" section
# expects. The live path refuses a partial record - a missing or empty key is
# a failed probe, not a blank the reader fills in. (Spaces on both ends: the
# CI suite's mutant drops one entry by its padded name; the suite also
# asserts every key here has a matching emit(...) in the program below.)
IB_REQUIRED=" measured_at panel_collector stats_db_bytes coverage_hostname_share coverage_window_days coverage_truncated domains_enabled mihomo_version connections_len connections_inner geo_fields "
IB_MAY_BE_EMPTY=" coverage_window_days "

# --- the in-container program (stdin -> python3 -) ----------------------------
# INSIGHTS_FIXTURE_DIR and INSIGHTS_NOW_EPOCH exist for the self-test only:
# they swap HTTP for canned JSON files and pin the clock. No single quotes
# in here - the program is one single-quoted sh string.
IB_PY='import calendar, json, os, sys, time, urllib.request
argv_port = sys.argv[1] if len(sys.argv) > 1 else "8090"
port = os.environ.get("PANEL_PORT", "").strip() or argv_port
fix = os.environ.get("INSIGHTS_FIXTURE_DIR", "")
now_s = float(os.environ.get("INSIGHTS_NOW_EPOCH", "") or time.time())
base = os.environ.get("PANEL_MIHOMO_URL", "").rstrip("/")
secret = os.environ.get("CONTROLLER_SECRET", "")


def fetch(name, url, auth):
    if fix:
        with open(os.path.join(fix, name + ".json"), encoding="utf-8") as f:
            return json.load(f)
    req = urllib.request.Request(url)
    if auth and secret:
        req.add_header("Authorization", "Bearer " + secret)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())


def probe(name, url, auth=False):
    try:
        return fetch(name, url, auth)
    except Exception:
        # the stage name only: exception text can carry the controller URL
        print("probe_failed=" + name)
        sys.exit(2)


panel = "http://127.0.0.1:" + port
since = time.strftime("%Y-%m-%dT%H", time.gmtime(now_s - 7 * 86400))
h = probe("health", panel + "/health")
cov = probe("coverage", panel + "/v1/stats/coverage?since=" + since)
# only the enabled flag is read; a since in the far future keeps rows empty
dom = probe("domains", panel + "/v1/stats/domains?since=9999")
ver = probe("version", base + "/version", True)
conns = probe("connections", base + "/connections", True)


def derive():
    out = []

    def emit(k, v):
        out.append("%s=%s" % (k, str(v).replace("\n", " ").strip()))

    emit("measured_at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now_s)))
    emit("panel_collector", h.get("collector", ""))
    emit("panel_day_framing", h.get("day_framing", ""))
    emit("stats_db_bytes", h.get("stats_db_bytes", ""))
    classes = {}
    for c in cov.get("classes") or []:
        classes[c.get("klass")] = c
    emit("coverage_hostname_share", (classes.get("hostname") or {}).get("share", ""))
    emit("coverage_ip_only_share", (classes.get("ip_only") or {}).get("share", ""))
    tot = cov.get("total") or {}
    emit("coverage_total_bytes", int(tot.get("up") or 0) + int(tot.get("down") or 0))
    win = cov.get("window") or {}
    emit("coverage_retention_days", win.get("retention_days", ""))
    oldest = str(win.get("oldest_bucket") or "")
    days = ""
    if len(oldest) >= 13:
        try:
            t0 = calendar.timegm(time.strptime(oldest[:13], "%Y-%m-%dT%H"))
            days = round((now_s - t0) / 86400.0, 1)
        except ValueError:
            days = ""
    emit("coverage_window_days", days)
    emit("coverage_truncated", str(bool(win.get("truncated"))).lower())
    emit("domains_enabled", str(bool(dom.get("enabled"))).lower())
    emit("mihomo_version", ver.get("version", ""))
    cl = conns.get("connections") or []
    md = [c.get("metadata") or {} for c in cl]
    emit("connections_len", len(cl))
    emit("connections_inner", sum(1 for m in md if m.get("type") == "Inner"))
    hosted = sum(1 for m in md if m.get("host") or m.get("sniffHost"))
    emit("connections_host_share", round(100.0 * hosted / len(cl), 1) if cl else "")
    geo = "unknown"
    if cl:
        geo = "present" if any(("dstGeoIP" in m) or ("dstIPASN" in m) for m in md) else "absent"
    emit("geo_fields", geo)
    populated = sum(1 for m in md if m.get("dstGeoIP") or m.get("dstIPASN"))
    emit("geo_populated_share", round(100.0 * populated / len(cl), 1) if cl else "")
    emit("mihomo_memory_bytes", conns.get("memory", ""))
    print("\n".join(out))


try:
    derive()
except Exception:
    # an unexpected payload shape from the :latest build - name the stage,
    # never the traceback
    print("probe_failed=parse")
    sys.exit(2)
'

# ib_validate FILE - the program output must carry every required key with a
# value (coverage_window_days may be empty) and no probe_failed line;
# rc 0 ok | 2 (reason on stderr)
ib_validate() {
  _ibv_fail="$(sed -n 's/^probe_failed=//p' "$1" | head -n 1)"
  if [ -n "$_ibv_fail" ]; then
    echo "insights_baseline: probe failed: $_ibv_fail" >&2
    return 2
  fi
  if ! [ -s "$1" ]; then
    echo "insights_baseline: probe failed: exec (no output from the panel container)" >&2
    return 2
  fi
  for _ibv_k in $IB_REQUIRED; do
    if ! grep -q "^$_ibv_k=" "$1"; then
      echo "insights_baseline: missing key: $_ibv_k" >&2
      return 2
    fi
    _ibv_v="$(sed -n "s/^$_ibv_k=//p" "$1" | head -n 1)"
    case "$IB_MAY_BE_EMPTY" in
      *" $_ibv_k "*) : ;;
      *)
        if [ -z "$_ibv_v" ]; then
          echo "insights_baseline: empty value: $_ibv_k" >&2
          return 2
        fi ;;
    esac
  done
  return 0
}

# ib_live - run the program inside the panel container; record on stdout
ib_live() {
  if ! _ibl_run="$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$PANEL_CONTAINER" 2>/dev/null)"; then
    echo "insights_baseline: probe failed: docker (inspect of $PANEL_CONTAINER failed - run as root with docker on PATH; is the stack deployed?)" >&2
    return 2
  fi
  if [ "$_ibl_run" != true ]; then
    echo "insights_baseline: probe failed: container ($PANEL_CONTAINER is not running: ${_ibl_run:-unknown})" >&2
    return 2
  fi
  _ibl_out="$(mktemp)"
  trap 'rm -f "$_ibl_out"' EXIT INT TERM
  printf '%s\n' "$IB_PY" | "$DOCKER_BIN" exec -i "$PANEL_CONTAINER" \
    python3 - "$PANEL_PORT" > "$_ibl_out" 2>/dev/null
  if ib_validate "$_ibl_out"; then
    cat "$_ibl_out"
    return 0
  fi
  return 2
}

# --- self-test ------------------------------------------------------------------
ib_self_test() {
  _t="$(mktemp -d)"
  trap 'rm -rf "$_t"' EXIT INT TERM
  _pass=0; _failn=0
  st_ok() { _pass=$((_pass + 1)); }
  st_fail() { echo "FAIL: $*" >&2; _failn=$((_failn + 1)); }
  mkdir -p "$_t/bin" "$_t/fix" "$_t/fix_nogeo" "$_t/fix_down" "$_t/fix_empty" "$_t/fix_bad"

  # stub docker: inspect answers FAKE_RUNNING (or fails with FAKE_INSPECT_RC);
  # exec captures the program it was handed on stdin and prints the canned
  # record FAKE_OUT. Every call's argv lands in FAKE_CALLS so the self-test
  # can assert what crossed the docker boundary.
  cat > "$_t/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_CALLS:-/dev/null}"
case "${1:-}" in
  inspect)
    [ "${FAKE_INSPECT_RC:-0}" = 0 ] || exit "$FAKE_INSPECT_RC"
    echo "${FAKE_RUNNING:-true}"; exit 0 ;;
  exec) cat > "${FAKE_STDIN:-/dev/null}"; cat "${FAKE_OUT:?}"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$_t/bin/docker"
  # DSM mounts /tmp noexec, so a stub under mktemp -d cannot run there: probe
  # it once and fall back to a dot-dir under the current directory (removed
  # with the rest)
  _stub="$_t/bin/docker"
  if ! "$_stub" inspect probe >/dev/null 2>&1; then
    _x="$(mktemp -d "$(pwd)/.insights-selftest.XXXXXX")"
    trap 'rm -rf "$_t" "$_x"' EXIT INT TERM
    mv "$_t/bin" "$_x/bin"
    _stub="$_x/bin/docker"
  fi

  cat > "$_t/full.txt" <<'EOF'
measured_at=2026-10-15T12:00:00Z
panel_collector=ok
panel_day_framing=ok
stats_db_bytes=1234567
coverage_hostname_share=80.0
coverage_ip_only_share=20.0
coverage_total_bytes=10000
coverage_retention_days=7
coverage_window_days=6.5
coverage_truncated=true
domains_enabled=false
mihomo_version=v1.19.0-fixture
connections_len=3
connections_inner=1
connections_host_share=66.7
geo_fields=present
geo_populated_share=66.7
mihomo_memory_bytes=65536000
EOF
  grep -v '^mihomo_version=' "$_t/full.txt" > "$_t/nover.txt"
  sed 's/^mihomo_version=.*/mihomo_version=/' "$_t/full.txt" > "$_t/blankver.txt"
  sed 's/^coverage_window_days=.*/coverage_window_days=/' "$_t/full.txt" > "$_t/blankdays.txt"
  printf 'probe_failed=connections\n' > "$_t/pf.txt"
  : > "$_t/empty.txt"

  # st_run [ENV=VAL ...] - the live path with the stub docker as DOCKER_BIN
  # (an absolute path: the script's own PATH prelude must not find a real
  # docker first; the stub lives wherever it can execute, see above)
  st_run() {
    RC=0
    : > "$_t/calls.txt"; : > "$_t/stdin.txt"
    env DOCKER_BIN="$_stub" FAKE_CALLS="$_t/calls.txt" FAKE_STDIN="$_t/stdin.txt" "$@" \
      sh "$0" > "$_t/out.txt" 2> "$_t/err.txt" || RC=$?
  }

  # 1) positive control: a full record passes through verbatim, rc 0
  st_run FAKE_OUT="$_t/full.txt"
  if [ "$RC" = 0 ]; then st_ok; else st_fail "positive-control rc=$RC (want 0): $(cat "$_t/err.txt")"; fi
  if cmp -s "$_t/out.txt" "$_t/full.txt"; then st_ok; else st_fail "positive-control output differs from the record"; fi
  if ! grep -q 'http\|Bearer' "$_t/out.txt"; then st_ok; else st_fail "record carries a URL or token"; fi
  # 1b) what crossed the docker boundary: the program on STDIN, only the
  #     port on argv, no -e env injection, no token
  if grep -q '^exec -i mihomo-panel python3 - 8090$' "$_t/calls.txt"; then st_ok; else st_fail "exec argv shape: $(grep '^exec' "$_t/calls.txt")"; fi
  if ! grep -q 'urllib\|import \| -e ' "$_t/calls.txt"; then st_ok; else st_fail "program text or an env injection crossed on argv"; fi
  if grep -q '^import calendar, json, os, sys, time, urllib.request$' "$_t/stdin.txt"; then st_ok; else st_fail "program did not arrive on stdin"; fi
  if ! grep -q 'inspect -f {{.State.Running}} mihomo-panel' "$_t/calls.txt"; then st_fail "inspect was not asked for the running state"; else st_ok; fi

  # 2) missing-key control: a record without mihomo_version is refused, rc 2
  st_run FAKE_OUT="$_t/nover.txt"
  if [ "$RC" = 2 ]; then st_ok; else st_fail "missing-key control rc=$RC (want 2)"; fi
  if grep -q 'missing key: mihomo_version' "$_t/err.txt"; then st_ok; else st_fail "missing-key control did not name mihomo_version"; fi
  if ! [ -s "$_t/out.txt" ]; then st_ok; else st_fail "missing-key control printed a partial record"; fi

  # 2b) empty-value control: a present-but-blank required key is refused;
  #     coverage_window_days may be blank (empty store)
  st_run FAKE_OUT="$_t/blankver.txt"
  if [ "$RC" = 2 ]; then st_ok; else st_fail "empty-value control rc=$RC (want 2)"; fi
  if grep -q 'empty value: mihomo_version' "$_t/err.txt"; then st_ok; else st_fail "empty-value control did not name mihomo_version"; fi
  st_run FAKE_OUT="$_t/blankdays.txt"
  if [ "$RC" = 0 ]; then st_ok; else st_fail "blank coverage_window_days must pass (rc=$RC)"; fi

  # 3) probe-failed control: the program named the stage, rc 2
  st_run FAKE_OUT="$_t/pf.txt"
  if [ "$RC" = 2 ]; then st_ok; else st_fail "probe-failed control rc=$RC (want 2)"; fi
  if grep -q 'probe failed: connections' "$_t/err.txt"; then st_ok; else st_fail "probe-failed control did not name the probe"; fi

  # 4) empty-output control: a silent exec is a failed probe, rc 2
  st_run FAKE_OUT="$_t/empty.txt"
  if [ "$RC" = 2 ]; then st_ok; else st_fail "empty-output control rc=$RC (want 2)"; fi
  if grep -q 'probe failed: exec' "$_t/err.txt"; then st_ok; else st_fail "empty-output control did not name exec"; fi

  # 5) container-down and docker-failed controls: rc 2, each names its stage
  st_run FAKE_OUT="$_t/full.txt" FAKE_RUNNING=false
  if [ "$RC" = 2 ]; then st_ok; else st_fail "container-down control rc=$RC (want 2)"; fi
  if grep -q 'probe failed: container' "$_t/err.txt"; then st_ok; else st_fail "container-down control did not name the container"; fi
  st_run FAKE_OUT="$_t/full.txt" FAKE_INSPECT_RC=1
  if [ "$RC" = 2 ]; then st_ok; else st_fail "docker-failed control rc=$RC (want 2)"; fi
  if grep -q 'probe failed: docker' "$_t/err.txt"; then st_ok; else st_fail "docker-failed control did not name docker"; fi
  if ! grep -q 'python3' "$_t/calls.txt"; then st_ok; else st_fail "docker-failed control still ran exec"; fi

  # 6) the in-container program against canned payloads (TEST-NET +
  #    example.com only; clock pinned to 2026-10-15T12:00:00Z) - wherever a
  #    python3 exists (CI: the app-unit python image); alpine has none and
  #    says so
  if command -v python3 >/dev/null 2>&1; then
    cat > "$_t/fix/health.json" <<'EOF'
{"db_ok":true,"parity":"ok","last_apply":"","marker":false,"collector":"ok","collector_last_ts":"2026-10-15T11:59:50","stats_db_bytes":1234567,"dashboard_port":8080,"day_tz":"UTC","day_cut":"03:00","day_framing":"ok"}
EOF
    cat > "$_t/fix/coverage.json" <<'EOF'
{"total":{"up":1000,"down":9000},"classes":[{"klass":"hostname","up":800,"down":7200,"share":80.0},{"klass":"ip_only","up":200,"down":1800,"share":20.0}],"rules":[{"rule":"Domain","rule_payload":"panel.example.com","up":1,"down":1}],"window":{"requested_since":"2026-10-08T12","requested_until":"","oldest_bucket":"2026-10-09T00","retention_days":7,"truncated":true}}
EOF
    cat > "$_t/fix/domains.json" <<'EOF'
{"enabled":false,"rows":[]}
EOF
    cat > "$_t/fix/version.json" <<'EOF'
{"meta":true,"version":"v1.19.0-fixture"}
EOF
    cat > "$_t/fix/connections.json" <<'EOF'
{"connections":[{"id":"a","metadata":{"network":"tcp","type":"Tun","sourceIP":"192.0.2.10","destinationIP":"","host":"www.example.com","sniffHost":"","dstGeoIP":["US"],"dstIPASN":"AS64496 EXAMPLE"},"upload":1,"download":2,"chains":["JP 01","Routing Mode"],"rule":"GeoSite","rulePayload":"example"},{"id":"b","metadata":{"network":"tcp","type":"Inner","sourceIP":"","destinationIP":"198.51.100.7","host":"","sniffHost":"","dstGeoIP":[],"dstIPASN":""},"upload":1,"download":2,"chains":["DIRECT"],"rule":"Match","rulePayload":""},{"id":"c","metadata":{"network":"udp","type":"Tun","sourceIP":"192.0.2.11","destinationIP":"198.51.100.9","host":"","sniffHost":"cdn.example.com","dstGeoIP":["US"],"dstIPASN":"AS64496 EXAMPLE"},"upload":1,"download":2,"chains":["DIRECT"],"rule":"GeoIP","rulePayload":"CN"}],"downloadTotal":10,"uploadTotal":5,"memory":65536000}
EOF
    for _d in fix_nogeo fix_down fix_empty fix_bad; do
      cp "$_t/fix/health.json" "$_t/fix/coverage.json" "$_t/fix/domains.json" "$_t/$_d/"
    done
    cp "$_t/fix/version.json" "$_t/fix_nogeo/"; cp "$_t/fix/version.json" "$_t/fix_empty/"; cp "$_t/fix/version.json" "$_t/fix_bad/"
    sed 's/,"dstGeoIP":\[[^]]*\],"dstIPASN":"[^"]*"//g' "$_t/fix/connections.json" > "$_t/fix_nogeo/connections.json"
    printf '{"connections":[],"downloadTotal":0,"uploadTotal":0,"memory":1}\n' > "$_t/fix_empty/connections.json"
    printf '{"connections":"not-a-list","memory":1}\n' > "$_t/fix_bad/connections.json"
    # fix_down deliberately has no version.json: the controller is unreachable

    st_py() {  # st_py FIXTURE_DIR -> $_t/py.txt, rc in PRC
      PRC=0
      printf '%s\n' "$IB_PY" | env INSIGHTS_FIXTURE_DIR="$1" INSIGHTS_NOW_EPOCH=1792065600 \
        python3 - 8090 > "$_t/py.txt" 2> "$_t/pyerr.txt" || PRC=$?
    }
    st_line() {  # st_line NAME EXPECTED_LINE
      if grep -qx "$2" "$_t/py.txt"; then st_ok; else st_fail "$1: expected '$2' in: $(tr '\n' ' ' < "$_t/py.txt")"; fi
    }
    st_py "$_t/fix"
    if [ "$PRC" = 0 ]; then st_ok; else st_fail "program rc=$PRC: $(cat "$_t/pyerr.txt")"; fi
    st_line measured_at   'measured_at=2026-10-15T12:00:00Z'
    st_line collector     'panel_collector=ok'
    st_line db_bytes      'stats_db_bytes=1234567'
    st_line host_share    'coverage_hostname_share=80.0'
    st_line window_days   'coverage_window_days=6.5'
    st_line truncated     'coverage_truncated=true'
    st_line domains       'domains_enabled=false'
    st_line version       'mihomo_version=v1.19.0-fixture'
    st_line conn_len      'connections_len=3'
    st_line conn_inner    'connections_inner=1'
    st_line conn_hosted   'connections_host_share=66.7'
    st_line geo_present   'geo_fields=present'
    st_line geo_populated 'geo_populated_share=66.7'
    st_line mem           'mihomo_memory_bytes=65536000'
    if ! grep -q 'example.com\|192.0.2\|198.51.100\|http' "$_t/py.txt"; then st_ok; else st_fail "program printed an address, hostname or URL"; fi
    if ib_validate "$_t/py.txt" 2>/dev/null; then st_ok; else st_fail "program output does not satisfy the key contract"; fi
    st_py "$_t/fix_nogeo"
    st_line geo_absent    'geo_fields=absent'
    st_line geo_pop_zero  'geo_populated_share=0.0'
    st_py "$_t/fix_empty"
    st_line geo_unknown   'geo_fields=unknown'
    st_line conn_len_zero 'connections_len=0'
    if ib_validate "$_t/py.txt" 2>/dev/null; then st_ok; else st_fail "zero-connection record must still satisfy the key contract"; fi
    st_py "$_t/fix_bad"
    if [ "$PRC" = 2 ]; then st_ok; else st_fail "bad-shape rc=$PRC (want 2)"; fi
    st_line parse_named   'probe_failed=parse'
    st_py "$_t/fix_down"
    if [ "$PRC" = 2 ]; then st_ok; else st_fail "unreachable-controller rc=$PRC (want 2)"; fi
    st_line probe_named   'probe_failed=version'
    if ! grep -q 'Traceback\|Errno\|No such' "$_t/py.txt" "$_t/pyerr.txt"; then st_ok; else st_fail "failure path leaked exception text"; fi
    # the container's own PANEL_PORT outranks the argv default (observable
    # only through a failing live fetch in fixture-less mode: the program
    # must try the env port, so an unreachable loopback port still names
    # the health stage rather than crashing)
    if printf '%s\n' "$IB_PY" | env PANEL_PORT=1 python3 - 8090 2>/dev/null | grep -qx 'probe_failed=health'; then st_ok; else st_fail "env PANEL_PORT path did not name the health stage"; fi
  else
    echo "SKIP: python3 absent - the in-container program's fixture layer was not exercised here (CI runs it in the app-unit python image; locally run the self-test on a host with python3)"
  fi

  echo "insights_baseline self-test: $_pass passed, $_failn failed"
  [ "$_failn" -eq 0 ] || return 1
  echo "OK: insights_baseline record contract (positive, missing-key, empty-value, probe-failed, empty-output, container-down, docker-failed controls), program on stdin only, no URL/token/address in any record"
  return 0
}

case "${1:-}" in
  --self-test) ib_self_test ;;
  "") ib_live ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 1 ;;
esac
