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
  info|login|pull|tag|logs|rm) exit 0 ;;
  compose)
    shift
    case "$*" in
      version) exit 0 ;;
      *'up --help'*) printf -- '--pull never\n'; exit 0 ;;
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
      *ip_forward*) echo 1 ;;
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
      *'{{.State.Running}}'*mihomo-ui*) echo "${FAKE_UI_RUNNING:-false}"; exit 0 ;;
      *'{{.State.Running}}'*) echo "${FAKE_MIHOMO_RUNNING:-false}"; exit 0 ;;
      *'{{.RestartCount}}'*) echo 0; exit 0 ;;
      *'{{.Image}}'*) echo sha256:fakerunning; exit 0 ;;
      *compose.service*mihomo-ui*) echo metacubexd; exit 0 ;;
      *compose.service*) echo mihomo; exit 0 ;;
      *compose.project*) echo "${FAKE_COMPOSE_PROJECT:-syno-mihomo-gateway}"; exit 0 ;;
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

DATA="$TMP/data"
mkdir -p "$DATA/config" "$DATA/logs"
export GATEWAY_DATA_DIR="$DATA"
export ENV_FILE="$DATA/.env"
export LOCK_DIR="$TMP/gw.lock"

# LOCK_DIR must default at SOURCE time, not only inside load_env: gateway.sh
# takes the deploy/redeploy/modify lock before load_env runs, so a box that
# does not export LOCK_DIR (every real NAS) otherwise dies on mkdir '' -
# the redeploy-on-NAS regression. This suite exports LOCK_DIR above for
# hermeticity, which is exactly why the bug needs its own assertion.
( unset LOCK_DIR; . "$ROOT/scripts/lib/common.sh"; [ -n "${LOCK_DIR:-}" ] ) \
  && ok || fail "common.sh does not default LOCK_DIR at source time (headless redeploy lock breaks)"
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
