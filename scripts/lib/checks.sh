#!/bin/sh
# checks.sh - the single enumeration point for the gateway diagnostics (#30).
# One check function per row of the checks_run table below; checks_run applies
# the gate semantics and emits one record per check on stdout:
#
#   name|value|sev|detail
#   #hint|<extra remediation line for the human renderer>   (0..n, follows its check)
#
# consumed by the two renderers - doctor.sh's render_human and gateway.sh's
# render_json. Check functions NEVER print; they set:
#   CHECK_VALUE  - the frozen --json vocabulary (scripts/cli/spec.yaml
#                  json_output; cli_contract_check.py gates the names, the
#                  gateway_cli_check.sh parity suite pins the values). An
#                  EMPTY value means "no record" (the check does not apply).
#   CHECK_SEV    - ok | bad | warn | silent. bad accumulates BROKEN
#                  (EXIT_CONFIG), warn DEGRADED (EXIT_PARTIAL); silent carries
#                  no severity and renders no human line (unknown/disabled/
#                  absent stay visible in --json only).
#   CHECK_DETAIL - the human message body (doctor.sh renders 'ok    <detail>'
#                  / 'ERROR <detail>' / 'WARN  <detail>'); empty when silent.
#   CHECK_HINT   - optional extra remediation line(s), newline-separated,
#                  printed to stderr by the human renderer after the line.
# Values and details never contain '|' - the record framing depends on it.
#
# Gate semantics (the pre-#30 --json structure, now shared by both modes):
# the basics always run and emit; the deep set runs only when every basic is
# ok (else a single 'mihomo|unknown' record marks the gap); the probes nested
# under mihomo run only while it is running; the tail is ungated. The parity
# suite asserts this ordering end-to-end in both renderers.
#
# Requires common.sh, registry.sh, network.sh, compose.sh, geodata.sh,
# cloudflared.sh, resolve.sh, scheduler.sh sourced first (both entry points
# already source them). POSIX/BusyBox sh; no bashisms.
#
# Platform-conditional phrasing (#50, DEC-A plain vars): remediation text
# renders from INSTALLER_ENTRY (entry-script name in rerun/redeploy hints)
# and PLATFORM_LABEL (dsm | linux | pi - selects DSM-UI vs generic wording).
# install-linux.sh / install-pi.sh set + persist them; the DSM path never
# does, so UNSET keeps today's DSM wording byte-for-byte (CI golden-compares
# pin that). Text selection only - never gate/severity/value changes.

chk_env() {
  if [ -f "$ENV_FILE" ] && dotenv_load "$ENV_FILE" >/dev/null 2>&1; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL=".env parsed safely"
    return 0
  fi
  CHECK_VALUE=broken CHECK_SEV=bad
  if [ ! -f "$ENV_FILE" ]; then
    CHECK_DETAIL=".env is missing: $ENV_FILE"
    CHECK_HINT="      the release tree is unpacked but not configured - run: sudo sh ./${INSTALLER_ENTRY:-install.sh}"
  else
    CHECK_DETAIL=".env is present but does not parse - fix the reported line or re-run: sudo sh ./${INSTALLER_ENTRY:-install.sh}"
  fi
}

chk_docker() {
  if ! detect_compose >/dev/null 2>&1; then
    CHECK_VALUE=broken CHECK_SEV=bad CHECK_DETAIL="Docker or Compose is unavailable"
  elif ! "$DOCKER_BIN" info >/dev/null 2>&1; then
    CHECK_VALUE=broken CHECK_SEV=bad CHECK_DETAIL="Docker daemon is unavailable or permission was denied"
  else
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="Docker daemon and Compose are available"
  fi
}

chk_arch() {
  _ca_host="$(host_arch)"
  if [ "$_ca_host" = "${EXPECTED_ARCH:-amd64}" ]; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="host architecture=$_ca_host"
  else
    CHECK_VALUE=mismatch CHECK_SEV=bad
    CHECK_DETAIL="EXPECTED_ARCH=${EXPECTED_ARCH:-amd64}, host=$_ca_host"
  fi
}

chk_tun_device() {
  if [ -c /dev/net/tun ]; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="host /dev/net/tun exists"
  else
    CHECK_VALUE=missing CHECK_SEV=bad CHECK_DETAIL="host /dev/net/tun is missing"
  fi
}

chk_network() {
  if check_network >/dev/null 2>&1; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="macvlan network is present and consistent"
  else
    CHECK_VALUE=broken CHECK_SEV=bad CHECK_DETAIL="macvlan network is missing or inconsistent"
  fi
}

chk_compose() {
  # shellcheck disable=SC2086 # COMPOSE_CMD may be two words
  if ( cd "$REPO_ROOT" && $COMPOSE_CMD --env-file "$ENV_FILE" config >/dev/null ) 2>/dev/null; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="Compose configuration is valid"
  else
    CHECK_VALUE=broken CHECK_SEV=bad CHECK_DETAIL="Compose configuration is invalid"
  fi
}

chk_mihomo() {
  _cm_state="$("$DOCKER_BIN" inspect -f '{{.State.Status}}' "$MIHOMO_CONTAINER" 2>/dev/null)"
  if [ "$_cm_state" = running ]; then
    _cm_restarts="$("$DOCKER_BIN" inspect -f '{{.RestartCount}}' "$MIHOMO_CONTAINER" 2>/dev/null)"
    CHECK_VALUE=running CHECK_SEV=ok CHECK_DETAIL="mihomo is running (restarts=${_cm_restarts:-0})"
  else
    CHECK_VALUE=not-running CHECK_SEV=bad CHECK_DETAIL="mihomo container state=${_cm_state:-missing}"
  fi
}

chk_tun_gateway() {
  if [ "${TUN_ENABLE:-true}" != true ]; then
    CHECK_VALUE=disabled CHECK_SEV=ok
    CHECK_DETAIL="TUN transparent gateway disabled (TUN_ENABLE=false) - reachable proxy + controller mode"
  elif mihomo_gateway_probe >/dev/null 2>&1; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="in-container TUN gateway is ready"
  else
    CHECK_VALUE=broken CHECK_SEV=bad CHECK_DETAIL="in-container TUN gateway is not ready"
  fi
}

chk_controller() {
  if mihomo_controller_probe >/dev/null 2>&1; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="controller API responds"
  else
    CHECK_VALUE=broken CHECK_SEV=bad CHECK_DETAIL="controller API does not respond"
  fi
}

chk_image_arch() {
  [ -n "${MIHOMO_IMAGE:-}" ] || return 0   # no image ref -> no record, either mode
  if arch_ok "$MIHOMO_IMAGE" >/dev/null 2>&1; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="mihomo image architecture matches the host"
  else
    CHECK_VALUE=mismatch CHECK_SEV=bad CHECK_DETAIL="mihomo image architecture does not match the host"
  fi
}

chk_dashboard() {
  if [ "$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$METACUBEXD_CONTAINER" 2>/dev/null)" = true ]; then
    CHECK_VALUE=running CHECK_SEV=ok CHECK_DETAIL="dashboard container is running"
  else
    CHECK_VALUE=not-running CHECK_SEV=warn CHECK_DETAIL="dashboard container is not running"
  fi
}

chk_update_task() {
  if [ "${UPDATE_ENABLED:-true}" != true ]; then
    CHECK_VALUE=disabled CHECK_SEV=silent
    return 0
  fi
  scheduler_task_deployed "scripts/auto_update.sh"
  case "$?" in
    0) CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="auto-update task is scheduled" ;;
    1) CHECK_VALUE=missing CHECK_SEV=warn
       case "${PLATFORM_LABEL:-dsm}" in
         dsm) CHECK_DETAIL="no scheduled task runs scripts/auto_update.sh - see: sh scripts/install_scheduler.sh" ;;
         *)   CHECK_DETAIL="no scheduled task runs scripts/auto_update.sh - see: sudo sh scripts/gateway.sh cron --apply-crontab --yes" ;;
       esac ;;
    *) CHECK_VALUE=unknown CHECK_SEV=silent ;;
  esac
}

chk_boot_task() {
  scheduler_task_deployed "scripts/setup_network.sh"
  case "$?" in
    0) CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="boot self-heal task is scheduled (setup_network.sh)" ;;
    1) CHECK_VALUE=missing CHECK_SEV=warn
       case "${PLATFORM_LABEL:-dsm}" in
         dsm) CHECK_DETAIL="no Boot-up task runs scripts/setup_network.sh - TUN/macvlan will not self-heal after a reboot" ;;
         *)   CHECK_DETAIL="no boot task runs scripts/setup_network.sh - TUN/macvlan will not self-heal after a reboot" ;;
       esac ;;
    *) CHECK_VALUE=unknown CHECK_SEV=silent ;;
  esac
}

chk_cloudflared() {
  "$DOCKER_BIN" inspect "${CF_CONTAINER_NAME:-cloudflared}" >/dev/null 2>&1 || {
    CHECK_VALUE=absent CHECK_SEV=silent
    return 0
  }
  if cloudflared_probe_connected "${CF_CONTAINER_NAME:-cloudflared}" >/dev/null 2>&1; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="cloudflared tunnel is connected"
  else
    CHECK_VALUE=down CHECK_SEV=warn
    CHECK_DETAIL="cloudflared tunnel is not connected - if the host resolvers are unreliable, set CF_DNS in .env and run: sudo sh scripts/gateway.sh update --yes"
  fi
}

chk_subscription() {
  if [ -n "$(subscription_current 2>/dev/null)" ]; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="subscription URL is stored"
  else
    CHECK_VALUE=missing CHECK_SEV=warn
    CHECK_DETAIL="no subscription URL is stored - set one: sudo sh scripts/gateway.sh modify --subscription <URL> --yes"
  fi
}

chk_host_dns() {
  _ch_out="$(resolv_conf_probe 2>/dev/null)"
  case "$?" in
    0) CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="host DNS resolvers answer" ;;
    1) CHECK_VALUE=degraded CHECK_SEV=warn
       case "${PLATFORM_LABEL:-dsm}" in
         dsm) _ch_where='DSM Control Panel > Network' ;;
         *)   _ch_where='/etc/resolv.conf or your network manager' ;;
       esac
       CHECK_DETAIL="host DNS resolver(s) not answering: ${_ch_out##* } - set reachable resolvers in $_ch_where (domestic ones on a filtered network)" ;;
    *) CHECK_VALUE=unknown CHECK_SEV=silent ;;
  esac
}

chk_geodata() {
  if geodata_cached "$CONFIG_STATE_DIR"; then
    CHECK_VALUE=cached CHECK_SEV=ok CHECK_DETAIL="geo databases are cached"
  else
    CHECK_VALUE=missing CHECK_SEV=warn
    CHECK_DETAIL="geo databases are not cached - a deploy pre-seeds them via CDN mirrors; the first start may stall without them"
  fi
}

# dns_privacy - which DNS profile the RENDERED config carries. v2 = split-
# horizon foreign-by-default (policy entries, no fallback dual-query): the
# domestic resolvers see only CN-listed domains. v1 = policy entries but the
# fallback line survives (a pre-v1.3.10 render; long-tail lookups still get
# copied to the domestic resolvers). legacy = no policy entries at all.
# The greps anchor on the rendered YAML lines exactly like
# validate_release.sh's helpers: '^  fallback:' cannot match fallback-filter
# (the colon) and comment prose never matches either.
chk_dns_privacy() {
  _cdp="$CONFIG_STATE_DIR/config.yaml"
  if [ ! -r "$_cdp" ]; then
    CHECK_VALUE=unknown CHECK_SEV=silent CHECK_DETAIL=''
    return 0
  fi
  if grep -q "^    'geosite:cn':" "$_cdp" 2>/dev/null; then
    if grep -q '^  fallback:' "$_cdp" 2>/dev/null; then
      CHECK_VALUE=v1 CHECK_SEV=warn
      CHECK_DETAIL="DNS split-horizon v1 residual - the fallback dual-query still copies long-tail lookups to the domestic resolvers"
      CHECK_HINT="      re-render onto the v2 core: sudo sh ./${INSTALLER_ENTRY:-install.sh} (Redeploy)"
    else
      CHECK_VALUE=v2 CHECK_SEV=ok
      CHECK_DETAIL="DNS privacy: split-horizon v2 (foreign-by-default) - domestic resolvers see only CN-listed domains"
    fi
  else
    CHECK_VALUE=legacy CHECK_SEV=warn
    CHECK_DETAIL="legacy DNS profile - the domestic resolvers see every hostname mihomo resolves"
    CHECK_HINT="      a stale pre-v2 render is on disk - re-render onto the v2 core: sudo sh ./${INSTALLER_ENTRY:-install.sh} (Redeploy)"
  fi
}

# ipv6_bypass - whether the LAN carries a live global-IPv6 path AROUND the
# gateway. The gateway is IPv4-only (v4 macvlan, dns ipv6:false), so router
# advertisements that hand LAN clients a global IPv6 address + resolver give
# every dual-stack device a route that never crosses the gateway: its DNS
# leaks to the ISP resolvers and IPv6-preferring sites (streaming) go direct.
# PARENT_INTERFACE is the witness: it sits on the same L2 segment as the
# clients, so a global inet6 there proves the RAs reach everyone. RA
# addresses outlive the router setting (valid-lifetime), so the warn can
# persist until leases expire or the interface bounces. Only ROUTABLE
# addresses (GUA, 2000::/3 - first hex digit 2 or 3) mean a real bypass:
# a ULA (fc00::/7) is private address space the kernel still labels
# 'scope global', announced by Matter/Thread border routers (Apple
# HomePod/TV and the like) with no route to the internet - harmless, and
# warning on it would leave doctor permanently DEGRADED on any LAN with
# a smart-home hub (observed live 2026-07-13).
chk_ipv6_bypass() {
  command -v ip >/dev/null 2>&1 || { CHECK_VALUE=unknown CHECK_SEV=silent; return 0; }
  [ -n "${PARENT_INTERFACE:-}" ] || { CHECK_VALUE=unknown CHECK_SEV=silent; return 0; }
  if ! _ci6="$(ip -6 addr show dev "$PARENT_INTERFACE" 2>/dev/null)"; then
    CHECK_VALUE=unknown CHECK_SEV=silent
    return 0
  fi
  if printf '%s\n' "$_ci6" | grep -q 'inet6 [23].*scope global'; then
    CHECK_VALUE=exposed CHECK_SEV=warn
    CHECK_DETAIL="internet-routable global IPv6 is live on $PARENT_INTERFACE - dual-stack clients resolve and route over IPv6 around the IPv4-only gateway (DNS leaks; IPv6-preferring sites go direct)"
    CHECK_HINT="      disable IPv6 (or its RA/RDNSS announcements) on the router's LAN, then renew client leases - see docs/troubleshooting.md"
  elif printf '%s\n' "$_ci6" | grep -q 'inet6 .*scope global'; then
    CHECK_VALUE=ok CHECK_SEV=ok
    CHECK_DETAIL="only private (ULA) IPv6 on $PARENT_INTERFACE - not internet-routable, no path around the gateway (Matter/Thread hubs announce these)"
  else
    CHECK_VALUE=ok CHECK_SEV=ok
    CHECK_DETAIL="no global IPv6 on $PARENT_INTERFACE - no IPv6 path around the gateway"
  fi
}

# full_proxy helpers (#46) - pure text/arithmetic, no docker.
#
# _fp_ip2n IP - dotted-quad to integer; -1 for anything that is not a
# canonical IPv4 (IPv6 sources, empty fields) so callers can skip it.
_fp_ip2n() {
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
# _fp_in_band IP BAND - BAND is one CIDR per line; 0 when IP falls inside
# any entry (64-bit shell arithmetic; BusyBox-safe).
_fp_in_band() {
  _fib_n=$(_fp_ip2n "$1")
  [ "$_fib_n" -ge 0 ] || return 1
  while IFS= read -r _fib_c; do
    [ -n "$_fib_c" ] || continue
    _fib_bn=$(_fp_ip2n "${_fib_c%%/*}")
    [ "$_fib_bn" -ge 0 ] || continue
    _fib_len=${_fib_c#*/}
    if [ "$_fib_len" -ge 32 ]; then _fib_m=4294967295
    elif [ "$_fib_len" -le 0 ]; then _fib_m=0
    else _fib_m=$(( 4294967295 - (1 << (32 - _fib_len)) + 1 )); fi
    [ $(( _fib_n & _fib_m )) -eq $(( _fib_bn & _fib_m )) ] && return 0
  done <<FIBEOF
$2
FIBEOF
  return 1
}
# _fp_is_lan IP - destinations mihomo's own GEOIP,LAN rule keeps DIRECT
# for the band, and nothing more: private (10/8, 172.16/12, 192.168/16),
# unspecified (0.0.0.0), loopback (127/8), link-local (169.254/16), and
# multicast (exactly 224.0.0.0/4 - upstream isLan() uses IsMulticast(),
# which does NOT cover 240.0.0.0/4 or the broadcast address, so those
# stay SCANNABLE here; a band flow there is judged, not exempted).
_fp_is_lan() {
  _fil_n=$(_fp_ip2n "$1")
  [ "$_fil_n" -ge 0 ] || return 1
  [ "$_fil_n" -eq 0 ] && return 0
  { [ "$_fil_n" -ge 167772160 ]  && [ "$_fil_n" -le 184549375 ]; }  && return 0
  { [ "$_fil_n" -ge 2886729728 ] && [ "$_fil_n" -le 2887778303 ]; } && return 0
  { [ "$_fil_n" -ge 3232235520 ] && [ "$_fil_n" -le 3232301055 ]; } && return 0
  { [ "$_fil_n" -ge 2130706432 ] && [ "$_fil_n" -le 2147483647 ]; } && return 0
  { [ "$_fil_n" -ge 2851995648 ] && [ "$_fil_n" -le 2852061183 ]; } && return 0
  { [ "$_fil_n" -ge 3758096384 ] && [ "$_fil_n" -le 4026531839 ]; } && return 0
  return 1
}
# _fp_conns - controller /connections JSON on stdin -> one line per
# connection: sourceIP|destinationIP|network|fp/nofp (fp = the chain
# carries 'Full-Tunnel Devices'). Connections are split onto lines FIRST (a
# multi-char RS is a gawk extension BusyBox awk lacks), then matched
# field-by-field.
_fp_conns() {
  sed 's/{"id":/\
{"id":/g' | awk '
    /"id":/ {
      src=""; dst=""; net=""; fp="nofp"
      if (match($0, /"sourceIP":"[^"]*"/))      src=substr($0, RSTART+12, RLENGTH-13)
      if (match($0, /"destinationIP":"[^"]*"/)) dst=substr($0, RSTART+17, RLENGTH-18)
      if (match($0, /"network":"[^"]*"/))       net=substr($0, RSTART+11, RLENGTH-12)
      if (match($0, /"chains":\[[^]]*"Full-Tunnel Devices"[^]]*\]/)) fp="fp"
      print src "|" dst "|" net "|" fp
    }'
}

# full_proxy - the per-device full-proxy band guard (#46). Two legs:
#   (a) STATIC PARITY (the dns_privacy stale-render pattern): the rendered
#       SRC-IP-CIDR rule set must equal the normalized FULL_PROXY_SOURCES
#       knob - a mismatch means the operator's band edit is NOT live.
#   (b) RUNTIME (controller /connections via the _pg_ctl plumbing): any
#       non-LAN flow FROM a band source whose chain lacks 'Full-Tunnel Devices'
#       breaks the band guarantee - in practice the DEC-A residual: a
#       UDP/QUIC flow whose exit node lacks UDP relay falls through the
#       SRC rule at the rule engine, and CN-listed destinations then go
#       DIRECT (browsers retry over proxied TCP).
# Ungated-tail placement (like dns_privacy/config_rejected): the static
# leg is a host-side file read that must fire even when mihomo is down;
# the runtime leg degrades to static-only when the controller is
# unreachable. The guarantee also assumes no routable LAN IPv6 - the
# ipv6_bypass check owns that condition.
chk_full_proxy() {
  _cfp_cfg="${CONFIG_STATE_DIR:-}/config.yaml"
  _cfp_knob="${FULL_PROXY_SOURCES:-}"
  _cfp_lines=""
  [ -n "${CONFIG_STATE_DIR:-}" ] && [ -r "$_cfp_cfg" ] \
    && _cfp_lines="$(sed -n "s/^  - 'SRC-IP-CIDR,\([^,]*\),Full-Tunnel Devices'\$/\1/p" "$_cfp_cfg" 2>/dev/null)"
  if [ -z "$_cfp_knob" ] && [ -z "$_cfp_lines" ]; then
    CHECK_VALUE=disabled CHECK_SEV=silent
    return 0
  fi
  if [ -n "$_cfp_knob" ] && { [ -z "${CONFIG_STATE_DIR:-}" ] || [ ! -r "$_cfp_cfg" ]; }; then
    CHECK_VALUE=unknown CHECK_SEV=silent
    return 0
  fi
  # normalize the knob exactly like the renderer: bare IP -> /32
  _cfp_want="$(printf '%s' "$_cfp_knob" | tr ',' '\n' | sed -e '/^$/d' \
    -e 's|^\([0-9.]*\)$|\1/32|')"
  if [ "$_cfp_want" != "$_cfp_lines" ]; then
    CHECK_VALUE=parity-drift CHECK_SEV=warn
    CHECK_DETAIL="the rendered SRC-IP-CIDR band differs from FULL_PROXY_SOURCES - the band edit is NOT live (stale render)"
    CHECK_HINT="      re-render: sudo sh ./${INSTALLER_ENTRY:-install.sh} (Redeploy); if the render was refused, config_rejected names the reason"
    return 0
  fi
  _cfp_n=$(printf '%s\n' "$_cfp_want" | sed '/^$/d' | wc -l | tr -d ' ')
  _cfp_raw="$(_pg_ctl /connections)" || _cfp_raw=''
  if [ -z "$_cfp_raw" ]; then
    CHECK_VALUE=ok CHECK_SEV=ok
    CHECK_DETAIL="band rules live ($_cfp_n entr(y/ies)); runtime scan skipped - controller unreachable (guarantee assumes no routable LAN IPv6 - see ipv6_bypass)"
    return 0
  fi
  _cfp_scanned=0; _cfp_viol=0; _cfp_vex=''
  while IFS='|' read -r _cfp_src _cfp_dst _cfp_net _cfp_fp; do
    [ -n "$_cfp_src" ] || continue
    _fp_in_band "$_cfp_src" "$_cfp_want" || continue
    [ -n "$_cfp_dst" ] || continue      # destination not resolved yet - unjudgeable
    _fp_is_lan "$_cfp_dst" && continue  # LAN destinations stay DIRECT by design
    _cfp_scanned=$((_cfp_scanned + 1))
    if [ "$_cfp_fp" != fp ]; then
      _cfp_viol=$((_cfp_viol + 1))
      [ -n "$_cfp_vex" ] || _cfp_vex="$(printf '%s -> %s (%s)' "$_cfp_src" "$_cfp_dst" "${_cfp_net:-?}" | tr '|' '/')"
    fi
  done <<CFPEOF
$(printf '%s' "$_cfp_raw" | _fp_conns)
CFPEOF
  if [ "$_cfp_viol" -gt 0 ]; then
    CHECK_VALUE=chain-violation CHECK_SEV=warn
    CHECK_DETAIL="$_cfp_viol of $_cfp_scanned non-LAN flow(s) from band source(s) bypass Full-Tunnel Devices (e.g. $_cfp_vex) - usually the DEC-A UDP/QUIC fallthrough: the exit node lacks UDP relay, so CN destinations go DIRECT (browsers retry over proxied TCP); the band guarantee also assumes no routable LAN IPv6 (see ipv6_bypass)"
    CHECK_HINT="      persistent TCP violations mean the rules on disk and in memory disagree - redeploy; UDP-only flags are the documented QUIC residual (an opt-in UDP block ships only if the airport's UDP proves unreliable)"
    return 0
  fi
  CHECK_VALUE=ok CHECK_SEV=ok
  CHECK_DETAIL="band rules live ($_cfp_n entr(y/ies)); $_cfp_scanned band flow(s) scanned, all riding Full-Tunnel Devices (guarantee assumes no routable LAN IPv6 - see ipv6_bypass)"
}

# proxy_groups - zero-node guard for the generated "<Country> Auto" url-test
# groups (#34, reworked for the group-model streamline #45). A regex matching
# zero provider nodes is only observable at runtime: every generated group
# renders empty-fallback REJECT, so an emptied group blackholes its traffic
# instead of silently leaking DIRECT - either way the operator finds out
# HERE. Group discovery is DYNAMIC from the controller (/group), never a
# hardcoded list; counting excludes BOTH placeholder adapters: COMPATIBLE
# (mihomo's default for an empty group - Direct-typed, the leak class) and
# REJECT (our empty-fallback). DEC-A cold-start grace: when EVERY url-test
# group is empty the provider itself has no nodes (cold start or dead
# subscription) - report that single condition with the seeding runbook
# instead of blaming the filters. default-empty = the country group the
# Exit Country selector is CURRENTLY riding has zero nodes (the routing
# default is dead - bad); any OTHER empty country group is a warn. A live
# config with no country groups (a pre-streamline render still running) is
# reported ok with a note.
#
# _pg_ctl PATH - controller GET from INSIDE the container (a macvlan child
# is unreachable from its own host); bearer token over stdin, never argv.
_pg_ctl() {
  _pg_url="http://127.0.0.1:${CONTROLLER_PORT:-9090}$1"
  if [ -n "${CONTROLLER_SECRET:-}" ]; then
    # shellcheck disable=SC2016 # $SMG_AUTH expands in the container shell
    printf 'Authorization: Bearer %s\n' "$CONTROLLER_SECRET" | \
      "$DOCKER_BIN" exec -i "$MIHOMO_CONTAINER" \
      sh -c 'IFS= read -r SMG_AUTH; exec wget -q -T 10 -O - --header "$SMG_AUTH" "$1"' _ "$_pg_url" 2>/dev/null
  else
    "$DOCKER_BIN" exec "$MIHOMO_CONTAINER" wget -q -T 10 -O - "$_pg_url" 2>/dev/null
  fi
}
# _pg_enc NAME - %XX-encode EVERY byte (over-encoding is legal per RFC 3986)
# so operator-defined CJK group names survive as a URL path segment.
_pg_enc() {
  printf '%s' "$1" | od -An -v -tx1 | tr ' ' '\n' | grep -v '^$' \
    | while IFS= read -r _pe_b; do printf '%%%s' "$_pe_b"; done
}
# _pg_real NAME - real member count: all[] minus the placeholder adapters.
_pg_real() {
  _pg_ctl "/proxies/$(_pg_enc "$1")" \
    | sed -n 's/.*"all":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' \
    | sed -n 's/^"\(.*\)"$/\1/p' | grep -v '^COMPATIBLE$' | grep -c -v '^REJECT$'
}
chk_proxy_groups() {
  _pg_raw="$(_pg_ctl /group)" || _pg_raw=''
  if [ -z "$_pg_raw" ]; then
    CHECK_VALUE=unknown CHECK_SEV=silent
    return 0
  fi
  # The routing default: the country group Exit Country is currently riding
  # ("now"). Empty when no Exit Country group exists (a pre-streamline
  # config still live) - the default-empty state is then unjudgeable.
  _pg_now="$(_pg_ctl "/proxies/$(_pg_enc 'Exit Country')" \
    | sed -n 's/.*"now":"\([^"]*\)".*/\1/p')"
  # Every "name" key in /group is a group name (member nodes appear only as
  # bare strings inside all[]). Group names may carry interior spaces (the
  # line-wise read below is space-safe) and cannot shadow the reserved
  # names skipped below (the retired PROXY/STREAMING stay skipped so a
  # pre-streamline config never miscounts its selectors as country groups).
  _pg_names="$(printf '%s' "$_pg_raw" \
    | awk -F'"name":"' '{ for (i = 2; i <= NF; i++) { n = $i; sub(/".*/, "", n); print n } }')"
  # Exit Country EXISTS but its "now" fetch failed (transient controller
  # flake): judging emptiness without the selection would misclassify
  # default-empty as country-empty (the #45 gap-panel advisory) - report
  # unknown instead of guessing; the next doctor run re-probes.
  if [ -z "$_pg_now" ] && printf '%s\n' "$_pg_names" | grep -qx 'Exit Country'; then
    CHECK_VALUE=unknown CHECK_SEV=silent
    return 0
  fi
  _pg_country_n=0; _pg_default_empty=0
  _pg_empty=''; _pg_any_real=0
  while IFS= read -r _pg_n; do
    [ -n "$_pg_n" ] || continue
    case "$_pg_n" in
      'Routing Mode'|'Streaming Unlock'|'Exit Country'|'Full-Tunnel Devices'|'Priority Nodes'|PROXY|STREAMING|GLOBAL|DIRECT|REJECT|REJECT-DROP|PASS|COMPATIBLE) continue ;;
    esac
    _pg_c="$(_pg_real "$_pg_n")"; _pg_c=${_pg_c:-0}
    [ "$_pg_c" -gt 0 ] && _pg_any_real=1
    case "$_pg_n" in
      'All Nodes') : ;;  # full pool - its emptiness IS the provider condition below
      *)
        _pg_country_n=$((_pg_country_n + 1))
        if [ "$_pg_c" -eq 0 ]; then
          if [ -n "$_pg_now" ] && [ "$_pg_n" = "$_pg_now" ]; then
            _pg_default_empty=1
          else
            # '|' frames the check record - never let a crafted name break it
            _pg_sane="$(printf '%s' "$_pg_n" | tr '|' '/')"
            _pg_empty="${_pg_empty:+$_pg_empty, }$_pg_sane"
          fi
        fi ;;
    esac
  done <<PGEOF
$_pg_names
PGEOF
  if [ "$_pg_any_real" -eq 0 ]; then
    CHECK_VALUE=provider-empty CHECK_SEV=warn
    CHECK_DETAIL="every url-test group is empty - the provider has no nodes yet (cold start or dead subscription), not a filter problem"
    CHECK_HINT="      seed the provider from the host: sudo sh scripts/seed_provider.sh - see docs/troubleshooting.md (Provider has no nodes)"
    return 0
  fi
  if [ "$_pg_country_n" -eq 0 ]; then
    CHECK_VALUE=ok CHECK_SEV=ok
    CHECK_DETAIL="no country groups visible from the controller (a pre-streamline config is still live; redeploy renders the Exit Country model)"
    return 0
  fi
  if [ "$_pg_default_empty" -eq 1 ]; then
    _pg_now_sane="$(printf '%s' "$_pg_now" | tr '|' '/')"
    CHECK_VALUE=default-empty CHECK_SEV=bad
    CHECK_DETAIL="the Exit Country selection '$_pg_now_sane' has NO nodes - its COUNTRY_GROUPS regex matches no provider node, so default-route traffic is REJECTED (fail closed)${_pg_empty:+; other empty country group(s): $_pg_empty}"
    CHECK_HINT="      tune the COUNTRY_GROUPS regex(es) in .env and redeploy: sudo sh ./${INSTALLER_ENTRY:-install.sh} (Redeploy); stopgap: pick another country in the dashboard Exit Country selector"
    return 0
  fi
  if [ -n "$_pg_empty" ]; then
    CHECK_VALUE=country-empty CHECK_SEV=warn
    CHECK_DETAIL="country group(s) match no provider node: $_pg_empty - selecting them REJECTs (fail closed)"
    CHECK_HINT="      tune the COUNTRY_GROUPS regex(es) in .env to your airport's node names, then redeploy - see docs/configuration.md"
    return 0
  fi
  CHECK_VALUE=ok CHECK_SEV=ok
  CHECK_DETAIL="country groups all have real nodes ($_pg_country_n group(s)${_pg_now:+; Exit Country riding '$(printf '%s' "$_pg_now" | tr '|' '/')'})"
}

# config_rejected - consumer of the entrypoint gate's rejection marker (#38,
# the #36 loudness rider). scripts/mihomo_entrypoint.sh keeps the last-good
# config running when a render or `mihomo -t` fails and records the rejection
# in $CONFIG_STATE_DIR/.config.yaml.rejected (0600, secrets scrubbed, removed
# again on the next green swap). A present marker means the operator's LAST
# EDIT IS SILENTLY NOT LIVE while everything else reports green - an
# operator-must-act state (bad), mirroring proxy_groups default-empty. The
# value mirrors the marker's own frozen reason token (render-failed |
# config-test-failed), degrading to 'rejected' when the first line is
# unparseable; absence (or no config dir yet) is health. Host-side file read
# only - no docker exec, no controller call - so it also fires when mihomo
# itself is crash-looping (first-boot hard fail), which is why it lives in
# checks_run's UNGATED tail, not behind the mihomo-running gate.
chk_config_rejected() {
  _crj_f="${CONFIG_STATE_DIR:-}/.config.yaml.rejected"
  if [ -z "${CONFIG_STATE_DIR:-}" ] || [ ! -f "$_crj_f" ]; then
    CHECK_VALUE=ok CHECK_SEV=ok
    CHECK_DETAIL="no rejected render - the live config.yaml is the last one that passed the config test"
    return 0
  fi
  # first two lines only; sanitize '|' so a crafted marker can never break
  # the record framing (the same rule proxy_groups applies to group names)
  _crj_reason="$(sed -n '1s/^reason: //p' "$_crj_f" 2>/dev/null | tr '|' '/')"
  _crj_time="$(sed -n '2s/^time: //p' "$_crj_f" 2>/dev/null | tr '|' '/')"
  case "$_crj_reason" in
    render-failed|config-test-failed) CHECK_VALUE="$_crj_reason" ;;
    *) CHECK_VALUE=rejected ;;
  esac
  CHECK_SEV=bad
  CHECK_DETAIL="the last config render was REJECTED (${_crj_reason:-unreadable reason}${_crj_time:+, $_crj_time}) - mihomo is running on the PREVIOUS config and the latest .env/subscription edit is NOT applied"
  CHECK_HINT="      read the scrubbed marker: cat <data-dir>/config/.config.yaml.rejected - fix the named value in .env, then redeploy: sudo sh ./${INSTALLER_ENTRY:-install.sh} (Redeploy); a green render clears this automatically"
  return 0
}

# _c_emit NAME - run chk_NAME and print its record (plus any hint lines).
# Leaves CHECK_VALUE/CHECK_SEV set for the caller's gate logic.
_c_emit() {
  CHECK_VALUE='' CHECK_SEV=ok CHECK_DETAIL='' CHECK_HINT=''
  "chk_$1"
  [ -n "$CHECK_VALUE" ] || return 0
  printf '%s|%s|%s|%s\n' "$1" "$CHECK_VALUE" "$CHECK_SEV" "$CHECK_DETAIL"
  if [ -n "$CHECK_HINT" ]; then
    printf '%s\n' "$CHECK_HINT" | while IFS= read -r _ce_h; do
      printf '#hint|%s\n' "$_ce_h"
    done
  fi
  return 0
}

# checks_run - walk the table in contract order, applying the gates. THE table:
# adding a check = one chk_* function above + one _c_emit line here (plus its
# name in scripts/cli/spec.yaml's json_output notes, en+zh - CI enforces that).
checks_run() {
  _cr_broken=0
  for _cr_n in env docker arch tun_device network; do
    _c_emit "$_cr_n"
    if [ "$CHECK_SEV" = bad ]; then _cr_broken=1; fi
  done
  if [ "$_cr_broken" = 0 ]; then
    _c_emit compose
    _c_emit mihomo
    if [ "$CHECK_VALUE" = running ]; then
      _c_emit tun_gateway
      _c_emit controller
      _c_emit image_arch
      _c_emit proxy_groups
    fi
    _c_emit dashboard
    _c_emit update_task
    _c_emit boot_task
    _c_emit cloudflared
  else
    printf '%s\n' 'mihomo|unknown|silent|'
  fi
  _c_emit subscription
  _c_emit host_dns
  _c_emit geodata
  _c_emit dns_privacy
  _c_emit config_rejected
  _c_emit ipv6_bypass
  _c_emit full_proxy
}
