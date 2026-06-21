#!/bin/sh
# Regression tests for DSM scheduling and the unattended image-update helpers.
# Runs with POSIX/BusyBox sh and uses fake Docker/Compose commands only.
# shellcheck disable=SC2016,SC2329

set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/smg-update-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
expect_success() { _name="$1"; shift; if "$@"; then ok; else fail "$_name"; fi; }
expect_failure() { _name="$1"; shift; if "$@"; then fail "$_name"; else ok; fi; }
assert_contains() {
  _name="$1"; _text="$2"; _needle="$3"
  case "$_text" in *"$_needle"*) ok ;; *) fail "$_name (missing: $_needle)" ;; esac
}
assert_not_contains() {
  _name="$1"; _text="$2"; _needle="$3"
  case "$_text" in *"$_needle"*) fail "$_name (unexpected: $_needle)" ;; *) ok ;; esac
}

# DSM Task Scheduler: the command must use an absolute script path and must not
# redirect into UPDATE_LOG. auto_update.sh already tees into that file; an outer
# redirect duplicates every line and keeps writing to a renamed file after rotation.
SCHED_ROOT="$TMP/project with spaces"
mkdir -p "$SCHED_ROOT/scripts/lib"
SCHED_ROOT="$(CDPATH='' cd -- "$SCHED_ROOT" && pwd)"
cp "$ROOT/scripts/install_scheduler.sh" "$SCHED_ROOT/scripts/"
cp "$ROOT/scripts/lib/common.sh" "$SCHED_ROOT/scripts/lib/"
cp "$ROOT/scripts/lib/scheduler.sh" "$SCHED_ROOT/scripts/lib/"
printf '%s\n' 'UPDATE_SCHEDULE="5 3 * * *"' 'UPDATE_TZ=UTC' > "$SCHED_ROOT/.env"
SCHED_OUT="$(sh "$SCHED_ROOT/scripts/install_scheduler.sh" 2>&1)" || fail "valid DSM schedule should render"
SCHED_DATA="$(dirname "$SCHED_ROOT")/syno-mihomo-gateway-data"
[ -f "$SCHED_DATA/.env" ] || fail "scheduler did not migrate legacy .env to persistent data"
assert_contains "scheduler uses explicit /bin/sh" "$SCHED_OUT" "/bin/sh"
assert_contains "scheduler uses absolute script path" "$SCHED_OUT" "$SCHED_ROOT/scripts/auto_update.sh"
assert_contains "boot task uses absolute script path" "$SCHED_OUT" "$SCHED_ROOT/scripts/setup_network.sh"
assert_not_contains "scheduler must not duplicate its own log" "$SCHED_OUT" ">> logs/auto-update.log"

# A hand-edited schedule is untrusted data. Reject invalid ranges/extra fields
# instead of printing an unsafe fallback crontab line.
printf '%s\n' 'UPDATE_SCHEDULE="99 27 * * * root touch /tmp/bad"' 'UPDATE_TZ=UTC' > "$SCHED_DATA/.env"
if sh "$SCHED_ROOT/scripts/install_scheduler.sh" >/dev/null 2>&1; then
  fail "invalid cron schedule should be rejected"
else
  ok
fi

# Direct cron parser coverage: DSM/BusyBox-safe numeric syntax only.
# shellcheck source=scripts/lib/scheduler.sh
. "$ROOT/scripts/lib/scheduler.sh"
expect_success "daily cron accepted" cron_normalize '0 2 * * *'
expect_success "range/list/step cron accepted" cron_normalize '*/15 0-23 * * 1-5'
expect_failure "minute range enforced" cron_normalize '60 2 * * *'
expect_failure "hour range enforced" cron_normalize '0 24 * * *'
expect_failure "named weekdays rejected consistently" cron_normalize '0 2 * * MON'
if [ "$(cron_daily_hhmm '5 3 * * *')" = '03:05' ]; then ok; else fail "daily time rendering"; fi
expect_failure "complex cron is not described as one daily time" cron_daily_hhmm '*/5 * * * *'
if [ "$(shell_quote "a'b")" = "'a'\''b'" ]; then ok; else fail "POSIX shell quoting"; fi
RELOAD_BIN="$TMP/reload-bin"
RELOAD_CALLS="$TMP/reload.calls"
mkdir -p "$RELOAD_BIN"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$RELOAD_CALLS"' 'exit 0' > "$RELOAD_BIN/synosystemctl"
chmod +x "$RELOAD_BIN/synosystemctl"
export RELOAD_CALLS
OLD_PATH="$PATH"
PATH="$RELOAD_BIN:$PATH"; export PATH
expect_success "DSM 7 crond reload command is probed" scheduler_reload_crond
assert_contains "DSM 7 reload targets crond" "$(cat "$RELOAD_CALLS")" "restart crond"
PATH="$OLD_PATH"; export PATH
# shellcheck source=scripts/installer/flow_cron.sh
. "$ROOT/scripts/installer/flow_cron.sh"
env_get() { printf '%s\n' '08 09 * * *'; }
if [ "$(_default_hhmm)" = '09:08' ]; then ok; else fail "installer daily default handles leading zeros"; fi
env_get() { printf '%s\n' 'not a schedule'; }
if [ "$(_default_hhmm)" = '02:00' ]; then ok; else fail "installer invalid schedule default"; fi

# shellcheck source=scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/registry.sh
. "$ROOT/scripts/lib/registry.sh"
# shellcheck source=scripts/lib/compose.sh
. "$ROOT/scripts/lib/compose.sh"

LOG_FILE="$TMP/update.log"
ENV_FILE="$TMP/.env"
REPO_ROOT="$TMP"
MIHOMO_IMAGE="acr.example/mihomo:latest"
METACUBEXD_IMAGE="acr.example/metacubexd:latest"

# A failed re-tag means rollback did not happen. It must be surfaced before
# Compose is invoked; silently returning success would certify a bad rollback.
MOCK_DOCKER="$TMP/docker"
printf '%s\n' '#!/bin/sh' 'case "$1" in tag) exit 1 ;; *) exit 0 ;; esac' > "$MOCK_DOCKER"
chmod +x "$MOCK_DOCKER"
DOCKER_BIN="$MOCK_DOCKER"
COMPOSE_CMD=true
expect_failure "rollback fails when docker tag fails" rollback_compose sha256:old-mihomo ""

# Shared fake Compose CLI for config/apply behavior.
MOCK_COMPOSE="$TMP/docker-compose"
MOCK_COMPOSE_CALLS="$TMP/compose.calls"
export MOCK_COMPOSE_CALLS
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$*" >> "$MOCK_COMPOSE_CALLS"' \
  'case "$*" in' \
  '  "up --help") [ "${MOCK_PULL_SUPPORT:-1}" = 1 ] && echo "  --pull policy (always|missing|never)"; exit 0 ;;' \
  '  *" config"*) exit "${MOCK_CONFIG_RC:-0}" ;;' \
  '  *" up -d"*) exit "${MOCK_UP_RC:-0}" ;;' \
  'esac' \
  'exit 0' > "$MOCK_COMPOSE"
chmod +x "$MOCK_COMPOSE"
COMPOSE_CMD="$MOCK_COMPOSE"
export MOCK_PULL_SUPPORT=1 MOCK_CONFIG_RC=0 MOCK_UP_RC=0
: > "$MOCK_COMPOSE_CALLS"
expect_success "Compose model validation succeeds" compose_config_check
MOCK_CONFIG_RC=1; export MOCK_CONFIG_RC
expect_failure "Compose model validation failure propagates" compose_config_check
MOCK_CONFIG_RC=0; export MOCK_CONFIG_RC
: > "$MOCK_COMPOSE_CALLS"
expect_success "validated local Compose apply succeeds" compose_up_local
COMPOSE_LOG="$(cat "$MOCK_COMPOSE_CALLS")"
assert_contains "Compose v2 apply forbids implicit pull" "$COMPOSE_LOG" "--pull never"
MOCK_PULL_SUPPORT=0; export MOCK_PULL_SUPPORT
: > "$MOCK_COMPOSE_CALLS"
expect_success "legacy Compose fallback succeeds" compose_up_local
COMPOSE_LOG="$(cat "$MOCK_COMPOSE_CALLS")"
assert_not_contains "legacy Compose gets no unsupported pull flag" "$COMPOSE_LOG" "--pull never"

# Fake Docker CLI for daemon/config/pull/digest/architecture/change tests.
MOCK_DOCKER="$TMP/docker-full"
MOCK_DOCKER_CALLS="$TMP/docker.calls"
MOCK_PULL_COUNT="$TMP/pull.count"
export MOCK_DOCKER_CALLS MOCK_PULL_COUNT
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$*" >> "$MOCK_DOCKER_CALLS"' \
  'case "$1" in' \
  '  info) exit "${MOCK_INFO_RC:-0}" ;;' \
  '  login) while IFS= read -r _line; do :; done; exit "${MOCK_LOGIN_RC:-0}" ;;' \
  '  pull)' \
  '    _n="$(cat "$MOCK_PULL_COUNT" 2>/dev/null || echo 0)"; _n=$((_n+1)); echo "$_n" > "$MOCK_PULL_COUNT"' \
  '    [ "$_n" -le "${MOCK_PULL_FAILS:-0}" ] && exit 1; exit 0 ;;' \
  '  image)' \
  '    case "$2" in' \
  '      inspect)' \
  '        case "$*" in' \
  '          *"{{.Id}}"*) [ -n "${MOCK_LOCAL_ID:-}" ] && echo "$MOCK_LOCAL_ID"; exit 0 ;;' \
  '          *"{{.Architecture}}"*) [ -n "${MOCK_ARCH:-}" ] && echo "$MOCK_ARCH"; exit 0 ;;' \
  '          *) exit "${MOCK_OLD_IMAGE_RC:-0}" ;;' \
  '        esac ;;' \
  '      prune) exit 0 ;;' \
  '    esac ;;' \
  '  inspect)' \
  '    case "$*" in' \
  '      *"{{.Image}}"*) [ -n "${MOCK_RUNNING_ID:-}" ] && echo "$MOCK_RUNNING_ID"; exit 0 ;;' \
  '      *"{{.RestartCount}}"*) echo "${MOCK_RESTART_COUNT:-0}"; exit 0 ;;' \
  '      *"{{.State.Running}}"*) echo "${MOCK_RUNNING:-true}"; exit 0 ;;' \
  '      *) exit 0 ;;' \
  '    esac ;;' \
  '  exec)' \
  '    case "$*" in' \
  '      *"command -v wget"*) exit 0 ;;' \
  '      *"wget -q"*) exit "${MOCK_CONTROLLER_RC:-0}" ;;' \
  '      *"/sys/class/net/"*) exit "${MOCK_TUN_RC:-0}" ;;' \
  '      *"/proc/sys/net/ipv4/ip_forward"*) echo "${MOCK_FORWARD:-1}"; exit 0 ;;' \
  '    esac ;;' \
  '  run) exit "${MOCK_IPTABLES_RC:-0}" ;;' \
  '  tag) exit "${MOCK_TAG_RC:-0}" ;;' \
  'esac' \
  'exit 0' > "$MOCK_DOCKER"
chmod +x "$MOCK_DOCKER"
DOCKER_BIN="$MOCK_DOCKER"
: > "$MOCK_DOCKER_CALLS"

MOCK_INFO_RC=0; export MOCK_INFO_RC
expect_success "Docker daemon preflight succeeds" docker_daemon_ready
MOCK_INFO_RC=1; export MOCK_INFO_RC
expect_failure "Docker daemon preflight detects unavailable daemon" docker_daemon_ready
MOCK_INFO_RC=0; export MOCK_INFO_RC
if (
  _ready_attempt=0
  detect_compose() { _ready_attempt=$((_ready_attempt + 1)); [ "$_ready_attempt" -ge 3 ]; }
  docker_daemon_ready() { return 0; }
  sleep() { :; }
  wait_for_docker_ready 3 1
); then
  ok
else
  fail "Docker readiness wait should tolerate boot-time startup delay"
fi
if (
  detect_compose() { return 1; }
  docker_daemon_ready() { return 1; }
  wait_for_docker_ready 0 1
); then
  fail "Docker readiness timeout should propagate"
else
  ok
fi

UPDATE_ENABLED=true
PULL_RETRIES=3
PULL_RETRY_DELAY=0
DOCKER_READY_TIMEOUT=120
DOCKER_READY_INTERVAL=5
HEALTH_RETRIES=1
HEALTH_INTERVAL=0
HEALTH_MAX_RESTARTS=1
CF_HEALTH_TIMEOUT=1
LOG_KEEP=1
LOG_MAX_BYTES=1024
UPDATE_IMAGES="$MIHOMO_IMAGE $METACUBEXD_IMAGE"
TUN_AUTO_REDIRECT=false
expect_success "valid updater configuration accepted" validate_update_config
TUN_AUTO_REDIRECT=False
expect_failure "TUN auto-redirect boolean is strict" validate_update_config
TUN_AUTO_REDIRECT=false
CF_IMAGE=acr.example/cloudflared:latest
expect_failure "configured cloudflared must be mapped in UPDATE_IMAGES" validate_update_config
UPDATE_IMAGES="$UPDATE_IMAGES $CF_IMAGE"
expect_success "configured cloudflared mapping accepted" validate_update_config
CF_IMAGE=
UPDATE_IMAGES="$MIHOMO_IMAGE $METACUBEXD_IMAGE"
UPDATE_ENABLED=False
expect_failure "invalid kill-switch value is rejected" validate_update_config
UPDATE_ENABLED=true
PULL_RETRIES=0
expect_failure "zero pull retries rejected" validate_update_config
PULL_RETRIES=3
UPDATE_IMAGES="$MIHOMO_IMAGE"
expect_failure "missing Compose image mapping rejected" validate_update_config
UPDATE_IMAGES="$MIHOMO_IMAGE $METACUBEXD_IMAGE"
UPDATE_IMAGES="$UPDATE_IMAGES *"
expect_failure "wildcard image reference is rejected before shell expansion" validate_update_config
UPDATE_IMAGES="$MIHOMO_IMAGE $METACUBEXD_IMAGE"

MOCK_PULL_FAILS=2 MOCK_LOCAL_ID=sha256:new; export MOCK_PULL_FAILS MOCK_LOCAL_ID
: > "$MOCK_PULL_COUNT"
expect_success "image pull retries and verifies local image" pull_image "$MIHOMO_IMAGE"
if [ "$(cat "$MOCK_PULL_COUNT")" = 3 ]; then ok; else fail "pull retry count"; fi
MOCK_PULL_FAILS=0 MOCK_LOCAL_ID=; export MOCK_PULL_FAILS MOCK_LOCAL_ID
: > "$MOCK_PULL_COUNT"
expect_failure "pull success without inspectable image rejected" pull_image "$MIHOMO_IMAGE"

MOCK_LOCAL_ID=sha256:new MOCK_RUNNING_ID=sha256:old; export MOCK_LOCAL_ID MOCK_RUNNING_ID
expect_success "different image IDs require deploy" deploy_needed "$MIHOMO_IMAGE" "$MIHOMO_CONTAINER"
MOCK_RUNNING_ID=sha256:new; export MOCK_RUNNING_ID
expect_failure "equal image IDs are a no-op" deploy_needed "$MIHOMO_IMAGE" "$MIHOMO_CONTAINER"

MOCK_ARCH="$(host_arch)"; export MOCK_ARCH
expect_success "matching image architecture accepted" arch_ok "$MIHOMO_IMAGE"
MOCK_ARCH=definitely-wrong; export MOCK_ARCH
expect_failure "wrong image architecture rejected" arch_ok "$MIHOMO_IMAGE"

DOCKER_REGISTRY=
expect_success "public registry skips login" acr_login
DOCKER_REGISTRY=acr.example DOCKER_USERNAME='' ACR_PASSWORD=''
expect_failure "private registry requires credentials" acr_login
DOCKER_USERNAME=user ACR_PASSWORD=secret MOCK_LOGIN_RC=0
export MOCK_LOGIN_RC
expect_success "private registry noninteractive login succeeds" acr_login

# DSM-safe mode avoids iptables entirely. Explicit opt-in proves that the
# target image can create a NAT chain against this kernel before recreation.
: > "$MOCK_DOCKER_CALLS"
TUN_AUTO_REDIRECT=false
expect_success "default TUN mode skips auto-redirect probe" mihomo_auto_redirect_probe "$MIHOMO_IMAGE"
assert_not_contains "disabled auto-redirect makes no probe container" "$(cat "$MOCK_DOCKER_CALLS")" "run --rm --privileged"
TUN_AUTO_REDIRECT=true MOCK_IPTABLES_RC=0; export MOCK_IPTABLES_RC
expect_success "compatible auto-redirect opt-in passes" mihomo_auto_redirect_probe "$MIHOMO_IMAGE"
assert_contains "enabled auto-redirect uses disposable privileged probe" "$(cat "$MOCK_DOCKER_CALLS")" "run --rm --privileged --network none"
MOCK_IPTABLES_RC=4; export MOCK_IPTABLES_RC
expect_failure "incompatible DSM nftables backend is rejected" mihomo_auto_redirect_probe "$MIHOMO_IMAGE"
TUN_AUTO_REDIRECT=false MOCK_IPTABLES_RC=0; export MOCK_IPTABLES_RC

# Health gate covers stability, authenticated controller access, forwarding, UI
# inspection, and - only when TUN_ENABLE=true - the in-container TUN dataplane.
sleep() { :; }
MOCK_RUNNING=true MOCK_RESTART_COUNT=0 MOCK_CONTROLLER_RC=0 MOCK_TUN_RC=0 MOCK_FORWARD=1
export MOCK_RUNNING MOCK_RESTART_COUNT MOCK_CONTROLLER_RC MOCK_TUN_RC MOCK_FORWARD
CONTROLLER_PORT=9090 CONTROLLER_SECRET=token TUN_DEVICE=mihomo-tun
HEALTH_RETRIES=1 HEALTH_INTERVAL=0 HEALTH_MAX_RESTARTS=1

# Default (TUN opt-in OFF): a healthy controller passes and the in-container TUN
# interface is NOT required (there is no tun dataplane in this mode).
TUN_ENABLE=false; export TUN_ENABLE
: > "$MOCK_DOCKER_CALLS"
expect_success "healthy controller passes with TUN off (no tun required)" health_gate
HEALTH_CALLS="$(cat "$MOCK_DOCKER_CALLS")"
assert_contains "controller secret is sent" "$HEALTH_CALLS" "Authorization: Bearer token"
MOCK_TUN_RC=1; export MOCK_TUN_RC
expect_success "missing in-container TUN is ignored when TUN off" health_gate
MOCK_TUN_RC=0; export MOCK_TUN_RC

# TUN_ENABLE=true: the transparent-gateway dataplane IS required again.
TUN_ENABLE=true; export TUN_ENABLE
expect_success "healthy controller and TUN dataplane pass with TUN on" health_gate
MOCK_TUN_RC=1; export MOCK_TUN_RC
expect_failure "missing in-container TUN fails health gate with TUN on" health_gate
MOCK_TUN_RC=0; export MOCK_TUN_RC
TUN_ENABLE=false; export TUN_ENABLE

# Rollback success path validates old images, re-tags both, and recreates from
# local cache without an implicit registry pull.
MOCK_OLD_IMAGE_RC=0 MOCK_TAG_RC=0 MOCK_PULL_SUPPORT=1 MOCK_UP_RC=0
export MOCK_OLD_IMAGE_RC MOCK_TAG_RC MOCK_PULL_SUPPORT MOCK_UP_RC
COMPOSE_CMD="$MOCK_COMPOSE"
: > "$MOCK_DOCKER_CALLS"; : > "$MOCK_COMPOSE_CALLS"
expect_success "rollback re-tags and recreates old images" rollback_compose sha256:old-mihomo sha256:old-ui
ROLLBACK_DOCKER="$(cat "$MOCK_DOCKER_CALLS")"
ROLLBACK_COMPOSE="$(cat "$MOCK_COMPOSE_CALLS")"
assert_contains "mihomo rollback tag applied" "$ROLLBACK_DOCKER" "tag sha256:old-mihomo $MIHOMO_IMAGE"
assert_contains "UI rollback tag applied" "$ROLLBACK_DOCKER" "tag sha256:old-ui $METACUBEXD_IMAGE"
assert_contains "rollback forbids implicit pull" "$ROLLBACK_COMPOSE" "--pull never"
expect_failure "rollback without prior image is unavailable" rollback_compose "" ""

# Orchestrator integration tests. Source the entrypoint without running it, then
# replace every host/Docker side effect with a trace function.
AUTO_UPDATE_SOURCE_ONLY=1
AUTO_UPDATE_SELF_DIR="$ROOT/scripts"
export AUTO_UPDATE_SOURCE_ONLY AUTO_UPDATE_SELF_DIR
# shellcheck source=scripts/auto_update.sh
. "$ROOT/scripts/auto_update.sh"

TRACE="$TMP/orchestrator.trace"
export TRACE

if (
  load_env() {
    LOG_FILE="$TMP/orchestrator.log"; UPDATE_ENABLED=false; UPDATE_IMAGES=''
    MIHOMO_IMAGE=''; METACUBEXD_IMAGE=''; CF_IMAGE=''; CF_CONTAINER_NAME=cloudflared
  }
  rotate_log() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  validate_update_config() { printf '%s\n' full-validation >> "$TRACE"; return 1; }
  wait_for_docker_ready() { printf '%s\n' docker-wait >> "$TRACE"; return 1; }
  notify() { :; }
  cloudflared_cleanup_candidate() { :; }
  : > "$TRACE"
  auto_update_main
); then
  ok
else
  fail "valid kill-switch should no-op even when deployment settings are incomplete"
fi
DISABLED_TRACE="$(cat "$TRACE")"
assert_not_contains "kill-switch skips full config validation" "$DISABLED_TRACE" "full-validation"
assert_not_contains "kill-switch skips Docker wait" "$DISABLED_TRACE" "docker-wait"

if (
  load_env() {
    LOG_FILE="$TMP/orchestrator.log"; UPDATE_ENABLED=true; UPDATE_IMAGES="m u"
    MIHOMO_IMAGE=m; METACUBEXD_IMAGE=u; CF_IMAGE=c; CF_CONTAINER_NAME=cloudflared
    NOTIFY_ON_NOCHANGE=0
  }
  rotate_log() { :; }
  acquire_lock() { printf '%s\n' lock >> "$TRACE"; }
  release_lock() { printf '%s\n' release >> "$TRACE"; }
  detect_compose() { printf '%s\n' detect >> "$TRACE"; DOCKER_BIN=true; return 0; }
  docker_daemon_ready() { printf '%s\n' daemon >> "$TRACE"; return 0; }
  validate_update_config() { printf '%s\n' validate >> "$TRACE"; return 0; }
  check_arch_expectation() { printf '%s\n' arch >> "$TRACE"; return 0; }
  check_tun() { printf '%s\n' tun >> "$TRACE"; return 0; }
  check_network() { printf '%s\n' network >> "$TRACE"; return 0; }
  compose_config_check() { printf '%s\n' compose-config >> "$TRACE"; return 1; }
  acr_login() { printf '%s\n' login >> "$TRACE"; return 0; }
  pull_image() { printf '%s\n' pull >> "$TRACE"; return 0; }
  notify() { printf '%s\n' notify >> "$TRACE"; }
  cloudflared_cleanup_candidate() { :; }
  : > "$TRACE"
  auto_update_main
); then
  fail "invalid Compose preflight should exit nonzero"
else
  _rc=$?
  if [ "$_rc" -eq "$EXIT_CONFIG" ]; then ok; else fail "Compose preflight exit code (got $_rc)"; fi
fi
PREFLIGHT_TRACE="$(tr '\n' ' ' < "$TRACE")"
assert_contains "preflight reaches Compose validation" "$PREFLIGHT_TRACE" "compose-config"
assert_not_contains "preflight failure prevents registry login" "$PREFLIGHT_TRACE" "login"
assert_not_contains "preflight failure prevents pulls" "$PREFLIGHT_TRACE" "pull"

# An incompatible explicit auto-redirect opt-in is discovered after the image
# is pulled but before Compose changes the running gateway. It is not a rollback
# case because no service mutation has occurred.
if (
  load_env() {
    LOG_FILE="$TMP/orchestrator.log"; UPDATE_ENABLED=true; UPDATE_IMAGES="m u"
    MIHOMO_IMAGE=m; METACUBEXD_IMAGE=u; CF_IMAGE=; CF_CONTAINER_NAME=cloudflared
    MIHOMO_CONTAINER=mihomo; METACUBEXD_CONTAINER=mihomo-ui
    NOTIFY_ON_NOCHANGE=0; TUN_AUTO_REDIRECT=true
  }
  rotate_log() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  detect_compose() { DOCKER_BIN=true; return 0; }
  docker_daemon_ready() { return 0; }
  validate_update_config() { return 0; }
  check_arch_expectation() { return 0; }
  check_tun() { return 0; }
  check_network() { return 0; }
  compose_config_check() { return 0; }
  acr_login() { return 0; }
  pull_image() { return 0; }
  arch_ok() { return 0; }
  deploy_needed() { [ "$1" = "$MIHOMO_IMAGE" ]; }
  running_image_id() { printf '%s\n' sha256:old; }
  mihomo_auto_redirect_probe() { printf '%s\n' redirect-probe >> "$TRACE"; return 1; }
  compose_up_local() { printf '%s\n' compose-apply >> "$TRACE"; return 0; }
  rollback_compose() { printf '%s\n' rollback >> "$TRACE"; return 0; }
  notify() { :; }
  cloudflared_cleanup_candidate() { :; }
  : > "$TRACE"
  auto_update_main
); then
  fail "incompatible auto-redirect should report a partial failure"
else
  _rc=$?
  if [ "$_rc" -eq "$EXIT_PARTIAL" ]; then ok; else fail "auto-redirect probe exit code (got $_rc)"; fi
fi
REDIRECT_TRACE="$(cat "$TRACE")"
assert_contains "auto-redirect compatibility is probed" "$REDIRECT_TRACE" "redirect-probe"
assert_not_contains "failed auto-redirect probe prevents Compose apply" "$REDIRECT_TRACE" "compose-apply"
assert_not_contains "pre-apply auto-redirect failure does not roll back" "$REDIRECT_TRACE" "rollback"

if (
  load_env() {
    LOG_FILE="$TMP/orchestrator.log"; UPDATE_ENABLED=true; UPDATE_IMAGES="m u"
    MIHOMO_IMAGE=m; METACUBEXD_IMAGE=u; CF_IMAGE=c; CF_CONTAINER_NAME=cloudflared
    MIHOMO_CONTAINER=mihomo; METACUBEXD_CONTAINER=mihomo-ui
    NOTIFY_ON_NOCHANGE=0
  }
  rotate_log() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  detect_compose() { DOCKER_BIN=true; return 0; }
  docker_daemon_ready() { return 0; }
  validate_update_config() { return 0; }
  check_arch_expectation() { return 0; }
  check_tun() { return 0; }
  check_network() { return 0; }
  compose_config_check() { return 0; }
  acr_login() { return 0; }
  pull_image() { printf 'pull:%s\n' "$1" >> "$TRACE"; return 0; }
  arch_ok() { return 0; }
  deploy_needed() { [ "$1" = "$MIHOMO_IMAGE" ]; }
  running_image_id() { printf '%s\n' sha256:old; }
  compose_up_local() { printf '%s\n' compose-apply >> "$TRACE"; return 1; }
  rollback_compose() { printf '%s\n' rollback >> "$TRACE"; return 0; }
  health_gate() { printf '%s\n' health >> "$TRACE"; return 0; }
  notify() { printf '%s\n' notify >> "$TRACE"; }
  cloudflared_cleanup_candidate() { :; }
  : > "$TRACE"
  auto_update_main
); then
  fail "failed Compose apply should report a partial failure"
else
  _rc=$?
  if [ "$_rc" -eq "$EXIT_PARTIAL" ]; then ok; else fail "failed apply exit code (got $_rc)"; fi
fi
APPLY_TRACE="$(tr '\n' ' ' < "$TRACE")"
assert_contains "all configured images are pulled before apply" "$APPLY_TRACE" "pull:m pull:u compose-apply"
assert_contains "failed apply triggers rollback and re-health" "$APPLY_TRACE" "compose-apply rollback health"

if [ "$FAIL" -ne 0 ]; then
  printf 'FAILED: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'OK: %s DSM scheduler/update regression assertions passed\n' "$PASS"
