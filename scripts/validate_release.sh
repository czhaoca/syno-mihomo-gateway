#!/bin/sh
# validate_release.sh - on-NAS release validation for a staged bundle.
# Proves, on the real network, what CI can only prove structurally:
#   A. the staged bundle deploys and doctor is healthy;
#   B. an UNCHANGED pre-split-horizon .env still renders the legacy config
#      (upgrade compatibility), then split-horizon is enabled from the
#      shipped .env.example defaults and renders the policy;
#   C. COLD START: with the node cache and provider cache parked and every
#      tunnel-dependent resolver black-holed, nodes still come up - the
#      2026-07 chicken-and-egg, disproven on the wire;
#   D. the DNS_GEOIP_NO_RESOLVE flip renders, routes, and reverts.
#
# Run on the NAS, in a real terminal (sudo needs a TTY):
#   sudo sh /volume1/docker/smg-staging/validate_release.sh
# Flags:
#   --self-test   run the unprivileged unit checks of the measurement
#                 helpers and exit (used by CI; needs no docker/root)
#   --skip-knob   skip block D (the DNS_GEOIP_NO_RESOLVE spot-check)
#   --no-extract  validate the installed tree as-is (skip A0/A1)
#   --keep        keep split-horizon enabled in .env at the end
#   --revert      restore the original .env at the end
#                 (neither flag -> asked on the TTY; default is revert)
# Env overrides: SMG_STAGE, SMG_RELEASE_DIR.
#
# Controller/routing probes run INSIDE the mihomo container (docker exec):
# on this NAS a macvlan child is reachable from LAN peers but NOT from the
# host itself, so host-side curls measure nothing (learned the hard way).
# .env values are read via the repo's dotenv parser, which handles quoted
# values - never with a bare cut(1). Children (gateway.sh, doctor.sh, docker
# compose) run with a SCRUBBED environment: this shell exports REPO_ROOT and
# every .env key (lib sourcing + load_env), an inherited REPO_ROOT breaks the
# childrens' lib locators, and docker compose lets process env override
# --env-file - both bit validation run 2.
set -u

STAGE="${SMG_STAGE:-/volume1/docker/smg-staging}"
REL="${SMG_RELEASE_DIR:-/volume1/docker/syno-mihomo-gateway}"
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LOG="$STAGE/validate-results.log"
BLACKHOLE="https://192.0.2.1/dns-query#PROXY"  # RFC 5737 TEST-NET-1: never routes

SELF_TEST=0; SKIP_KNOB=0; NO_EXTRACT=0; FINAL=""
for _a in "$@"; do
  case "$_a" in
    --self-test) SELF_TEST=1 ;;
    --skip-knob) SKIP_KNOB=1 ;;
    --no-extract) NO_EXTRACT=1 ;;
    --keep) FINAL=keep ;;
    --revert) FINAL=revert ;;
    *) echo "unknown flag: $_a" >&2; exit 3 ;;
  esac
done

# ---- measurement helpers (pure; unit-checked by --self-test) ----------------

# rendered_policy_on FILE - the split-horizon block is actually rendered.
# Anchored to the real YAML lines, never to comment prose.
rendered_policy_on() {
  grep -q '^  nameserver-policy:' "$1" \
    && grep -q "^    'geosite:cn':" "$1" \
    && grep -q "^    'geosite:geolocation-!cn':" "$1"
}

# rendered_knob_on FILE - the GEOIP rule carries no-resolve. The template's
# comments mention "no-resolve" as prose, so the grep must anchor on the
# exact rendered rule line (the false positive that bit validation v1).
rendered_knob_on()  { grep -q "^  - 'GEOIP,CN,DIRECT,no-resolve'$" "$1"; }
rendered_knob_off() { grep -q "^  - 'GEOIP,CN,DIRECT'$" "$1"; }

# rendered_psn_untunneled FILE - proxy-server-nameserver carries no #group
# fragment (the cold-start invariant).
rendered_psn_untunneled() {
  grep '^  proxy-server-nameserver:' "$1" | grep -vq '#'
}

# alive_count - count alive nodes from /proxies JSON on stdin.
alive_count() { grep -o '"alive":true' | wc -l | tr -d ' '; }

# example_dns KEY - read a shipped default from the release .env.example
# (the committed script itself must not hardcode DNS servers - CLAUDE.md).
example_dns() { grep "^$1=" "$REL/.env.example" | head -n1 | cut -d= -f2-; }

# run_scrubbed CMD... - run a child with a clean environment (PATH/HOME only),
# so nothing this shell sourced or load_env exported can leak into it.
run_scrubbed() { env -i PATH="$PATH" HOME="${HOME:-/tmp}" "$@"; }

# doctor_rc_ok RC - doctor's contract is 0 healthy | 2 degraded | 3 broken;
# anything else (e.g. 1 = the script itself crashed while sourcing) must
# FAIL, never pass (run 2's lax "!= 3" gate accepted a crash as a pass).
doctor_rc_ok() { case "$1" in 0|2) return 0 ;; *) return 1 ;; esac; }

# ---- self-test (CI: unprivileged, no docker) ---------------------------------

self_test() {
  _stp=0; _stf=0
  st_ok()  { _stp=$((_stp+1)); }
  st_bad() { echo "SELF-TEST FAIL: $*" >&2; _stf=$((_stf+1)); }
  # Locate a tree that carries the libs + .env.example: the checkout when the
  # script runs from <repo>/scripts/, else the installed release dir (the
  # staging copy on the NAS has neither next to it).
  if [ -f "$SELF_DIR/lib/common.sh" ]; then
    ROOT="$(CDPATH='' cd -- "$SELF_DIR/.." && pwd)"
  elif [ -f "$REL/scripts/lib/common.sh" ]; then
    ROOT="$REL"
  else
    echo "SELF-TEST FAIL: no release tree found (need scripts/lib/common.sh in $SELF_DIR/.. or $REL)" >&2
    exit 1
  fi
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

  # 1) the shipped .env.example carries every key this script reads from it
  REL="$ROOT"
  for _k in DNS_NAMESERVER DNS_FALLBACK DNS_CN_NAMESERVER \
            DNS_FOREIGN_NAMESERVER DNS_GEOIP_NO_RESOLVE; do
    if [ -n "$(example_dns "$_k")" ]; then st_ok; else st_bad ".env.example lacks $_k"; fi
  done

  # 2) rule greps must not be fooled by template comment prose (v1 bug):
  #    a legacy render carries the no-resolve COMMENT but the bare rule.
  cat > "$TMP/legacy.yaml" <<'EOF'
dns:
  nameserver: [ 192.0.2.53 ]
  proxy-server-nameserver: [ 192.0.2.53 ]
rules:
  # Setting DNS_GEOIP_NO_RESOLVE=true in .env renders a `,no-resolve` suffix
  - 'GEOSITE,CN,DIRECT'
  - 'GEOIP,CN,DIRECT'
  - 'MATCH,PROXY'
EOF
  if rendered_knob_on "$TMP/legacy.yaml"; then st_bad "knob_on fooled by comment prose"; else st_ok; fi
  if rendered_knob_off "$TMP/legacy.yaml"; then st_ok; else st_bad "knob_off missed the bare rule"; fi
  if rendered_policy_on "$TMP/legacy.yaml"; then st_bad "policy_on false positive"; else st_ok; fi
  if rendered_psn_untunneled "$TMP/legacy.yaml"; then st_ok; else st_bad "psn check false negative"; fi
  cat > "$TMP/policy.yaml" <<'EOF'
dns:
  nameserver-policy:
    'geosite:cn': [ https://192.0.2.53/dns-query ]
    'geosite:geolocation-!cn': [ https://192.0.2.54/dns-query#PROXY ]
  proxy-server-nameserver: [ https://192.0.2.53/dns-query#PROXY ]
rules:
  - 'GEOIP,CN,DIRECT,no-resolve'
EOF
  if rendered_policy_on "$TMP/policy.yaml"; then st_ok; else st_bad "policy_on missed a real policy"; fi
  if rendered_knob_on "$TMP/policy.yaml"; then st_ok; else st_bad "knob_on missed the real rule"; fi
  if rendered_psn_untunneled "$TMP/policy.yaml"; then st_bad "psn check missed a #PROXY fragment"; else st_ok; fi

  # 3) alive-count parser
  _n=$(printf '{"proxies":{"a":{"alive":true},"b":{"alive":false},"c":{"alive":true}}}' | alive_count)
  if [ "$_n" = 2 ]; then st_ok; else st_bad "alive_count got $_n, want 2"; fi

  # 4) .env values are parsed via the repo dotenv parser, which strips quotes
  #    (v1 read them raw and built literal-quote URLs).
  printf 'MIHOMO_IP="192.0.2.10"\nCONTROLLER_PORT=9090\n' > "$TMP/env"
  # shellcheck disable=SC2030 # subshell isolation is the point
  ( NO_LOG_INIT=1; export NO_LOG_INIT
    ENV_FILE="$TMP/env"; export ENV_FILE
    . "$ROOT/scripts/lib/common.sh"
    dotenv_load "$TMP/env" || exit 1
    [ "$MIHOMO_IP" = "192.0.2.10" ] || exit 1
    [ "$CONTROLLER_PORT" = "9090" ] || exit 1 )
  # shellcheck disable=SC2181 # the subshell above is the tested unit
  if [ $? -eq 0 ]; then st_ok; else st_bad "dotenv parser did not strip quotes"; fi

  # 5) children get a scrubbed environment (the run-2 env-bleed class:
  #    exported .env keys override compose --env-file; an exported REPO_ROOT
  #    breaks the child lib locators)
  # shellcheck disable=SC2016 # the expansion must happen in the CHILD shell
  _out=$(FOO_BLEED=bad run_scrubbed sh -c 'echo "${FOO_BLEED:-CLEAN}"')
  if [ "$_out" = CLEAN ]; then st_ok; else st_bad "run_scrubbed leaked env: $_out"; fi

  # 6) doctor rc gate: only the documented 0|2 pass; crash rc must fail
  for _rc in 0 2; do
    if doctor_rc_ok "$_rc"; then st_ok; else st_bad "doctor_rc_ok rejected rc $_rc"; fi
  done
  for _rc in 1 3; do
    if doctor_rc_ok "$_rc"; then st_bad "doctor_rc_ok accepted rc $_rc"; else st_ok; fi
  done

  echo "validate_release self-test: $_stp passed, $_stf failed"
  [ "$_stf" -eq 0 ] || exit 1
  echo "OK: measurement helpers (policy/knob/psn rule anchoring, alive-count, quoted-.env parsing, .env.example key coverage, scrubbed child env, doctor rc gate)"
  exit 0
}
[ "$SELF_TEST" = 1 ] && self_test

# ---- privileged validation ---------------------------------------------------

[ "$(id -u)" = 0 ] || { echo "run with sudo (real TTY)"; exit 6; }

main() {

PASS=""; FAIL=""
ok()  { echo "PASS: $*"; PASS="$PASS|$*"; }
bad() { echo "FAIL: $*"; FAIL="$FAIL|$*"; }
say() { echo; echo "=== $* ==="; }

say "A0: staged bundle"
TARBALL=$(find "$STAGE" -maxdepth 1 -name 'syno-mihomo-gateway-*.tar.gz' 2>/dev/null | sort | tail -n1)
if [ "$NO_EXTRACT" = 1 ] || [ -z "$TARBALL" ]; then
  echo "no extract (flag or no staged bundle) - validating the installed tree"
else
  ( cd "$STAGE" && sha256sum -c "$TARBALL.sha256" ) || { bad "bundle checksum"; exit 3; }
  ok "bundle checksum ($(basename "$TARBALL"))"
  say "A1: extract candidate over release dir"
  ( cd "$REL" && tar xzf "$TARBALL" --strip-components=1 ) || { bad "extract"; exit 3; }
  ok "extracted (VERSION now: $(cat "$REL/VERSION"))"
fi

# From here on, use the CANDIDATE tree's own libs: the code being validated
# is also the code doing the measuring.
NO_LOG_INIT=1; export NO_LOG_INIT
# shellcheck source=scripts/lib/common.sh
. "$REL/scripts/lib/common.sh"
# shellcheck source=scripts/lib/registry.sh
. "$REL/scripts/lib/registry.sh"
# shellcheck source=scripts/lib/compose.sh
. "$REL/scripts/lib/compose.sh"
load_env || { bad "load_env failed"; exit 3; }
detect_compose >/dev/null 2>&1 || { bad "docker/compose not detected"; exit 3; }
CFG="$GATEWAY_DATA_DIR/config/config.yaml"
ORIG="$ENV_FILE.v138orig"

# env_set KEY VALUE - replace-or-append in the live .env, preserving the file
# inode/mode (600) by writing through cat. The value is escaped for the sed
# replacement side (\ & |) like render_config.sh's esc(), so a future
# .env.example default containing & or | cannot mangle the write.
env_set() {
  _es_v=$(printf '%s' "$2" | sed -e 's/\\/\\\\/g' -e 's/&/\\\&/g' -e 's/|/\\|/g')
  if grep -q "^$1=" "$ENV_FILE"; then
    sed "s|^$1=.*|$1=$_es_v|" "$ENV_FILE" > "$ENV_FILE.tmp"
  else
    cat "$ENV_FILE" > "$ENV_FILE.tmp"; printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE.tmp"
  fi
  cat "$ENV_FILE.tmp" > "$ENV_FILE" && rm -f "$ENV_FILE.tmp"
}

recreate() {
  ( cd "$REL" && run_scrubbed "$DOCKER_BIN" compose --env-file "$ENV_FILE" up -d --force-recreate "$MIHOMO_CONTAINER" ) || return 1
  sleep 20
}

# ctl_get PATH - controller API from INSIDE the container (macvlan host
# isolation); bearer token over stdin, never argv (repo rule).
ctl_get() {
  _url="http://127.0.0.1:${CONTROLLER_PORT:-9090}$1"
  if [ -n "${CONTROLLER_SECRET:-}" ]; then
    # shellcheck disable=SC2016 # $SMG_AUTH expands in the container shell
    printf 'Authorization: Bearer %s\n' "$CONTROLLER_SECRET" | \
      "$DOCKER_BIN" exec -i "$MIHOMO_CONTAINER" \
      sh -c 'IFS= read -r SMG_AUTH; exec wget -q -T 10 -O - --header "$SMG_AUTH" "$1"' _ "$_url" 2>/dev/null
  else
    "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 10 -O - "$_url" 2>/dev/null
  fi
}

# delay_probe GROUP URL - ask mihomo ITSELF to fetch URL through GROUP via
# the controller delay endpoint (authoritative: the request traverses the
# real egress path). Retried: nodes may still be health-checking right after
# a recreate. (Run 2's http_proxy-wget probes were unreliable - busybox wget
# ignored the proxy, so baidu "passed" direct and gstatic failed direct.)
delay_probe() {
  _dp_i=0
  while [ "$_dp_i" -lt 3 ]; do
    case "$(ctl_get "/proxies/$1/delay?timeout=5000&url=$2")" in
      *'"delay"'*) return 0 ;;
    esac
    _dp_i=$((_dp_i+1)); sleep 10
  done
  return 1
}

restore_env() {  # put the pre-validation .env back
  [ -f "$ORIG" ] && cat "$ORIG" > "$ENV_FILE" && rm -f "$ORIG"
}
# shellcheck disable=SC2329 # invoked via the trap below
on_abort() { echo "INTERRUPTED - restoring original .env"; restore_env; recreate; exit 1; }
trap on_abort INT TERM

say "A2: redeploy + baseline doctor"
run_scrubbed sh "$REL/scripts/gateway.sh" redeploy --yes; RC=$?
if [ "$RC" = 0 ]; then ok "redeploy rc 0"; else bad "redeploy rc $RC"; fi
run_scrubbed sh "$REL/scripts/doctor.sh"; RC=$?
if doctor_rc_ok "$RC"; then ok "baseline doctor rc $RC (0 healthy | 2 degraded)"; else bad "baseline doctor rc $RC (crash or broken)"; fi

say "A2.5: measurement preflight (controller reachable from inside the container)"
if mihomo_controller_probe >/dev/null 2>&1; then
  ok "controller probe (docker exec)"
else
  bad "controller probe failed - every later count would be meaningless; aborting"
  exit 3
fi

say "A3: upgrade compatibility - the UNCHANGED .env must render the legacy config"
if rendered_policy_on "$CFG"; then
  echo "note: nameserver-policy already rendered (this .env already opted in)"
else
  ok "pre-split-horizon .env renders WITHOUT nameserver-policy (byte-compat path)"
fi
if rendered_knob_off "$CFG"; then ok "GEOIP rule bare (knob off/unset)"; else bad "bare GEOIP rule missing"; fi

say "A4: enable split-horizon from the shipped .env.example defaults"
cp -p "$ENV_FILE" "$ORIG"
for _k in DNS_NAMESERVER DNS_FALLBACK DNS_CN_NAMESERVER DNS_FOREIGN_NAMESERVER; do
  _v="$(example_dns "$_k")"
  [ -n "$_v" ] || { bad "no $_k in $REL/.env.example"; exit 3; }
  env_set "$_k" "$_v"
done
env_set DNS_GEOIP_NO_RESOLVE false
recreate || bad "compose recreate (enable split-horizon)"
load_env || true
if rendered_policy_on "$CFG"; then ok "nameserver-policy rendered"; else bad "nameserver-policy did NOT render"; fi
if rendered_psn_untunneled "$CFG"; then ok "proxy-server-nameserver untunneled (cold-start invariant)"; else bad "proxy-server-nameserver carries a #fragment"; fi

say "B: cold start - parked caches + black-holed tunnel resolvers"
CACHES=""
if [ -f "$GATEWAY_DATA_DIR/config/cache.db" ]; then
  mv "$GATEWAY_DATA_DIR/config/cache.db" "$GATEWAY_DATA_DIR/config/cache.db.v138park" \
    && CACHES="$CACHES cache.db"
fi
if [ -d "$GATEWAY_DATA_DIR/config/proxies" ]; then
  mv "$GATEWAY_DATA_DIR/config/proxies" "$GATEWAY_DATA_DIR/config/proxies.v138park"
  CACHES="$CACHES $GATEWAY_DATA_DIR/config/proxies"
fi
echo "parked:${CACHES:- (nothing cached)}"
env_set DNS_FALLBACK "$BLACKHOLE"
env_set DNS_FOREIGN_NAMESERVER "$BLACKHOLE"
recreate || bad "compose recreate (cold)"
load_env || true
N=0
for _i in 1 2 3 4 5 6; do
  sleep 15
  N=$(ctl_get /proxies | alive_count); N=${N:-0}
  echo "  t+$((_i*15))s alive nodes: $N"
  [ "$N" -gt 0 ] && break
done
if delay_probe PROXY "http://www.gstatic.com/generate_204"; then EGRESS=1; else EGRESS=0; fi
if [ "$N" -gt 0 ] || [ "$EGRESS" = 1 ]; then
  ok "COLD START: alive=$N egress_delay_probe=$EGRESS with no caches + dead tunnel resolvers"
else
  bad "COLD START: no alive node and no egress after 90s"
  "$DOCKER_BIN" logs "$MIHOMO_CONTAINER" 2>&1 | tail -40 | sed 's/^/    /'
fi
if [ "$N" -gt 0 ] || [ "$EGRESS" = 1 ]; then
  # cold start passed: the freshly built caches are the good ones now
  rm -f "$GATEWAY_DATA_DIR/config/cache.db.v138park"
  rm -rf "$GATEWAY_DATA_DIR/config/proxies.v138park"
else
  # cold start FAILED: put the known-good caches back so the restored
  # config comes up warm instead of forcing a second cold rebuild
  if [ -f "$GATEWAY_DATA_DIR/config/cache.db.v138park" ]; then
    rm -f "$GATEWAY_DATA_DIR/config/cache.db"
    mv "$GATEWAY_DATA_DIR/config/cache.db.v138park" "$GATEWAY_DATA_DIR/config/cache.db"
  fi
  if [ -d "$GATEWAY_DATA_DIR/config/proxies.v138park" ]; then
    rm -rf "$GATEWAY_DATA_DIR/config/proxies"
    mv "$GATEWAY_DATA_DIR/config/proxies.v138park" "$GATEWAY_DATA_DIR/config/proxies"
  fi
fi

say "B2: real tunnel resolvers back + doctor --egress"
env_set DNS_FALLBACK "$(example_dns DNS_FALLBACK)"
env_set DNS_FOREIGN_NAMESERVER "$(example_dns DNS_FOREIGN_NAMESERVER)"
recreate || bad "compose recreate (restore resolvers)"
load_env || true
run_scrubbed sh "$REL/scripts/doctor.sh" --egress; RC=$?
if doctor_rc_ok "$RC"; then ok "doctor --egress rc $RC (0 healthy | 2 degraded-optional)"
else bad "doctor --egress rc $RC (crash or broken)"; fi

if [ "$SKIP_KNOB" = 0 ]; then
  say "C: DNS_GEOIP_NO_RESOLVE flip (renders, routes, reverts)"
  env_set DNS_GEOIP_NO_RESOLVE true
  recreate || bad "compose recreate (knob on)"
  if rendered_knob_on "$CFG"; then ok "no-resolve rendered onto the GEOIP rule"; else bad "no-resolve did not render"; fi
  # automated egress probes: mihomo itself fetches through each path via the
  # controller delay endpoint (the same mechanism doctor --egress trusts)
  if delay_probe DIRECT "http://www.baidu.com"; then
    ok "CN egress via DIRECT (mihomo-fetched baidu)"
  else
    bad "CN egress via DIRECT failed (baidu delay probe)"
  fi
  if delay_probe PROXY "http://www.gstatic.com/generate_204"; then
    ok "foreign egress via PROXY (mihomo-fetched gstatic 204 through the node)"
  else
    bad "foreign egress via PROXY failed (gstatic delay probe)"
  fi
  echo
  echo ">>> LAN spot-check, from any device using the gateway - example sites:"
  echo ">>>  1) Mainstream CN, expect DIRECT and fast:  www.baidu.com   www.jd.com"
  echo ">>>  2) Foreign, expect via the node:           www.google.com  www.youtube.com"
  echo ">>>  3) Niche CN (the no-resolve trade-off): any SMALL local business/"
  echo ">>>     forum site (.com of a local shop) - it should STILL LOAD, maybe"
  echo ">>>     slower. The dashboard (Connections view) is the referee:"
  echo ">>>       GeoSite(CN) -> DIRECT       = site is on the China list (pick smaller)"
  echo ">>>       Match -> PROXY[<node>]      = unlisted, riding the proxy (expected)"
  printf ">>> Press Enter when checked (the knob auto-reverts) : "
  read -r _ans </dev/tty || true
  env_set DNS_GEOIP_NO_RESOLVE false
  recreate || bad "compose recreate (knob off)"
  if rendered_knob_off "$CFG"; then ok "knob reverted, rule bare again"; else bad "revert failed"; fi
else
  say "C: skipped (--skip-knob)"
fi

say "D: keep split-horizon in .env, or restore the original?"
case "$FINAL" in
  keep) KEEP=1 ;;
  revert) KEEP=0 ;;
  *)
    printf ">>> Keep split-horizon enabled (values from .env.example)? [y/N] : "
    read -r _k </dev/tty || _k=""
    case "$_k" in y|Y|yes) KEEP=1 ;; *) KEEP=0 ;; esac ;;
esac
if [ "$KEEP" = 1 ]; then
  rm -f "$ORIG"
  echo "keeping split-horizon (revert later by restoring your old DNS_* lines)"
else
  restore_env
  recreate || bad "compose recreate (final revert)"
  echo "original .env restored"
fi

say "final doctor"
run_scrubbed sh "$REL/scripts/doctor.sh"; RC=$?
if doctor_rc_ok "$RC"; then ok "final doctor rc $RC (0 healthy | 2 degraded)"; else bad "final doctor rc $RC (crash or broken)"; fi

say "SUMMARY"
echo "PASS:"; printf '%s' "$PASS" | tr '|' '\n' | sed '/^$/d;s/^/  + /'
echo "FAIL:"; printf '%s' "$FAIL" | tr '|' '\n' | sed '/^$/d;s/^/  - /'
echo
echo "log: $LOG"
if [ -z "$FAIL" ]; then
  echo "VALIDATION: ALL GREEN"; echo 0 > "$STAGE/.v138rc"
else
  echo "VALIDATION: HAS FAILURES"; echo 1 > "$STAGE/.v138rc"
fi
}

# portable transcript (no bash process substitution): pipe main to tee and
# recover the real exit code from the sidecar file.
rm -f "$LOG" "$STAGE/.v138rc"
main "$@" 2>&1 | tee "$LOG"
chmod 644 "$LOG" 2>/dev/null || true
RC=$(cat "$STAGE/.v138rc" 2>/dev/null || echo 1)
rm -f "$STAGE/.v138rc"
exit "$RC"
