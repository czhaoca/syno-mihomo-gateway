#!/bin/sh
# Unit tests for scripts/lib/container.sh - the generic container spec
# capture/replay engine (fake Docker only; no real daemon).
# shellcheck disable=SC2016

set -u
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/smg-generic-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# shellcheck source=scripts/ci/lib/assert.sh
. "$ROOT/scripts/ci/lib/assert.sh"
# shellcheck source=scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/container.sh
. "$ROOT/scripts/lib/container.sh"
# shellcheck source=scripts/lib/targets.sh
. "$ROOT/scripts/lib/targets.sh"

LOG_FILE="$TMP/update.log"
CALLS="$TMP/docker.calls"
export CALLS
MOCK_DOCKER="$TMP/docker"
cat >"$MOCK_DOCKER" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  inspect)
    # Emulate the real CLI: docker inspect -f prints the template output and
    # then appends ONE more newline. Every arm below runs in the subshell; the
    # trailing echo reproduces that extra newline so the capture engine is
    # tested against realistic (not idealized) daemon output.
    (
    case "$*" in
      "inspect missingctr") exit 1 ;;
      *"Ulimits"*failctr) exit 1 ;;
      *ctr-counts*)
        if [ -n "${MOCK_COUNTS:-}" ]; then printf '%s\n' "$MOCK_COUNTS"
        else
          if [ -n "${MOCK_LABELS:-}" ]; then _mc_lbl=$(printf '%s\n' "$MOCK_LABELS" | wc -l | tr -dc 0-9); else _mc_lbl=0; fi
          if [ -n "${MOCK_HC_TEST:-}" ]; then _mc_hc=$(printf '%s\n' "$MOCK_HC_TEST" | wc -l | tr -dc 0-9); else _mc_hc=0; fi
          printf '1 1 1 %s %s\n' "$_mc_lbl" "$_mc_hc"
        fi
        exit 0 ;;
      *IPv6Address*) printf '%s' "${MOCK_IP6:-}"; exit 0 ;;
      *"Config.Env"*sha256:oldimg) [ -n "${MOCK_IMG_ENV:-}" ] && printf '%s\n' "$MOCK_IMG_ENV"; exit 0 ;;
      *"Config.Cmd"*sha256:oldimg) [ -n "${MOCK_IMG_CMD:-}" ] && printf '%s\n' "$MOCK_IMG_CMD"; exit 0 ;;
      *"Config.Entrypoint"*sha256:oldimg) [ -n "${MOCK_IMG_ENTRYPOINT:-}" ] && printf '%s\n' "$MOCK_IMG_ENTRYPOINT"; exit 0 ;;
      *"compose.service"*composectr) echo 'web|smg-stack'; exit 0 ;;
      *"compose.service"*ambctr) echo 'web|'; exit 0 ;;
      *"compose.service"*) echo '|'; exit 0 ;;
      *"Config.Image"*hubctr) echo 'docker.io/library/nginx:latest'; exit 0 ;;
      *"Config.Image"*) echo 'acr.example/myns/web:latest'; exit 0 ;;
      *".State.Running"*stopctr) echo false; exit 0 ;;
      *"State.Health"*) echo "${MOCK_HEALTH_STATUS:-none}"; exit 0 ;;
      *"{{.RestartCount}}"*) echo "${MOCK_RESTARTS:-0}"; exit 0 ;;
      *ctr-guard*) [ -n "${MOCK_GUARD:-}" ] && printf '%s\n' "$MOCK_GUARD"; exit 0 ;;
      *"HostConfig.NetworkMode"*) echo "${MOCK_NETWORK_MODE:-appnet}"; exit 0 ;;
      *"AutoRemove"*) echo "${MOCK_AUTOREMOVE:-false}"; exit 0 ;;
      *"IpcMode"*) echo "${MOCK_IPC:-}"; exit 0 ;;
      *"PidMode"*) echo "${MOCK_PID:-}"; exit 0 ;;
      *"UTSMode"*) echo "${MOCK_UTS:-}"; exit 0 ;;
      *"Config.Labels"*sha256:oldimg) [ -n "${MOCK_IMG_LABELS:-}" ] && printf '%s\n' "$MOCK_IMG_LABELS"; exit 0 ;;
      *"Config.Labels"*) [ -n "${MOCK_LABELS:-}" ] && printf '%s\n' "$MOCK_LABELS"; exit 0 ;;
      *"Sysctls"*) [ -n "${MOCK_SYSCTLS:-}" ] && printf '%s\n' "$MOCK_SYSCTLS"; exit 0 ;;
      *"LogConfig.Type"*) echo "${MOCK_LOG_DRIVER:-json-file}"; exit 0 ;;
      *"LogConfig.Config"*) [ -n "${MOCK_LOG_OPTS:-}" ] && printf '%s\n' "$MOCK_LOG_OPTS"; exit 0 ;;
      *"StopSignal"*) echo "${MOCK_STOP_SIGNAL:-}"; exit 0 ;;
      *"StopTimeout"*) echo "${MOCK_STOP_TIMEOUT:-}"; exit 0 ;;
      *"GroupAdd"*) [ -n "${MOCK_GROUP_ADD:-}" ] && printf '%s\n' "$MOCK_GROUP_ADD"; exit 0 ;;
      *"Ulimits"*) [ -n "${MOCK_ULIMITS:-}" ] && printf '%s\n' "$MOCK_ULIMITS"; exit 0 ;;
      *"HostConfig.Memory"*) echo "${MOCK_MEMORY:-0}"; exit 0 ;;
      *"NanoCpus"*) echo "${MOCK_NANOCPUS:-0}"; exit 0 ;;
      *"ShmSize"*) echo "${MOCK_SHM:-0}"; exit 0 ;;
      *"OomKillDisable"*) echo "${MOCK_OOM:-false}"; exit 0 ;;
      *"Config.Hostname"*) echo "${MOCK_HOSTNAME:-}"; exit 0 ;;
      *"{{.Id}}"*) echo "${MOCK_ID:-aabbccddeeff00112233445566778899}"; exit 0 ;;
      *"MacAddress"*) echo "${MOCK_MAC:-}"; exit 0 ;;
      *"Healthcheck.Test"*sha256:oldimg) [ -n "${MOCK_IMG_HC_TEST:-}" ] && printf '%s\n' "$MOCK_IMG_HC_TEST"; exit 0 ;;
      *"Healthcheck.Test"*) [ -n "${MOCK_HC_TEST:-}" ] && printf '%s\n' "$MOCK_HC_TEST"; exit 0 ;;
      *"Healthcheck.Interval"*sha256:oldimg) [ -n "${MOCK_IMG_HC_META:-}" ] && printf '%s\n' "$MOCK_IMG_HC_META"; exit 0 ;;
      *"Healthcheck.Interval"*) [ -n "${MOCK_HC_META:-}" ] && printf '%s\n' "$MOCK_HC_META"; exit 0 ;;
      *".State.Running"*) echo true; exit 0 ;;
      *"Config.Env"*) printf '%s\n' 'APP_MODE=prod'; exit 0 ;;
      *"Config.Cmd"*) printf '%s\n' serve; exit 0 ;;
      *"Config.Entrypoint"*) printf '%s\n' /entry; exit 0 ;;
      *"HostConfig.Binds"*) printf '%s\n' '/host/cfg:/cfg:ro'; exit 0 ;;
      *".Mounts"*) [ -n "${MOCK_VOLUMES:-}" ] && printf '%s\n' "$MOCK_VOLUMES"; exit 0 ;;
      *"PortBindings"*) printf '%s\n' '|8080|80/tcp'; exit 0 ;;
      *"NetworkSettings.Networks"*)
        if [ "${MOCK_NETWORKS+x}" = x ]; then [ -z "$MOCK_NETWORKS" ] || printf '%s\n' "$MOCK_NETWORKS"
        else printf '%s\n' 'appnet|10.10.0.5|web,aabbccddeeff'; fi
        exit 0 ;;
      *"HostConfig.Dns"*|*"ExtraHosts"*|*"CapAdd"*|*"CapDrop"*|*"SecurityOpt"*|*"Devices"*|*"Tmpfs"*) exit 0 ;;
      *"RestartPolicy.Name"*) echo "${MOCK_RESTART_POLICY-unless-stopped}"; exit 0 ;;
      *"MaximumRetryCount"*) echo 0; exit 0 ;;
      *"Config.User"*|*"Config.WorkingDir"*) exit 0 ;;
      *"ReadonlyRootfs"*|*"Privileged"*) echo false; exit 0 ;;
      *"{{.Image}}"*) echo sha256:oldimg; exit 0 ;;
    esac
    exit 0
    )
    _rc=$?
    [ "$_rc" -eq 0 ] && echo
    exit "$_rc" ;;
  run)
    if [ -n "${MOCK_RUN_FAIL_FLAG:-}" ] && [ -f "$MOCK_RUN_FAIL_FLAG" ]; then
      rm -f "$MOCK_RUN_FAIL_FLAG"; exit 1
    fi
    exit "${MOCK_RUN_RC:-0}" ;;
  exec) exit "${MOCK_EXEC_RC:-0}" ;;
  logs) [ -n "${MOCK_LOGS:-}" ] && printf '%s\n' "$MOCK_LOGS"; exit 0 ;;
  image)
    case "$*" in *"{{.Id}}"*) echo "${MOCK_NEW_IMAGE_ID:-sha256:newimg}" ;; esac
    exit 0 ;;
  rm|stop|start|network) exit 0 ;;
esac
exit 0
EOF
chmod +x "$MOCK_DOCKER"
DOCKER_BIN="$MOCK_DOCKER"
ANON_VOL='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

# --- T1: expanded-surface capture + canonical replay -------------------------
MOCK_LABELS='com.docker.compose.project=smg
app.role=web
org.example.version=1.0'
MOCK_IMG_LABELS='org.example.version=1.0'
MOCK_SYSCTLS='net.ipv4.ip_forward=1'
MOCK_LOG_DRIVER=json-file MOCK_LOG_OPTS='max-size=10m'
MOCK_STOP_SIGNAL=SIGQUIT MOCK_STOP_TIMEOUT=25
MOCK_GROUP_ADD=video MOCK_ULIMITS='nofile=1024:2048'
MOCK_MEMORY=536870912 MOCK_NANOCPUS=1500000000
MOCK_HOSTNAME=webhost MOCK_MAC='02:42:ac:11:00:05'
MOCK_HC_TEST='CMD-SHELL
curl -f http://localhost/'
MOCK_HC_META='30s|5s|10s|3'
MOCK_VOLUMES="$ANON_VOL|/data|true"
export MOCK_LABELS MOCK_IMG_LABELS MOCK_SYSCTLS MOCK_LOG_DRIVER MOCK_LOG_OPTS
export MOCK_STOP_SIGNAL MOCK_STOP_TIMEOUT MOCK_GROUP_ADD MOCK_ULIMITS
export MOCK_MEMORY MOCK_NANOCPUS MOCK_HOSTNAME MOCK_MAC MOCK_HC_TEST MOCK_HC_META MOCK_VOLUMES

: >"$CALLS"
expect_success "expanded spec capture succeeds" container_capture_spec webapp
: >"$CALLS"
expect_success "canonical replay succeeds" container_run_saved canonical webapp-new acr.example/ns/webapp:latest
RUN_LINE="$(grep '^run ' "$CALLS" | tail -n1)"
assert_contains "user label replayed" "$RUN_LINE" '--label app.role=web'
assert_contains "compose label re-stamped" "$RUN_LINE" '--label com.docker.compose.project=smg'
assert_not_contains "image-inherited label not pinned" "$RUN_LINE" 'org.example.version'
assert_contains "sysctl replayed" "$RUN_LINE" '--sysctl net.ipv4.ip_forward=1'
assert_contains "log driver replayed" "$RUN_LINE" '--log-driver json-file'
assert_contains "log option replayed" "$RUN_LINE" '--log-opt max-size=10m'
assert_contains "stop signal replayed" "$RUN_LINE" '--stop-signal SIGQUIT'
assert_contains "stop timeout replayed" "$RUN_LINE" '--stop-timeout 25'
assert_contains "group-add replayed" "$RUN_LINE" '--group-add video'
assert_contains "ulimit replayed" "$RUN_LINE" '--ulimit nofile=1024:2048'
assert_contains "memory limit replayed" "$RUN_LINE" '--memory 536870912'
assert_contains "cpu limit replayed as decimal" "$RUN_LINE" '--cpus 1.5'
assert_contains "explicit hostname replayed" "$RUN_LINE" '--hostname webhost'
assert_contains "mac address replayed" "$RUN_LINE" '--mac-address 02:42:ac:11:00:05'
assert_contains "primary network restored" "$RUN_LINE" '--network appnet'
assert_contains "static IP restored" "$RUN_LINE" '--ip 10.10.0.5'
assert_contains "user network alias restored" "$RUN_LINE" '--network-alias web'
assert_not_contains "auto short-id alias filtered" "$RUN_LINE" '--network-alias aabbccddeeff'
assert_contains "anonymous volume replayed by name" "$RUN_LINE" "-v $ANON_VOL:/data"
assert_contains "bind mount replayed" "$RUN_LINE" '-v /host/cfg:/cfg:ro'
assert_contains "published port restored" "$RUN_LINE" '-p 8080:80/tcp'
assert_contains "healthcheck override replayed" "$RUN_LINE" '--health-cmd curl -f http://localhost/'
assert_contains "healthcheck interval replayed" "$RUN_LINE" '--health-interval 30s'
assert_contains "healthcheck retries replayed" "$RUN_LINE" '--health-retries 3'

# --- T2: candidate mode omits conflict-capable settings ----------------------
: >"$CALLS"
expect_success "candidate replay succeeds" container_run_saved candidate webapp-cand acr.example/ns/webapp:latest
CAND_LINE="$(grep '^run ' "$CALLS" | tail -n1)"
assert_not_contains "candidate omits published port" "$CAND_LINE" '-p 8080:80/tcp'
assert_not_contains "candidate omits static IP" "$CAND_LINE" '--ip 10.10.0.5'
assert_not_contains "candidate omits network alias" "$CAND_LINE" '--network-alias'
assert_contains "candidate never auto-restarts" "$CAND_LINE" '--restart no'

# --- T3: restore_old recreates from the saved old image ----------------------
: >"$CALLS"
expect_success "restore_old succeeds" container_restore_old webapp
RESTORE_CALLS="$(cat "$CALLS")"
assert_contains "restore removes the failed container" "$RESTORE_CALLS" 'rm -f webapp'
assert_contains "restore recreates from old image ID" "$RESTORE_CALLS" 'sha256:oldimg'
container_cleanup_workdir

# --- T4: auto-generated hostname is not pinned -------------------------------
MOCK_HOSTNAME=aabbccddeeff; export MOCK_HOSTNAME
expect_success "capture with auto hostname" container_capture_spec webapp
: >"$CALLS"
expect_success "replay with auto hostname" container_run_saved canonical webapp-new acr.example/ns/webapp:latest
assert_not_contains "auto short-id hostname not replayed" "$(grep '^run ' "$CALLS" | tail -n1)" '--hostname'
container_cleanup_workdir

# --- T5: image-inherited healthcheck is not replayed --------------------------
MOCK_IMG_HC_TEST="$MOCK_HC_TEST" MOCK_IMG_HC_META="$MOCK_HC_META"
export MOCK_IMG_HC_TEST MOCK_IMG_HC_META
expect_success "capture with inherited healthcheck" container_capture_spec webapp
: >"$CALLS"
expect_success "replay with inherited healthcheck" container_run_saved canonical webapp-new acr.example/ns/webapp:latest
assert_not_contains "inherited healthcheck left to the image" "$(grep '^run ' "$CALLS" | tail -n1)" '--health-cmd'
container_cleanup_workdir
MOCK_IMG_HC_TEST= MOCK_IMG_HC_META=; export MOCK_IMG_HC_TEST MOCK_IMG_HC_META

# --- T6: exec-form healthcheck override is fail-closed ------------------------
MOCK_HC_TEST='CMD
/bin/check'
export MOCK_HC_TEST
HC_OUT="$(container_capture_spec webapp 2>&1)" && fail "exec-form healthcheck override must refuse" || ok
assert_contains "exec-form refusal names the cause" "$HC_OUT" 'exec-form'
container_cleanup_workdir
MOCK_HC_TEST='CMD-SHELL
curl -f http://localhost/'
export MOCK_HC_TEST

# --- T7: unreplayable-mode refusals -------------------------------------------
MOCK_NETWORK_MODE='container:other'; export MOCK_NETWORK_MODE
expect_failure "container network mode refused" container_capture_spec webapp
MOCK_NETWORK_MODE=appnet; export MOCK_NETWORK_MODE
MOCK_AUTOREMOVE=true; export MOCK_AUTOREMOVE
expect_failure "AutoRemove container refused" container_capture_spec webapp
MOCK_AUTOREMOVE=false; export MOCK_AUTOREMOVE
MOCK_IPC='container:x'; export MOCK_IPC
expect_failure "container IPC mode refused" container_capture_spec webapp
MOCK_IPC=; export MOCK_IPC
MOCK_PID='container:x'; export MOCK_PID
expect_failure "container PID mode refused" container_capture_spec webapp
MOCK_PID=; export MOCK_PID
container_cleanup_workdir

# --- T8: fail-closed parity guard ---------------------------------------------
MOCK_GUARD=''; export MOCK_GUARD
expect_success "all-default guard passes" container_parity_guard webapp
MOCK_GUARD='Mounts=1'; export MOCK_GUARD
GUARD_OUT="$(container_parity_guard webapp 2>&1)" && fail "non-default Mounts must refuse" || ok
assert_contains "guard refusal names the field" "$GUARD_OUT" 'Mounts=1'
MOCK_GUARD='PidsLimit=<nil>'; export MOCK_GUARD
expect_success "nil PidsLimit passes" container_parity_guard webapp
MOCK_GUARD='PidsLimit=100'; export MOCK_GUARD
expect_failure "set PidsLimit refused" container_parity_guard webapp
MOCK_GUARD='Runtime=runc'; export MOCK_GUARD
expect_success "default runtime passes" container_parity_guard webapp
MOCK_GUARD='Runtime=kata'; export MOCK_GUARD
expect_failure "alternate runtime refused" container_parity_guard webapp
MOCK_GUARD='Init=true'; export MOCK_GUARD
expect_failure "docker --init refused" container_parity_guard webapp
MOCK_GUARD=''; export MOCK_GUARD

# --- T9: enrollment list CRUD + validation --------------------------------
TARGETS_FILE="$TMP/update-targets"
MIHOMO_CONTAINER=mihomo METACUBEXD_CONTAINER=metacubexd CF_CONTAINER_NAME=cloudflared
DOCKER_REGISTRY=acr.example ACR_NAMESPACE=myns

expect_success "enroll creates a record" target_enroll webctr
grep -q '^webctr|recreate|$' "$TARGETS_FILE" && ok || fail "enroll wrote the default record"
PERM="$(ls -l "$TARGETS_FILE" | cut -c1-10)"
[ "$PERM" = "-rw-------" ] && ok || fail "targets file is not chmod 600 ($PERM)"
expect_success "re-enroll updates in place" target_enroll webctr recreate 'log:ready'
[ "$(grep -c '^webctr|' "$TARGETS_FILE")" = 1 ] && ok || fail "re-enroll duplicated the record"
grep -q '^webctr|recreate|log:ready$' "$TARGETS_FILE" && ok || fail "re-enroll updated the probe"
expect_failure "gateway trio cannot be enrolled" target_enroll mihomo
expect_failure "invalid container name refused" target_enroll 'bad;name'
expect_failure "invalid strategy refused" target_enroll okctr bluegreen
expect_failure "probe with shell metachars refused" target_enroll okctr recreate 'exec:x; rm -rf /'
expect_success "remove deletes the record" target_remove webctr
grep -q '^webctr|' "$TARGETS_FILE" && fail "remove left the record behind" || ok
expect_failure "removing an unknown target fails loudly" target_remove ghostctr

expect_success "well-formed list validates" sh -c "printf '%s\n' 'webctr|recreate|' 'apictr|recreate|exec:curl -f http://localhost/' > '$TARGETS_FILE'; TARGETS_FILE='$TARGETS_FILE' true" 
expect_success "targets_validate accepts the list" targets_validate
printf '%s\n' 'bad name|recreate|' > "$TARGETS_FILE"
expect_failure "name with space rejected" targets_validate
printf '%s\n' 'webctr|teleport|' > "$TARGETS_FILE"
expect_failure "unknown strategy rejected" targets_validate
printf '%s\n' 'webctr|recreate|x|y' > "$TARGETS_FILE"
expect_failure "extra field rejected" targets_validate

# --- T9b: injection regressions (QA findings) --------------------------------
: >"$TARGETS_FILE"
expect_failure "probe with pipe delimiter refused" target_enroll okctr recreate 'exec:ps aux | grep ready'
expect_failure "probe with newline refused" target_enroll okctr recreate "exec:x
fake|recreate|"
expect_success "enroll webXtr" target_enroll webXtr
expect_failure "removing web.tr must not wildcard-match webXtr" target_remove web.tr
grep -q '^webXtr|' "$TARGETS_FILE" && ok || fail "dot-collision deleted webXtr"
expect_success "enroll literal web.tr" target_enroll web.tr
expect_success "remove literal web.tr" target_remove web.tr
grep -q '^webXtr|' "$TARGETS_FILE" && ok || fail "removing web.tr cross-deleted webXtr"

# --- T10: database-image warning helper -------------------------------------
expect_success "postgres image flagged database-like" targets_image_databaselike 'acr.example/myns/postgres:16'
expect_failure "web image not database-like" targets_image_databaselike 'acr.example/myns/web:latest'

# --- T11: discovery filters (policy denylist + ACR gate) ---------------------
printf '%s
' \
  'webctr|recreate|' \
  'composectr|recreate|' \
  'ambctr|recreate|' \
  'hubctr|recreate|' \
  'stopctr|recreate|' \
  'missingctr|recreate|' \
  'mihomo|recreate|' \
  'denctr|recreate|' > "$TARGETS_FILE"
UPDATE_DENY_CONTAINERS='den*'
DISCOVER_OUT="$(targets_discover 2>"$TMP/discover.log")"
DISCOVER_LOG="$(cat "$TMP/discover.log")"
[ "$DISCOVER_OUT" = 'webctr|acr.example/myns/web:latest|recreate|' ] && ok || fail "discovery emitted: $DISCOVER_OUT"
assert_contains "compose-managed excluded with reason" "$DISCOVER_LOG" 'composectr'
assert_contains "ambiguous excluded with reason" "$DISCOVER_LOG" 'ambctr'
assert_contains "non-ACR image excluded actionably" "$DISCOVER_LOG" 'Mirror it first'
assert_contains "gateway trio excluded from discovery" "$DISCOVER_LOG" 'mihomo'
assert_contains "deny pattern excluded" "$DISCOVER_LOG" 'denctr'
assert_not_contains "eligible target not warned about" "$DISCOVER_LOG" 'webctr'
UPDATE_DENY_CONTAINERS=

# --- T12: discovery is empty-safe when ACR mode is off ------------------------
_OLD_REG="$DOCKER_REGISTRY"
DOCKER_REGISTRY=
NOACR_OUT="$(targets_discover 2>/dev/null)"
[ -z "$NOACR_OUT" ] && ok || fail "REGISTRY_MODE=docker must yield zero candidates"
DOCKER_REGISTRY="$_OLD_REG"

# --- T13: generic driver (health ladder, rollback, last-good) -----------------
# The driver functions live in auto_update.sh; source it via its test seam.
(
  AUTO_UPDATE_SOURCE_ONLY=1
  AUTO_UPDATE_SELF_DIR="$ROOT/scripts"
  export AUTO_UPDATE_SOURCE_ONLY AUTO_UPDATE_SELF_DIR
  GATEWAY_DATA_DIR="$TMP/data"
  export GATEWAY_DATA_DIR
  # shellcheck source=scripts/auto_update.sh
  . "$ROOT/scripts/auto_update.sh"
  DOCKER_BIN="$MOCK_DOCKER"
  LOG_FILE="$TMP/driver.log"
  HEALTH_RETRIES=2 HEALTH_INTERVAL=0 HEALTH_MAX_RESTARTS=3
  sleep() { :; }
  DFAIL=0
  dfail() { printf 'FAIL: %s\n' "$*" >&2; DFAIL=$((DFAIL + 1)); }

  # ladder: floor-only passes with a WARN
  MOCK_HEALTH_STATUS=none MOCK_RESTARTS=0; export MOCK_HEALTH_STATUS MOCK_RESTARTS
  FLOOR_OUT="$(generic_health_gate webapp '' 2>&1)" || dfail "floor-only gate should pass"
  case "$FLOOR_OUT" in *floor*|*WARN*) : ;; *) dfail "floor-only gate did not WARN" ;; esac

  # ladder: native healthcheck must reach healthy
  MOCK_HEALTH_STATUS=unhealthy; export MOCK_HEALTH_STATUS
  generic_health_gate webapp '' >/dev/null 2>&1 && dfail "unhealthy native status must fail the gate"
  MOCK_HEALTH_STATUS=healthy; export MOCK_HEALTH_STATUS
  generic_health_gate webapp '' >/dev/null 2>&1 || dfail "healthy native status should pass"

  # ladder: exec + log probes
  MOCK_HEALTH_STATUS=none MOCK_EXEC_RC=1; export MOCK_HEALTH_STATUS MOCK_EXEC_RC
  generic_health_gate webapp 'exec:true-check' >/dev/null 2>&1 && dfail "failing exec probe must fail the gate"
  MOCK_EXEC_RC=0; export MOCK_EXEC_RC
  generic_health_gate webapp 'exec:true-check' >/dev/null 2>&1 || dfail "passing exec probe should pass"
  MOCK_LOGS='service ready'; export MOCK_LOGS
  generic_health_gate webapp 'log:ready' >/dev/null 2>&1 || dfail "log marker probe should pass"
  MOCK_LOGS='starting'; export MOCK_LOGS
  generic_health_gate webapp 'log:ready' >/dev/null 2>&1 && dfail "missing log marker must fail the gate"
  MOCK_LOGS=; export MOCK_LOGS

  # update: happy path persists last-good only after the gate passes
  MOCK_HEALTH_STATUS=none; export MOCK_HEALTH_STATUS
  : >"$CALLS"
  generic_update_target webapp acr.example/myns/web:new '' >/dev/null 2>&1 \
    || dfail "happy-path generic update should succeed"
  grep -q '^rm -f webapp$' "$CALLS" || dfail "old container was not removed in place"
  grep -q '^run .*acr.example/myns/web:new' "$CALLS" || dfail "new image was not run"
  LG="$GATEWAY_DATA_DIR/state/last-good/webapp"
  [ -f "$LG" ] || dfail "last-good record missing"
  grep -q '^image_id=sha256:newimg$' "$LG" 2>/dev/null || dfail "last-good image_id wrong: $(cat "$LG" 2>/dev/null)"
  grep -q '^spec_digest=..*$' "$LG" 2>/dev/null || dfail "last-good spec digest missing"
  LGPERM="$(ls -l "$LG" 2>/dev/null | cut -c1-10)"
  [ "$LGPERM" = "-rw-------" ] || dfail "last-good record not chmod 600 ($LGPERM)"

  # update: failed apply auto-restores the saved old image (rolled-back rc=2)
  MOCK_RUN_FAIL_FLAG="$TMP/run.fail.once"; export MOCK_RUN_FAIL_FLAG
  : >"$MOCK_RUN_FAIL_FLAG"
  : >"$CALLS"
  generic_update_target webapp acr.example/myns/web:new '' >/dev/null 2>&1
  _gu_rc=$?
  [ "$_gu_rc" = 2 ] || dfail "rolled-back update should return 2 (got $_gu_rc)"
  grep -q '^run .*sha256:oldimg' "$CALLS" || dfail "rollback did not recreate the old image"
  MOCK_RUN_FAIL_FLAG=; export MOCK_RUN_FAIL_FLAG

  # refusal: a parity-guard hit returns 3 and leaves the container UNTOUCHED
  # (the orchestrator reports it as REFUSED, never as rollback-incomplete)
  MOCK_GUARD='Mounts=1'; export MOCK_GUARD
  : >"$CALLS"
  generic_update_target webapp acr.example/myns/web:new '' >/dev/null 2>&1
  _gu_rc=$?
  [ "$_gu_rc" = 3 ] || dfail "guard refusal should return 3 (got $_gu_rc)"
  grep -q '^rm -f webapp$' "$CALLS" && dfail "guard refusal removed the container"
  MOCK_GUARD=''; export MOCK_GUARD

  # pull-failure classification: only unambiguous missing-manifest errors get
  # the mirroring hint; auth/ACL failures must not be misdiagnosed.
  PULL_LAST_ERROR='manifest unknown: manifest unknown'
  case "$(pull_failure_hint)" in
    *"not mirrored in ACR"*) : ;;
    *) dfail "manifest-unknown pull failure lacks the mirroring hint" ;;
  esac
  PULL_LAST_ERROR="pull access denied for acr.example/myns/web, repository does not exist or may require 'docker login'"
  case "$(pull_failure_hint)" in
    '') : ;;
    *) dfail "access-denied pull failure must not get the mirroring hint" ;;
  esac
  PULL_LAST_ERROR='net/http: TLS handshake timeout'
  case "$(pull_failure_hint)" in
    '') : ;;
    *) dfail "transient network pull failure must not get the mirroring hint" ;;
  esac

  exit "$DFAIL"
)
_drc=$?
if [ "$_drc" -eq 0 ]; then
  PASS=$((PASS + 22))
else
  FAIL=$((FAIL + _drc))
fi

# --- T14: state_diff.sh derives from the capture contract ---------------------
SD="$ROOT/scripts/state_diff.sh"
SNAP="$TMP/snap"
export DOCKER_BIN   # state_diff.sh runs as a subprocess against the fake docker
MOCK_HEALTH_STATUS=none MOCK_HOSTNAME=webhost; export MOCK_HEALTH_STATUS MOCK_HOSTNAME
expect_success "state snapshot succeeds" sh "$SD" snapshot webapp "$SNAP"
[ -f "$SNAP/scalars" ] || fail "snapshot did not write the scalar set"
assert_not_contains "image id exempt from the contract" "$(cat "$SNAP/scalars")" 'sha256:oldimg'
expect_success "identical container compares clean" sh "$SD" compare webapp "$SNAP"
_OLD_SYSCTLS="$MOCK_SYSCTLS"
MOCK_SYSCTLS='net.ipv4.ip_forward=0'; export MOCK_SYSCTLS
SD_OUT="$(sh "$SD" compare webapp "$SNAP" 2>&1)" && fail "mutated sysctl must fail the diff" || ok
assert_contains "diff names the drifted field" "$SD_OUT" 'sysctls'
MOCK_SYSCTLS="$_OLD_SYSCTLS"; export MOCK_SYSCTLS
_OLD_STOP="$MOCK_STOP_SIGNAL"
MOCK_STOP_SIGNAL=SIGTERM; export MOCK_STOP_SIGNAL
SD_OUT="$(sh "$SD" compare webapp "$SNAP" 2>&1)" && fail "mutated stop signal must fail the diff" || ok
assert_contains "scalar diff names the field" "$SD_OUT" 'stop_signal'
MOCK_STOP_SIGNAL="$_OLD_STOP"; export MOCK_STOP_SIGNAL
# A recreated container gets a new Id: its auto short-id alias and an
# auto-generated hostname must be normalized away, never reported as drift.
MOCK_ID='ffeeddccbbaa99887766554433221100' MOCK_HOSTNAME=webhost
MOCK_NETWORKS='appnet|10.10.0.5|web,ffeeddccbbaa'
export MOCK_ID MOCK_HOSTNAME MOCK_NETWORKS
expect_success "new container id and auto alias are normalized" sh "$SD" compare webapp "$SNAP"
unset MOCK_ID MOCK_NETWORKS

# --- T15: fail-closed hardening regressions -----------------------------------
# parity guard: uncaptured publish/oom/device-cgroup settings refuse
MOCK_GUARD='PublishAllPorts=true'; export MOCK_GUARD
GUARD_OUT="$(container_parity_guard webapp 2>&1)" && fail "-P container must refuse" || ok
assert_contains "guard names PublishAllPorts" "$GUARD_OUT" 'PublishAllPorts=true'
MOCK_GUARD='PublishAllPorts=false'; export MOCK_GUARD
expect_success "default PublishAllPorts passes" container_parity_guard webapp
MOCK_GUARD='OomScoreAdj=500'; export MOCK_GUARD
expect_failure "OomScoreAdj refused" container_parity_guard webapp
MOCK_GUARD='OomScoreAdj=0'; export MOCK_GUARD
expect_success "default OomScoreAdj passes" container_parity_guard webapp
MOCK_GUARD='DeviceCgroupRules=1'; export MOCK_GUARD
expect_failure "DeviceCgroupRules refused" container_parity_guard webapp
MOCK_GUARD=''; export MOCK_GUARD

# newline smuggling: element counts must match the captured line counts
MOCK_COUNTS='2 1 1 3 2'; export MOCK_COUNTS
NL_OUT="$(container_capture_spec webapp 2>&1)" && fail "env newline mismatch must refuse" || ok
assert_contains "newline refusal names the artifact" "$NL_OUT" 'env'
unset MOCK_COUNTS
container_cleanup_workdir

# static IPv6 is fail-closed
MOCK_IP6='fd00:1::10'; export MOCK_IP6
IP6_OUT="$(container_capture_spec webapp 2>&1)" && fail "static IPv6 must refuse" || ok
assert_contains "IPv6 refusal names the cause" "$IP6_OUT" 'IPv6'
MOCK_IP6=''; export MOCK_IP6
container_cleanup_workdir

# image-inherited env/cmd/entrypoint are NOT pinned onto the new image
MOCK_IMG_ENV='APP_MODE=prod' MOCK_IMG_CMD='serve' MOCK_IMG_ENTRYPOINT='/entry'
export MOCK_IMG_ENV MOCK_IMG_CMD MOCK_IMG_ENTRYPOINT
expect_success "capture with inherited env/cmd/entrypoint" container_capture_spec webapp
[ -s "$CTR_WORKDIR/env" ] && fail "inherited env line was pinned" || ok
: >"$CALLS"
expect_success "replay with inherited cmd/entrypoint" container_run_saved canonical webapp-new acr.example/ns/webapp:latest
INHERIT_LINE="$(grep '^run ' "$CALLS" | tail -n1)"
assert_not_contains "inherited entrypoint left to the image" "$INHERIT_LINE" '--entrypoint'
assert_not_contains "inherited cmd left to the image" "$INHERIT_LINE" ' serve'
container_cleanup_workdir

# create-time overrides ARE still replayed when the image defaults differ
MOCK_IMG_ENV='OTHER=1' MOCK_IMG_CMD='old-serve' MOCK_IMG_ENTRYPOINT='/old-entry'
export MOCK_IMG_ENV MOCK_IMG_CMD MOCK_IMG_ENTRYPOINT
expect_success "capture with real overrides" container_capture_spec webapp
grep -qx 'APP_MODE=prod' "$CTR_WORKDIR/env" && ok || fail "override env line lost"
: >"$CALLS"
expect_success "replay with real overrides" container_run_saved canonical webapp-new acr.example/ns/webapp:latest
OVR_LINE="$(grep '^run ' "$CALLS" | tail -n1)"
assert_contains "override entrypoint replayed" "$OVR_LINE" '--entrypoint /entry'
assert_contains "override cmd replayed" "$OVR_LINE" ' serve'
container_cleanup_workdir
MOCK_IMG_ENV= MOCK_IMG_CMD= MOCK_IMG_ENTRYPOINT=
export MOCK_IMG_ENV MOCK_IMG_CMD MOCK_IMG_ENTRYPOINT

# a dynamically-assigned IP is never pinned (default-bridge replay must work:
# docker rejects --ip there, which would break update AND rollback)
MOCK_NETWORKS='bridge||'; export MOCK_NETWORKS
MOCK_NETWORK_MODE=bridge; export MOCK_NETWORK_MODE
expect_success "capture on the default bridge" container_capture_spec webapp
: >"$CALLS"
expect_success "replay on the default bridge" container_run_saved canonical webapp-new acr.example/ns/webapp:latest
BR_LINE="$(grep '^run ' "$CALLS" | tail -n1)"
assert_not_contains "dynamic IP not pinned" "$BR_LINE" '--ip '
container_cleanup_workdir
unset MOCK_NETWORKS; MOCK_NETWORK_MODE=appnet; export MOCK_NETWORK_MODE

# a pinned MAC stays off the candidate (it would collide with the live one)
expect_success "capture for candidate MAC check" container_capture_spec webapp
: >"$CALLS"
expect_success "candidate replay for MAC check" container_run_saved candidate webapp-cand acr.example/ns/webapp:latest
assert_not_contains "candidate omits the pinned MAC" "$(grep '^run ' "$CALLS" | tail -n1)" '--mac-address'
container_cleanup_workdir

# an empty RestartPolicy.Name replays as no policy, not unless-stopped
MOCK_RESTART_POLICY=; export MOCK_RESTART_POLICY
expect_success "capture with empty restart policy" container_capture_spec webapp
: >"$CALLS"
expect_success "replay with empty restart policy" container_run_saved canonical webapp-new acr.example/ns/webapp:latest
assert_contains "empty policy replays as --restart no" "$(grep '^run ' "$CALLS" | tail -n1)" '--restart no'
container_cleanup_workdir
unset MOCK_RESTART_POLICY

# mid-capture failure must not leak the secret-bearing workdir
TMPDIR="$TMP"; export TMPDIR
expect_failure "mid-capture inspect failure fails the capture" container_capture_spec failctr
ls "$TMP"/smg-container.* >/dev/null 2>&1 && fail "capture failure leaked a workdir" || ok
unset TMPDIR

# concurrent enroll/remove: a held lock fails loudly, then releases cleanly
mkdir "$TARGETS_FILE.lock"
LOCK_OUT="$(target_enroll lockctr 2>&1)" && fail "held lock must fail enroll" || ok
assert_contains "lock failure names the lock dir" "$LOCK_OUT" 'lock'
rmdir "$TARGETS_FILE.lock"
expect_success "enroll succeeds after lock release" target_enroll lockctr
[ -d "$TARGETS_FILE.lock" ] && fail "enroll left the lock held" || ok
expect_success "cleanup lockctr" target_remove lockctr

if [ "$FAIL" -ne 0 ]; then
  printf 'FAILED: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'OK: %s generic capture/replay assertions passed\n' "$PASS"
