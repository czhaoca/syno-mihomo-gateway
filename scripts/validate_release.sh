#!/bin/sh
# validate_release.sh - on-NAS release validation for a staged bundle.
# Proves, on the real network, what CI can only prove structurally:
#   A. the staged bundle deploys and doctor is healthy (incl. the Streaming
#      Sites group + netflix rule of v1.3.10, renamed in the group-model
#      streamline);
#   B. the saved .env renders the v2 split-horizon config - the ONLY DNS
#      profile since the proxy-groups-v2 purge - then the sniffer and
#      country groups are refreshed from the shipped .env.example defaults
#      (policy entries + foreign-by-default core, no fallback dual-query);
#   C. COLD START: with the node cache and provider cache parked and every
#      tunnel-dependent resolver black-holed, nodes still come up - the
#      2026-07 chicken-and-egg, disproven on the wire - and long-tail DNS
#      FAILS CLOSED (never silently answered by a domestic resolver) while
#      the policy-pinned hosts keep resolving; then an owner LAN spot-check
#      (dnsleaktest extended + netflix via the Streaming Sites group);
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
#   --probe-ip X  automated full-proxy band probe (#46): X is a SPARE LAN
#                 IPv4 the owner supplies (never committed - CLAUDE.md's
#                 no-hardcoded-address rule is why there is no default).
#                 A5 then temporarily adds X to FULL_PROXY_SOURCES,
#                 attaches an ephemeral probe container (the mihomo image,
#                 default route re-pointed at the gateway) and asserts its
#                 flows carry 'Full Proxy' via /connections. Liveness-
#                 checked first (a replying IP is NOT spare); torn down on
#                 completion AND from the INT/TERM trap. Unset -> a manual
#                 B3-style prompt when the band knob is live, else skipped.
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
# Proxy Mode egress probes fire only after a group-wide url-test kick, and
# the parked caches are RESTORED after the cold-start block, never dropped:
# cache.db carries the dashboard-selected node, and the template's All Nodes
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
BLACKHOLE="https://192.0.2.1/dns-query#All Nodes"  # RFC 5737 TEST-NET-1: never routes

SELF_TEST=0; SKIP_KNOB=0; NO_EXTRACT=0; FINAL=""; PROBE_IP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) SELF_TEST=1 ;;
    --skip-knob) SKIP_KNOB=1 ;;
    --no-extract) NO_EXTRACT=1 ;;
    --keep) FINAL=keep ;;
    --revert) FINAL=revert ;;
    --probe-ip)
      [ $# -ge 2 ] || { echo "--probe-ip needs a value (a spare LAN IPv4)" >&2; exit 3; }
      PROBE_IP="$2"; shift ;;
    --probe-ip=*) PROBE_IP="${1#*=}" ;;
    *) echo "unknown flag: $1" >&2; exit 3 ;;
  esac
  shift
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

# urltest_groups - controller /group JSON on stdin -> the url-test pool
# names, one per line. Every "name" key in /group is a group (member nodes
# appear only as bare strings inside all[]); dropping the fixed selector and
# builtin names (current AND retired - a pre-streamline config may still be
# live during validation) leaves All Nodes + the .env-driven country set -
# DYNAMIC discovery, never a hardcoded list.
# Mirrors the doctor's chk_proxy_groups enumeration (scripts/lib/checks.sh).
urltest_groups() {
  awk -F'"name":"' '{ for (i = 2; i <= NF; i++) { n = $i; sub(/".*/, "", n); print n } }' \
    | grep -v -e '^Proxy Mode$' -e '^Streaming Sites$' -e '^Country Pick$' \
              -e '^Full Proxy$' -e '^Priority Nodes$' \
              -e '^PROXY$' -e '^STREAMING$' -e '^GLOBAL$' -e '^DIRECT$' \
              -e '^REJECT$' -e '^REJECT-DROP$' -e '^PASS$' -e '^COMPATIBLE$'
}

# url_encode NAME - %XX-encode EVERY byte (over-encoding is legal per RFC
# 3986) so the CJK country-group names survive as controller URL path
# segments (mirrors the doctor's _pg_enc).
url_encode() {
  printf '%s' "$1" | od -An -v -tx1 | tr ' ' '\n' | grep -v '^$' \
    | while IFS= read -r _ue_b; do printf '%%%s' "$_ue_b"; done
}

# filtered_real_count - real_node_count for the generated country groups,
# which render `empty-fallback: REJECT`: an emptied group reports
# all:["REJECT"], so BOTH placeholder adapters are excluded (issue #35;
# same rule as the doctor's _pg_real).
filtered_real_count() { members_of | grep -v '^COMPATIBLE$' | grep -c -v '^REJECT$'; }

# resolve_now_chain START - follow group "now" members through ctl_get until
# a non-group answers (bounded walk: the streamlined graph chains Proxy Mode
# -> Country Pick -> "<Country> Auto" -> node); prints the final member. A
# member whose /proxies/<name> answer carries an all[] list is itself a
# group. ctl_get is the injectable transport (--self-test stubs it).
resolve_now_chain() {
  _rnc=$(ctl_get "/proxies/$(url_encode "$1")" | effective_now)
  _rnc_hop=0
  while [ "$_rnc_hop" -lt 4 ] && [ -n "$_rnc" ]; do
    _rnc_j=$(ctl_get "/proxies/$(url_encode "$_rnc")")
    case "$_rnc_j" in
      *'"all":['*) _rnc=$(printf '%s' "$_rnc_j" | effective_now) ;;
      *) break ;;
    esac
    _rnc_hop=$((_rnc_hop+1))
  done
  printf '%s' "$_rnc"
}

# fp_ip2n IP - dotted-quad to integer; -1 for anything not canonical IPv4
# (IPv6 sources, empty fields) so callers can skip it. (#46)
fp_ip2n() {
  _f2_old_ifs=$IFS; IFS='.'
  set -f
  # shellcheck disable=SC2086  # deliberate '.' field split
  set -- $1
  set +f
  IFS=$_f2_old_ifs
  if [ $# -ne 4 ]; then echo -1; return 0; fi
  for _f2_o in "$@"; do
    case "$_f2_o" in
      ''|*[!0-9]*) echo -1; return 0 ;;
      0) : ;;
      0*) echo -1; return 0 ;;  # leading zero: $((08)) is an octal SYNTAX ERROR in ash
    esac
    if [ "${#_f2_o}" -gt 3 ] || [ "$_f2_o" -gt 255 ]; then echo -1; return 0; fi
  done
  echo $(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
}

# fp_ip_in_cidr IP CIDR - 0 when IP falls inside CIDR (64-bit shell
# arithmetic; BusyBox-safe). Non-IPv4 input never matches. (#46)
fp_ip_in_cidr() {
  _fic_n=$(fp_ip2n "$1")
  [ "$_fic_n" -ge 0 ] || return 1
  _fic_bn=$(fp_ip2n "${2%%/*}")
  [ "$_fic_bn" -ge 0 ] || return 1
  _fic_len=${2#*/}
  case "$_fic_len" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$_fic_len" -ge 32 ]; then _fic_m=4294967295
  elif [ "$_fic_len" -le 0 ]; then _fic_m=0
  else _fic_m=$(( 4294967295 - (1 << (32 - _fic_len)) + 1 )); fi
  [ $(( _fic_n & _fic_m )) -eq $(( _fic_bn & _fic_m )) ]
}

# fp_conn_lines - controller /connections JSON on stdin -> one line per
# connection: sourceIP|destinationIP|network|fp/nofp (fp = the chain
# carries 'Full Proxy'). Connections are split onto lines FIRST (a
# multi-char RS is a gawk extension BusyBox awk lacks). Mirrors the
# doctor's _fp_conns - duplicated because checks.sh and this script cannot
# source each other; both sides are suite-covered. (#46)
fp_conn_lines() {
  sed 's/{"id":/\
{"id":/g' | awk '
    /"id":/ {
      src=""; dst=""; net=""; fp="nofp"
      if (match($0, /"sourceIP":"[^"]*"/))      src=substr($0, RSTART+12, RLENGTH-13)
      if (match($0, /"destinationIP":"[^"]*"/)) dst=substr($0, RSTART+17, RLENGTH-18)
      if (match($0, /"network":"[^"]*"/))       net=substr($0, RSTART+11, RLENGTH-12)
      if (match($0, /"chains":\[[^]]*"Full Proxy"[^]]*\]/)) fp="fp"
      print src "|" dst "|" net "|" fp
    }'
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
# dropped the park on pass, which reset the Proxy Mode selector to the group
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
  # (the retired PRIORITY_* knobs are deliberately absent - group-model
  # streamline)
  REL="$ROOT"
  for _k in DNS_NAMESERVER DNS_CN_NAMESERVER \
            DNS_FOREIGN_NAMESERVER DNS_GEOIP_NO_RESOLVE SNIFFER_ENABLE \
            COUNTRY_GROUPS; do
    if [ -n "$(example_dns "$_k")" ]; then st_ok; else st_bad ".env.example lacks $_k"; fi
  done
  for _k in PRIORITY_INCLUDE_FILTER PRIORITY_EXCLUDE_FILTER; do
    if [ -n "$(example_dns "$_k")" ]; then st_bad ".env.example still ships retired knob $_k"; else st_ok; fi
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
  _n=$(printf '{"name":"All Nodes","type":"URLTest"}' | real_node_count)
  if [ "$_n" = 0 ]; then st_ok; else st_bad "real_node_count invented members with no all[]: $_n"; fi

  # 3b) filtered-group release gate helpers (#35): group discovery from a
  #     canned /group payload (CJK names kept, selectors/builtins dropped),
  #     the %XX byte encoder against a HARDCODED expected string (verifies
  #     the encoder independently), and placeholder exclusion counting BOTH
  #     adapters - a live emptied filtered group reports all:["REJECT"]
  #     (the epic's empty-fallback), not COMPATIBLE.
  _gj='{"proxies":[{"name":"Proxy Mode","type":"Selector","all":["Country Pick","DIRECT","REJECT"]},{"name":"Streaming Sites","type":"Selector","all":["Proxy Mode","Japan Auto","DIRECT"]},{"name":"Country Pick","type":"Selector","all":["Japan Auto"]},{"name":"Japan Auto","type":"URLTest","all":["n1"]},{"name":"All Nodes","type":"URLTest","hidden":true,"all":["n1"]},{"name":"GLOBAL","type":"Selector","all":["All Nodes","Proxy Mode"]}]}'
  _names=$(printf '%s' "$_gj" | urltest_groups)
  if [ "$_names" = 'Japan Auto
All Nodes' ]; then st_ok; else st_bad "urltest_groups got: $(printf '%s' "$_names" | tr '\n' ' ')"; fi
  _e=$(url_encode 'All Nodes')
  if [ "$_e" = '%41%6c%6c%20%4e%6f%64%65%73' ]; then st_ok; else st_bad "url_encode(All Nodes) got: $_e"; fi
  _e=$(url_encode 'Country Pick')
  if [ "$_e" = '%43%6f%75%6e%74%72%79%20%50%69%63%6b' ]; then st_ok; else st_bad "url_encode(Country Pick) got: $_e"; fi
  _e=$(url_encode 日本)
  if [ "$_e" = '%e6%97%a5%e6%9c%ac' ]; then st_ok; else st_bad "url_encode(日本) got: $_e"; fi
  _n=$(printf '{"all":["REJECT"],"emptyFallback":"REJECT","now":"REJECT"}' | filtered_real_count)
  if [ "$_n" = 0 ]; then st_ok; else st_bad "filtered_real_count counted the REJECT placeholder: $_n"; fi
  _n=$(printf '{"all":["COMPATIBLE"],"now":"COMPATIBLE"}' | filtered_real_count)
  if [ "$_n" = 0 ]; then st_ok; else st_bad "filtered_real_count counted the COMPATIBLE placeholder: $_n"; fi
  _n=$(printf '{"all":["HK01","REJECT","COMPATIBLE","JP02"],"now":"HK01"}' | filtered_real_count)
  if [ "$_n" = 2 ]; then st_ok; else st_bad "filtered_real_count miscounted a mixed group: $_n"; fi

  _now=$(printf '{"all":["A","B"],"now":"HK09","type":"Selector"}' | effective_now)
  if [ "$_now" = "HK09" ]; then st_ok; else st_bad "effective_now got '$_now'"; fi
  for _m in COMPATIBLE DIRECT REJECT ""; do
    if now_is_real "$_m"; then st_bad "now_is_real accepted '$_m'"; else st_ok; fi
  done
  if now_is_real "HK09"; then st_ok; else st_bad "now_is_real rejected a real node"; fi

  # 3c) multi-level egress indirection (group-model streamline): the chain
  #     walk follows group "now" members through the injectable ctl_get
  #     transport (Proxy Mode -> Country Pick -> Japan Auto -> node) and
  #     stops at the first non-group answer; a REJECTing chain resolves to
  #     the placeholder, which now_is_real then refuses.
  _enc_pm=$(url_encode 'Proxy Mode')
  _enc_cp=$(url_encode 'Country Pick')
  _enc_ja=$(url_encode 'Japan Auto')
  ctl_get() {
    case "$1" in
      "/proxies/$_enc_pm") printf '{"all":["Country Pick","DIRECT","REJECT"],"now":"Country Pick"}' ;;
      "/proxies/$_enc_cp") printf '{"all":["Japan Auto"],"now":"Japan Auto"}' ;;
      "/proxies/$_enc_ja") printf '{"all":["JP01","JP02"],"now":"JP01"}' ;;
      *) printf '{}' ;;
    esac
  }
  _ch=$(resolve_now_chain 'Proxy Mode')
  if [ "$_ch" = "JP01" ]; then st_ok; else st_bad "resolve_now_chain got '$_ch' (want JP01)"; fi
  ctl_get() { printf '{"all":["REJECT"],"emptyFallback":"REJECT","now":"REJECT"}'; }
  _ch=$(resolve_now_chain 'Proxy Mode')
  if now_is_real "$_ch"; then st_bad "chain walk accepted placeholder '$_ch'"; else st_ok; fi
  unset -f ctl_get

  # 3d) full-proxy band helpers (#46): connection-line parsing (chain
  #     membership, per-connection splitting without gawk RS) + CIDR
  #     membership arithmetic (the A5 probe and its IP guards ride these).
  _fc=$(printf '%s' '{"connections":[{"id":"a1","metadata":{"network":"tcp","sourceIP":"192.0.2.20","destinationIP":"93.184.216.34"},"chains":["JP01","Japan Auto","Country Pick","Proxy Mode","Full Proxy"]},{"id":"a2","metadata":{"network":"udp","sourceIP":"192.0.2.21","destinationIP":"120.232.145.144"},"chains":["DIRECT"]}]}' | fp_conn_lines)
  if [ "$_fc" = '192.0.2.20|93.184.216.34|tcp|fp
192.0.2.21|120.232.145.144|udp|nofp' ]; then st_ok; else st_bad "fp_conn_lines got: $_fc"; fi
  if fp_ip_in_cidr 192.0.2.20 192.0.2.16/28; then st_ok; else st_bad "fp_ip_in_cidr missed an in-band IP"; fi
  if fp_ip_in_cidr 192.0.2.33 192.0.2.16/28; then st_bad "fp_ip_in_cidr accepted an out-of-band IP"; else st_ok; fi
  if fp_ip_in_cidr 192.0.2.5 192.0.2.5/32; then st_ok; else st_bad "fp_ip_in_cidr missed a /32 exact"; fi
  if fp_ip_in_cidr 192.0.2.6 192.0.2.5/32; then st_bad "fp_ip_in_cidr /32 matched a neighbor"; else st_ok; fi
  if fp_ip_in_cidr bogus.example 192.0.2.16/28; then st_bad "fp_ip_in_cidr accepted a non-IP"; else st_ok; fi
  # leading-zero octets must resolve to the -1 sentinel, never reach the
  # arithmetic ($((08)) is an octal SYNTAX ERROR in dash/BusyBox ash)
  if fp_ip_in_cidr 192.008.2.5 192.0.2.16/28; then st_bad "fp_ip_in_cidr accepted a leading-zero octet"; else st_ok; fi

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
  echo "OK: measurement helpers (policy/knob/psn/split-core rule anchoring incl. bootstrap-pin + comment-prose immunity, provider-node counting + real-member egress gate, filtered-group discovery + %XX name encoding + COMPATIBLE/REJECT placeholder exclusion, full-proxy band connection parsing + CIDR membership, quoted-.env parsing, .env.example key coverage, scrubbed child env, doctor rc gate, summary accumulator, cache unpark)"
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
# real egress path). The group name is %XX-encoded here, so callers pass the
# human name ('Proxy Mode', DIRECT). Retried: nodes may still be
# health-checking right after a recreate. (Run 2's http_proxy-wget probes
# were unreliable - busybox wget ignored the proxy, so baidu "passed" direct
# and gstatic failed direct.)
delay_probe() {
  _dp_i=0
  while [ "$_dp_i" -lt 3 ]; do
    case "$(ctl_get "/proxies/$(url_encode "$1")/delay?timeout=5000&url=$2")" in
      *'"delay"'*) return 0 ;;
    esac
    _dp_i=$((_dp_i+1)); sleep 10
  done
  return 1
}

# kick_urltest - run a group-wide delay test over the country groups
# (discovered live) plus the hidden All Nodes anchor so the node picks rest
# on fresh data. The url-test groups are lazy: with the selection cache
# wiped and zero LAN traffic since the recreate, a pick can be an untested
# dead node no real client would ride - run 3 probed exactly that for nine
# minutes while 9 nodes sat alive. A missing group makes each kick a
# harmless no-op (the Proxy Mode probe still decides).
kick_urltest() {
  ctl_get "/group/All%20Nodes/delay?timeout=5000&url=http://www.gstatic.com/generate_204" >/dev/null 2>&1 || true
  _ku_list=$(ctl_get /group | urltest_groups)
  while IFS= read -r _ku_g; do
    [ -n "$_ku_g" ] || continue
    [ "$_ku_g" = "All Nodes" ] && continue
    ctl_get "/group/$(url_encode "$_ku_g")/delay?timeout=5000&url=http://www.gstatic.com/generate_204" >/dev/null 2>&1 || true
  done <<KUEOF
$_ku_list
KUEOF
}

# diag_egress - after a failed Proxy Mode probe, log who is selected along
# the chain and which members actually pass, so a failure is diagnosable
# from the transcript.
diag_egress() {
  echo "  diag Proxy Mode group: $(ctl_get /proxies/Proxy%20Mode)"
  echo "  diag Country Pick group: $(ctl_get /proxies/Country%20Pick)"
  echo "  diag All Nodes group: $(ctl_get /proxies/All%20Nodes)"
  echo "  diag per-member delay: $(ctl_get "/group/Proxy%20Mode/delay?timeout=8000&url=http://www.gstatic.com/generate_204")"
}

# egress_via_real_node - the Proxy Mode group's EFFECTIVE member, resolved
# through the group chain (Proxy Mode -> Country Pick -> "<Country> Auto" ->
# node; resolve_now_chain's bounded walk), is an actual provider node. A
# delay-probe PASS alone is not egress proof: an empty group degrades to
# COMPATIBLE (= DIRECT), and gstatic's generate_204 answers direct from CN
# (run 3.5's false PASS).
egress_via_real_node() {
  now_is_real "$(resolve_now_chain 'Proxy Mode')"
}

restore_env() {  # put the pre-validation .env back
  [ -f "$ORIG" ] && cat "$ORIG" > "$ENV_FILE" && rm -f "$ORIG"
}
# fp_probe_teardown - remove the A5 band-probe container if one is up; a
# ^C must never leave it holding the owner's spare IP on the live macvlan.
fp_probe_teardown() { "${DOCKER_BIN:-docker}" rm -f smg-fp-probe >/dev/null 2>&1 || true; }
# shellcheck disable=SC2329 # invoked via the trap below
on_abort() { echo "INTERRUPTED - restoring original .env"; fp_probe_teardown; restore_env; recreate; exit 1; }
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
# v1.3.10 routing surface (renamed in the group-model streamline): the
# Streaming Sites selector and the deterministic domain rules are static
# template content - present in EVERY DNS profile.
case "$(ctl_get /proxies/Streaming%20Sites)" in
  *'"Streaming Sites"'*) ok "Streaming Sites group present (dashboard-pinnable)" ;;
  *) bad "Streaming Sites group missing from the controller" ;;
esac
if grep -q "^  - 'GEOSITE,NETFLIX,Streaming Sites'" "$CFG"; then
  ok "netflix rule rendered at the head of the chain"
else
  bad "GEOSITE,NETFLIX,Streaming Sites rule missing from the render"
fi
for _svc in SPOTIFY TIDAL DEEZER SOUNDCLOUD; do
  if grep -q "^  - 'GEOSITE,$_svc,Streaming Sites'" "$CFG"; then
    ok "$_svc rule rendered (audio streaming rides Streaming Sites)"
  else
    bad "GEOSITE,$_svc,Streaming Sites rule missing from the render"
  fi
done
if grep -q "^  - 'GEOSITE,GEOLOCATION-!CN,Proxy Mode'" "$CFG"; then
  ok "listed-foreign Proxy Mode rule rendered (skips GEOIP lookups)"
else
  bad "GEOSITE,GEOLOCATION-!CN,Proxy Mode rule missing from the render"
fi
if grep -q "^  - 'GEOIP,LAN,DIRECT,no-resolve'" "$CFG"; then
  ok "LAN-direct rule rendered (private destinations never ride the tunnel)"
else
  bad "GEOIP,LAN,DIRECT,no-resolve rule missing from the render"
fi

say "A3: the saved .env renders the v2 split-horizon policy (the only DNS profile)"
if rendered_policy_on "$CFG"; then
  ok "nameserver-policy rendered (split-horizon v2)"
else
  bad "nameserver-policy missing - a render without the split pair should be impossible"
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

say "A4: enable split-horizon + sniffer + country groups from the shipped .env.example defaults"
cp -p "$ENV_FILE" "$ORIG"
for _k in DNS_NAMESERVER DNS_CN_NAMESERVER DNS_FOREIGN_NAMESERVER \
          SNIFFER_ENABLE COUNTRY_GROUPS; do
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

say "A4.5: country groups carry real nodes (release gate - fails on empty)"
# The A4 env just enabled the SHIPPED country-group defaults, so the groups
# now rendered are exactly what a new install gets - and Country Pick's
# members ARE these groups. A generated group matching ZERO provider nodes
# means the release's regexes do not fit the validation airport's node
# names: selecting it REJECTs (fail closed by design), and shipping that as
# a default is the false-PASS class this script exists to kill - so staging
# FAILS here (issue #35 DEC-A; the doctor's runtime posture stays warn for
# non-selected country groups). Discovery is live from the controller; the
# retry absorbs the post-recreate window while the provider cache loads.
_FG_LIST=$(ctl_get /group | urltest_groups)
if [ -z "$_FG_LIST" ]; then
  bad "no url-test groups discoverable from the controller (/group)"
else
  _FG_N=0
  while IFS= read -r _fg; do
    [ -n "$_fg" ] || continue
    [ "$_fg" = "All Nodes" ] && continue  # full pool - counted by the cold-start leg
    _FG_N=$((_FG_N+1))
    _fn=0
    for _i in 1 2 3; do
      _fn=$(ctl_get "/proxies/$(url_encode "$_fg")" | filtered_real_count); _fn=${_fn:-0}
      [ "$_fn" -gt 0 ] && break
      sleep 5
    done
    if [ "$_fn" -gt 0 ]; then
      ok "country group '$_fg': $_fn real node(s)"
    else
      bad "country group '$_fg' matches ZERO provider nodes - the shipped regex does not fit this airport's naming (selection REJECTs; fix COUNTRY_GROUPS in .env.example before release)"
    fi
  done <<FGEOF
$_FG_LIST
FGEOF
  if [ "$_FG_N" -gt 0 ]; then
    ok "country-group gate covered $_FG_N group(s), discovered live (no hardcoded list)"
  else
    bad "no country groups rendered - COUNTRY_GROUPS is REQUIRED and the A4 env just set the shipped default; the render or recreate must have failed"
  fi
fi

# A5 runs in the resolvers-restored window (before the cold-start
# black-holing) so the probe's fetches measure the real band path.
say "A5: full-proxy band (#46; --probe-ip <spare-lan-ip> enables the automated leg)"
if [ -n "$PROBE_IP" ]; then
  _fp_go=1
  case "$PROBE_IP" in
    *:*|*/*) bad "probe IP '$PROBE_IP' must be a bare IPv4 (no CIDR, no IPv6)"; _fp_go=0 ;;
  esac
  if [ "$_fp_go" = 1 ] && [ "$(fp_ip2n "$PROBE_IP")" -lt 0 ]; then
    bad "probe IP '$PROBE_IP' is not a valid IPv4 address"; _fp_go=0
  fi
  if [ "$_fp_go" = 1 ] && ! fp_ip_in_cidr "$PROBE_IP" "${SUBNET_CIDR:-0.0.0.0/32}"; then
    bad "probe IP $PROBE_IP is outside SUBNET_CIDR ${SUBNET_CIDR:-<unset>}"; _fp_go=0
  fi
  if [ "$_fp_go" = 1 ] && { [ "$PROBE_IP" = "${MIHOMO_IP:-}" ] || [ "$PROBE_IP" = "${ROUTER_IP:-}" ]; }; then
    bad "probe IP $PROBE_IP collides with the gateway or router"; _fp_go=0
  fi
  # Liveness gate (panel criterion): an IP that answers ping is NOT spare -
  # attaching over a live host would ARP-conflict the production dataplane.
  if [ "$_fp_go" = 1 ] && run_scrubbed "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" ping -c 1 -W 1 "$PROBE_IP" >/dev/null 2>&1; then
    bad "probe IP $PROBE_IP answers ping - it is IN USE; pick a spare LAN IP"; _fp_go=0
  fi
  if [ "$_fp_go" = 1 ]; then
    _fp_prev="${FULL_PROXY_SOURCES:-}"
    if [ -n "$_fp_prev" ]; then
      env_set FULL_PROXY_SOURCES "$_fp_prev,$PROBE_IP"
    else
      env_set FULL_PROXY_SOURCES "$PROBE_IP"
    fi
    recreate || bad "compose recreate (band on)"
    load_env || true
    if grep -q "^  - 'SRC-IP-CIDR,$PROBE_IP/32,Full Proxy'" "$CFG"; then
      ok "band rule rendered for the probe IP (/32-normalized)"
    else
      bad "band rule for $PROBE_IP did not render"
    fi
    # The probe container is a stand-in for a real band DEVICE: it joins
    # the SAME macvlan (a second network on that subnet would trip
    # docker's IPAM overlap refusal), re-points its default route at the
    # gateway (gateway + DNS = mihomo, exactly like a DHCP client), and
    # fetches the 204 endpoint in a short loop so /connections has a live
    # flow to judge. Reuses the already-present mihomo image (no pull;
    # busybox ip/route + wget are in its alpine base). Torn down here AND
    # from on_abort.
    fp_probe_teardown
    # shellcheck disable=SC2016 # "$1" expands in the probe container's shell
    if run_scrubbed "$DOCKER_BIN" run -d --rm --name smg-fp-probe \
        --network "${TPROXY_NETWORK:-tproxy_network}" --ip "$PROBE_IP" \
        --dns "${MIHOMO_IP:?}" --cap-add NET_ADMIN \
        --entrypoint /bin/sh "${MIHOMO_IMAGE:?}" -c \
        'ip route replace default via "$1" 2>/dev/null || { route del default 2>/dev/null; route add default gw "$1"; }; i=0; while [ "$i" -lt 20 ]; do wget -q -T 4 -O /dev/null http://www.gstatic.com/generate_204 2>/dev/null; sleep 1; i=$((i+1)); done' \
        _ "$MIHOMO_IP" >/dev/null 2>&1; then
      _fp_seen=0; _fp_viol=''
      _fp_i=0
      while [ "$_fp_i" -lt 12 ]; do
        _fp_lines=$(ctl_get /connections | fp_conn_lines | grep "^$PROBE_IP|" || true)
        if [ -n "$_fp_lines" ]; then
          _fp_seen=1
          case "$_fp_lines" in *'|nofp'*) _fp_viol="$_fp_lines" ;; esac
          break
        fi
        _fp_i=$((_fp_i + 1)); sleep 1
      done
      if [ "$_fp_seen" = 1 ] && [ -z "$_fp_viol" ]; then
        ok "probe flow from $PROBE_IP rides Full Proxy (chain verified via /connections)"
      elif [ "$_fp_seen" = 1 ]; then
        bad "a probe flow from $PROBE_IP bypassed Full Proxy: $(printf '%s' "$_fp_viol" | head -n1)"
      else
        bad "no flow from $PROBE_IP observed via /connections within 12s (probe container up, band rule rendered)"
      fi
      fp_probe_teardown
    else
      bad "probe container failed to start (network ${TPROXY_NETWORK:-tproxy_network}, ip $PROBE_IP)"
    fi
    env_set FULL_PROXY_SOURCES "$_fp_prev"
    recreate || bad "compose recreate (band restore)"
    load_env || true
  fi
elif [ -n "${FULL_PROXY_SOURCES:-}" ]; then
  echo ">>> FULL_PROXY_SOURCES is live but no --probe-ip was given. Manual"
  echo ">>> spot-check, from the router console + any band-capable device:"
  echo ">>>  1) flip the device's fixed-IP reservation INTO the band + reconnect"
  echo ">>>  2) MetaCubeXD -> Connections: that device's non-LAN flows must"
  echo ">>>     show 'Full Proxy' in the chain"
  echo ">>>  3) flip the reservation back + reconnect"
  printf ">>> Press Enter when checked : "
  read -r _ans </dev/tty || true
  ok "A5 manual band spot-check acknowledged (knob live, no --probe-ip)"
else
  echo "skipped - FULL_PROXY_SOURCES unset and no --probe-ip (the band is opt-in)"
  ok "A5 skipped (band feature not in use)"
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
env_set DNS_FOREIGN_NAMESERVER "$BLACKHOLE"
recreate || bad "compose recreate (cold)"
load_env || true
N=0
for _i in 1 2 3 4 5 6; do
  sleep 15
  N=$(ctl_get /proxies/All%20Nodes | real_node_count); N=${N:-0}
  echo "  t+$((_i*15))s provider nodes: $N"
  [ "$N" -gt 0 ] && break
done
kick_urltest
if delay_probe 'Proxy Mode' "http://www.gstatic.com/generate_204" && egress_via_real_node; then
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
echo ">>>    region', open MetaCubeXD -> Proxies -> Streaming Sites and pin an"
echo ">>>    unlock-capable node (All Nodes picks by latency, not by unlock),"
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
  if delay_probe 'Proxy Mode' "http://www.gstatic.com/generate_204" && egress_via_real_node; then
    ok "foreign egress via Proxy Mode (mihomo-fetched gstatic 204 through a real node)"
  else
    bad "foreign egress via Proxy Mode failed (probe failed, or effective member is a placeholder/builtin)"
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
  echo ">>>       Match -> Proxy Mode[...]    = unlisted, riding the proxy (expected)"
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
