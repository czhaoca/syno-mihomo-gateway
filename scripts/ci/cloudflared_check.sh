#!/bin/sh
# Unit tests for the external cloudflared staged updater.
# shellcheck disable=SC2016

set -u
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/smg-cloudflared-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# shellcheck source=scripts/ci/lib/assert.sh
. "$ROOT/scripts/ci/lib/assert.sh"

# shellcheck source=scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/cloudflared.sh
. "$ROOT/scripts/lib/cloudflared.sh"

LOG_FILE="$TMP/update.log"
CALLS="$TMP/docker.calls"
export CALLS
MOCK_DOCKER="$TMP/docker"
cat >"$MOCK_DOCKER" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  inspect)
    # Emulate the real CLI: docker inspect -f appends ONE newline after the
    # template output (see generic_update_check.sh for the full rationale).
    (
    case "$*" in
      "inspect cloudflared") exit "${MOCK_BLUE_INSPECT_RC:-0}" ;;
      "inspect cloudflared-candidate") exit "${MOCK_CAND_INSPECT_RC:-1}" ;;
      *ctr-counts*) echo "${MOCK_COUNTS:-2 4 2 0 0}"; exit 0 ;;
      *IPv6Address*) printf '%s' "${MOCK_IP6:-}"; exit 0 ;;
      *"Config.Env"*sha256:old-cloudflared) exit 0 ;;
      *"Config.Cmd"*sha256:old-cloudflared) exit 0 ;;
      *"Config.Entrypoint"*sha256:old-cloudflared) exit 0 ;;
      *".State.Running"*)
        case "$*" in *cloudflared-candidate*) echo "${MOCK_CAND_RUNNING:-true}" ;; *) echo "${MOCK_BLUE_RUNNING:-true}" ;; esac; exit 0 ;;
      *"State.Health"*) echo "${MOCK_HEALTH:-healthy}"; exit 0 ;;
      *"HostConfig.NetworkMode"*) echo "${MOCK_NETWORK_MODE:-bridge}"; exit 0 ;;
      *"HostConfig.AutoRemove"*) echo false; exit 0 ;;
      *"Config.Env"*) printf '%s\n' 'TUNNEL_TOKEN=preserved' 'TUNNEL_METRICS=0.0.0.0:2000'; exit 0 ;;
      *"Config.Cmd"*) printf '%s\n' tunnel run '--label' 'name with spaces'; exit 0 ;;
      *"Config.Entrypoint"*) printf '%s\n' /usr/local/bin/cloudflared --no-autoupdate; exit 0 ;;
      *"HostConfig.Binds"*) printf '%s\n' "${MOCK_BINDS:-/cfg:/etc/cloudflared:ro}"; exit 0 ;;
      *".Mounts"*) [ -n "${MOCK_MOUNTS:-}" ] && printf '%s\n' "$MOCK_MOUNTS"; exit 0 ;;
      *"PortBindings"*) echo '127.0.0.1|2000|2000/tcp'; exit 0 ;;
      *"NetworkSettings.Networks"*)
        if [ "${MOCK_NETWORKS+x}" = x ]; then [ -z "$MOCK_NETWORKS" ] || printf '%s\n' "$MOCK_NETWORKS"
        else printf '%s\n' 'bridge|172.17.0.2' 'extra|10.0.0.2'; fi
        exit 0 ;;
      *"HostConfig.Dns"*|*"HostConfig.ExtraHosts"*|*"HostConfig.CapAdd"*|*"HostConfig.CapDrop"*|*"HostConfig.SecurityOpt"*|*"HostConfig.Devices"*|*"HostConfig.Tmpfs"*) exit 0 ;;
      *"RestartPolicy.Name"*) echo unless-stopped; exit 0 ;;
      *"MaximumRetryCount"*) echo 0; exit 0 ;;
      *"Config.User"*|*"Config.WorkingDir"*) exit 0 ;;
      *"ReadonlyRootfs"*|*"HostConfig.Privileged"*) echo false; exit 0 ;;
      *"{{.Image}}"*) echo sha256:old-cloudflared; exit 0 ;;
    esac
    )
    _rc=$?
    [ "$_rc" -eq 0 ] && echo
    exit "$_rc" ;;
  logs) [ "${MOCK_LOG_CONNECTED:-0}" = 1 ] && echo 'Registered tunnel connection'; exit 0 ;;
  run)
    _env_file=""; _want_env=0
    for _arg in "$@"; do
      if [ "$_want_env" = 1 ]; then _env_file="$_arg"; _want_env=0; continue; fi
      [ "$_arg" != --env-file ] || _want_env=1
    done
    if [ -n "$_env_file" ] && [ -f "$_env_file" ] \
       && grep -q '^TUNNEL_TOKEN=secret-token$' "$_env_file"; then
      printf '%s\n' 'env-file-token-present' >> "$CALLS"
    fi
    case "$*" in
      *"--name cloudflared "*"acr.example/cloudflared:latest"*) [ "${MOCK_NEW_CANONICAL_FAIL:-0}" = 1 ] && exit 1 ;;
      *"--name cloudflared-candidate "*) exit "${MOCK_CANDIDATE_RUN_RC:-0}" ;;
    esac
    exit "${MOCK_RUN_RC:-0}" ;;
  stop) exit "${MOCK_STOP_RC:-0}" ;;
  rm) case "$*" in 'rm cloudflared') exit "${MOCK_BLUE_RM_RC:-0}" ;; *) exit 0 ;; esac ;;
  start|network) exit 0 ;;
esac
exit 0
EOF
chmod +x "$MOCK_DOCKER"
DOCKER_BIN="$MOCK_DOCKER"
CF_CONTAINER_NAME=cloudflared
CF_IMAGE=acr.example/cloudflared:latest
CF_HEALTH_TIMEOUT=3
sleep() { :; }

# Cleanup is state-aware: safe with a canonical connector, conservative without.
MOCK_BLUE_INSPECT_RC=0 MOCK_CAND_INSPECT_RC=0 MOCK_BLUE_RUNNING=true MOCK_CAND_RUNNING=true
export MOCK_BLUE_INSPECT_RC MOCK_CAND_INSPECT_RC MOCK_BLUE_RUNNING MOCK_CAND_RUNNING
: >"$CALLS"
expect_success "stale candidate cleanup succeeds when canonical is running" cloudflared_cleanup_candidate
assert_contains "stale candidate removed" "$(cat "$CALLS")" 'rm -f cloudflared-candidate'
MOCK_BLUE_RUNNING=false CF_KEEP_CANDIDATE=0; export MOCK_BLUE_RUNNING
expect_failure "live candidate is preserved when canonical is unavailable" cloudflared_cleanup_candidate
[ "$CF_KEEP_CANDIDATE" = 1 ] && ok || fail "candidate preservation flag"

# Connectivity proof supports native health or the registration log.
CF_KEEP_CANDIDATE=0 MOCK_BLUE_RUNNING=true MOCK_CAND_RUNNING=true MOCK_HEALTH=healthy MOCK_LOG_CONNECTED=0
export MOCK_BLUE_RUNNING MOCK_CAND_RUNNING MOCK_HEALTH MOCK_LOG_CONNECTED
expect_success "native health proves candidate" cloudflared_wait_connected cloudflared-candidate 3
MOCK_CAND_RUNNING=false; export MOCK_CAND_RUNNING
expect_failure "early candidate exit detected" cloudflared_wait_connected cloudflared-candidate 3
MOCK_CAND_RUNNING=true MOCK_HEALTH=none MOCK_LOG_CONNECTED=1
export MOCK_CAND_RUNNING MOCK_HEALTH MOCK_LOG_CONNECTED
expect_success "registration log proves connector" cloudflared_wait_connected cloudflared-candidate 3

# First provision requires a token and removes a failed new container.
MOCK_BLUE_INSPECT_RC=1 MOCK_CAND_INSPECT_RC=1 MOCK_RUN_RC=0 MOCK_HEALTH=healthy MOCK_LOG_CONNECTED=0
export MOCK_BLUE_INSPECT_RC MOCK_CAND_INSPECT_RC MOCK_RUN_RC MOCK_HEALTH MOCK_LOG_CONNECTED
CF_TUNNEL_TOKEN=
expect_failure "first provision requires token" cloudflared_blue_green
CF_TUNNEL_TOKEN=secret-token
: >"$CALLS"
expect_success "first provision starts and verifies" cloudflared_blue_green
assert_contains "first provision receives private env file" "$(cat "$CALLS")" 'env-file-token-present'
assert_not_contains "first provision keeps token out of argv" "$(grep '^run ' "$CALLS")" 'TUNNEL_TOKEN=secret-token'
MOCK_RUN_RC=1; export MOCK_RUN_RC
: >"$CALLS"
expect_failure "failed first provision propagates" cloudflared_blue_green
assert_contains "failed first provision is removed" "$(cat "$CALLS")" 'rm -f cloudflared'

# Existing-container update: candidate omits conflicting ports/static IP; final
# canonical restores them and exact command arguments.
MOCK_BLUE_INSPECT_RC=0 MOCK_CAND_INSPECT_RC=1 MOCK_RUN_RC=0 MOCK_CANDIDATE_RUN_RC=0
MOCK_NEW_CANONICAL_FAIL=0 MOCK_STOP_RC=0 MOCK_BLUE_RM_RC=0 MOCK_BLUE_RUNNING=true MOCK_CAND_RUNNING=true
MOCK_HEALTH=healthy CF_TUNNEL_TOKEN=
export MOCK_BLUE_INSPECT_RC MOCK_CAND_INSPECT_RC MOCK_RUN_RC MOCK_CANDIDATE_RUN_RC
export MOCK_NEW_CANONICAL_FAIL MOCK_STOP_RC MOCK_BLUE_RM_RC MOCK_BLUE_RUNNING MOCK_CAND_RUNNING MOCK_HEALTH
: >"$CALLS"
expect_success "staged update succeeds" cloudflared_blue_green
UPDATE_CALLS="$(cat "$CALLS")"
CAND_RUN="$(printf '%s\n' "$UPDATE_CALLS" | grep '^run .*--name cloudflared-candidate ' | head -n1)"
FINAL_RUN="$(printf '%s\n' "$UPDATE_CALLS" | grep '^run .*--name cloudflared ' | tail -n1)"
assert_not_contains "candidate omits host port" "$CAND_RUN" '-p 127.0.0.1:2000:2000/tcp'
assert_not_contains "candidate omits static IP" "$CAND_RUN" '--ip 172.17.0.2'
assert_contains "canonical restores host port" "$FINAL_RUN" '-p 127.0.0.1:2000:2000/tcp'
assert_contains "canonical restores static IP" "$FINAL_RUN" '--ip 172.17.0.2'
assert_contains "multi-part entrypoint preserved" "$FINAL_RUN" '--entrypoint /usr/local/bin/cloudflared'
assert_contains "command argument with spaces preserved" "$FINAL_RUN" 'name with spaces'
[ -z "$CF_WORKDIR" ] && ok || fail "private state directory was not cleaned"

# Canonical replay preserves host networking, filters duplicate volume mounts,
# and applies a token override only through the private env file.
MOCK_NETWORK_MODE=host MOCK_NETWORKS= MOCK_BINDS='named:/etc/cloudflared:ro'
MOCK_MOUNTS='named|/etc/cloudflared|false' CF_TUNNEL_TOKEN=secret-token
export MOCK_NETWORK_MODE MOCK_NETWORKS MOCK_BINDS MOCK_MOUNTS
_cloudflared_capture_spec cloudflared || fail "host-network spec capture"
grep -q '^TUNNEL_TOKEN=secret-token$' "$CF_WORKDIR/env" && ok || fail "token override stored in private env file"
: >"$CALLS"
expect_success "host-network canonical spec replays" _cloudflared_run_saved canonical cloudflared-replay "$CF_IMAGE"
REPLAY_RUN="$(grep '^run ' "$CALLS" | tail -n1)"
assert_contains "host network restored" "$REPLAY_RUN" '--network host'
MOUNT_COUNT="$(printf '%s\n' "$REPLAY_RUN" | grep -o -- '-v named:/etc/cloudflared:ro' | wc -l | tr -d ' ')"
[ "$MOUNT_COUNT" = 1 ] && ok || fail "named volume was replayed more than once"
assert_not_contains "token override absent from replay argv" "$REPLAY_RUN" 'TUNNEL_TOKEN=secret-token'
cloudflared_cleanup_workdir
unset MOCK_NETWORK_MODE MOCK_NETWORKS MOCK_BINDS MOCK_MOUNTS
CF_TUNNEL_TOKEN=

MOCK_STOP_RC=1; export MOCK_STOP_RC
: >"$CALLS"
expect_failure "unconfirmed old-container stop aborts cutover" cloudflared_blue_green
assert_contains "candidate removed when old connector remains live" "$(cat "$CALLS")" 'rm -f cloudflared-candidate'
MOCK_STOP_RC=0 MOCK_BLUE_RM_RC=1; export MOCK_STOP_RC MOCK_BLUE_RM_RC
: >"$CALLS"
expect_failure "old-container removal failure aborts cutover" cloudflared_blue_green
assert_contains "stopped old connector is restarted" "$(cat "$CALLS")" 'start cloudflared'
MOCK_BLUE_RM_RC=0; export MOCK_BLUE_RM_RC

# A failed new canonical is replaced with the old image while candidate remains.
MOCK_NEW_CANONICAL_FAIL=1; export MOCK_NEW_CANONICAL_FAIL
: >"$CALLS"
expect_failure "failed new canonical reports failure after rollback" cloudflared_blue_green
ROLLBACK_CALLS="$(cat "$CALLS")"
assert_contains "rollback recreates old image" "$ROLLBACK_CALLS" 'sha256:old-cloudflared'
assert_contains "candidate removed only after rollback" "$ROLLBACK_CALLS" 'rm -f cloudflared-candidate'

if [ "$FAIL" -ne 0 ]; then
  printf 'FAILED: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'OK: %s cloudflared staged-update assertions passed\n' "$PASS"
