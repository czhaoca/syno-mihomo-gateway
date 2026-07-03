#!/bin/sh
# state_diff.sh - prove a container's replayable configuration survived an
# update. Snapshots are taken with the SAME capture engine the updater
# replays from (scripts/lib/container.sh), so the compared field set IS the
# retention contract - never a hand-maintained copy of it.
#
# Exempt by derivation (expected to change across an update): the image ID,
# the container Id, and Docker-generated identity that follows the Id (the
# auto short-id network alias and an auto-generated hostname).
#
# Caveat: the labels, env, cmd, entrypoint and hc-test/hc-meta artifacts are
# DERIVED OVERRIDES relative to each side's own image (container value minus
# that image's baked-in value). A rare false DRIFT on exactly these artifacts
# is possible when the new image bakes in the same override verbatim -
# confirm with a manual `docker inspect` diff before treating it as a real
# regression.
#
# Normalized by design (never drift): bind mounts and volume attachments are
# compared as ONE canonical set (a replayed anonymous volume legitimately
# moves from Mounts to Binds), and network_mode "default" equals "bridge".
#
# Usage:
#   state_diff.sh snapshot NAME DIR   # before the update
#   state_diff.sh compare  NAME DIR   # after the update; exit 1 on drift
#
# Read-only against the daemon. POSIX /bin/sh (DSM BusyBox).

PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

SELF_DIR="${STATE_DIFF_SELF_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/lib/common.sh"
# shellcheck source=scripts/lib/container.sh
. "$SELF_DIR/lib/container.sh"

LOG_FILE="${LOG_FILE:-/dev/null}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

SD_FILES="env cmd entrypoint mounts ports dns extra-hosts cap-add cap-drop security-opt devices tmpfs sysctls log-opts group-add ulimits labels"

# _sd_collect NAME OUTDIR - one normalized snapshot of the capture contract.
_sd_collect() {
  _sdc_name="$1"; _sdc_dir="$2"
  container_capture_spec "$_sdc_name" || return 1
  mkdir -p "$_sdc_dir" || { container_cleanup_workdir; return 1; }
  for _sdc_f in $SD_FILES; do
    cp "$CTR_WORKDIR/$_sdc_f" "$_sdc_dir/$_sdc_f" 2>/dev/null || : >"$_sdc_dir/$_sdc_f"
  done
  # Binds-vs-volumes is Docker bookkeeping, not configuration: an
  # image-declared VOLUME attaches anonymously (in Mounts), and a faithful
  # replay must re-attach that same volume via -v name:dest - which Docker
  # records under Binds. Comparing the two files separately would flag that
  # legitimate move as drift, so compare ONE canonical attachment set instead.
  {
    awk -F: 'NF >= 2 { ro = "rw"; if ($3 ~ /(^|,)ro(,|$)/) ro = "ro"; print $1 "|" $2 "|" ro }' \
      "$CTR_WORKDIR/binds" 2>/dev/null
    awk -F'|' 'NF >= 2 { print $1 "|" $2 "|" ($3 == "true" ? "rw" : "ro") }' \
      "$CTR_WORKDIR/volumes" 2>/dev/null
  } | sort >"$_sdc_dir/mounts"
  # Docker adds the container's own short id as a network alias; a recreated
  # container gets a new one by design, so it is identity, not configuration.
  awk -F'|' -v id="$(printf '%.12s' "${CTR_SPEC_ID:-}")" '{
    n = split($3, a, ","); out = ""
    for (i = 1; i <= n; i++) if (a[i] != "" && a[i] != id) out = out (out == "" ? "" : ",") a[i]
    print $1 "|" $2 "|" out
  }' "$CTR_WORKDIR/networks.raw" >"$_sdc_dir/networks" 2>/dev/null || : >"$_sdc_dir/networks"
  {
    printf 'restart=%s\n' "${CTR_SPEC_RESTART:-}"
    printf 'restart_max=%s\n' "${CTR_SPEC_RESTART_MAX:-}"
    printf 'user=%s\n' "${CTR_SPEC_USER:-}"
    printf 'workdir=%s\n' "${CTR_SPEC_WORKDIR:-}"
    printf 'readonly=%s\n' "${CTR_SPEC_READONLY:-}"
    printf 'privileged=%s\n' "${CTR_SPEC_PRIVILEGED:-}"
    # "default" IS the bridge network; a replay that re-attaches the bridge
    # explicitly changes only the label, not the dataplane. Normalize so the
    # equivalent modes never read as drift.
    _sdc_netmode="${CTR_SPEC_NETWORK_MODE:-}"
    [ "$_sdc_netmode" = default ] && _sdc_netmode=bridge
    printf 'network_mode=%s\n' "$_sdc_netmode"
    printf 'log_driver=%s\n' "${CTR_SPEC_LOG_DRIVER:-}"
    printf 'stop_signal=%s\n' "${CTR_SPEC_STOP_SIGNAL:-}"
    printf 'stop_timeout=%s\n' "${CTR_SPEC_STOP_TIMEOUT:-}"
    printf 'memory=%s\n' "${CTR_SPEC_MEMORY:-}"
    printf 'nanocpus=%s\n' "${CTR_SPEC_NANOCPUS:-}"
    printf 'shm=%s\n' "${CTR_SPEC_SHM:-}"
    printf 'oom_disable=%s\n' "${CTR_SPEC_OOM_DISABLE:-}"
    printf 'mac=%s\n' "${CTR_SPEC_MAC:-}"
    printf 'ipc=%s\n' "${CTR_SPEC_IPC:-}"
    printf 'pid=%s\n' "${CTR_SPEC_PID:-}"
    printf 'uts=%s\n' "${CTR_SPEC_UTS:-}"
    printf 'hostname=%s\n' "${CTR_SPEC_HOSTNAME:-}"
    printf 'hc_override=%s\n' "${CTR_SPEC_HC_REPLAY:-0}"
  } >"$_sdc_dir/scalars"
  if [ "${CTR_SPEC_HC_REPLAY:-0}" = 1 ]; then
    cp "$CTR_WORKDIR/hc-test" "$_sdc_dir/hc-test" 2>/dev/null || : >"$_sdc_dir/hc-test"
    cp "$CTR_WORKDIR/hc-meta" "$_sdc_dir/hc-meta" 2>/dev/null || : >"$_sdc_dir/hc-meta"
  else
    : >"$_sdc_dir/hc-test"; : >"$_sdc_dir/hc-meta"
  fi
  container_cleanup_workdir
  return 0
}

sd_snapshot() {
  _sd_collect "$1" "$2" || { echo "state_diff: could not snapshot '$1'" >&2; exit 1; }
  echo "state_diff: snapshot of '$1' written to $2"
  exit 0
}

sd_compare() {
  _sdm_name="$1"; _sdm_base="$2"
  [ -f "$_sdm_base/scalars" ] || { echo "state_diff: '$_sdm_base' is not a snapshot directory" >&2; exit 1; }
  _sdm_now="$(mktemp -d "${TMPDIR:-/tmp}/smg-statediff.XXXXXX")" || exit 1
  trap 'rm -rf "$_sdm_now"' EXIT INT TERM
  _sd_collect "$_sdm_name" "$_sdm_now" || { echo "state_diff: could not re-capture '$_sdm_name'" >&2; exit 1; }
  _sdm_drift=0
  for _sdm_f in $SD_FILES networks hc-test hc-meta; do
    if ! cmp -s "$_sdm_base/$_sdm_f" "$_sdm_now/$_sdm_f" 2>/dev/null; then
      _sdm_drift=1
      echo "DRIFT: $_sdm_f"
      diff "$_sdm_base/$_sdm_f" "$_sdm_now/$_sdm_f" 2>/dev/null | sed 's/^/  /'
    fi
  done
  _sdm_keys="$(awk -F= 'NR == FNR { v[$1] = $2; next } ($1 in v) && v[$1] != $2 { print $1 }' \
    "$_sdm_base/scalars" "$_sdm_now/scalars")"
  if [ -n "$_sdm_keys" ]; then
    _sdm_drift=1
    for _sdm_k in $_sdm_keys; do
      echo "DRIFT: $_sdm_k ($(grep "^$_sdm_k=" "$_sdm_base/scalars") -> $(grep "^$_sdm_k=" "$_sdm_now/scalars"))"
    done
  fi
  if [ "$_sdm_drift" -ne 0 ]; then
    echo "state_diff: '$_sdm_name' DRIFTED from the snapshot - the update did not retain its configuration" >&2
    exit 1
  fi
  echo "state_diff: '$_sdm_name' matches the snapshot (image/identity fields exempt)"
  exit 0
}

case "${1:-}" in
  snapshot) [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: state_diff.sh snapshot NAME DIR" >&2; exit 1; }
            sd_snapshot "$2" "$3" ;;
  compare)  [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: state_diff.sh compare NAME DIR" >&2; exit 1; }
            sd_compare "$2" "$3" ;;
  *) echo "usage: state_diff.sh snapshot|compare NAME DIR" >&2; exit 1 ;;
esac
