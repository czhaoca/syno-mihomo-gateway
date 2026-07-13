#!/bin/sh
# validate_release.sh - on-NAS release validation for a staged bundle.
# Proves, on the real network, what CI can only prove structurally:
#   A. the staged bundle deploys and doctor is healthy (incl. the STREAMING
#      group + netflix rule of v1.3.10);
#   B. an UNCHANGED pre-split-horizon .env still renders the legacy config
#      (upgrade compatibility), then split-horizon is enabled from the
#      shipped .env.example defaults and renders the policy AND the v2
#      foreign-by-default core (no fallback dual-query);
#   C. COLD START: with the node cache and provider cache parked and every
#      tunnel-dependent resolver black-holed, nodes still come up - the
#      2026-07 chicken-and-egg, disproven on the wire - and long-tail DNS
#      FAILS CLOSED (never silently answered by a domestic resolver) while
#      the policy-pinned hosts keep resolving; then an owner LAN spot-check
#      (dnsleaktest extended + netflix via the STREAMING group);
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
# PROXY-group egress probes fire only after a group-wide url-test kick, and
# the parked caches are RESTORED after the cold-start block, never dropped:
# cache.db carries the dashboard-selected node, and the template's `auto`
# url-test group is lazy - with the selection wiped and zero LAN traffic
# after a recreate, every probe measures an untested default node that no
# real client would ride - both bit validation run 3.
# Node counts are PROVIDER members (never the global "alive" flags: built-ins
# like DIRECT/REJECT are always alive, and an EMPTY group degrades to the
# COMPATIBLE placeholder), and an egress PASS requires the effective member to
# be a real node (gstatic's generate_204 is served by Google's China edge, so
# a COMPATIBLE/DIRECT egress can fetch it without any node) - both masked the
# 2026-07-12 zero-node provider outage as a cold-start pass.
set -u

STAGE="${SMG_STAGE:-/volume1/docker/smg-staging}"
REL="${SMG_RELEASE_DIR:-/volume1/docker/syno-mihomo-gateway}"
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LOG="$STAGE/validate-results.log"
BLACKHOLE="https://192.0.2.1/dns-query#auto"  # RFC 5737 TEST-NET-1: never routes

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

# rendered_split_core_on FILE - the v2 foreign-by-default core is rendered:
# the DEFAULT nameserver rides a '#group' detour AND the fallback dual-query
# line is gone (long-tail hostnames can no longer reach a domestic resolver).
# Anchored to the real YAML lines: '^  nameserver:' cannot match
# 'nameserver-policy:' and '^  fallback:' cannot match 'fallback-filter:'
# (the colon anchors both), and comment prose never matches either.
rendered_split_core_on() {
  grep '^  nameserver:' "$1" | grep -q '#' \
    && ! grep -q '^  fallback:' "$1"
}
# rendered_split_core_off FILE - the legacy core: untunneled default
# nameserver AND the fallback dual-query still present.
rendered_split_core_off() {
  grep '^  nameserver:' "$1" | grep -vq '#' \
    && grep -q '^  fallback:' "$1"
}

# members_of - group JSON on stdin -> member names, one per line.
members_of() {
  sed -n 's/.*"all":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | sed -n 's/^"\(.*\)"$/\1/p'
}

# real_node_count - provider nodes in a group JSON on stdin, excluding the
# COMPATIBLE placeholder an EMPTY group degrades to. Never count the global
# /proxies "alive" flags: built-ins (DIRECT/REJECT/PASS/...) are always alive,
# which read the 2026-07-12 zero-node outage as "alive=9".
real_node_count() { members_of | grep -c -v '^COMPATIBLE$'; }

# effective_now - the "now" (selected member) from group JSON on stdin.
effective_now() { sed -n 's/.*"now":"\([^"]*\)".*/\1/p'; }

# now_is_real NAME - the member actually tunnels: not empty, not a built-in,
# not the empty-group placeholder (COMPATIBLE dials DIRECT, and gstatic's
# generate_204 is reachable direct from CN via Google's China edge).
now_is_real() {
  case "$1" in
    ''|COMPATIBLE|DIRECT|REJECT|REJECT-DROP|PASS) return 1 ;;
    *) return 0 ;;
  esac
}

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

# Result accumulation. The separator is the ASCII unit separator, which never
# appears in a message - run 3 used '|' and the summary split every doctor
# message ("rc 0 (0 healthy | 2 degraded)") across two lines.
US=$(printf '\037')
PASS=""; FAIL=""
ok()  { echo "PASS: $*"; PASS="$PASS$US$*"; }
bad() { echo "FAIL: $*"; FAIL="$FAIL$US$*"; }
say() { echo; echo "=== $* ==="; }

# unpark PATH - put PATH back from PATH.v138park (file or directory),
# replacing whatever the cold run rebuilt; no-op without a park. Run 3
# dropped the park on pass, which reset the PROXY selector to the group
# default and lost the owner's dashboard-selected node.
unpark() {
  [ -e "$1.v138park" ] || return 0
  rm -rf "$1"
  mv "$1.v138park" "$1"
}

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
            DNS_FOREIGN_NAMESERVER DNS_GEOIP_NO_RESOLVE SNIFFER_ENABLE \
            AUTO_EXCLUDE_FILTER; do
    if [ -n "$(example_dns "$_k")" ]; then st_ok; else st_bad ".env.example lacks $_k"; fi
  done

  # 2) rule greps must not be fooled by template comment prose (v1 bug):
  #    a legacy render carries the no-resolve COMMENT but the bare rule.
  cat > "$TMP/legacy.yaml" <<'EOF'
dns:
  # a v1.3.8 legacy render still carries the BOOTSTRAP pins (mirror + panel);
  # rendered_policy_on must not read them as split-horizon opt-in
  nameserver-policy:
    'testingcf.jsdelivr.net': [ https://192.0.2.53/dns-query ]
    'panel.example.com': [ https://192.0.2.53/dns-query ]
  nameserver: [ 192.0.2.53 ]
  fallback: [ https://192.0.2.99/dns-query#auto ]
  proxy-server-nameserver: [ 192.0.2.53 ]
  fallback-filter:
    geoip: true
rules:
  # Setting DNS_GEOIP_NO_RESOLVE=true in .env renders a `,no-resolve` suffix
  - 'GEOSITE,CN,DIRECT'
  - 'GEOIP,CN,DIRECT'
  - 'MATCH,PROXY'
EOF
  if rendered_knob_on "$TMP/legacy.yaml"; then st_bad "knob_on fooled by comment prose"; else st_ok; fi
  if rendered_knob_off "$TMP/legacy.yaml"; then st_ok; else st_bad "knob_off missed the bare rule"; fi
  if rendered_policy_on "$TMP/legacy.yaml"; then st_bad "policy_on read the bootstrap pins as split-horizon"; else st_ok; fi
  if rendered_psn_untunneled "$TMP/legacy.yaml"; then st_ok; else st_bad "psn check false negative"; fi
  if rendered_split_core_off "$TMP/legacy.yaml"; then st_ok; else st_bad "split_core_off missed the legacy core"; fi
  if rendered_split_core_on "$TMP/legacy.yaml"; then st_bad "split_core_on misread the legacy core as v2"; else st_ok; fi
  cat > "$TMP/policy.yaml" <<'EOF'
dns:
  # the v2 core removes the fallback: dual-query - this comment mentioning
  # fallback: and nameserver: must not fool the line-anchored greps
  nameserver-policy:
    'geosite:cn': [ https://192.0.2.53/dns-query ]
    'geosite:geolocation-!cn': [ https://192.0.2.54/dns-query#auto ]
  proxy-server-nameserver: [ https://192.0.2.53/dns-query#PROXY ]
  nameserver: [ https://192.0.2.54/dns-query#auto ]
rules:
  - 'GEOIP,CN,DIRECT,no-resolve'
EOF
  if rendered_policy_on "$TMP/policy.yaml"; then st_ok; else st_bad "policy_on missed a real policy"; fi
  if rendered_knob_on "$TMP/policy.yaml"; then st_ok; else st_bad "knob_on missed the real rule"; fi
  if rendered_psn_untunneled "$TMP/policy.yaml"; then st_bad "psn check missed a #PROXY fragment"; else st_ok; fi
  if rendered_split_core_on "$TMP/policy.yaml"; then st_ok; else st_bad "split_core_on missed the v2 core"; fi
  if rendered_split_core_off "$TMP/policy.yaml"; then st_bad "split_core_off misread the v2 core as legacy"; else st_ok; fi

  # 3) provider-node counting: the COMPATIBLE placeholder of an EMPTY group is
  #    never a node (run 3.5: "alive=9" was built-ins while the provider had
  #    zero nodes), and the effective-member gate rejects placeholder/builtin
  #    egress (gstatic 204 is fetchable DIRECT from CN).
  _n=$(printf '{"all":["COMPATIBLE"],"emptyFallback":"COMPATIBLE","now":"COMPATIBLE"}' | real_node_count)
  if [ "$_n" = 0 ]; then st_ok; else st_bad "real_node_count counted the COMPATIBLE placeholder: $_n"; fi
  _n=$(printf '{"all":["HK01","JP02","COMPATIBLE"],"now":"HK01"}' | real_node_count)
  if [ "$_n" = 2 ]; then st_ok; else st_bad "real_node_count miscounted a live provider group: $_n"; fi
  _n=$(printf '{"name":"auto","type":"URLTest"}' | real_node_count)
  if [ "$_n" = 0 ]; then st_ok; else st_bad "real_node_count invented members with no all[]: $_n"; fi
  _now=$(printf '{"all":["A","B"],"now":"HK09","type":"Selector"}' | effective_now)
  if [ "$_now" = "HK09" ]; then st_ok; else st_bad "effective_now got '$_now'"; fi
  for _m in COMPATIBLE DIRECT REJECT ""; do
    if now_is_real "$_m"; then st_bad "now_is_real accepted '$_m'"; else st_ok; fi
  done
  if now_is_real "HK09"; then st_ok; else st_bad "now_is_real rejected a real node"; fi

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

  # 7) summary accumulator: a message containing '|' must render as ONE line
  #    (run 3's summary split the doctor messages at every pipe)
  PASS=""; FAIL=""
  ok "doctor rc 0 (0 healthy | 2 degraded)" >/dev/null
  ok "second entry" >/dev/null
  _n=$(printf '%s\n' "$PASS" | tr "$US" '\n' | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$_n" = 2 ]; then st_ok; else st_bad "summary accumulator rendered $_n lines, want 2"; fi
  PASS=""; FAIL=""

  # 8) unpark restores the parked copy over the rebuilt one (file and dir)
  #    and is a no-op without a park
  printf 'rebuilt' > "$TMP/cache.db"; printf 'owner' > "$TMP/cache.db.v138park"
  unpark "$TMP/cache.db"
  if [ "$(cat "$TMP/cache.db")" = owner ] && [ ! -e "$TMP/cache.db.v138park" ]; then
    st_ok
  else st_bad "unpark(file) did not restore the park"; fi
  mkdir -p "$TMP/proxies" "$TMP/proxies.v138park"
  printf 'rebuilt' > "$TMP/proxies/p.yaml"; printf 'owner' > "$TMP/proxies.v138park/p.yaml"
  unpark "$TMP/proxies"
  if [ "$(cat "$TMP/proxies/p.yaml")" = owner ] && [ ! -e "$TMP/proxies.v138park" ]; then
    st_ok
  else st_bad "unpark(dir) did not restore the park"; fi
  printf 'live' > "$TMP/plain"
  unpark "$TMP/plain"
  if [ "$(cat "$TMP/plain")" = live ]; then st_ok; else st_bad "unpark(no park) touched the live file"; fi

  echo "validate_release self-test: $_stp passed, $_stf failed"
  [ "$_stf" -eq 0 ] || exit 1
  echo "OK: measurement helpers (policy/knob/psn/split-core rule anchoring incl. bootstrap-pin + comment-prose immunity, provider-node counting + real-member egress gate, quoted-.env parsing, .env.example key coverage, scrubbed child env, doctor rc gate, summary accumulator, cache unpark)"
  exit 0
}
[ "$SELF_TEST" = 1 ] && self_test

# ---- privileged validation ---------------------------------------------------

[ "$(id -u)" = 0 ] || { echo "run with sudo (real TTY)"; exit 6; }

main() {

PASS=""; FAIL=""

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

# kick_urltest - run a group-wide delay test over the template's `auto`
# url-test group so its node pick rests on fresh data. `auto` is lazy: with
# the selection cache wiped and zero LAN traffic since the recreate, its
# pick can be an untested dead node no real client would ride - run 3
# probed exactly that for nine minutes while 9 nodes sat alive. A renamed
# group makes this a harmless no-op (the PROXY probe still decides).
kick_urltest() {
  ctl_get "/group/auto/delay?timeout=5000&url=http://www.gstatic.com/generate_204" >/dev/null 2>&1 || true
}

# diag_egress - after a failed PROXY probe, log who is selected and which
# members actually pass, so a failure is diagnosable from the transcript.
diag_egress() {
  echo "  diag PROXY group: $(ctl_get /proxies/PROXY)"
  echo "  diag auto group: $(ctl_get /proxies/auto)"
  echo "  diag per-member delay: $(ctl_get "/group/PROXY/delay?timeout=8000&url=http://www.gstatic.com/generate_204")"
}

# egress_via_real_node - the PROXY group's EFFECTIVE member (one level of
# `auto` indirection resolved) is an actual provider node. A delay-probe PASS
# alone is not egress proof: an empty group degrades to COMPATIBLE (= DIRECT),
# and gstatic's generate_204 answers direct from CN (run 3.5's false PASS).
egress_via_real_node() {
  _evn=$(ctl_get /proxies/PROXY | effective_now)
  [ "$_evn" = auto ] && _evn=$(ctl_get /proxies/auto | effective_now)
  now_is_real "$_evn"
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
# v1.3.10 routing surface: the STREAMING selector and the deterministic
# domain rules are static template content - present in EVERY DNS profile.
case "$(ctl_get /proxies/STREAMING)" in
  *'"STREAMING"'*) ok "STREAMING group present (dashboard-pinnable)" ;;
  *) bad "STREAMING group missing from the controller" ;;
esac
if grep -q "^  - 'GEOSITE,NETFLIX,STREAMING'" "$CFG"; then
  ok "netflix rule rendered at the head of the chain"
else
  bad "GEOSITE,NETFLIX,STREAMING rule missing from the render"
fi
if grep -q "^  - 'GEOSITE,GEOLOCATION-!CN,PROXY'" "$CFG"; then
  ok "listed-foreign PROXY rule rendered (skips GEOIP lookups)"
else
  bad "GEOSITE,GEOLOCATION-!CN,PROXY rule missing from the render"
fi
if grep -q "^  - 'GEOIP,LAN,DIRECT,no-resolve'" "$CFG"; then
  ok "LAN-direct rule rendered (private destinations never ride the tunnel)"
else
  bad "GEOIP,LAN,DIRECT,no-resolve rule missing from the render"
fi

say "A3: upgrade compatibility - the UNCHANGED .env must render the legacy config"
if rendered_policy_on "$CFG"; then
  echo "note: nameserver-policy already rendered (this .env already opted in)"
else
  ok "pre-split-horizon .env renders WITHOUT nameserver-policy (byte-compat path)"
fi
if rendered_knob_off "$CFG"; then ok "GEOIP rule bare (knob off/unset)"; else bad "bare GEOIP rule missing"; fi
# Bootstrap panel pin (2026-07-12 outage): the airport-panel host must sit in
# nameserver-policy in EVERY mode. Derive the host exactly like the renderer;
# an IP-literal subscription host is pinless by design - note and skip.
PH=$(grep -v '^#' "$SUBSCRIPTION_FILE" | grep -v '^[[:space:]]*$' | head -n1 \
  | sed -e 's/^[A-Za-z0-9_.-]*=//' -e 's/[[:space:]]*$//' \
  | sed -n 's|^[A-Za-z][A-Za-z0-9+.-]*://\([^/?#]*\).*|\1|p' \
  | sed -e 's/^.*@//' -e 's/:[0-9]*$//')
case "$PH" in
  ''|\[*) echo "note: no panel pin expected (unparseable/IPv6-literal subscription host)" ;;
  *[!0-9.]*)
    if grep -q "^    '$PH':" "$CFG"; then
      ok "bootstrap panel pin rendered ($PH -> domestic nameserver)"
    else
      bad "bootstrap panel pin missing for $PH"
    fi ;;
  *) echo "note: no panel pin expected (IP-literal subscription host $PH)" ;;
esac

say "A4: enable split-horizon + sniffer + exclude filter from the shipped .env.example defaults"
cp -p "$ENV_FILE" "$ORIG"
for _k in DNS_NAMESERVER DNS_FALLBACK DNS_CN_NAMESERVER DNS_FOREIGN_NAMESERVER \
          SNIFFER_ENABLE AUTO_EXCLUDE_FILTER; do
  _v="$(example_dns "$_k")"
  [ -n "$_v" ] || { bad "no $_k in $REL/.env.example"; exit 3; }
  env_set "$_k" "$_v"
done
env_set DNS_GEOIP_NO_RESOLVE false
recreate || bad "compose recreate (enable split-horizon)"
load_env || true
if rendered_policy_on "$CFG"; then ok "nameserver-policy rendered"; else bad "nameserver-policy did NOT render"; fi
if rendered_psn_untunneled "$CFG"; then ok "proxy-server-nameserver untunneled (cold-start invariant)"; else bad "proxy-server-nameserver carries a #fragment"; fi
if rendered_split_core_on "$CFG"; then
  ok "v2 core rendered (foreign-by-default nameserver, fallback dual-query gone)"
else
  bad "v2 core did NOT render (nameserver untunneled, or a fallback: line survives)"
fi
if grep -q '^sniffer:' "$CFG" && grep -q '^  parse-pure-ip: true' "$CFG"; then
  ok "sniffer rendered (raw-IP flows recover hostnames - DNS-bypassing clients route correctly)"
else
  bad "sniffer block missing from the render (SNIFFER_ENABLE sync failed?)"
fi

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
  N=$(ctl_get /proxies/auto | real_node_count); N=${N:-0}
  echo "  t+$((_i*15))s provider nodes: $N"
  [ "$N" -gt 0 ] && break
done
kick_urltest
if delay_probe PROXY "http://www.gstatic.com/generate_204" && egress_via_real_node; then
  EGRESS=1
else
  EGRESS=0
fi
if [ "$N" -gt 0 ]; then
  ok "COLD START: provider_nodes=$N egress_via_real_node=$EGRESS with no caches + dead tunnel resolvers"
else
  bad "COLD START: provider delivered no node after 90s (a live fetch must work with the panel pin)"
  "$DOCKER_BIN" logs "$MIHOMO_CONTAINER" 2>&1 | tail -40 | sed 's/^/    /'
fi
[ "$EGRESS" = 1 ] || diag_egress
# Fail-closed proof (v2, while the tunnel resolvers are STILL black-holed):
# a long-tail lookup must DIE - nothing may silently answer it from a
# domestic resolver (the whole point of removing the fallback dual-query) -
# while a policy-pinned host keeps resolving via the domestic list. The
# controller /dns/query endpoint exercises the real upstream chain,
# bypassing the fake-ip middleware that answers LAN clients.
_LT="failclosed-$$-$(date +%s).example.com"
case "$(ctl_get "/dns/query?name=$_LT&type=A")" in
  *'"Answer"'*) bad "FAIL-CLOSED: long-tail $_LT got an ANSWER with dead tunnel resolvers - a domestic leak path survives" ;;
  *) ok "fail-closed: long-tail lookup dies while the tunnel resolvers are dead" ;;
esac
case "$(ctl_get "/dns/query?name=www.gstatic.com&type=A")" in
  *'"Answer"'*) ok "policy-pinned host still resolves via the domestic list" ;;
  *) bad "pinned-host lookup failed - the bootstrap pins are broken" ;;
esac
# Put the owner's caches back regardless of outcome: cache.db carries the
# dashboard-selected node (run 3 dropped it on pass, reset the selection to
# the group default, and measured THAT for the rest of the run), and the
# parked provider list spares a refetch. The cold container holds its
# cache.db open by file descriptor, so replacing the path now is safe -
# the B2 recreate starts from the restored files.
unpark "$GATEWAY_DATA_DIR/config/cache.db"
unpark "$GATEWAY_DATA_DIR/config/proxies"

say "B2: real tunnel resolvers back + doctor --egress"
env_set DNS_FALLBACK "$(example_dns DNS_FALLBACK)"
env_set DNS_FOREIGN_NAMESERVER "$(example_dns DNS_FOREIGN_NAMESERVER)"
recreate || bad "compose recreate (restore resolvers)"
load_env || true
run_scrubbed sh "$REL/scripts/doctor.sh" --egress; RC=$?
if doctor_rc_ok "$RC"; then ok "doctor --egress rc $RC (0 healthy | 2 degraded-optional)"
else bad "doctor --egress rc $RC (crash or broken)"; fi

say "B3: LAN privacy + streaming spot-check (owner, from any LAN client)"
echo ">>> 1) DNS leak: run the EXTENDED test at dnsleaktest.com. The servers"
echo ">>>    listed must be your tunnel exit / foreign DoH operators ONLY -"
echo ">>>    AliDNS (Alibaba) or DNSPod (Tencent) appearing means the"
echo ">>>    long-tail leak is back."
echo ">>> 2) Netflix: open any title. If it says 'not available in your"
echo ">>>    region', open MetaCubeXD -> Proxies -> STREAMING and pin an"
echo ">>>    unlock-capable node (auto picks by latency, not by unlock),"
echo ">>>    then reload the title."
printf ">>> Press Enter when both are checked : "
read -r _ans </dev/tty || true

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
  kick_urltest
  if delay_probe PROXY "http://www.gstatic.com/generate_204" && egress_via_real_node; then
    ok "foreign egress via PROXY (mihomo-fetched gstatic 204 through a real node)"
  else
    bad "foreign egress via PROXY failed (probe failed, or effective member is a placeholder/builtin)"
    diag_egress
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
echo "PASS:"; printf '%s\n' "$PASS" | tr "$US" '\n' | sed '/^$/d;s/^/  + /'
echo "FAIL:"; printf '%s\n' "$FAIL" | tr "$US" '\n' | sed '/^$/d;s/^/  - /'
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
