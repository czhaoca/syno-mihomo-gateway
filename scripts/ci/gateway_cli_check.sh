#!/bin/sh
# gateway_cli_check.sh - behavioral suite for scripts/gateway.sh, the
# non-interactive command surface. Two layers, matching the repo idiom:
#   1. SUBPROCESS tests: run `sh gateway.sh ...` with a PATH-prepended stub dir
#      (function overrides do not cross the subprocess boundary), asserting the
#      CLI contract: usage/exit codes, the --yes and root gates, argv secret
#      rejection, --json stdout purity, and the unified gateway.log.
#   2. SOURCED tests (GATEWAY_SOURCE_ONLY=1): override the orchestration
#      functions to assert the fail-before-mutation deploy order, exactly like
#      dsm_installer_check.sh does for flow_deploy.
# Runs under BusyBox ash (alpine) and any POSIX sh. No real docker/network I/O.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
GW="$ROOT/scripts/gateway.sh"

pass=0; failn=0
ok()   { pass=$((pass+1)); }
fail() { echo "FAIL: $*" >&2; failn=$((failn+1)); }
fatal() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- static invariants ---------------------------------------------------------
[ -f "$GW" ] || fatal "scripts/gateway.sh does not exist"
if grep -E '^[^#]*\. .*(/ui\.sh|/i18n\.sh)' "$GW" >/dev/null; then
  fail "gateway.sh sources TTY code (ui.sh/i18n.sh)"
else ok; fi

# --- stub environment ----------------------------------------------------------
case "$(uname -m)" in
  x86_64|amd64) HOST_ARCH=amd64 ;;
  aarch64|arm64) HOST_ARCH=arm64 ;;
  armv7l|armv7) HOST_ARCH=arm ;;
  *) HOST_ARCH="$(uname -m)" ;;
esac
export HOST_ARCH

STUB="$TMP/bin"; mkdir -p "$STUB"
CALLS="$TMP/docker.calls"; : > "$CALLS"
export CALLS

cat > "$STUB/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  info) exit "${FAKE_INFO_RC:-0}" ;;
  logs) [ -n "${FAKE_CF_LOG:-}" ] && printf '%s\n' "$FAKE_CF_LOG"; exit 0 ;;
  login|pull|tag|rm) exit 0 ;;
  compose)
    shift
    case "$*" in
      version) exit 0 ;;
      *'up --help'*) printf -- '--pull never\n'; exit 0 ;;
      *' config'*) exit "${FAKE_COMPOSE_CFG_RC:-0}" ;;
      *) exit 0 ;;
    esac ;;
  image)
    case "$*" in
      *'{{.Id}}'*) echo sha256:fakelocal ;;
      *'{{.Architecture}}'*) echo "${FAKE_IMG_ARCH:-$HOST_ARCH}" ;;
    esac
    exit 0 ;;
  run) exit 0 ;;
  exec)
    case "$*" in
      *ip_forward*) echo "${FAKE_IP_FORWARD:-1}" ;;
      *sys/class/net*) exit "${FAKE_TUN_IF_RC:-0}" ;;
      *'/version'*) exit "${FAKE_CTL_RC:-0}" ;;
      # proxy_groups controller endpoints (chk_proxy_groups): /group lists the
      # groups; per-group /proxies/<name> URLs arrive %XX-encoded byte by byte
      # (auto=%61%75%74%6f, auto-x=%61%75%74%6f%2d%78, JPX=%4a%50%58 - the
      # auto-x pattern must precede auto, whose encoding is its prefix).
      *'/group'*)
        case "${FAKE_PG_MODE:-healthy}" in
          preepic) printf '{"proxies":[{"name":"auto","type":"URLTest","all":["n1","n2"]},{"name":"PROXY","type":"Selector","all":["auto","DIRECT","REJECT"]},{"name":"STREAMING","type":"Selector","all":["PROXY","auto","DIRECT"]},{"name":"GLOBAL","type":"Selector","all":["auto","PROXY"]}]}' ;;
          *) printf '{"proxies":[{"name":"auto","type":"URLTest","all":["n1","n2"]},{"name":"auto-x","type":"URLTest","all":["n1"]},{"name":"JPX","type":"URLTest","all":["n1"]},{"name":"PROXY","type":"Selector","all":["auto-x","auto","JPX","DIRECT","REJECT"]},{"name":"STREAMING","type":"Selector","all":["PROXY","auto","JPX","DIRECT"]},{"name":"GLOBAL","type":"Selector","all":["auto","PROXY"]}]}' ;;
        esac ;;
      *'/proxies/%61%75%74%6f%2d%78'*)
        if [ "${FAKE_PG_MODE:-healthy}" = default-empty ]; then
          printf '{"all":["REJECT"],"now":"REJECT"}'
        else
          printf '{"all":["n1"],"now":"n1"}'
        fi ;;
      *'/proxies/%4a%50%58'*)
        case "${FAKE_PG_MODE:-healthy}" in
          country-empty|default-empty) printf '{"all":["REJECT"],"now":"REJECT"}' ;;
          *) printf '{"all":["n1"],"now":"n1"}' ;;
        esac ;;
      *'/proxies/%61%75%74%6f'*) printf '{"all":["n1","n2"],"now":"n1"}' ;;
    esac
    exit 0 ;;
  network)
    case "$*" in
      *'{{.Driver}}'*) printf '%s\n' "${FAKE_NET_SPEC:-}"; exit 0 ;;
      *'.Containers'*) printf '%s\n' "${FAKE_ATTACHMENTS:-}"; exit 0 ;;
      *create*) exit 0 ;;
      *rm*) exit 0 ;;
      *) exit "${FAKE_NETWORK_RC:-1}" ;;
    esac ;;
  inspect)
    case "$*" in
      *'{{.State.Running}}'*cloudflared*) echo "${FAKE_CF_RUNNING:-false}"; exit 0 ;;
      *'{{.State.Running}}'*mihomo-ui*) echo "${FAKE_UI_RUNNING:-false}"; exit 0 ;;
      *'{{.State.Running}}'*) echo "${FAKE_MIHOMO_RUNNING:-false}"; exit 0 ;;
      *'.State.Health'*) echo "${FAKE_CF_HEALTH:-none}"; exit 0 ;;
      *'{{.State.StartedAt}}'*) echo '2026-01-01T00:00:00Z'; exit 0 ;;
      *'{{.State.Status}}'*) echo "${FAKE_MIHOMO_STATE:-missing}"; exit 0 ;;
      *'{{.RestartCount}}'*) echo 0; exit 0 ;;
      *'{{.Image}}'*) echo sha256:fakerunning; exit 0 ;;
      *compose.service*mihomo-ui*) echo metacubexd; exit 0 ;;
      *compose.service*) echo mihomo; exit 0 ;;
      *compose.project*) echo "${FAKE_COMPOSE_PROJECT:-syno-mihomo-gateway}"; exit 0 ;;
      *cloudflared*) exit "${FAKE_CF_RC:-1}" ;;
      *mihomo-ui*) exit "${FAKE_UI_RC:-1}" ;;
      *mihomo*) exit "${FAKE_MIHOMO_RC:-1}" ;;
    esac
    exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB/docker"

cat > "$STUB/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-u" ] && { echo "${FAKE_UID:-0}"; exit 0; }
exit 0
EOF
chmod +x "$STUB/id"

# validate_network_plan probes the parent interface via `ip link show` (else
# ifconfig). Stub `ip` so PARENT_INTERFACE=eth0 "exists" on every dev/CI
# platform (macOS has ifconfig but no eth0; CI containers vary) and every
# address query returns empty = the code's own "cannot verify, don't block"
# path. Deterministic on both platforms, no real network I/O. The `-6 addr`
# form feeds chk_ipv6_bypass: FAKE_IP6_RC flips it unprobeable, FAKE_IP6_GLOBAL
# emits one routable global inet6 line (RFC 3849 documentation prefix,
# fixture-only), FAKE_IP6_ULA one private fd00:: line the kernel also labels
# 'scope global' (the Matter/Thread border-router shape).
cat > "$STUB/ip" <<'EOF'
#!/bin/sh
case "$*" in
  -6\ addr*)
    [ "${FAKE_IP6_RC:-0}" = 0 ] || exit "$FAKE_IP6_RC"
    [ "${FAKE_IP6_GLOBAL:-0}" = 1 ] \
      && printf '    inet6 2001:db8::1/64 scope global dynamic\n'
    [ "${FAKE_IP6_ULA:-0}" = 1 ] \
      && printf '    inet6 fd00::1/64 scope global mngtmpaddr dynamic\n'
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB/ip"

DATA="$TMP/data"
mkdir -p "$DATA/config" "$DATA/logs"
export GATEWAY_DATA_DIR="$DATA"
export ENV_FILE="$DATA/.env"
export LOCK_DIR="$TMP/gw.lock"

# Optional-tunable defaults must exist at SOURCE time, not only inside
# load_env. Two production paths skip load_env: deploy/redeploy/modify take
# the lock BEFORE it runs (an unset LOCK_DIR died on mkdir '' - the
# redeploy-on-NAS regression), and status/doctor --json load via dotenv_load
# only (a lean .env without CONTROLLER_PORT probed http://127.0.0.1:/version).
# This suite exports LOCK_DIR and a rich fixture .env above for hermeticity,
# which is exactly why the CLASS needs its own assertion: unset the whole
# family, source common.sh, and require every shipped default to be present.
( unset INSTALLER_LANG UPDATE_ENABLED EXPECTED_ARCH CONTROLLER_PORT \
        CF_CONTAINER_NAME CF_HEALTH_TIMEOUT NOTIFY_ON_NOCHANGE UPDATE_LOG \
        LOG_KEEP LOG_MAX_BYTES PULL_RETRIES PULL_RETRY_DELAY \
        DOCKER_READY_TIMEOUT DOCKER_READY_INTERVAL HEALTH_RETRIES \
        HEALTH_INTERVAL HEALTH_MAX_RESTARTS TUN_DEVICE TUN_ENABLE \
        TUN_AUTO_REDIRECT LOCK_DIR
  . "$ROOT/scripts/lib/common.sh"
  [ -n "${LOCK_DIR:-}" ] && [ "${CONTROLLER_PORT:-}" = 9090 ] \
    && [ "${EXPECTED_ARCH:-}" = amd64 ] && [ "${TUN_ENABLE:-}" = true ] \
    && [ "${TUN_AUTO_REDIRECT:-}" = false ] && [ -n "${HEALTH_RETRIES:-}" ] \
    && [ -n "${UPDATE_LOG:-}" ] && [ -n "${CF_CONTAINER_NAME:-}" ] \
    && [ -n "${PULL_RETRIES:-}" ] && [ -n "${TUN_DEVICE:-}" ] ) \
  && ok || fail "common.sh does not default the optional tunables at source time (pre-load_env and dotenv_load-only paths break on a lean environment)"

# The concrete dotenv_load-only victim: mihomo_controller_probe builds its URL
# from CONTROLLER_PORT. With the key absent from .env and no source-time
# default, gateway.sh doctor --json probed http://127.0.0.1:/version - a false
# 'controller broken' the human doctor (load_env) never showed. Probe the REAL
# function with the variable unset and require the shipped port in the argv
# the stub docker records.
(
  unset CONTROLLER_PORT CONTROLLER_SECRET
  PATH="$STUB:$PATH"; export PATH
  CALLS="$TMP/probe.calls"; : > "$CALLS"; export CALLS
  . "$ROOT/scripts/lib/common.sh"
  . "$ROOT/scripts/lib/registry.sh"
  . "$ROOT/scripts/lib/compose.sh"
  detect_compose >/dev/null 2>&1 || exit 1   # DOCKER_BIN is set here, not at source
  mihomo_controller_probe >/dev/null 2>&1 || :
  grep -q '127\.0\.0\.1:9090/version' "$CALLS"
) && ok || fail "mihomo_controller_probe does not use the shipped controller port with CONTROLLER_PORT unset (doctor --json false alarm on a lean .env)"
cat > "$ENV_FILE" <<EOF
REGISTRY_MODE=docker
MIHOMO_IMAGE=docker.io/metacubex/mihomo:latest
METACUBEXD_IMAGE=ghcr.io/metacubex/metacubexd:latest
UPDATE_IMAGES="docker.io/metacubex/mihomo:latest ghcr.io/metacubex/metacubexd:latest"
PARENT_INTERFACE=eth0
ROUTER_IP=192.168.1.1
SUBNET_CIDR=192.168.1.0/24
MIHOMO_IP=192.168.1.100
WEB_UI_PORT=8080
CONTROLLER_PORT=9090
DNS_DEFAULT_NAMESERVER=1.1.1.1
DNS_NAMESERVER=1.1.1.1
DNS_FALLBACK=1.1.1.1
EXPECTED_ARCH=$HOST_ARCH
TUN_ENABLE=false
TUN_AUTO_REDIRECT=false
HEALTH_RETRIES=2
HEALTH_INTERVAL=0
PULL_RETRIES=1
PULL_RETRY_DELAY=0
EOF
printf '%s\n' 'https://sub.example/token' > "$DATA/config/subscription.txt"

# gw = run as (fake) root; gwu = run as a (fake) unprivileged user.
# COMPOSE_PROJECT_NAME pins the expected project regardless of what the CI
# checkout directory happens to be called (the stub docker reports the same
# name, so lifecycle sees our own containers unless FAKE_COMPOSE_PROJECT says
# otherwise).
export COMPOSE_PROJECT_NAME=syno-mihomo-gateway
gw()  { FAKE_UID=0    PATH="$STUB:$PATH" sh "$GW" "$@" </dev/null; }
gwu() { FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" "$@" </dev/null; }

expect_rc() {
  _want="$1"; shift
  _got=0; "$@" >"$TMP/out" 2>"$TMP/err" || _got=$?
  if [ "$_got" = "$_want" ]; then ok; else
    fail "expected rc $_want got $_got for: $* (stderr: $(tail -n2 "$TMP/err" | tr '\n' ' '))"
  fi
}

# --- usage / unknown input -> EXIT_CONFIG (3) -----------------------------------
expect_rc 3 gw
expect_rc 3 gw bogus-verb
expect_rc 3 gw deploy --definitely-unknown-flag --yes
expect_rc 0 gw --help
expect_rc 0 gw help

# --- secrets are never accepted on argv -----------------------------------------
expect_rc 3 gw deploy --yes --controller-secret=abc
grep -qi '\.env' "$TMP/err" || fail "secret rejection did not point at .env"
expect_rc 3 gw deploy --yes --acr-password abc
expect_rc 3 gw modify --yes --cf-tunnel-token=abc

# --- confirmation gate: mutating verb, non-TTY stdin, no --yes -> 7 --------------
expect_rc 7 gw deploy
expect_rc 7 gw redeploy
expect_rc 7 gw modify --network
expect_rc 7 gw update
expect_rc 7 gw cron --apply-crontab --time 03:00

# --- root gate: confirmed mutating verb without root -> 6 ------------------------
expect_rc 6 gwu deploy --yes
expect_rc 6 gwu redeploy --yes

# --- --json is read-only-verbs only ----------------------------------------------
expect_rc 3 gw deploy --yes --json

# --- dry-run: allowed without --yes and without root; mutates nothing ------------
: > "$CALLS"
expect_rc 0 gwu deploy --dry-run
if grep -Eq 'network create|up -d|rm -f|network rm|^pull ' "$CALLS"; then
  fail "deploy --dry-run performed a mutating docker call: $(grep -E 'network create|up -d|rm -f|network rm|^pull ' "$CALLS" | head -n1)"
else ok; fi

# --- foreign compose project: a preserve deploy plan is rejected with 3 ----------
# The stub reports existing managed containers whose project label differs from
# ours (a legacy flat install); the plan step must fail before any mutation.
FAKE_MIHOMO_RC=0 FAKE_UI_RC=0 FAKE_COMPOSE_PROJECT=mihomo
export FAKE_MIHOMO_RC FAKE_UI_RC FAKE_COMPOSE_PROJECT
expect_rc 3 gwu deploy --dry-run
grep -qi "compose project 'mihomo'" "$TMP/out" "$TMP/err" \
  && ok || fail "foreign-project rejection did not name the foreign project"
unset FAKE_COMPOSE_PROJECT
FAKE_MIHOMO_RC=1 FAKE_UI_RC=1
export FAKE_MIHOMO_RC FAKE_UI_RC

# --- status: read-only, no root, exit 0 ------------------------------------------
expect_rc 0 gwu status
grep -q 'fresh' "$TMP/out" || fail "status did not report the fresh stack state"

# TUN is ON by default everywhere (render_config.sh and load_env both default
# it to true); a stray false fallback in a path that skips load_env (status's
# lean dotenv_load) misreports the tun line and could skip the TUN dataplane
# probe on default configs. Keep every fallback aligned to true. The bracket
# in the pattern keeps this check from matching its own source.
if grep -rn 'TUN_ENABLE:-fals[e]' "$ROOT/scripts" >/dev/null 2>&1; then
  fail "a script defaults TUN_ENABLE to false; align fallbacks with the render/load_env default (true)"
else
  ok
fi

# --- status --json: exactly one JSON object on stdout, nothing else --------------
expect_rc 0 gwu status --json
_lines="$(wc -l < "$TMP/out" | tr -d ' ')"
[ "$_lines" = 1 ] || fail "status --json stdout is not exactly one line ($_lines lines)"
case "$(cat "$TMP/out")" in
  '{'*'}') ok ;;
  *) fail "status --json stdout is not a JSON object: $(head -c 120 "$TMP/out")" ;;
esac
grep -q '"verb":"status"' "$TMP/out" || fail "status --json missing verb field"
grep -q '"stack_state":"fresh"' "$TMP/out" || fail "status --json missing stack_state"
grep -q '"checks":\[' "$TMP/out" || fail "status --json missing checks[]"
grep -q '"exit_code":' "$TMP/out" || fail "status --json missing exit_code"

# --- unified log: verb= and run-id fields, legacy names symlinked ----------------
GWLOG="$DATA/logs/gateway.log"
[ -f "$GWLOG" ] || fail "logs/gateway.log was not created"
grep -q 'verb=status run=' "$GWLOG" || fail "gateway.log lacks verb=/run-id fields"
[ -L "$DATA/logs/install.log" ] || fail "install.log is not a symlink to the unified log"
[ -L "$DATA/logs/auto-update.log" ] || fail "auto-update.log is not a symlink to the unified log"

# --- doctor host_dns/geodata fixtures: hermetic resolver probe + cached geodata --
# The host_dns check probes every nameserver in SMG_RESOLV_CONF via nslookup;
# stub both so the suite never touches the machine's real resolvers, and
# pre-seed the geo databases so existing doctor severities stay unchanged.
cat > "$STUB/nslookup" <<'EOF'
#!/bin/sh
exit "${FAKE_NS_RC:-0}"
EOF
chmod +x "$STUB/nslookup"
printf 'nameserver 192.0.2.53\n' > "$TMP/resolv.conf"
export SMG_RESOLV_CONF="$TMP/resolv.conf"
printf 'fixture' > "$DATA/config/GeoSite.dat"
printf 'fixture' > "$DATA/config/geoip.metadb"
# dns_privacy reads the rendered config: seed the v2 (split-horizon
# foreign-by-default) shape so existing severities stay all-ok, keeping a
# pristine copy for the flip cases below (RFC 5737 addresses only).
cat > "$TMP/config.v2.yaml" <<'EOF'
dns:
  nameserver-policy:
    'testingcf.jsdelivr.net': [ https://192.0.2.53/dns-query ]
    'www.gstatic.com': [ https://192.0.2.53/dns-query ]
    'geosite:cn': [ https://192.0.2.53/dns-query ]
    'geosite:geolocation-!cn': [ https://192.0.2.54/dns-query#auto ]
  proxy-server-nameserver: [ https://192.0.2.53/dns-query ]
  nameserver: [ https://192.0.2.54/dns-query#auto ]
EOF
cp "$TMP/config.v2.yaml" "$DATA/config/config.yaml"

# --- doctor --json: one JSON object on stdout, doctor exit semantics (0/2/3) -----
_rc=0; FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err" || _rc=$?
case "$_rc" in 0|2|3) ok ;; *) fail "doctor --json exited $_rc (want 0/2/3)" ;; esac
_lines="$(wc -l < "$TMP/out" | tr -d ' ')"
[ "$_lines" = 1 ] || fail "doctor --json stdout is not exactly one line"
grep -q '"verb":"doctor"' "$TMP/out" || fail "doctor --json missing verb field"
grep -q '"checks":\[' "$TMP/out" || fail "doctor --json missing checks[]"

# --- doctor subscription parity: human doctor.sh mirrors --json's check ----------
# subscription.txt was seeded above -> both modes report it as stored, no WARN.
grep -q '"name":"subscription","value":"ok"' "$TMP/out" \
  || fail "doctor --json lacks subscription:ok with a stored URL"
FAKE_UID=0 PATH="$STUB:$PATH" sh "$ROOT/scripts/doctor.sh" </dev/null >"$TMP/dout" 2>"$TMP/derr" || :
grep -q 'subscription URL is stored' "$TMP/dout" \
  || fail "doctor.sh did not report the stored subscription"
if grep -q 'subscription' "$TMP/derr"; then
  fail "doctor.sh warned despite a stored subscription"
fi
# with the file gone, both modes must flag it (missing / WARN) - same severity.
mv "$DATA/config/subscription.txt" "$DATA/config/subscription.txt.keep"
FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err" || :
grep -q '"name":"subscription","value":"missing"' "$TMP/out" \
  || fail "doctor --json lacks subscription:missing without a URL"
FAKE_UID=0 PATH="$STUB:$PATH" sh "$ROOT/scripts/doctor.sh" </dev/null >"$TMP/dout" 2>"$TMP/derr" || :
grep -q 'WARN.*subscription' "$TMP/derr" \
  || fail "doctor.sh did not warn about the missing subscription"
mv "$DATA/config/subscription.txt.keep" "$DATA/config/subscription.txt"
ok

# --- doctor host_dns / geodata parity: both modes, both severities ---------------
# Fixtures above give an answering resolver + cached geodata -> ok/cached.
FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err" || :
grep -q '"name":"host_dns","value":"ok"' "$TMP/out" || fail "doctor --json lacks host_dns:ok"
grep -q '"name":"geodata","value":"cached"' "$TMP/out" || fail "doctor --json lacks geodata:cached"
# a dead resolver degrades BOTH modes the same way.
FAKE_NS_RC=1; export FAKE_NS_RC
FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err" || :
grep -q '"name":"host_dns","value":"degraded"' "$TMP/out" \
  || fail "doctor --json lacks host_dns:degraded with a dead resolver"
FAKE_UID=0 PATH="$STUB:$PATH" sh "$ROOT/scripts/doctor.sh" </dev/null >"$TMP/dout" 2>"$TMP/derr" || :
grep -q 'WARN.*host DNS' "$TMP/derr" || fail "doctor.sh did not warn about the dead resolver"
FAKE_NS_RC=0; export FAKE_NS_RC
# uncached geodata -> missing / WARN on both sides.
mv "$DATA/config/GeoSite.dat" "$DATA/config/GeoSite.dat.keep"
FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err" || :
grep -q '"name":"geodata","value":"missing"' "$TMP/out" || fail "doctor --json lacks geodata:missing"
FAKE_UID=0 PATH="$STUB:$PATH" sh "$ROOT/scripts/doctor.sh" </dev/null >"$TMP/dout" 2>"$TMP/derr" || :
grep -q 'WARN.*geo databases' "$TMP/derr" || fail "doctor.sh did not warn about uncached geodata"
mv "$DATA/config/GeoSite.dat.keep" "$DATA/config/GeoSite.dat"
ok

# --- doctor dns_privacy parity: v2 ok / v1 + legacy warn / no config silent ------
# The v2 fixture config seeded above -> ok in --json, no WARN in human.
FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err" || :
grep -q '"name":"dns_privacy","value":"v2"' "$TMP/out" \
  || fail "doctor --json lacks dns_privacy:v2 with the v2 config"
# a surviving fallback line (pre-v1.3.10 render) degrades BOTH modes.
cp "$TMP/config.v2.yaml" "$DATA/config/config.yaml"
printf '  fallback: [ https://192.0.2.99/dns-query ]\n' >> "$DATA/config/config.yaml"
FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err" || :
grep -q '"name":"dns_privacy","value":"v1"' "$TMP/out" \
  || fail "doctor --json lacks dns_privacy:v1 with a surviving fallback line"
FAKE_UID=0 PATH="$STUB:$PATH" sh "$ROOT/scripts/doctor.sh" </dev/null >"$TMP/dout" 2>"$TMP/derr" || :
grep -q 'WARN.*v1 residual' "$TMP/derr" || fail "doctor.sh did not warn about the v1 residual"
# no geosite policy entries at all = the legacy profile; WARN + upgrade hint.
printf 'dns:\n  nameserver: [ 192.0.2.53 ]\n  fallback: [ https://192.0.2.99/dns-query ]\n' \
  > "$DATA/config/config.yaml"
FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err" || :
grep -q '"name":"dns_privacy","value":"legacy"' "$TMP/out" \
  || fail "doctor --json lacks dns_privacy:legacy without policy entries"
FAKE_UID=0 PATH="$STUB:$PATH" sh "$ROOT/scripts/doctor.sh" </dev/null >"$TMP/dout" 2>"$TMP/derr" || :
grep -q 'WARN.*legacy DNS profile' "$TMP/derr" || fail "doctor.sh did not warn about the legacy profile"
grep -q 'split-horizon upgrade' "$TMP/derr" || fail "doctor.sh legacy warn lacks the upgrade hint"
# unreadable/missing config -> unknown in --json, SILENT in human (no line).
rm -f "$DATA/config/config.yaml"
FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err" || :
grep -q '"name":"dns_privacy","value":"unknown"' "$TMP/out" \
  || fail "doctor --json lacks dns_privacy:unknown without a rendered config"
FAKE_UID=0 PATH="$STUB:$PATH" sh "$ROOT/scripts/doctor.sh" </dev/null >"$TMP/dout" 2>"$TMP/derr" || :
if grep -q 'DNS privacy\|DNS profile\|v1 residual' "$TMP/dout" "$TMP/derr"; then
  fail "doctor.sh rendered a dns_privacy line for a missing config (must be silent)"
fi
# restore the pristine v2 fixture for everything downstream.
cp "$TMP/config.v2.yaml" "$DATA/config/config.yaml"
ok

# --- doctor FULL parity (#29): every check, human vs --json classification -------
# The three cases above cover the UNGATED checks; the deep set is gated on the
# basics including a raw [ -c /dev/net/tun ] with no test seam - the reason
# parity stopped at 3 checks. Create the node inside THIS container only
# (guarded by the /.dockerenv marker; the suite's canonical home is alpine
# docker per docs/development.md) and skip loudly elsewhere - never mknod on a
# bare host. Idiom: one healthy baseline pass asserts every ok-side value in
# both modes, then each check flips to its failing state one knob at a time
# and both modes must agree on value/text AND classification (exit code) -
# the flip runs double as the red-direction proof for every new case.
djson() { FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err"; }
dhum()  { FAKE_UID=0 PATH="$STUB:$PATH" sh "$ROOT/scripts/doctor.sh" </dev/null >"$TMP/dout" 2>"$TMP/derr"; }
jval()  { grep -q "\"name\":\"$1\",\"value\":\"$2\"" "$TMP/out"; }
dpar() { # NAME - run both modes, capture rcs into _jrc/_hrc
  _jrc=0; djson || _jrc=$?
  _hrc=0; dhum || _hrc=$?
}
cat > "$STUB/crontab" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$STUB/crontab"   # scheduler_task_deployed's last resort stays deterministic
# Container-only block: the mknod AND the /usr/local/bin stub copies below
# mutate the environment, which is fine for the suite's own throwaway
# container and never acceptable on a real host. doctor.sh PREPENDS
# /usr/local/bin:/usr/bin:... to PATH (line 5), so the BusyBox nslookup and
# crontab would shadow $STUB's fakes - park copies in /usr/local/bin, which
# wins that prepend (docker resolves to $STUB anyway: alpine has no real one).
_fp_run=0
if [ -f /.dockerenv ]; then
  if [ ! -c /dev/net/tun ]; then
    mkdir -p /dev/net 2>/dev/null || :
    mknod /dev/net/tun c 10 200 2>/dev/null || :
  fi
  if [ -c /dev/net/tun ] && mkdir -p /usr/local/bin 2>/dev/null \
     && cp "$STUB/nslookup" "$STUB/crontab" "$STUB/ip" /usr/local/bin/ 2>/dev/null; then
    _fp_run=1
  fi
fi
if [ "$_fp_run" = 1 ]; then
  cp "$ENV_FILE" "$TMP/env.keep"
  # the fixture ships TUN_ENABLE=false; the deep gateway probe needs true
  sed 's/^TUN_ENABLE=false$/TUN_ENABLE=true/' "$TMP/env.keep" > "$ENV_FILE"
  FAKE_MIHOMO_RC=0 FAKE_UI_RC=0 FAKE_MIHOMO_RUNNING=true FAKE_UI_RUNNING=true
  FAKE_MIHOMO_STATE=running FAKE_NETWORK_RC=0
  FAKE_NET_SPEC='macvlan|eth0|192.168.1.0/24|192.168.1.1'
  FAKE_CF_RC=0 FAKE_CF_RUNNING=true FAKE_CF_HEALTH=healthy
  SMG_SCHED_TASK_DIR="$TMP/no-taskdir" SMG_SCHED_EVENT_DB="$TMP/no-db"
  SMG_SCHED_CRONTAB="$TMP/sched.crontab"
  printf '0 2 * * *\troot\tsh /x/scripts/auto_update.sh\n@boot\troot\tsh /x/scripts/setup_network.sh\n' > "$TMP/sched.crontab"
  export FAKE_MIHOMO_RC FAKE_UI_RC FAKE_MIHOMO_RUNNING FAKE_UI_RUNNING \
         FAKE_MIHOMO_STATE FAKE_NETWORK_RC FAKE_NET_SPEC FAKE_CF_RC \
         FAKE_CF_RUNNING FAKE_CF_HEALTH SMG_SCHED_TASK_DIR SMG_SCHED_EVENT_DB \
         SMG_SCHED_CRONTAB

  # healthy baseline: all 20 checks ok-side in --json, HEALTHY rc 0 in both
  dpar
  [ "$_jrc" = 0 ] && [ "$_hrc" = 0 ] \
    && ok || fail "full-parity baseline rc: json=$_jrc human=$_hrc (want 0/0; derr: $(tail -n2 "$TMP/derr" | tr '\n' ' '))"
  for _pc in 'env ok' 'docker ok' 'arch ok' 'tun_device ok' 'network ok' \
             'compose ok' 'mihomo running' 'tun_gateway ok' 'controller ok' \
             'image_arch ok' 'proxy_groups ok' 'dashboard running' \
             'update_task ok' 'boot_task ok' \
             'cloudflared ok' 'subscription ok' 'host_dns ok' 'geodata cached' \
             'dns_privacy v2' 'ipv6_bypass ok'; do
    # shellcheck disable=SC2086 # deliberate: NAME VALUE split
    jval $_pc && ok || fail "healthy doctor --json lacks ${_pc%% *}:${_pc##* }"
  done
  grep -q 'Result: HEALTHY' "$TMP/dout" && ok || fail "healthy doctor.sh not HEALTHY"

  # env (missing .env): both broken/ERROR, rc 3; --json gates the deep set
  mv "$ENV_FILE" "$ENV_FILE.keep"
  dpar
  jval env broken && jval mihomo unknown && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q '\.env is missing' "$TMP/derr" \
    && ok || fail "env-missing parity (json=$_jrc human=$_hrc)"
  mv "$ENV_FILE.keep" "$ENV_FILE"

  # docker daemon down: both broken, rc 3
  FAKE_INFO_RC=1; export FAKE_INFO_RC
  dpar
  jval docker broken && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q 'Docker daemon is unavailable' "$TMP/derr" \
    && ok || fail "docker-down parity (json=$_jrc human=$_hrc)"
  unset FAKE_INFO_RC

  # arch mismatch: both broken, rc 3
  sed 's/^EXPECTED_ARCH=.*/EXPECTED_ARCH=zzz9/' "$ENV_FILE" > "$ENV_FILE.tmp" \
    && mv "$ENV_FILE.tmp" "$ENV_FILE"
  dpar
  jval arch mismatch && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q 'EXPECTED_ARCH=zzz9' "$TMP/derr" \
    && ok || fail "arch-mismatch parity (json=$_jrc human=$_hrc)"
  sed 's/^TUN_ENABLE=false$/TUN_ENABLE=true/' "$TMP/env.keep" > "$ENV_FILE"

  # tun_device missing: remove the node, both broken rc 3, deep set gated
  rm -f /dev/net/tun
  dpar
  jval tun_device missing && jval mihomo unknown && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q 'host /dev/net/tun is missing' "$TMP/derr" \
    && ok || fail "tun_device-missing parity (json=$_jrc human=$_hrc)"
  mknod /dev/net/tun c 10 200 2>/dev/null || :
  [ -c /dev/net/tun ] || fail "could not restore /dev/net/tun after the missing-direction case"

  # network broken: both rc 3
  FAKE_NETWORK_RC=1; export FAKE_NETWORK_RC
  dpar
  jval network broken && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q 'macvlan network is missing or inconsistent' "$TMP/derr" \
    && ok || fail "network-broken parity (json=$_jrc human=$_hrc)"
  FAKE_NETWORK_RC=0; export FAKE_NETWORK_RC

  # compose config invalid: both broken, rc 3
  FAKE_COMPOSE_CFG_RC=1; export FAKE_COMPOSE_CFG_RC
  dpar
  jval compose broken && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q 'Compose configuration is invalid' "$TMP/derr" \
    && ok || fail "compose-invalid parity (json=$_jrc human=$_hrc)"
  unset FAKE_COMPOSE_CFG_RC

  # mihomo not running: both broken rc 3; the nested probes are skipped in BOTH
  FAKE_MIHOMO_RUNNING=false FAKE_MIHOMO_STATE=exited
  export FAKE_MIHOMO_RUNNING FAKE_MIHOMO_STATE
  dpar
  jval mihomo not-running && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q 'mihomo container state=exited' "$TMP/derr" \
    && ok || fail "mihomo-down parity (json=$_jrc human=$_hrc)"
  if grep -q '"name":"tun_gateway"' "$TMP/out"; then
    fail "mihomo-down: --json still probed tun_gateway (human mode skips nested probes)"
  else ok; fi
  FAKE_MIHOMO_RUNNING=true FAKE_MIHOMO_STATE=running
  export FAKE_MIHOMO_RUNNING FAKE_MIHOMO_STATE

  # tun_gateway broken (TUN iface missing in-container): both rc 3
  FAKE_TUN_IF_RC=1; export FAKE_TUN_IF_RC
  dpar
  jval tun_gateway broken && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q 'in-container TUN gateway is not ready' "$TMP/derr" \
    && ok || fail "tun_gateway-broken parity (json=$_jrc human=$_hrc)"
  unset FAKE_TUN_IF_RC

  # tun_gateway disabled (TUN_ENABLE=false): no severity in either mode
  cp "$TMP/env.keep" "$ENV_FILE"   # fixture ships TUN_ENABLE=false
  dpar
  jval tun_gateway disabled && [ "$_jrc" = 0 ] && [ "$_hrc" = 0 ] \
    && grep -q 'TUN transparent gateway disabled' "$TMP/dout" \
    && ok || fail "tun_gateway-disabled parity (json=$_jrc human=$_hrc)"
  sed 's/^TUN_ENABLE=false$/TUN_ENABLE=true/' "$TMP/env.keep" > "$ENV_FILE"

  # controller not answering: both broken rc 3
  FAKE_CTL_RC=1; export FAKE_CTL_RC
  dpar
  jval controller broken && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q 'controller API does not respond' "$TMP/derr" \
    && ok || fail "controller-broken parity (json=$_jrc human=$_hrc)"
  unset FAKE_CTL_RC

  # image_arch mismatch: both broken rc 3
  FAKE_IMG_ARCH=bogusarch; export FAKE_IMG_ARCH
  dpar
  jval image_arch mismatch && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q 'image architecture does not match' "$TMP/derr" \
    && ok || fail "image_arch-mismatch parity (json=$_jrc human=$_hrc)"
  unset FAKE_IMG_ARCH

  # dashboard not running: DEGRADED (warn) on both sides, rc 2
  FAKE_UI_RUNNING=false; export FAKE_UI_RUNNING
  dpar
  jval dashboard not-running && [ "$_jrc" = 2 ] && [ "$_hrc" = 2 ] \
    && grep -q 'WARN.*dashboard container is not running' "$TMP/derr" \
    && grep -q 'Result: DEGRADED' "$TMP/derr" \
    && ok || fail "dashboard-down parity (json=$_jrc human=$_hrc)"
  FAKE_UI_RUNNING=true; export FAKE_UI_RUNNING

  # update_task missing: degraded/WARN on both, rc 2
  printf '@boot\troot\tsh /x/scripts/setup_network.sh\n' > "$TMP/sched.crontab"
  dpar
  jval update_task missing && [ "$_jrc" = 2 ] && [ "$_hrc" = 2 ] \
    && grep -q 'no scheduled task runs scripts/auto_update.sh' "$TMP/derr" \
    && ok || fail "update_task-missing parity (json=$_jrc human=$_hrc)"

  # boot_task missing: degraded/WARN on both, rc 2
  printf '0 2 * * *\troot\tsh /x/scripts/auto_update.sh\n' > "$TMP/sched.crontab"
  dpar
  jval boot_task missing && [ "$_jrc" = 2 ] && [ "$_hrc" = 2 ] \
    && grep -q 'no Boot-up task runs scripts/setup_network.sh' "$TMP/derr" \
    && ok || fail "boot_task-missing parity (json=$_jrc human=$_hrc)"

  # scheduler unknown (nothing searchable): NO severity in either mode
  SMG_SCHED_CRONTAB="$TMP/absent.crontab"; export SMG_SCHED_CRONTAB
  dpar
  jval update_task unknown && jval boot_task unknown && [ "$_jrc" = 0 ] && [ "$_hrc" = 0 ] \
    && ok || fail "scheduler-unknown parity (json=$_jrc human=$_hrc)"
  if grep -q 'scheduled' "$TMP/dout" "$TMP/derr"; then
    fail "scheduler-unknown: doctor.sh mentioned scheduler tasks on a box with no searchable scheduler"
  else ok; fi
  SMG_SCHED_CRONTAB="$TMP/sched.crontab"; export SMG_SCHED_CRONTAB
  printf '0 2 * * *\troot\tsh /x/scripts/auto_update.sh\n@boot\troot\tsh /x/scripts/setup_network.sh\n' > "$TMP/sched.crontab"

  # update_task disabled: named in --json, silent in human mode, rc 0
  sed 's/^TUN_ENABLE=false$/TUN_ENABLE=true/' "$TMP/env.keep" > "$ENV_FILE"
  printf 'UPDATE_ENABLED=false\n' >> "$ENV_FILE"
  dpar
  jval update_task disabled && [ "$_jrc" = 0 ] && [ "$_hrc" = 0 ] \
    && ok || fail "update_task-disabled parity (json=$_jrc human=$_hrc)"
  if grep -q 'auto-update task' "$TMP/dout"; then
    fail "update_task-disabled: doctor.sh checked a disabled updater's task"
  else ok; fi
  sed 's/^TUN_ENABLE=false$/TUN_ENABLE=true/' "$TMP/env.keep" > "$ENV_FILE"

  # cloudflared absent: named in --json, silent in human mode, rc 0
  FAKE_CF_RC=1; export FAKE_CF_RC
  dpar
  jval cloudflared absent && [ "$_jrc" = 0 ] && [ "$_hrc" = 0 ] \
    && ok || fail "cloudflared-absent parity (json=$_jrc human=$_hrc)"
  if grep -q 'cloudflared' "$TMP/dout" "$TMP/derr"; then
    fail "cloudflared-absent: doctor.sh mentioned an absent optional container"
  else ok; fi
  FAKE_CF_RC=0; export FAKE_CF_RC

  # cloudflared down: degraded/WARN on both, rc 2
  FAKE_CF_HEALTH=none; export FAKE_CF_HEALTH
  dpar
  jval cloudflared down && [ "$_jrc" = 2 ] && [ "$_hrc" = 2 ] \
    && grep -q 'WARN.*cloudflared tunnel is not connected' "$TMP/derr" \
    && ok || fail "cloudflared-down parity (json=$_jrc human=$_hrc)"

  # cloudflared ok via the log-registration signal (no native health)
  FAKE_CF_LOG='Registered tunnel connection abc123'; export FAKE_CF_LOG
  dpar
  jval cloudflared ok && [ "$_jrc" = 0 ] && [ "$_hrc" = 0 ] \
    && grep -q 'cloudflared tunnel is connected' "$TMP/dout" \
    && ok || fail "cloudflared-signal parity (json=$_jrc human=$_hrc)"
  unset FAKE_CF_LOG
  FAKE_CF_HEALTH=healthy; export FAKE_CF_HEALTH

  # ipv6_bypass exposed (global v6 on the LAN parent): degraded/WARN both, rc 2
  FAKE_IP6_GLOBAL=1; export FAKE_IP6_GLOBAL
  dpar
  jval ipv6_bypass exposed && [ "$_jrc" = 2 ] && [ "$_hrc" = 2 ] \
    && grep -q 'WARN.*global IPv6 is live on eth0' "$TMP/derr" \
    && grep -q 'disable IPv6' "$TMP/derr" \
    && ok || fail "ipv6_bypass-exposed parity (json=$_jrc human=$_hrc)"
  unset FAKE_IP6_GLOBAL

  # ipv6_bypass ULA-only (Matter/Thread hub RA): ok in BOTH modes, rc 0 - a
  # private fd00:: prefix is not internet-routable and must never degrade
  FAKE_IP6_ULA=1; export FAKE_IP6_ULA
  dpar
  jval ipv6_bypass ok && [ "$_jrc" = 0 ] && [ "$_hrc" = 0 ] \
    && grep -q 'only private (ULA) IPv6' "$TMP/dout" \
    && ok || fail "ipv6_bypass-ula parity (json=$_jrc human=$_hrc)"
  # ...and a routable GUA alongside the ULA still wins: exposed, rc 2
  FAKE_IP6_GLOBAL=1; export FAKE_IP6_GLOBAL
  dpar
  jval ipv6_bypass exposed && [ "$_jrc" = 2 ] && [ "$_hrc" = 2 ] \
    && ok || fail "ipv6_bypass-ula+gua parity (json=$_jrc human=$_hrc)"
  unset FAKE_IP6_ULA FAKE_IP6_GLOBAL

  # ipv6_bypass unprobeable (ip errors): unknown in --json, silent in human, rc 0
  FAKE_IP6_RC=1; export FAKE_IP6_RC
  dpar
  jval ipv6_bypass unknown && [ "$_jrc" = 0 ] && [ "$_hrc" = 0 ] \
    && ok || fail "ipv6_bypass-unknown parity (json=$_jrc human=$_hrc)"
  if grep -q 'IPv6' "$TMP/dout" "$TMP/derr"; then
    fail "ipv6_bypass-unknown: doctor.sh mentioned IPv6 on an unprobeable box"
  else ok; fi
  unset FAKE_IP6_RC

  # proxy_groups country-empty (a COUNTRY_GROUPS regex matches nothing):
  # degraded/WARN in both modes, rc 2, remediation hint names the knob
  FAKE_PG_MODE=country-empty; export FAKE_PG_MODE
  dpar
  jval proxy_groups country-empty && [ "$_jrc" = 2 ] && [ "$_hrc" = 2 ] \
    && grep -q 'WARN.*country group' "$TMP/derr" \
    && grep -q 'COUNTRY_GROUPS' "$TMP/derr" \
    && ok || fail "proxy_groups-country-empty parity (json=$_jrc human=$_hrc)"

  # proxy_groups default-empty (auto-x matches no node): BROKEN both, rc 3
  FAKE_PG_MODE=default-empty; export FAKE_PG_MODE
  dpar
  jval proxy_groups default-empty && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
    && grep -q 'ERROR.*auto-x' "$TMP/derr" \
    && ok || fail "proxy_groups-default-empty parity (json=$_jrc human=$_hrc)"

  # proxy_groups pre-epic config (no filtered groups rendered): ok both, rc 0
  FAKE_PG_MODE=preepic; export FAKE_PG_MODE
  dpar
  jval proxy_groups ok && [ "$_jrc" = 0 ] && [ "$_hrc" = 0 ] \
    && grep -q 'no filtered proxy groups' "$TMP/dout" \
    && ok || fail "proxy_groups-preepic parity (json=$_jrc human=$_hrc)"
  unset FAKE_PG_MODE

  # restore the outer suite's world exactly as the earlier sections left it
  cp "$TMP/env.keep" "$ENV_FILE"
  FAKE_MIHOMO_RC=1 FAKE_UI_RC=1
  export FAKE_MIHOMO_RC FAKE_UI_RC
  unset FAKE_MIHOMO_RUNNING FAKE_UI_RUNNING FAKE_MIHOMO_STATE FAKE_NETWORK_RC \
        FAKE_NET_SPEC FAKE_CF_RC FAKE_CF_RUNNING FAKE_CF_HEALTH \
        SMG_SCHED_TASK_DIR SMG_SCHED_EVENT_DB SMG_SCHED_CRONTAB
else
  echo "SKIP: doctor full-parity runs container-only (needs /dev/net/tun + PATH stubs; adjudicate in docker - docs/development.md)" >&2
  if [ ! -c /dev/net/tun ]; then
    # the missing-device direction is still a real parity case out here:
    dpar
    jval tun_device missing && jval mihomo unknown && [ "$_jrc" = 3 ] && [ "$_hrc" = 3 ] \
      && grep -q 'host /dev/net/tun is missing' "$TMP/derr" \
      && ok || fail "tun_device missing-direction parity (json=$_jrc human=$_hrc)"
  fi
fi

# --- hermetic env -i smoke: no harness exports reach the scripts under test ------
# The LOCK_DIR incident survived CI because the harness exported the very
# variable whose shipped default was missing (env-bleed). These subprocess
# runs strip the environment to PATH plus STUB SEAMS ONLY (CALLS/FAKE_*/SMG_*
# configure the fakes, never the production scripts) over a COPIED tree whose
# default data-dir path lands inside $TMP - so any production variable that is
# consumed before load_env, or that lacks a source-time default, fails loudly
# here instead of riding a harness export. deploy --yes is included on
# purpose: --dry-run skips acquire_lock, which is how the original incident
# stayed invisible; the run therefore exercises the REAL default lock path
# under /tmp (created and released within the run; a crashed run leaves a
# stale lock the next run reclaims by design).
# The tree copies under a directory NAMED like the real release checkout so
# compose_project_name's basename fallback matches the stub docker's project
# label (env -i strips the COMPOSE_PROJECT_NAME the outer suite exports).
HERM="$TMP/hermetic/syno-mihomo-gateway"; mkdir -p "$HERM"
cp -R "$ROOT/scripts" "$HERM/scripts"
cp -R "$ROOT/config" "$HERM/config"
# a dev tree may hold REAL gitignored runtime files under config/ - never let
# them ride into the sandbox (the fixture seeds its own subscription).
rm -f "$HERM/config/subscription.txt" "$HERM/config/config.yaml"
cp "$ROOT/docker-compose.yml" "$HERM/docker-compose.yml" 2>/dev/null || :
HDATA="$TMP/hermetic/syno-mihomo-gateway-data"   # the copied tree's DEFAULT data-dir path
mkdir -p "$HDATA/config" "$HDATA/logs"
cat > "$HDATA/.env" <<EOF
# CONTROLLER_PORT and LOCK_DIR are deliberately ABSENT: the hermetic runs must
# exercise the shipped source-time defaults on the dotenv_load-only paths.
REGISTRY_MODE=docker
MIHOMO_IMAGE=docker.io/metacubex/mihomo:latest
METACUBEXD_IMAGE=ghcr.io/metacubex/metacubexd:latest
UPDATE_IMAGES="docker.io/metacubex/mihomo:latest ghcr.io/metacubex/metacubexd:latest"
PARENT_INTERFACE=eth0
ROUTER_IP=192.168.1.1
SUBNET_CIDR=192.168.1.0/24
MIHOMO_IP=192.168.1.100
WEB_UI_PORT=8080
DNS_DEFAULT_NAMESERVER=1.1.1.1
DNS_NAMESERVER=1.1.1.1
DNS_FALLBACK=1.1.1.1
EXPECTED_ARCH=$HOST_ARCH
TUN_ENABLE=false
TUN_AUTO_REDIRECT=false
HEALTH_RETRIES=2
HEALTH_INTERVAL=0
PULL_RETRIES=1
PULL_RETRY_DELAY=0
EOF
printf '%s\n' 'https://sub.example/token' > "$HDATA/config/subscription.txt"
printf 'fixture' > "$HDATA/config/GeoSite.dat"
printf 'fixture' > "$HDATA/config/geoip.metadb"
# deploy's ensure_tun_device mknods /dev/net/tun - host state outside this
# smoke's scope (and root-only on dev machines; a REAL device node in the CI
# container otherwise). Stub mknod, and chmod ONLY for that path so every
# other chmod in the run stays real.
cat > "$STUB/mknod" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$STUB/chmod" <<'EOF'
#!/bin/sh
case "$*" in *"/dev/net/tun"*) exit 0 ;; esac
exec /bin/chmod "$@"
EOF
chmod +x "$STUB/mknod" "$STUB/chmod"
HGW="$HERM/scripts/gateway.sh"
HCALLS="$TMP/herm.calls"
# FAKE_IMG_ARCH rides along because the stub docker's arch answer defaults to
# $HOST_ARCH, which env -i strips (stub seams are allowed through; production
# variables are not).
henv() { env -i PATH="$STUB:/usr/bin:/bin" CALLS="$HCALLS" SMG_RESOLV_CONF="$TMP/resolv.conf" FAKE_IMG_ARCH="$HOST_ARCH" "$@"; }

: > "$HCALLS"
_rc=0; henv sh "$HGW" --help </dev/null >"$TMP/out" 2>"$TMP/err" || _rc=$?
[ "$_rc" = 0 ] && ok || fail "hermetic --help exited $_rc (stderr: $(tail -n2 "$TMP/err" | tr '\n' ' '))"

_rc=0; henv sh "$HGW" status --json </dev/null >"$TMP/out" 2>"$TMP/err" || _rc=$?
[ "$_rc" = 0 ] && ok || fail "hermetic status --json exited $_rc (stderr: $(tail -n2 "$TMP/err" | tr '\n' ' '))"
_lines="$(wc -l < "$TMP/out" | tr -d ' ')"
[ "$_lines" = 1 ] && ok || fail "hermetic status --json stdout is not exactly one line ($_lines)"
grep -q '"stack_state":"fresh"' "$TMP/out" || fail "hermetic status --json lacks stack_state"

_rc=0; henv sh "$HGW" doctor --json </dev/null >"$TMP/out" 2>"$TMP/err" || _rc=$?
case "$_rc" in 0|2|3) ok ;; *) fail "hermetic doctor --json exited $_rc (want 0/2/3; stderr: $(tail -n2 "$TMP/err" | tr '\n' ' '))" ;; esac
_lines="$(wc -l < "$TMP/out" | tr -d ' ')"
[ "$_lines" = 1 ] && ok || fail "hermetic doctor --json stdout is not exactly one line ($_lines)"
grep -q '"name":"env","value":"ok"' "$TMP/out" || fail "hermetic doctor --json did not load the .env (env check not ok)"
grep -q '"name":"docker","value":"ok"' "$TMP/out" || fail "hermetic doctor --json docker check not ok (stub docker unreachable?)"

: > "$HCALLS"
_rc=0; henv FAKE_MIHOMO_RUNNING=true FAKE_UI_RUNNING=true sh "$HGW" deploy --yes </dev/null >"$TMP/out" 2>"$TMP/err" || _rc=$?
[ "$_rc" = 0 ] && ok || fail "hermetic deploy --yes exited $_rc - a production variable may lack its source-time default (last output: $(tail -n3 "$TMP/out" "$TMP/err" 2>/dev/null | grep -v '^==>' | tail -n3 | tr '\n' ' '))"
grep -q 'up -d' "$HCALLS" && ok || fail "hermetic deploy --yes never reached compose up"
if grep -q 'could not acquire lock at *$' "$TMP/err"; then
  fail "hermetic deploy hit the empty-LOCK_DIR lock failure"
else ok; fi

# --- cron: persists schedule settings without touching any crontab ---------------
expect_rc 0 gw cron --time 03:30 --tz UTC --enable
_sched="$(PATH="$STUB:$PATH" sh -c ". '$ROOT/scripts/lib/common.sh'; dotenv_get UPDATE_SCHEDULE" 2>/dev/null)" || _sched=''
[ "$_sched" = '30 3 * * *' ] || fail "cron --time 03:30 persisted '$_sched' (want '30 3 * * *')"
_tz="$(PATH="$STUB:$PATH" sh -c ". '$ROOT/scripts/lib/common.sh'; dotenv_get UPDATE_TZ" 2>/dev/null)" || _tz=''
[ "$_tz" = 'UTC' ] || fail "cron --tz UTC persisted '$_tz'"
expect_rc 3 gw cron --time 27:99

# --- cron --apply-crontab: honors CRONTAB_FILE, needs --yes + root ----------------
CRON_FILE="$TMP/crontab"; printf '# fake dsm crontab\n' > "$CRON_FILE"
export CRONTAB_FILE="$CRON_FILE"
expect_rc 0 gw cron --apply-crontab --yes
grep -q 'auto_update.sh' "$CRON_FILE" || fail "cron --apply-crontab did not write the schedule line"
expect_rc 6 gwu cron --apply-crontab --yes
unset CRONTAB_FILE

# --- update: execs auto_update.sh with pass-through args -------------------------
_rc=0; FAKE_UID=0 PATH="$STUB:$PATH" sh "$GW" update --yes --definitely-bogus </dev/null >"$TMP/out" 2>"$TMP/err" || _rc=$?
[ "$_rc" = 3 ] || fail "update pass-through did not surface auto_update's EXIT_CONFIG (got $_rc)"
grep -q 'unknown argument' "$TMP/err" || fail "update did not reach auto_update.sh arg parsing"

# --- update: target management (read-only vs mutating) ---------------------------
expect_rc 0 gwu update --list-targets
grep -q 'no generic targets enrolled' "$TMP/out" || fail "empty --list-targets message missing"
expect_rc 0 gwu update --last
grep -q 'no updater run recorded' "$TMP/out" || fail "empty --last message missing"
expect_rc 7 gw update --enable web1
expect_rc 6 gwu update --enable web1 --yes
expect_rc 0 gw update --enable web1 --yes
grep -q '^web1|recreate|$' "$DATA/state/update-targets" || fail "--enable did not write the managed list"
expect_rc 0 gwu update --list-targets
grep -q 'web1' "$TMP/out" || fail "--list-targets does not show the enrolled target"
expect_rc 3 gw update --enable mihomo --yes
expect_rc 0 gw update --disable web1 --yes
if grep -q '^web1|' "$DATA/state/update-targets"; then fail "--disable left the record behind"; else ok; fi

# --dry-run exempts the --yes/root gates, so it must be rejected on the
# target-management modes instead of silently riding that exemption.
expect_rc 3 gwu update --enable web1 --dry-run
if grep -q '^web1|' "$DATA/state/update-targets" 2>/dev/null; then
  fail "--dry-run --enable mutated the managed list"
else ok; fi
expect_rc 3 gwu update --list-targets --dry-run
expect_rc 3 gw update --yes --enable
grep -q 'requires a container name' "$TMP/out" "$TMP/err" || fail "--enable with no value lacks the actionable error"

# --- update --last + status surface the last-run record --------------------------
mkdir -p "$DATA/state"
printf '%s\n' '{"ts":"t","exit_code":0,"dry_run":0,"updated":1,"unchanged":2,"failed":0,"rolled_back":0}' > "$DATA/state/last-run.json"
expect_rc 0 gwu update --last
grep -q '"updated":1' "$TMP/out" || fail "--last does not show the recorded run"
_rc=0; FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" status --json </dev/null >"$TMP/out" 2>/dev/null || _rc=$?
grep -q '"last_update":{"ts":"t"' "$TMP/out" || fail "status --json lacks the last_update object"
rm -f "$DATA/state/last-run.json"
_rc=0; FAKE_UID=1000 PATH="$STUB:$PATH" sh "$GW" status --json </dev/null >"$TMP/out" 2>/dev/null || _rc=$?
grep -q '"last_update":null' "$TMP/out" || fail "status --json lacks the null last_update before any run"

# --- sourced-mode: fail-before-mutation deployment order -------------------------
(
  set -eu
  ORDER="$TMP/order"
  GATEWAY_SOURCE_ONLY=1
  GATEWAY_SELF_DIR="$ROOT/scripts"
  export GATEWAY_SOURCE_ONLY GATEWAY_SELF_DIR
  PATH="$STUB:$PATH"
  # shellcheck source=scripts/gateway.sh
  . "$GW"

  _gw_load_config() { return 0; }
  _gw_preflight() { echo preflight >> "$ORDER"; }
  _gw_plan_cleanup() { echo plan >> "$ORDER"; }
  _gw_prepare() { echo prepare >> "$ORDER"; }
  _gw_apply_cleanup() { echo cleanup >> "$ORDER"; }
  _gw_create_network() { echo network >> "$ORDER"; }
  _gw_deploy_stack() { echo deploy >> "$ORDER"; }
  _gw_report() { :; }
  GW_YES=1; GW_DRY_RUN=0

  : > "$ORDER"
  gateway_deploy >/dev/null 2>&1 || { echo "FAIL: stubbed gateway_deploy failed" >&2; exit 1; }
  [ "$(tr '\n' ' ' < "$ORDER")" = 'preflight plan prepare cleanup network deploy ' ] \
    || { echo "FAIL: unsafe deploy order: $(tr '\n' ' ' < "$ORDER")" >&2; exit 1; }

  _gw_prepare() { echo prepare >> "$ORDER"; return 1; }
  : > "$ORDER"
  gateway_deploy >/dev/null 2>&1 && { echo "FAIL: deploy continued after preparation failure" >&2; exit 1; }
  case "$(tr '\n' ' ' < "$ORDER")" in
    *cleanup*|*network*|*deploy*) echo "FAIL: deploy mutated state before preparation succeeded" >&2; exit 1 ;;
  esac
  exit 0
) || fail "sourced-mode deploy-order block failed"

echo "gateway CLI: $pass checks passed, $failn failed"
[ "$failn" -eq 0 ] || exit 1
echo "OK: gateway.sh CLI contract (usage/exit codes, --yes + root gates, argv secret rejection, --json purity, unified log, cron/update wiring, fail-before-mutation order)"
