#!/bin/sh
# gateway.sh - the non-interactive, API-style command surface for the Mihomo
# transparent-proxy gateway. Other procedures (DSM Task Scheduler, scripts, CI)
# call these verbs directly; the interactive installer (install.sh) remains the
# TTY front-end over the same scripts/lib functions.
#
# Usage: gateway.sh <verb> [options]
#
# Verbs:
#   deploy     bring the stack up from the saved .env (images derived if absent)
#   redeploy   deploy strictly from the saved, complete .env
#   modify     change one thing, then re-apply: --network | --images
#              [--mihomo-tag T --metacubexd-tag T] | --subscription URL
#   cron       persist the auto-update schedule: --time HH:MM | --schedule EXPR,
#              --tz TZ, --enable | --disable; --apply-crontab writes /etc/crontab
#   status     read-only deployment state (--json for one machine-readable object)
#   doctor     read-only diagnostics (wraps scripts/doctor.sh; --json, --egress)
#   update     run the unattended updater (execs scripts/auto_update.sh;
#              --dry-run and --force pass through), or manage generic targets:
#              --list-targets | --last (read-only) | --enable N | --disable N
#
# Guardrails (authoritative reference: docs/cli.md, generated from
# scripts/cli/spec.yaml - keep this header aligned when the spec changes):
#   - Mutating verbs (deploy, redeploy, modify, update, cron --apply-crontab)
#     require an explicit --yes; --dry-run is exempt and mutates nothing.
#   - Mutating verbs require root (exit 6 otherwise); status/doctor do not.
#   - Secrets are NEVER accepted on argv (visible in ps) - set them in .env.
#   - --json is supported on the read-only verbs only: exactly one JSON object
#     on stdout, every log line to the file + stderr.
#
# Exit codes: 0 ok | 2 partial | 3 config/preflight | 4 locked | 5 login |
#             6 needs-root | 7 needs---yes  (0/2/3/4/5 keep their documented
#             DSM Task Scheduler meanings; 6/7 are new, never repurposed).
#
# POSIX /bin/sh, BusyBox-safe (DSM). Sources the UI-free runtime libraries in
# scripts/lib plus scripts/installer/envedit.sh (a data-only module: .env
# read/write + image-ref derivation; its error channel is the ui_error hook,
# routed to log_error here). It NEVER sources ui.sh or i18n.sh.

# Survive cron's stripped PATH on DSM. APPEND (not prepend) so a caller's PATH
# keeps priority - the CLI test harness relies on PATH-injected stubs.
PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

SELF_DIR="${GATEWAY_SELF_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/lib/common.sh"
# shellcheck source=scripts/lib/notify.sh
. "$SELF_DIR/lib/notify.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SELF_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/compose.sh
. "$SELF_DIR/lib/compose.sh"
# shellcheck source=scripts/lib/geodata.sh
. "$SELF_DIR/lib/geodata.sh"
# shellcheck source=scripts/lib/cloudflared.sh
. "$SELF_DIR/lib/cloudflared.sh"
# shellcheck source=scripts/lib/network.sh
. "$SELF_DIR/lib/network.sh"
# shellcheck source=scripts/lib/lifecycle.sh
. "$SELF_DIR/lib/lifecycle.sh"
# shellcheck source=scripts/lib/scheduler.sh
. "$SELF_DIR/lib/scheduler.sh"
# shellcheck source=scripts/lib/resolve.sh
. "$SELF_DIR/lib/resolve.sh"
# shellcheck source=scripts/lib/checks.sh
. "$SELF_DIR/lib/checks.sh"
# shellcheck source=scripts/lib/targets.sh
. "$SELF_DIR/lib/targets.sh"
# help.sh is GENERATED from scripts/cli/spec.yaml (usage + gw_help) - the CLI
# contract gate (scripts/ci/cli_contract_check.py) keeps it byte-fresh.
# shellcheck source=scripts/lib/help.sh
. "$SELF_DIR/lib/help.sh"
# envedit.sh reports errors through ui_error; headless callers route it to the log.
ui_error() { log_error "$@"; }
# shellcheck source=scripts/installer/envedit.sh
. "$SELF_DIR/installer/envedit.sh"

# usage()/gw_help() come from the generated scripts/lib/help.sh above.

_gw_fail() { # CODE MESSAGE...
  _gwf_rc="$1"; shift
  log_error "$*"
  exit "$_gwf_rc"
}

_gw_jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

GW_CHECKS=''
_gw_check_add() { # NAME VALUE
  GW_CHECKS="${GW_CHECKS:+$GW_CHECKS,}{\"name\":\"$(_gw_jesc "$1")\",\"value\":\"$(_gw_jesc "$2")\"}"
}

# stack_state for headless callers (the interactive twin lives in
# scripts/installer/preflight.sh): deployed | partial | fresh.
_gw_stack_state() {
  _gss_d="$(_net_docker)"
  if [ "$("$_gss_d" inspect -f '{{.State.Running}}' "$MIHOMO_CONTAINER" 2>/dev/null)" = "true" ]; then
    echo deployed; return 0
  fi
  if network_exists 2>/dev/null || "$_gss_d" inspect "$MIHOMO_CONTAINER" >/dev/null 2>&1; then
    echo partial; return 0
  fi
  echo fresh
}

# --- deploy pipeline stages (each UI-free; overridable in tests) ---------------

_gw_load_config() {
  [ -f "$ENV_FILE" ] || _gw_fail "$EXIT_CONFIG" \
    ".env not found at $ENV_FILE - run 'sh ./${INSTALLER_ENTRY:-install.sh}' once, or create it from .env.example"
  load_env
  if [ "$GW_DRY_RUN" = 0 ]; then
    if [ -n "$GW_IFACE" ]; then
      env_set PARENT_INTERFACE "$GW_IFACE" || return "$EXIT_CONFIG"
      PARENT_INTERFACE="$GW_IFACE"; export PARENT_INTERFACE
    fi
    [ -z "$GW_MIHOMO_TAG" ] || env_set MIHOMO_TAG "$GW_MIHOMO_TAG" || return "$EXIT_CONFIG"
    [ -z "$GW_METACUBEXD_TAG" ] || env_set METACUBEXD_TAG "$GW_METACUBEXD_TAG" || return "$EXIT_CONFIG"
  fi
  if [ -z "${MIHOMO_IMAGE:-}" ] || [ -z "${METACUBEXD_IMAGE:-}" ] || [ "$GW_DO_IMG" = 1 ]; then
    if [ "$GW_VERB" = redeploy ]; then
      _gw_fail "$EXIT_CONFIG" "saved .env lacks resolved image refs - run 'gateway.sh deploy' or the installer"
    fi
    if [ "$GW_DRY_RUN" = 1 ]; then
      # Plan only: compute the refs without persisting anything. The CLI tag
      # wins over the saved one - the real run persists it first, so the plan
      # must preview the SAME ref the real run would deploy.
      MIHOMO_TAG="${GW_MIHOMO_TAG:-$(env_get MIHOMO_TAG 2>/dev/null || echo latest)}"
      METACUBEXD_TAG="${GW_METACUBEXD_TAG:-$(env_get METACUBEXD_TAG 2>/dev/null || echo latest)}"
      MIHOMO_IMAGE="$(derive_ref mihomo "$MIHOMO_TAG")" \
        || _gw_fail "$EXIT_CONFIG" "cannot derive MIHOMO_IMAGE (check REGISTRY_MODE/DOCKER_REGISTRY/ACR_NAMESPACE)"
      METACUBEXD_IMAGE="$(derive_ref metacubexd "$METACUBEXD_TAG")" \
        || _gw_fail "$EXIT_CONFIG" "cannot derive METACUBEXD_IMAGE"
    else
      resolve_images || _gw_fail "$EXIT_CONFIG" "could not derive image refs from the saved settings"
      resolve_update_images || log_warn "UPDATE_IMAGES was not refreshed (image refs unresolved)"
    fi
  fi
  for _k in ROUTER_IP SUBNET_CIDR MIHOMO_IP; do
    eval "_v=\${$_k:-}"
    [ -n "$_v" ] || _gw_fail "$EXIT_CONFIG" "$_k is not set in $ENV_FILE"
  done
  # Under 'modify --subscription --dry-run' the file is deliberately not
  # written yet; validate the PENDING value so the plan reflects the state
  # the real run would produce (and never tells the operator to run the
  # exact command they are running).
  _gw_sub=""
  if [ -n "${GW_SUB:-}" ]; then
    _gw_sub="$(resolve_subscription_url "$GW_SUB" 2>/dev/null)" || _gw_sub=""
  fi
  [ -n "$_gw_sub" ] || _gw_sub="$(subscription_current)"
  [ -n "$_gw_sub" ] || _gw_fail "$EXIT_CONFIG" \
    "no subscription URL stored at $SUBSCRIPTION_FILE - use 'gateway.sh modify --subscription URL'"
  resolve_subscription_url "$_gw_sub" >/dev/null \
    || _gw_fail "$EXIT_CONFIG" "stored subscription URL is not an http(s) URL"
  return 0
}

_gw_preflight() {
  detect_compose || return "$EXIT_CONFIG"
  wait_for_docker_ready || return "$EXIT_CONFIG"
  check_arch_expectation || return "$EXIT_CONFIG"
  compose_config_check || return "$EXIT_CONFIG"
  return 0
}

_gw_plan_cleanup() {
  lifecycle_inspect
  if ! resolve_cleanup_plan "$GW_CLEAN_C" "$GW_CLEAN_N"; then
    case "${RESOLVE_CLEANUP_REASON:-}" in
      ambiguous)        log_error "existing containers are not verifiably ours - clean them up manually first" ;;
      foreign_project)  log_error "existing containers belong to Compose project '${LIFECYCLE_COMPOSE_PROJECT:-?}' (an older or legacy deployment) - pass --cleanup-containers auto to replace them, or remove them manually first" ;;
      drift)            log_error "network '$TPROXY_NETWORK' exists with a different configuration - pass --cleanup-network auto" ;;
      unrelated)        log_error "network '$TPROXY_NETWORK' has attachments that are not ours - detach them manually first" ;;
      needs_containers) log_error "removing the network needs container cleanup too - pass --cleanup-containers auto" ;;
      *)                log_error "invalid cleanup mode (use preserve or auto)" ;;
    esac
    return "$EXIT_CONFIG"
  fi
  if [ "$CLEANUP_CONTAINERS_MODE" = manual ] || [ "$CLEANUP_NETWORK_MODE" = manual ]; then
    log_error "manual cleanup is interactive-only here - run these commands, then re-run:"
    lifecycle_print_container_commands >&2
    lifecycle_print_network_commands >&2
    return "$EXIT_CONFIG"
  fi
  return 0
}

_gw_prepare() {
  PREVIOUS_MIHOMO_IMAGE_ID="$(running_image_id "$MIHOMO_CONTAINER")"
  PREVIOUS_METACUBEXD_IMAGE_ID="$(running_image_id "$METACUBEXD_CONTAINER")"
  if [ "${REGISTRY_MODE:-acr}" = "acr" ]; then
    acr_login || return "$EXIT_LOGIN"
  fi
  for _img in "$MIHOMO_IMAGE" "$METACUBEXD_IMAGE"; do
    [ -n "$_img" ] || continue
    pull_image "$_img" || return "$EXIT_CONFIG"
    arch_ok "$_img" || return "$EXIT_CONFIG"
  done
  # Validate the rendered configuration against the pulled engine BEFORE any
  # teardown (the same fail-before-mutation guarantee flow_deploy.sh gives).
  _gw_cfg="$(mktemp -d "${TMPDIR:-/tmp}/smg-config.XXXXXX" 2>/dev/null)" \
    || { log_error "could not create a private temporary config directory"; return "$EXIT_CONFIG"; }
  chmod 700 "$_gw_cfg" 2>/dev/null || true
  if ! cp "$REPO_ROOT/config/config.template.yaml" "$SUBSCRIPTION_FILE" "$_gw_cfg/"; then
    rm -rf "$_gw_cfg"; log_error "could not stage the Mihomo configuration"; return "$EXIT_CONFIG"
  fi
  if ! MIHOMO_CONFIG_DIR="$_gw_cfg" sh "$REPO_ROOT/scripts/render_config.sh" >>"${LOG_FILE:-/dev/null}" 2>&1; then
    rm -rf "$_gw_cfg"; log_error "failed to render config/config.yaml (check subscription + DNS values)"; return "$EXIT_CONFIG"
  fi
  if ! "$DOCKER_BIN" run --rm --entrypoint /mihomo \
      -v "$_gw_cfg/config.yaml:/root/.config/mihomo/config.yaml:ro" \
      "$MIHOMO_IMAGE" -t -d /root/.config/mihomo >>"${LOG_FILE:-/dev/null}" 2>&1; then
    rm -rf "$_gw_cfg"; log_error "the pulled Mihomo image rejected the rendered configuration"; return "$EXIT_CONFIG"
  fi
  rm -rf "$_gw_cfg"
  mihomo_auto_redirect_probe "$MIHOMO_IMAGE" || return "$EXIT_CONFIG"
  # Pre-seed the geo databases (non-fatal: mihomo can still self-download,
  # but on a filtered network that fetch can stall the first start).
  if ! geodata_preseed "$CONFIG_STATE_DIR"; then
    log_warn "geo databases could not be pre-seeded; the first start may stall while mihomo fetches them"
  fi
  return 0
}

_gw_apply_cleanup() {
  lifecycle_inspect
  case "${CLEANUP_CONTAINERS_MODE:-preserve}" in
    auto)
      [ "${LIFECYCLE_CONTAINERS_PRESENT:-0}" = 1 ] && GW_MUTATED=1
      lifecycle_remove_containers || return "$EXIT_PARTIAL" ;;
    *)
      if [ "$LIFECYCLE_CONTAINERS_PRESENT" = 1 ] && [ "$LIFECYCLE_CONTAINERS_SAFE" != 1 ]; then
        log_error "existing containers are not verifiably ours"; return "$EXIT_CONFIG"
      fi ;;
  esac
  lifecycle_inspect
  case "${CLEANUP_NETWORK_MODE:-preserve}" in
    auto)
      [ "${LIFECYCLE_NETWORK_PRESENT:-0}" = 1 ] && GW_MUTATED=1
      lifecycle_remove_network || return "$EXIT_PARTIAL" ;;
    *)
      if [ "$LIFECYCLE_NETWORK_PRESENT" = 1 ] && [ "$LIFECYCLE_NETWORK_MATCHES" != 1 ]; then
        log_error "network '$TPROXY_NETWORK' exists with a different configuration"; return "$EXIT_CONFIG"
      fi ;;
  esac
  return 0
}

_gw_create_network() {
  _gcn_pi="${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}"
  [ -n "$_gcn_pi" ] || { log_error "no parent interface (set PARENT_INTERFACE in .env or pass --interface)"; return "$EXIT_CONFIG"; }
  warn_if_ovs_parent "$_gcn_pi"
  validate_network_plan "$_gcn_pi" "$SUBNET_CIDR" "$ROUTER_IP" "$MIHOMO_IP" \
    || { log_error "network settings are internally inconsistent (interface/subnet/router/MIHOMO_IP)"; return "$EXIT_CONFIG"; }
  # Non-interactive conflict guard: a taken MIHOMO_IP is a hard stop here (the
  # interactive wizard would offer an override; headless callers change .env).
  if ! mihomo_owns_ip "$MIHOMO_IP"; then
    # ip_in_use: 0 = taken (refuse), 1 = free, 2 = unverifiable (proceed).
    if ip_in_use "$MIHOMO_IP"; then
      log_error "MIHOMO_IP $MIHOMO_IP is already in use on the LAN - pick another in .env"
      return "$EXIT_CONFIG"
    fi
  fi
  ensure_tun_device || return "$EXIT_CONFIG"
  recreate_macvlan "$_gcn_pi" || { log_error "could not (re)create '$TPROXY_NETWORK' on $_gcn_pi"; return "$EXIT_CONFIG"; }
  return 0
}

_gw_deploy_stack() {
  if ! compose_recreate; then
    log_error "docker compose up failed"
    if rollback_compose "${PREVIOUS_MIHOMO_IMAGE_ID:-}" "${PREVIOUS_METACUBEXD_IMAGE_ID:-}" && health_gate; then
      log_warn "previous images restored and healthy"
    else
      log_error "automatic rollback was unavailable or did not restore health"
    fi
    return "$EXIT_PARTIAL"
  fi
  if health_gate; then
    return 0
  fi
  log_error "health gate failed after deploy"
  if rollback_compose "${PREVIOUS_MIHOMO_IMAGE_ID:-}" "${PREVIOUS_METACUBEXD_IMAGE_ID:-}" && health_gate; then
    log_warn "previous images restored and healthy"
  else
    log_error "automatic rollback was unavailable or did not restore health"
  fi
  return "$EXIT_PARTIAL"
}

_gw_report() {
  _gwr_pi="${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}")}"
  _gwr_nas="$(_iface_ipv4 "$_gwr_pi" 2>/dev/null)"
  if [ -z "$_gwr_nas" ]; then
    # Platform-conditional placeholder (#50): unset PLATFORM_LABEL = DSM text.
    case "${PLATFORM_LABEL:-dsm}" in
      dsm) _gwr_nas='<NAS-IP>' ;;
      *)   _gwr_nas='<host-IP>' ;;
    esac
  fi
  log_info "gateway deployed: dashboard http://$_gwr_nas:${WEB_UI_PORT:-8080}  backend ${MIHOMO_IP}:${CONTROLLER_PORT:-9090}"
  printf 'dashboard: http://%s:%s\n' "$_gwr_nas" "${WEB_UI_PORT:-8080}"
  printf 'backend:   %s:%s\n' "$MIHOMO_IP" "${CONTROLLER_PORT:-9090}"
  return 0
}

gateway_deploy() {
  _gw_load_config || return $?
  _gw_preflight || return $?
  _gw_plan_cleanup || return $?
  if [ "${GW_DRY_RUN:-0}" = 1 ]; then
    log_info "dry-run: no changes made"
    printf 'plan: images  %s | %s\n' "${MIHOMO_IMAGE:-?}" "${METACUBEXD_IMAGE:-?}"
    printf 'plan: cleanup containers=%s network=%s\n' "${CLEANUP_CONTAINERS_MODE:-preserve}" "${CLEANUP_NETWORK_MODE:-preserve}"
    printf 'plan: network %s parent=%s subnet=%s router=%s mihomo=%s\n' \
      "$TPROXY_NETWORK" "${PARENT_INTERFACE:-auto}" "${SUBNET_CIDR:-?}" "${ROUTER_IP:-?}" "${MIHOMO_IP:-?}"
    return 0
  fi
  _gw_prepare || return $?
  _gw_apply_cleanup || return $?
  if ! _gw_create_network; then
    # Exit 3 is documented as 'nothing changed'. Once auto-cleanup has torn
    # the old stack down, a network failure leaves the gateway DOWN - report
    # partial (2) and say so, never 'nothing changed'.
    if [ "${GW_MUTATED:-0}" = 1 ]; then
      log_error "the previous deployment was already removed by cleanup and the network step failed - the gateway is DOWN until a deploy succeeds"
      return "$EXIT_PARTIAL"
    fi
    return "$EXIT_CONFIG"
  fi
  _gw_deploy_stack || return $?
  _gw_report
}

gateway_modify() {
  if [ "$GW_DO_NET" = 0 ] && [ "$GW_DO_IMG" = 0 ] && [ -z "$GW_SUB" ]; then
    _gw_fail "$EXIT_CONFIG" "modify needs one of --network, --images, --subscription URL"
  fi
  # The tag flags are documented as 'with --images'; persisting them on any
  # other modify would silently desync MIHOMO_TAG from the deployed ref.
  if [ "$GW_DO_IMG" = 0 ] && [ -n "$GW_MIHOMO_TAG$GW_METACUBEXD_TAG" ]; then
    _gw_fail "$EXIT_CONFIG" "--mihomo-tag/--metacubexd-tag require --images"
  fi
  if [ -n "$GW_SUB" ]; then
    if ! _gwm_url="$(resolve_subscription_url "$GW_SUB")"; then
      _gw_fail "$EXIT_CONFIG" "--subscription value is not an http(s) URL"
    fi
    if [ "$GW_DRY_RUN" = 0 ]; then
      printf '%s\n' "$_gwm_url" > "$SUBSCRIPTION_FILE" \
        || _gw_fail "$EXIT_CONFIG" "cannot write $SUBSCRIPTION_FILE"
      chmod 600 "$SUBSCRIPTION_FILE" 2>/dev/null || true
      log_info "subscription URL updated"
    else
      log_info "dry-run: would write the cleaned subscription URL"
    fi
  fi
  gateway_deploy
}

# update --list-targets: the enrollment list plus each record's live
# eligibility (read-only; discovery warnings explain every exclusion).
gateway_update_list() {
  targets_validate || return "$EXIT_CONFIG"
  if [ ! -f "$TARGETS_FILE" ] || ! grep -q '[^[:space:]]' "$TARGETS_FILE" 2>/dev/null; then
    printf 'no generic targets enrolled (%s)\n' "$TARGETS_FILE"
    return "$EXIT_OK"
  fi
  [ -f "$ENV_FILE" ] && dotenv_load "$ENV_FILE" >/dev/null 2>&1
  _gul_eligible=""
  _gul_docker=0
  if detect_compose >/dev/null 2>&1; then
    _gul_docker=1
    # Exclusion reasons go to stderr for the operator; stdout is the data.
    _gul_eligible="$(targets_discover)"
  fi
  printf 'enrolled generic targets (%s):\n' "$TARGETS_FILE"
  while IFS='|' read -r _gul_name _gul_strategy _gul_probe || [ -n "$_gul_name" ]; do
    [ -n "$_gul_name" ] || continue
    case "$_gul_name" in \#*) continue ;; esac
    if [ "$_gul_docker" = 0 ]; then
      _gul_state='unknown (docker unavailable)'
    else
      _gul_state=excluded
      case "$_gul_eligible" in "$_gul_name|"*|*"
$_gul_name|"*) _gul_state=eligible ;; esac
    fi
    printf '  %s  strategy=%s  probe=%s  [%s]\n' \
      "$_gul_name" "${_gul_strategy:-recreate}" "${_gul_probe:-none}" "$_gul_state"
  done <"$TARGETS_FILE"
  return "$EXIT_OK"
}

# update --last: the outcome of the most recent updater run (read-only).
gateway_update_last() {
  _gulr_file="$GATEWAY_DATA_DIR/state/last-run.json"
  if [ ! -s "$_gulr_file" ]; then
    printf 'no updater run recorded yet (%s)\n' "$_gulr_file"
    return "$EXIT_OK"
  fi
  printf 'last updater run (%s):\n  %s\n' "$_gulr_file" "$(cat "$_gulr_file")"
  return "$EXIT_OK"
}

# The last-run record verbatim for status --json ("null" before the first run;
# the file is a single JSON object written atomically by auto_update.sh).
_gw_last_update_json() {
  _glu_file="$GATEWAY_DATA_DIR/state/last-run.json"
  if [ -s "$_glu_file" ]; then
    tr -d '\n' <"$_glu_file"
  else
    printf 'null'
  fi
}

gateway_status() {
  _gws_rc=0
  _gws_ok=true
  GW_CHECKS=''
  # status is the verb monitoring systems poll: it must emit its one object
  # even when .env is malformed (load_env would exit 3 with no output), so
  # it degrades to a 'broken' check like doctor does.
  if [ ! -f "$ENV_FILE" ]; then
    _gw_check_add env missing
  elif dotenv_load "$ENV_FILE" >/dev/null 2>&1; then
    _gw_check_add env parsed
  else
    _gw_check_add env broken
    _gws_rc="$EXIT_PARTIAL"; _gws_ok=false
  fi
  if detect_compose >/dev/null 2>&1 && "$DOCKER_BIN" info >/dev/null 2>&1; then
    _gw_check_add docker available
  else
    _gw_check_add docker unavailable
    _gws_rc="$EXIT_PARTIAL"; _gws_ok=false
  fi
  lifecycle_inspect 2>/dev/null
  _gws_state="$(_gw_stack_state)"
  _gw_check_add mihomo_container "$LIFECYCLE_MIHOMO_STATUS"
  _gw_check_add ui_container "$LIFECYCLE_UI_STATUS"
  if [ "$LIFECYCLE_NETWORK_PRESENT" != 1 ]; then
    _gw_check_add network absent
  elif [ "$LIFECYCLE_NETWORK_MATCHES" = 1 ]; then
    _gw_check_add network matches
  else
    _gw_check_add network drifted
  fi
  if [ -n "$(subscription_current 2>/dev/null)" ]; then
    _gw_check_add subscription present
  else
    _gw_check_add subscription missing
  fi
  _gw_check_add tun_enable "${TUN_ENABLE:-true}"

  _gws_pi="${PARENT_INTERFACE:-$(detect_parent_interface "${ROUTER_IP:-}" 2>/dev/null)}"
  _gws_nas="$(_iface_ipv4 "$_gws_pi" 2>/dev/null)"
  if [ -z "$_gws_nas" ]; then
    case "${PLATFORM_LABEL:-dsm}" in
      dsm) _gws_nas='<NAS-IP>' ;;
      *)   _gws_nas='<host-IP>' ;;
    esac
  fi
  _gws_url="http://$_gws_nas:${WEB_UI_PORT:-8080}"

  if [ "$GW_JSON" = 1 ]; then
    printf '{"verb":"status","ok":%s,"exit_code":%s,"stack_state":"%s","mihomo_ip":"%s","dashboard_url":"%s","checks":[%s],"last_update":%s}\n' \
      "$_gws_ok" "$_gws_rc" "$(_gw_jesc "$_gws_state")" "$(_gw_jesc "${MIHOMO_IP:-}")" \
      "$(_gw_jesc "$_gws_url")" "$GW_CHECKS" "$(_gw_last_update_json)"
  else
    printf 'state:     %s\n' "$_gws_state"
    printf 'mihomo:    %s (%s)\n' "$LIFECYCLE_MIHOMO_STATUS" "${MIHOMO_IP:-no ip configured}"
    printf 'dashboard: %s\n' "$_gws_url"
    printf 'tun:       %s\n' "${TUN_ENABLE:-true}"
    if [ -s "$GATEWAY_DATA_DIR/state/last-run.json" ]; then
      printf 'update:    %s\n' "$(cat "$GATEWAY_DATA_DIR/state/last-run.json")"
    else
      printf 'update:    never ran\n'
    fi
  fi
  return "$_gws_rc"
}

gateway_doctor() {
  if [ "$GW_JSON" != 1 ]; then
    if [ "$GW_EGRESS" = 1 ]; then
      exec sh "$SELF_DIR/doctor.sh" --egress
    fi
    exec sh "$SELF_DIR/doctor.sh"
  fi
  [ "$GW_EGRESS" = 0 ] || log_warn "--egress is only probed in human mode (doctor.sh); ignored under --json"
  # The checks live in lib/checks.sh (#30) - one table, two renderers; the
  # human twin is doctor.sh's render_human. --json must never report ok=true
  # for a state the human report calls BROKEN: both renderers derive their
  # exit code from the same per-record severity (bad -> EXIT_CONFIG, warn ->
  # EXIT_PARTIAL, silent -> none), so the classification cannot drift.
  checks_run | render_json
}

# render_json - the --json renderer for checks_run's records: emits the one
# {"verb":"doctor",...} object and returns the doctor exit code. Runs as the
# last pipeline stage (a subshell under BusyBox ash), so it owns both.
render_json() {
  GW_CHECKS=''
  _rj_broken=0; _rj_degraded=0
  while IFS='|' read -r _rj_n _rj_v _rj_s _rj_d; do
    case "$_rj_n" in '#hint') continue ;; esac
    _gw_check_add "$_rj_n" "$_rj_v"
    case "$_rj_s" in
      bad)  _rj_broken=1 ;;
      warn) _rj_degraded=1 ;;
    esac
  done
  if [ "$_rj_broken" = 1 ]; then _rj_rc="$EXIT_CONFIG"
  elif [ "$_rj_degraded" = 1 ]; then _rj_rc="$EXIT_PARTIAL"
  else _rj_rc=0; fi
  _rj_ok=false
  if [ "$_rj_rc" = 0 ]; then _rj_ok=true; fi
  printf '{"verb":"doctor","ok":%s,"exit_code":%s,"checks":[%s]}\n' "$_rj_ok" "$_rj_rc" "$GW_CHECKS"
  return "$_rj_rc"
}

_gw_apply_crontab() {
  _gac_ct="${CRONTAB_FILE:-/etc/crontab}"
  if [ ! -f "$_gac_ct" ]; then
    # Platform-conditional phrasing (#50): unset PLATFORM_LABEL = DSM text.
    case "${PLATFORM_LABEL:-dsm}" in
      dsm) _gw_fail "$EXIT_CONFIG" "no crontab at $_gac_ct - use DSM Task Scheduler (sh scripts/install_scheduler.sh)" ;;
      *)   _gw_fail "$EXIT_CONFIG" "no crontab at $_gac_ct - install cron, or schedule scripts/auto_update.sh with a systemd timer" ;;
    esac
  fi
  _gac_sched="$(cron_normalize "$(env_get UPDATE_SCHEDULE 2>/dev/null || echo '0 2 * * *')")" \
    || _gw_fail "$EXIT_CONFIG" "UPDATE_SCHEDULE is not a valid five-field cron expression"
  _gac_cmd="$(scheduler_update_command)" || return "$EXIT_CONFIG"
  _gac_line="$(printf '%s\troot\t%s' "$_gac_sched" "$_gac_cmd")"
  if grep -Fq "scripts/auto_update.sh" "$_gac_ct" 2>/dev/null; then
    if grep -Fq "$_gac_line" "$_gac_ct" 2>/dev/null; then
      log_info "an auto_update.sh entry already exists in $_gac_ct (schedule unchanged)"
      return 0
    fi
    # Managed rewrite: the entry is ours, so a schedule change in .env must
    # replace it - silently keeping the old line would diverge forever.
    # cat-overwrite (not mv) preserves /etc/crontab's inode and permissions.
    grep -Fv "scripts/auto_update.sh" "$_gac_ct" >"$_gac_ct.next" 2>/dev/null || : >>"$_gac_ct.next"
    printf '%s\n' "$_gac_line" >>"$_gac_ct.next" \
      || { rm -f "$_gac_ct.next"; _gw_fail "$EXIT_CONFIG" "cannot write $_gac_ct"; }
    cat "$_gac_ct.next" >"$_gac_ct" \
      || { rm -f "$_gac_ct.next"; _gw_fail "$EXIT_CONFIG" "cannot write $_gac_ct"; }
    rm -f "$_gac_ct.next"
    scheduler_reload_crond || log_warn "crond was not reloaded - the entry applies after the next crond restart"
    log_info "crontab entry UPDATED in $_gac_ct ($_gac_sched)"
    return 0
  fi
  printf '%s\n' "$_gac_line" >> "$_gac_ct" \
    || _gw_fail "$EXIT_CONFIG" "cannot write $_gac_ct"
  scheduler_reload_crond || log_warn "crond was not reloaded - the entry applies after the next crond restart"
  log_info "crontab entry installed in $_gac_ct ($_gac_sched)"
  return 0
}

gateway_cron() {
  [ -f "$ENV_FILE" ] || _gw_fail "$EXIT_CONFIG" ".env not found at $ENV_FILE - deploy first"
  load_env
  if [ -n "$GW_TIME" ]; then
    # Without a colon both %%:*/#*: expansions return the WHOLE string, so
    # '--time 7' would silently schedule 07:07 - require the separator.
    case "$GW_TIME" in *:*) : ;; *) _gw_fail "$EXIT_CONFIG" "--time expects HH:MM (got '$GW_TIME')" ;; esac
    _gwc_hh="${GW_TIME%%:*}"; _gwc_mm="${GW_TIME#*:}"
    case "$_gwc_hh" in ''|*[!0-9]*) _gw_fail "$EXIT_CONFIG" "--time expects HH:MM (got '$GW_TIME')" ;; esac
    case "$_gwc_mm" in ''|*[!0-9]*) _gw_fail "$EXIT_CONFIG" "--time expects HH:MM (got '$GW_TIME')" ;; esac
    _gwc_hh="$(printf '%s' "$_gwc_hh" | sed 's/^0*//')"; [ -n "$_gwc_hh" ] || _gwc_hh=0
    _gwc_mm="$(printf '%s' "$_gwc_mm" | sed 's/^0*//')"; [ -n "$_gwc_mm" ] || _gwc_mm=0
    [ "$_gwc_hh" -le 23 ] && [ "$_gwc_mm" -le 59 ] \
      || _gw_fail "$EXIT_CONFIG" "--time expects a 24h clock time (got '$GW_TIME')"
    GW_SCHED="$_gwc_mm $_gwc_hh * * *"
  fi
  if [ -n "$GW_SCHED" ]; then
    _gwc_norm="$(cron_normalize "$GW_SCHED")" \
      || _gw_fail "$EXIT_CONFIG" "invalid cron expression: $GW_SCHED"
    env_set UPDATE_SCHEDULE "$_gwc_norm" || return "$EXIT_CONFIG"
    log_info "UPDATE_SCHEDULE set to '$_gwc_norm'"
  fi
  if [ -n "$GW_TZ" ]; then
    env_set UPDATE_TZ "$GW_TZ" || return "$EXIT_CONFIG"
    log_info "UPDATE_TZ set to '$GW_TZ'"
  fi
  case "$GW_ENABLE" in
    true|false)
      env_set UPDATE_ENABLED "$GW_ENABLE" || return "$EXIT_CONFIG"
      log_info "UPDATE_ENABLED set to $GW_ENABLE" ;;
  esac
  if [ "$GW_APPLY_CRON" = 1 ]; then
    _gw_apply_crontab || return $?
  else
    printf 'schedule: %s (tz %s, enabled=%s)\n' \
      "$(env_get UPDATE_SCHEDULE 2>/dev/null || echo unset)" \
      "$(env_get UPDATE_TZ 2>/dev/null || echo system)" \
      "$(env_get UPDATE_ENABLED 2>/dev/null || echo true)"
    case "${PLATFORM_LABEL:-dsm}" in
      dsm) printf 'DSM Task Scheduler command: %s\n' "$(scheduler_update_command 2>/dev/null || echo '<resolve after deploy>')" ;;
      *)   printf 'Scheduled-task command: %s\n' "$(scheduler_update_command 2>/dev/null || echo '<resolve after deploy>')" ;;
    esac
    printf 'Or apply a crontab entry:   gateway.sh cron --apply-crontab --yes (as root)\n'
  fi
  return 0
}

# --- entry ----------------------------------------------------------------------

gateway_main() {
  ensure_persistent_state || {
    echo "FATAL: cannot create persistent data directory: $GATEWAY_DATA_DIR" >&2
    exit "${EXIT_CONFIG:-3}"
  }

  [ $# -ge 1 ] || { usage >&2; exit "$EXIT_CONFIG"; }
  case "$1" in
    --help|-h|help) usage; exit "$EXIT_OK" ;;
  esac
  GW_VERB="$1"; shift
  case "$GW_VERB" in
    deploy|redeploy|modify|cron|status|doctor|update) : ;;
    *) log_error "unknown verb: $GW_VERB"; usage >&2; exit "$EXIT_CONFIG" ;;
  esac

  # Secrets never transit argv (argv is visible in ps): reject them up front.
  # Match the FLAG NAME only (the part before '='): a legitimate value such as
  # a subscription URL almost always carries '?token=...' and must pass.
  for _a in "$@"; do
    case "${_a%%=*}" in
      --*secret*|--*password*|--*token*)
        echo "ERROR: secrets are never accepted on the command line - set them in .env ($ENV_FILE)" >&2
        exit "$EXIT_CONFIG" ;;
    esac
  done

  GW_YES=0 GW_DRY_RUN=0 GW_JSON=0 GW_EGRESS=0 GW_MUTATED=0
  GW_CLEAN_C=preserve GW_CLEAN_N=preserve GW_IFACE=''
  GW_DO_NET=0 GW_DO_IMG=0 GW_SUB='' GW_MIHOMO_TAG='' GW_METACUBEXD_TAG=''
  GW_TIME='' GW_SCHED='' GW_TZ='' GW_ENABLE='' GW_APPLY_CRON=0
  GW_PASS=''

  GW_UPD_MODE='' GW_UPD_NAME=''
  if [ "$GW_VERB" = update ]; then
    # Target-management flags are handled here; everything else except --yes
    # passes through to auto_update.sh verbatim.
    while [ $# -gt 0 ]; do
      _a="$1"
      case "$_a" in
        --help|-h) gw_help update; exit "$EXIT_OK" ;;
        --yes|-y) GW_YES=1 ;;
        --dry-run) GW_DRY_RUN=1; GW_PASS="$GW_PASS $_a" ;;
        --list-targets) GW_UPD_MODE=list ;;
        --last) GW_UPD_MODE=last ;;
        --enable=*) GW_UPD_MODE=enable; GW_UPD_NAME="${_a#*=}" ;;
        --enable) shift; GW_UPD_MODE=enable; GW_UPD_NAME="${1:-}" ;;
        --disable=*) GW_UPD_MODE=disable; GW_UPD_NAME="${_a#*=}" ;;
        --disable) shift; GW_UPD_MODE=disable; GW_UPD_NAME="${1:-}" ;;
        *) GW_PASS="$GW_PASS $_a" ;;
      esac
      [ $# -eq 0 ] || shift
    done
    # --dry-run has no meaning on the target-management modes, and because it
    # exempts the --yes/root gates it must never combine with a mode that
    # writes the managed list (or the gates would be bypassed).
    if [ -n "$GW_UPD_MODE" ] && [ "$GW_DRY_RUN" = 1 ]; then
      log_error "--dry-run cannot be combined with --list-targets/--last/--enable/--disable"
      exit "$EXIT_CONFIG"
    fi
    # Target-management modes never exec auto_update.sh, so any residual
    # pass-through flag (--json, --force, a typo) would be SILENTLY dropped
    # with exit 0 - reject it like every other verb rejects unknown options.
    if [ -n "$GW_UPD_MODE" ] && [ -n "${GW_PASS# }" ]; then
      log_error "unknown option for update --$GW_UPD_MODE:$GW_PASS"
      exit "$EXIT_CONFIG"
    fi
  else
    while [ $# -gt 0 ]; do
      _a="$1"
      case "$GW_VERB:$_a" in
        *:--help|*:-h) gw_help "$GW_VERB"; exit "$EXIT_OK" ;;
        *:--yes|*:-y) GW_YES=1 ;;
        deploy:--dry-run|redeploy:--dry-run|modify:--dry-run) GW_DRY_RUN=1 ;;
        status:--json|doctor:--json) GW_JSON=1 ;;
        *:--json) log_error "--json is only supported on status and doctor"; exit "$EXIT_CONFIG" ;;
        doctor:--egress) GW_EGRESS=1 ;;
        deploy:--cleanup-containers=*|redeploy:--cleanup-containers=*|modify:--cleanup-containers=*) GW_CLEAN_C="${_a#*=}" ;;
        deploy:--cleanup-containers|redeploy:--cleanup-containers|modify:--cleanup-containers) shift; GW_CLEAN_C="${1:-}" ;;
        deploy:--cleanup-network=*|redeploy:--cleanup-network=*|modify:--cleanup-network=*) GW_CLEAN_N="${_a#*=}" ;;
        deploy:--cleanup-network|redeploy:--cleanup-network|modify:--cleanup-network) shift; GW_CLEAN_N="${1:-}" ;;
        deploy:--interface=*|redeploy:--interface=*) GW_IFACE="${_a#*=}" ;;
        deploy:--interface|redeploy:--interface) shift; GW_IFACE="${1:-}" ;;
        modify:--network) GW_DO_NET=1 ;;
        modify:--images) GW_DO_IMG=1 ;;
        modify:--subscription=*) GW_SUB="${_a#*=}" ;;
        modify:--subscription) shift; GW_SUB="${1:-}" ;;
        modify:--mihomo-tag=*) GW_MIHOMO_TAG="${_a#*=}" ;;
        modify:--mihomo-tag) shift; GW_MIHOMO_TAG="${1:-}" ;;
        modify:--metacubexd-tag=*) GW_METACUBEXD_TAG="${_a#*=}" ;;
        modify:--metacubexd-tag) shift; GW_METACUBEXD_TAG="${1:-}" ;;
        cron:--time=*) GW_TIME="${_a#*=}" ;;
        cron:--time) shift; GW_TIME="${1:-}" ;;
        cron:--schedule=*) GW_SCHED="${_a#*=}" ;;
        cron:--schedule) shift; GW_SCHED="${1:-}" ;;
        cron:--tz=*) GW_TZ="${_a#*=}" ;;
        cron:--tz) shift; GW_TZ="${1:-}" ;;
        cron:--enable) GW_ENABLE=true ;;
        cron:--disable) GW_ENABLE=false ;;
        cron:--apply-crontab) GW_APPLY_CRON=1 ;;
        *) log_error "unknown option for $GW_VERB: $_a"; exit "$EXIT_CONFIG" ;;
      esac
      # A trailing value-taking flag has already consumed the last word: an
      # unguarded shift past the end aborts dash-style shells with exit 2.
      [ $# -eq 0 ] || shift
    done
  fi

  # Unified log: every verb logs to logs/gateway.log with verb= and run-id
  # fields; the legacy per-flow names become symlinks (one release) so tools
  # tailing them keep working.
  GATEWAY_VERB="$GW_VERB"
  GATEWAY_RUN_ID="$(date +%s).$$"
  GATEWAY_LOG="$GATEWAY_DATA_DIR/logs/gateway.log"
  export GATEWAY_VERB GATEWAY_RUN_ID GATEWAY_LOG
  LOG_FILE="$GATEWAY_LOG"
  for _l in install.log auto-update.log; do
    [ -e "$GATEWAY_DATA_DIR/logs/$_l" ] || ln -s gateway.log "$GATEWAY_DATA_DIR/logs/$_l" 2>/dev/null
  done
  if [ "$GW_JSON" = 1 ]; then
    GATEWAY_LOG_QUIET=1
    export GATEWAY_LOG_QUIET
  fi

  # Guardrails: --yes for anything mutating (dry-run exempt), then per-verb root.
  _gw_mutating=0
  case "$GW_VERB" in
    deploy|redeploy|modify) _gw_mutating=1 ;;
    update) case "$GW_UPD_MODE" in list|last) : ;; *) _gw_mutating=1 ;; esac ;;
    cron) [ "$GW_APPLY_CRON" = 1 ] && _gw_mutating=1 ;;
  esac
  if [ "$_gw_mutating" = 1 ] && [ "$GW_DRY_RUN" = 0 ] && [ "$GW_YES" = 0 ]; then
    log_error "refusing to change the system without an explicit --yes ($GW_VERB affects the running gateway)"
    exit "$EXIT_CONFIRM"
  fi
  if [ "$_gw_mutating" = 1 ] && [ "$GW_DRY_RUN" = 0 ]; then
    need_root || exit "$EXIT_ROOT"
  fi

  log_info "gateway.sh $GW_VERB start (yes=$GW_YES dry_run=$GW_DRY_RUN json=$GW_JSON)"

  case "$GW_VERB" in
    update)
      case "$GW_UPD_MODE" in
        list) gateway_update_list; exit $? ;;
        last) gateway_update_last; exit $? ;;
        enable)
          [ -n "$GW_UPD_NAME" ] || { log_error "--enable requires a container name"; exit "$EXIT_CONFIG"; }
          target_enroll "$GW_UPD_NAME" || exit "$EXIT_CONFIG"
          if detect_compose >/dev/null 2>&1; then
            # Enrollment is name-based and deliberately does not require the
            # container to exist yet, but a typo'd name would otherwise be
            # enrolled with exit 0 and never update - warn loudly.
            _gw_upd_run="$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$GW_UPD_NAME" 2>/dev/null || echo absent)"
            case "$_gw_upd_run" in
              true) : ;;
              false) log_warn "'$GW_UPD_NAME' is enrolled but not running - updates skip it until it runs" ;;
              *) log_warn "'$GW_UPD_NAME' is enrolled but no such container exists - check the name (updates skip it until it runs)" ;;
            esac
            _gw_upd_img="$("$DOCKER_BIN" inspect -f '{{.Config.Image}}' "$GW_UPD_NAME" 2>/dev/null)"
            if [ -n "$_gw_upd_img" ] && targets_image_databaselike "$_gw_upd_img"; then
              log_warn "'$GW_UPD_NAME' looks like a DATABASE ($_gw_upd_img): auto-recreate has no quiesce and can corrupt in-flight writes - enroll only if you accept that risk"
            fi
          fi
          exit "$EXIT_OK" ;;
        disable)
          [ -n "$GW_UPD_NAME" ] || { log_error "--disable requires a container name"; exit "$EXIT_CONFIG"; }
          target_remove "$GW_UPD_NAME" || exit "$EXIT_CONFIG"
          exit "$EXIT_OK" ;;
      esac
      # shellcheck disable=SC2086  # intentional word-split of pass-through flags
      exec sh "$SELF_DIR/auto_update.sh" $GW_PASS ;;
    status) gateway_status; exit $? ;;
    doctor) gateway_doctor; exit $? ;;
    cron)   gateway_cron; exit $? ;;
    deploy|redeploy)
      if [ "$GW_DRY_RUN" = 0 ]; then acquire_lock; trap 'release_lock' EXIT INT TERM; fi
      gateway_deploy; _gw_rc=$?
      [ "$_gw_rc" = 0 ] || [ "$GW_DRY_RUN" = 1 ] \
        || notify "Mihomo Gateway: $GW_VERB failed" "exit=$_gw_rc - see $GATEWAY_LOG"
      exit "$_gw_rc" ;;
    modify)
      if [ "$GW_DRY_RUN" = 0 ]; then acquire_lock; trap 'release_lock' EXIT INT TERM; fi
      gateway_modify; _gw_rc=$?
      [ "$_gw_rc" = 0 ] || [ "$GW_DRY_RUN" = 1 ] \
        || notify "Mihomo Gateway: modify failed" "exit=$_gw_rc - see $GATEWAY_LOG"
      exit "$_gw_rc" ;;
  esac
}

if [ "${GATEWAY_SOURCE_ONLY:-0}" != 1 ]; then
  gateway_main "$@"
fi
