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

chk_env() {
  if [ -f "$ENV_FILE" ] && dotenv_load "$ENV_FILE" >/dev/null 2>&1; then
    CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL=".env parsed safely"
    return 0
  fi
  CHECK_VALUE=broken CHECK_SEV=bad
  if [ ! -f "$ENV_FILE" ]; then
    CHECK_DETAIL=".env is missing: $ENV_FILE"
    CHECK_HINT="      the release tree is unpacked but not configured - run: sudo sh ./install.sh"
    if _ce_legacy="$(legacy_install_detect 2>/dev/null)"; then
      CHECK_HINT="$CHECK_HINT
      a legacy flat install exists at $_ce_legacy - import its state first: sudo sh scripts/migrate_legacy.sh --from $_ce_legacy --yes"
    fi
  else
    CHECK_DETAIL=".env is present but does not parse - fix the reported line or re-run: sudo sh ./install.sh"
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
       CHECK_DETAIL="no scheduled task runs scripts/auto_update.sh - see: sh scripts/install_scheduler.sh" ;;
    *) CHECK_VALUE=unknown CHECK_SEV=silent ;;
  esac
}

chk_boot_task() {
  scheduler_task_deployed "scripts/setup_network.sh"
  case "$?" in
    0) CHECK_VALUE=ok CHECK_SEV=ok CHECK_DETAIL="boot self-heal task is scheduled (setup_network.sh)" ;;
    1) CHECK_VALUE=missing CHECK_SEV=warn
       CHECK_DETAIL="no Boot-up task runs scripts/setup_network.sh - TUN/macvlan will not self-heal after a reboot" ;;
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
       CHECK_DETAIL="host DNS resolver(s) not answering: ${_ch_out##* } - set reachable resolvers in DSM Control Panel > Network (domestic ones on a filtered network)" ;;
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
      CHECK_HINT="      re-render onto the v2 core: sudo sh ./install.sh (Redeploy)"
    else
      CHECK_VALUE=v2 CHECK_SEV=ok
      CHECK_DETAIL="DNS privacy: split-horizon v2 (foreign-by-default) - domestic resolvers see only CN-listed domains"
    fi
  else
    CHECK_VALUE=legacy CHECK_SEV=warn
    CHECK_DETAIL="legacy DNS profile - the domestic resolvers see every hostname mihomo resolves"
    CHECK_HINT="      the redeploy wizard offers the split-horizon upgrade: sudo sh ./install.sh (Redeploy)"
  fi
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
}
