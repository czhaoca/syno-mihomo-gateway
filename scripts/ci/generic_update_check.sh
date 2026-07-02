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
    case "$*" in
      "inspect missingctr") exit 1 ;;
      *"compose.service"*composectr) echo 'web|smg-stack'; exit 0 ;;
      *"compose.service"*ambctr) echo 'web|'; exit 0 ;;
      *"compose.service"*) echo '|'; exit 0 ;;
      *"Config.Image"*hubctr) echo 'docker.io/library/nginx:latest'; exit 0 ;;
      *"Config.Image"*) echo 'acr.example/myns/web:latest'; exit 0 ;;
      *".State.Running"*stopctr) echo false; exit 0 ;;
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
      *"RestartPolicy.Name"*) echo unless-stopped; exit 0 ;;
      *"MaximumRetryCount"*) echo 0; exit 0 ;;
      *"Config.User"*|*"Config.WorkingDir"*) exit 0 ;;
      *"ReadonlyRootfs"*|*"Privileged"*) echo false; exit 0 ;;
      *"{{.Image}}"*) echo sha256:oldimg; exit 0 ;;
    esac
    exit 0 ;;
  run) exit "${MOCK_RUN_RC:-0}" ;;
  rm|stop|start|network|logs) exit 0 ;;
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
assert_contains "non-ACR image excluded actionably" "$DISCOVER_LOG" 'docker-china-sync'
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

if [ "$FAIL" -ne 0 ]; then
  printf 'FAILED: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'OK: %s generic capture/replay assertions passed\n' "$PASS"
