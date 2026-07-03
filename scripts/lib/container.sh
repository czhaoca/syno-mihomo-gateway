#!/bin/sh
# container.sh - generic container spec capture/replay engine.
#
# Snapshots a running container's replayable configuration from `docker
# inspect` into a private workdir, recreates the container by name from any
# image with that exact configuration, and restores the saved old image on
# failure. Extracted from the cloudflared blue-green updater (which now
# specializes it); consumed by the generic in-place update driver.
#
# Fail-closed contract (DEC-4): any setting this engine cannot faithfully
# replay must cause a refusal, never a silent drop. Hard refusals live in
# container_capture_spec (container:* net/ipc/pid modes, --rm, exec-form
# healthcheck overrides); the remaining uncaptured HostConfig surface is
# policed by container_parity_guard, which callers run before an update.
#
# Requires common.sh (log_*) and DOCKER_BIN. POSIX /bin/sh only.
# shellcheck disable=SC2016 # Docker Go templates are intentionally single quoted.

CTR_WORKDIR=""

container_cleanup_workdir() {
  [ -n "${CTR_WORKDIR:-}" ] || return 0
  rm -rf "$CTR_WORKDIR" 2>/dev/null || true
  CTR_WORKDIR=""
}

container_make_workdir() {
  container_cleanup_workdir
  CTR_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/smg-container.XXXXXX" 2>/dev/null)" || {
    log_error "could not create a private container state directory"
    return 1
  }
  chmod 700 "$CTR_WORKDIR" 2>/dev/null || {
    container_cleanup_workdir
    return 1
  }
  return 0
}

# The docker CLI appends one newline AFTER the template output, so a template
# that already ends each element with \n leaves a trailing blank line in every
# line-oriented capture file - which the element-count guard would misread as
# an embedded newline on EVERY real daemon (the fake-docker suites emit exact
# lines and never showed it). Normalize here: strip trailing newlines and emit
# nothing at all for empty output, so file line counts equal element counts.
# A value genuinely ending in \n now under-counts instead of over-counting;
# the guard still refuses it (DEC-4 fail-closed), just with the same message.
_ctr_inspect() {
  _ci_out="$("$DOCKER_BIN" inspect -f "$1" "$2" 2>/dev/null)" || return 1
  [ -n "$_ci_out" ] && printf '%s\n' "$_ci_out"
  return 0
}

# Uncaptured-but-consequential HostConfig surface. Everything here is a setting
# container_run_saved does not replay; a non-default value means an in-place
# recreate would silently degrade the container, so the guard refuses instead.
# The leading comment doubles as a fixture marker for the fake-docker suites.
CTR_GUARD_TMPL='{{/*ctr-guard*/}}Links={{len .HostConfig.Links}}
VolumesFrom={{len .HostConfig.VolumesFrom}}
Mounts={{len .HostConfig.Mounts}}
DeviceRequests={{len .HostConfig.DeviceRequests}}
DeviceCgroupRules={{len .HostConfig.DeviceCgroupRules}}
DnsOptions={{len .HostConfig.DnsOptions}}
DnsSearch={{len .HostConfig.DnsSearch}}
CpusetCpus={{.HostConfig.CpusetCpus}}
CpusetMems={{.HostConfig.CpusetMems}}
CgroupParent={{.HostConfig.CgroupParent}}
UsernsMode={{.HostConfig.UsernsMode}}
CpuShares={{.HostConfig.CpuShares}}
BlkioWeight={{.HostConfig.BlkioWeight}}
PidsLimit={{.HostConfig.PidsLimit}}
OomScoreAdj={{.HostConfig.OomScoreAdj}}
PublishAllPorts={{.HostConfig.PublishAllPorts}}
Init={{.HostConfig.Init}}
Runtime={{.HostConfig.Runtime}}'

# container_parity_guard NAME - 0 iff every uncaptured field is at its default.
container_parity_guard() {
  _cpg_name="$1"
  _cpg_out="$(_ctr_inspect "$CTR_GUARD_TMPL" "$_cpg_name")" || {
    log_error "parity guard: cannot inspect '$_cpg_name'"
    return 1
  }
  _cpg_bad="$(printf '%s\n' "$_cpg_out" | awk -F= '
    $1=="Links" || $1=="VolumesFrom" || $1=="Mounts" || $1=="DeviceRequests" \
      || $1=="DeviceCgroupRules" || $1=="DnsOptions" || $1=="DnsSearch" \
      || $1=="CpuShares" || $1=="BlkioWeight" || $1=="OomScoreAdj" \
      { if ($2 != "0" && $2 != "") print $1"="$2 }
    $1=="CpusetCpus" || $1=="CpusetMems" || $1=="CgroupParent" \
      || $1=="UsernsMode" { if ($2 != "") print $1"="$2 }
    $1=="PidsLimit" { if ($2 != "" && $2 != "0" && $2 != "<nil>") print $1"="$2 }
    $1=="PublishAllPorts" { if ($2 != "" && $2 != "false") print $1"="$2 }
    $1=="Init" { if ($2 != "" && $2 != "false" && $2 != "<nil>") print $1"="$2 }
    $1=="Runtime" { if ($2 != "" && $2 != "runc") print $1"="$2 }
  ')"
  [ -z "$_cpg_bad" ] && return 0
  log_error "parity guard: container '$_cpg_name' carries settings this updater cannot replay: $(printf '%s' "$_cpg_bad" | tr '\n' ' ') - refusing in-place update"
  return 1
}

# Capture the subset of Docker run configuration this engine can faithfully
# replay. Values with spaces remain one line/argument and are never eval'd.
# Any failure cleans up the workdir (it holds the container's env, which may
# carry credentials) - the impl can bail with a bare `return 1` at any point.
container_capture_spec() {
  _container_capture_spec_impl "$@" && return 0
  container_cleanup_workdir
  return 1
}

_container_capture_spec_impl() {
  _ccs_name="$1"
  container_make_workdir || return 1

  _ccs_netmode="$(_ctr_inspect '{{.HostConfig.NetworkMode}}' "$_ccs_name")"
  case "$_ccs_netmode" in container:*)
    log_error "container '$_ccs_name' uses container network mode, which cannot be replayed safely"
    container_cleanup_workdir; return 1 ;;
  esac
  if [ "$(_ctr_inspect '{{.HostConfig.AutoRemove}}' "$_ccs_name")" = true ]; then
    log_error "container '$_ccs_name' was created with --rm; automatic replacement is unsafe"
    container_cleanup_workdir; return 1
  fi
  CTR_SPEC_IPC="$(_ctr_inspect '{{.HostConfig.IpcMode}}' "$_ccs_name")"
  case "$CTR_SPEC_IPC" in container:*)
    log_error "container '$_ccs_name' shares another container's IPC namespace, which cannot be replayed safely"
    container_cleanup_workdir; return 1 ;;
  esac
  CTR_SPEC_PID="$(_ctr_inspect '{{.HostConfig.PidMode}}' "$_ccs_name")"
  case "$CTR_SPEC_PID" in container:*)
    log_error "container '$_ccs_name' shares another container's PID namespace, which cannot be replayed safely"
    container_cleanup_workdir; return 1 ;;
  esac
  CTR_SPEC_UTS="$(_ctr_inspect '{{.HostConfig.UTSMode}}' "$_ccs_name")"

  _ctr_inspect '{{range .Config.Env}}{{println .}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/env" || return 1
  chmod 600 "$CTR_WORKDIR/env" 2>/dev/null || return 1
  _ctr_inspect '{{range .Config.Cmd}}{{println .}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/cmd" || return 1
  _ctr_inspect '{{range .Config.Entrypoint}}{{println .}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/entrypoint" || return 1
  _ctr_inspect '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/binds" || return 1
  awk -F: 'NF >= 2 { print $2 }' "$CTR_WORKDIR/binds" >"$CTR_WORKDIR/bind-destinations" || return 1
  _ctr_inspect '{{range .Mounts}}{{if eq .Type "volume"}}{{printf "%s|%s|%t\n" .Name .Destination .RW}}{{end}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/volumes" || return 1
  _ctr_inspect '{{range $p,$c := .HostConfig.PortBindings}}{{range $c}}{{printf "%s|%s|%s\n" .HostIp .HostPort $p}}{{end}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/ports" || return 1
  # Record the USER-REQUESTED static address (IPAMConfig), never the runtime
  # one: replaying a daemon-assigned dynamic IP would freeze it - and docker
  # outright rejects --ip on the default bridge, which would break both the
  # update and the rollback. Dynamic allocations replay as dynamic.
  _ctr_inspect '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s|" $k}}{{if $v.IPAMConfig}}{{$v.IPAMConfig.IPv4Address}}{{end}}{{printf "|%s\n" (join $v.Aliases ",")}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/networks.raw" || return 1
  # Static IPv6 is not replayed (no --ip6 path); a pinned address would be
  # silently dropped on recreate, so refuse instead (DEC-4).
  _ccs_ip6="$(_ctr_inspect '{{range $k,$v := .NetworkSettings.Networks}}{{if $v.IPAMConfig}}{{$v.IPAMConfig.IPv6Address}}{{end}}{{end}}' "$_ccs_name")"
  if [ -n "$_ccs_ip6" ]; then
    log_error "container '$_ccs_name' pins a static IPv6 address, which this engine cannot replay - refusing in-place update"
    return 1
  fi
  _ctr_inspect '{{range .HostConfig.Dns}}{{println .}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/dns" || return 1
  _ctr_inspect '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/extra-hosts" || return 1
  _ctr_inspect '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/cap-add" || return 1
  _ctr_inspect '{{range .HostConfig.CapDrop}}{{println .}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/cap-drop" || return 1
  _ctr_inspect '{{range .HostConfig.SecurityOpt}}{{println .}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/security-opt" || return 1
  _ctr_inspect '{{range .HostConfig.Devices}}{{printf "%s:%s:%s\n" .PathOnHost .PathInContainer .CgroupPermissions}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/devices" || return 1
  _ctr_inspect '{{range $p,$o := .HostConfig.Tmpfs}}{{printf "%s|%s\n" $p $o}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/tmpfs" || return 1
  _ctr_inspect '{{range $k,$v := .HostConfig.Sysctls}}{{printf "%s=%s\n" $k $v}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/sysctls" || return 1
  _ctr_inspect '{{range $k,$v := .HostConfig.LogConfig.Config}}{{printf "%s=%s\n" $k $v}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/log-opts" || return 1
  _ctr_inspect '{{range .HostConfig.GroupAdd}}{{println .}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/group-add" || return 1
  _ctr_inspect '{{range .HostConfig.Ulimits}}{{printf "%s=%d:%d\n" .Name .Soft .Hard}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/ulimits" || return 1

  CTR_SPEC_RESTART="$(_ctr_inspect '{{.HostConfig.RestartPolicy.Name}}' "$_ccs_name")"
  CTR_SPEC_RESTART_MAX="$(_ctr_inspect '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "$_ccs_name")"
  CTR_SPEC_USER="$(_ctr_inspect '{{.Config.User}}' "$_ccs_name")"
  CTR_SPEC_WORKDIR="$(_ctr_inspect '{{.Config.WorkingDir}}' "$_ccs_name")"
  CTR_SPEC_READONLY="$(_ctr_inspect '{{.HostConfig.ReadonlyRootfs}}' "$_ccs_name")"
  CTR_SPEC_PRIVILEGED="$(_ctr_inspect '{{.HostConfig.Privileged}}' "$_ccs_name")"
  CTR_SPEC_LOG_DRIVER="$(_ctr_inspect '{{.HostConfig.LogConfig.Type}}' "$_ccs_name")"
  CTR_SPEC_STOP_SIGNAL="$(_ctr_inspect '{{.Config.StopSignal}}' "$_ccs_name")"
  CTR_SPEC_STOP_TIMEOUT="$(_ctr_inspect '{{if .Config.StopTimeout}}{{.Config.StopTimeout}}{{end}}' "$_ccs_name")"
  CTR_SPEC_MEMORY="$(_ctr_inspect '{{.HostConfig.Memory}}' "$_ccs_name")"
  CTR_SPEC_NANOCPUS="$(_ctr_inspect '{{.HostConfig.NanoCpus}}' "$_ccs_name")"
  CTR_SPEC_SHM="$(_ctr_inspect '{{.HostConfig.ShmSize}}' "$_ccs_name")"
  CTR_SPEC_OOM_DISABLE="$(_ctr_inspect '{{.HostConfig.OomKillDisable}}' "$_ccs_name")"
  CTR_SPEC_MAC="$(_ctr_inspect '{{.Config.MacAddress}}' "$_ccs_name")"
  CTR_SPEC_NETWORK_MODE="$_ccs_netmode"
  CTR_SPEC_ID="$(_ctr_inspect '{{.Id}}' "$_ccs_name")"
  CTR_OLD_IMAGE_ID="$(_ctr_inspect '{{.Image}}' "$_ccs_name")"
  [ -n "$CTR_OLD_IMAGE_ID" ] || {
    log_error "could not capture the current image ID of '$_ccs_name'"
    container_cleanup_workdir; return 1
  }

  # A hostname equal to the container's short ID is Docker-generated; pinning
  # it onto the replacement would freeze a stale identifier.
  CTR_SPEC_HOSTNAME="$(_ctr_inspect '{{.Config.Hostname}}' "$_ccs_name")"
  _ccs_id12="$(printf '%.12s' "$CTR_SPEC_ID")"
  [ -n "$_ccs_id12" ] && [ "$CTR_SPEC_HOSTNAME" = "$_ccs_id12" ] && CTR_SPEC_HOSTNAME=""

  # Replay only labels the container does not inherit unchanged from its old
  # image: pinning image labels would mask the new image's own values.
  _ctr_inspect '{{range $k,$v := .Config.Labels}}{{printf "%s=%s\n" $k $v}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/labels.ctr" || return 1
  _ctr_inspect '{{range $k,$v := .Config.Labels}}{{printf "%s=%s\n" $k $v}}{{end}}' "$CTR_OLD_IMAGE_ID" >"$CTR_WORKDIR/labels.img" || return 1
  if [ -s "$CTR_WORKDIR/labels.img" ]; then
    grep -Fxv -f "$CTR_WORKDIR/labels.img" "$CTR_WORKDIR/labels.ctr" >"$CTR_WORKDIR/labels" || : >"$CTR_WORKDIR/labels"
  else
    cp "$CTR_WORKDIR/labels.ctr" "$CTR_WORKDIR/labels" || return 1
  fi

  # A healthcheck identical to the old image's is inherited - the new image
  # supplies its own. A differing one is a create-time override and must be
  # replayed; only the CMD-SHELL/NONE forms map onto docker-run flags.
  _ctr_inspect '{{if .Config.Healthcheck}}{{range .Config.Healthcheck.Test}}{{println .}}{{end}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/hc-test" || return 1
  _ctr_inspect '{{if .Config.Healthcheck}}{{.Config.Healthcheck.Interval}}|{{.Config.Healthcheck.Timeout}}|{{.Config.Healthcheck.StartPeriod}}|{{.Config.Healthcheck.Retries}}{{end}}' "$_ccs_name" >"$CTR_WORKDIR/hc-meta" || return 1
  _ctr_inspect '{{if .Config.Healthcheck}}{{range .Config.Healthcheck.Test}}{{println .}}{{end}}{{end}}' "$CTR_OLD_IMAGE_ID" >"$CTR_WORKDIR/hc-test.img" || return 1
  _ctr_inspect '{{if .Config.Healthcheck}}{{.Config.Healthcheck.Interval}}|{{.Config.Healthcheck.Timeout}}|{{.Config.Healthcheck.StartPeriod}}|{{.Config.Healthcheck.Retries}}{{end}}' "$CTR_OLD_IMAGE_ID" >"$CTR_WORKDIR/hc-meta.img" || return 1

  # Fail closed on values the line-oriented capture cannot represent: an
  # element with an embedded newline spans extra lines and would be replayed
  # corrupted (split argv, truncated value), so refuse instead (DEC-4). The
  # element counts come straight from the daemon and must match the files.
  _ccs_counts="$(_ctr_inspect '{{/*ctr-counts*/}}{{len .Config.Env}} {{len .Config.Cmd}} {{len .Config.Entrypoint}} {{len .Config.Labels}} {{if .Config.Healthcheck}}{{len .Config.Healthcheck.Test}}{{else}}0{{end}}' "$_ccs_name")" || return 1
  set -f
  # shellcheck disable=SC2086 # deliberate word-split of the count quintet (set -f guards globs)
  set -- $_ccs_counts
  set +f
  if [ "$#" -ne 5 ]; then
    log_error "could not read the configuration element counts of '$_ccs_name'"
    return 1
  fi
  for _ccs_pair in "env=$1" "cmd=$2" "entrypoint=$3" "labels.ctr=$4" "hc-test=$5"; do
    _ccs_field="${_ccs_pair%%=*}"; _ccs_want="${_ccs_pair#*=}"
    _ccs_have="$(wc -l <"$CTR_WORKDIR/$_ccs_field" 2>/dev/null | tr -dc 0-9)"
    if [ "${_ccs_have:-0}" -ne "$_ccs_want" ] 2>/dev/null; then
      log_error "container '$_ccs_name': a $_ccs_field value contains an embedded newline, which cannot be replayed faithfully - refusing in-place update"
      return 1
    fi
  done

  # Env, Cmd and Entrypoint are inspected MERGED with the old image's own
  # defaults; replaying them wholesale would pin the OLD image's values onto
  # the new image (the same masking problem the labels/healthcheck handling
  # already solves). Keep only the create-time overrides: env lines the old
  # image does not carry verbatim, and Cmd/Entrypoint only when they differ
  # from the old image's - the new image then supplies its own defaults.
  _ctr_inspect '{{range .Config.Env}}{{println .}}{{end}}' "$CTR_OLD_IMAGE_ID" >"$CTR_WORKDIR/env.img" || return 1
  chmod 600 "$CTR_WORKDIR/env.img" 2>/dev/null || return 1
  if [ -s "$CTR_WORKDIR/env.img" ]; then
    grep -Fxv -f "$CTR_WORKDIR/env.img" "$CTR_WORKDIR/env" >"$CTR_WORKDIR/env.next" || : >>"$CTR_WORKDIR/env.next"
    chmod 600 "$CTR_WORKDIR/env.next" 2>/dev/null || return 1
    mv "$CTR_WORKDIR/env.next" "$CTR_WORKDIR/env" || return 1
  fi
  _ctr_inspect '{{range .Config.Cmd}}{{println .}}{{end}}' "$CTR_OLD_IMAGE_ID" >"$CTR_WORKDIR/cmd.img" || return 1
  _ctr_inspect '{{range .Config.Entrypoint}}{{println .}}{{end}}' "$CTR_OLD_IMAGE_ID" >"$CTR_WORKDIR/entrypoint.img" || return 1
  cmp -s "$CTR_WORKDIR/cmd" "$CTR_WORKDIR/cmd.img" && : >"$CTR_WORKDIR/cmd"
  cmp -s "$CTR_WORKDIR/entrypoint" "$CTR_WORKDIR/entrypoint.img" && : >"$CTR_WORKDIR/entrypoint"

  CTR_SPEC_HC_REPLAY=0
  if [ -s "$CTR_WORKDIR/hc-test" ]; then
    if ! cmp -s "$CTR_WORKDIR/hc-test" "$CTR_WORKDIR/hc-test.img" \
       || ! cmp -s "$CTR_WORKDIR/hc-meta" "$CTR_WORKDIR/hc-meta.img"; then
      case "$(sed -n '1p' "$CTR_WORKDIR/hc-test")" in
        CMD-SHELL|NONE) CTR_SPEC_HC_REPLAY=1 ;;
        *)
          log_error "container '$_ccs_name' carries an exec-form healthcheck override, which docker run cannot replay - refusing in-place update"
          container_cleanup_workdir; return 1 ;;
      esac
    fi
  fi

  # Replay the original primary network first, then all additional networks.
  # awk only creates the split files it writes to; pre-create both so the
  # replay loops always have a file to read.
  : >"$CTR_WORKDIR/networks.primary"; : >"$CTR_WORKDIR/networks.extra"
  awk -F'|' -v primary="$CTR_SPEC_NETWORK_MODE" '
    $1 == primary { print > primary_file; next }
    { print > extra_file }
  ' primary_file="$CTR_WORKDIR/networks.primary" extra_file="$CTR_WORKDIR/networks.extra" \
    "$CTR_WORKDIR/networks.raw"
  [ -s "$CTR_WORKDIR/networks.primary" ] || {
    sed -n '1p' "$CTR_WORKDIR/networks.raw" >"$CTR_WORKDIR/networks.primary"
    sed '1d' "$CTR_WORKDIR/networks.raw" >"$CTR_WORKDIR/networks.extra"
  }
  return 0
}

# Emit each saved alias except Docker's auto-added short-container-ID one.
_ctr_alias_list() {
  _cal_id12="$(printf '%.12s' "${CTR_SPEC_ID:-}")"
  printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r _cal_a; do
    [ -n "$_cal_a" ] || continue
    [ -n "$_cal_id12" ] && [ "$_cal_a" = "$_cal_id12" ] && continue
    printf '%s\n' "$_cal_a"
  done
}

# container_run_saved MODE NAME IMAGE - recreate from the captured spec.
# candidate mode omits anything that could collide with the live container
# (published ports, static IPs, network aliases) and never auto-restarts.
container_run_saved() {
  _crs_mode="$1"; _crs_name="$2"; _crs_image="$3"
  if [ "$_crs_mode" = candidate ]; then
    set -- --name "$_crs_name" --env-file "$CTR_WORKDIR/env" --restart no
  else
    # An empty captured RestartPolicy.Name means "no policy" (API-created
    # containers report ""); upgrading it would change crash/boot behavior.
    _crs_restart="${CTR_SPEC_RESTART:-no}"
    if [ "$_crs_restart" = on-failure ] && [ "${CTR_SPEC_RESTART_MAX:-0}" -gt 0 ] 2>/dev/null; then
      _crs_restart="on-failure:${CTR_SPEC_RESTART_MAX}"
    fi
    set -- --name "$_crs_name" --env-file "$CTR_WORKDIR/env" --restart "$_crs_restart"
  fi
  [ -n "${CTR_SPEC_USER:-}" ] && set -- "$@" --user "$CTR_SPEC_USER"
  [ -n "${CTR_SPEC_WORKDIR:-}" ] && set -- "$@" --workdir "$CTR_SPEC_WORKDIR"
  [ "${CTR_SPEC_READONLY:-false}" = true ] && set -- "$@" --read-only
  [ "${CTR_SPEC_PRIVILEGED:-false}" = true ] && set -- "$@" --privileged
  [ -n "${CTR_SPEC_HOSTNAME:-}" ] && set -- "$@" --hostname "$CTR_SPEC_HOSTNAME"
  # A pinned MAC is as collision-prone as a static IP: two containers sharing
  # one L2 address flap ARP. Candidates run beside the live container, so the
  # MAC is replayed only on the canonical replacement.
  if [ "$_crs_mode" = canonical ] && [ -n "${CTR_SPEC_MAC:-}" ]; then
    set -- "$@" --mac-address "$CTR_SPEC_MAC"
  fi
  [ -n "${CTR_SPEC_STOP_SIGNAL:-}" ] && set -- "$@" --stop-signal "$CTR_SPEC_STOP_SIGNAL"
  [ -n "${CTR_SPEC_STOP_TIMEOUT:-}" ] && set -- "$@" --stop-timeout "$CTR_SPEC_STOP_TIMEOUT"
  case "${CTR_SPEC_IPC:-}" in host|private|shareable|none) set -- "$@" --ipc "$CTR_SPEC_IPC" ;; esac
  [ "${CTR_SPEC_PID:-}" = host ] && set -- "$@" --pid host
  [ "${CTR_SPEC_UTS:-}" = host ] && set -- "$@" --uts host
  [ -n "${CTR_SPEC_LOG_DRIVER:-}" ] && set -- "$@" --log-driver "$CTR_SPEC_LOG_DRIVER"
  if [ "${CTR_SPEC_MEMORY:-0}" -gt 0 ] 2>/dev/null; then set -- "$@" --memory "$CTR_SPEC_MEMORY"; fi
  if [ "${CTR_SPEC_NANOCPUS:-0}" -gt 0 ] 2>/dev/null; then
    set -- "$@" --cpus "$(awk -v n="$CTR_SPEC_NANOCPUS" 'BEGIN { printf "%g", n / 1000000000 }')"
  fi
  # 67108864 is dockerd's built-in /dev/shm default; only a deviation is a setting.
  if [ "${CTR_SPEC_SHM:-0}" -gt 0 ] 2>/dev/null && [ "${CTR_SPEC_SHM}" != 67108864 ]; then
    set -- "$@" --shm-size "$CTR_SPEC_SHM"
  fi
  [ "${CTR_SPEC_OOM_DISABLE:-false}" = true ] && set -- "$@" --oom-kill-disable

  _crs_primary="$(head -n1 "$CTR_WORKDIR/networks.primary" 2>/dev/null)"
  _crs_primary_name="$(printf '%s' "$_crs_primary" | cut -d'|' -f1)"
  _crs_primary_ip="$(printf '%s' "$_crs_primary" | cut -d'|' -f2)"
  _crs_primary_aliases="$(printf '%s' "$_crs_primary" | cut -d'|' -f3)"
  [ -n "$_crs_primary_name" ] && set -- "$@" --network "$_crs_primary_name"
  if [ "$_crs_mode" = canonical ] && [ -z "$_crs_primary_name" ]; then
    case "${CTR_SPEC_NETWORK_MODE:-}" in
      host|none|bridge) set -- "$@" --network "$CTR_SPEC_NETWORK_MODE" ;;
    esac
  fi
  if [ "$_crs_mode" = canonical ] && [ -n "$_crs_primary_ip" ]; then
    set -- "$@" --ip "$_crs_primary_ip"
  fi
  if [ "$_crs_mode" = canonical ] && [ -n "$_crs_primary_aliases" ]; then
    while IFS= read -r _crs_alias || [ -n "$_crs_alias" ]; do
      [ -n "$_crs_alias" ] && set -- "$@" --network-alias "$_crs_alias"
    done <<EOF
$(_ctr_alias_list "$_crs_primary_aliases")
EOF
  fi

  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" -v "$_crs_line"; done <"$CTR_WORKDIR/binds"
  while IFS='|' read -r _crs_volume _crs_dest _crs_rw || [ -n "$_crs_volume$_crs_dest" ]; do
    [ -n "$_crs_volume" ] && [ -n "$_crs_dest" ] || continue
    grep -Fqx "$_crs_dest" "$CTR_WORKDIR/bind-destinations" 2>/dev/null && continue
    if [ "$_crs_rw" = false ]; then set -- "$@" -v "$_crs_volume:$_crs_dest:ro"; else set -- "$@" -v "$_crs_volume:$_crs_dest"; fi
  done <"$CTR_WORKDIR/volumes"
  if [ "$_crs_mode" = canonical ]; then
    while IFS='|' read -r _crs_hip _crs_hport _crs_cport || [ -n "$_crs_cport" ]; do
      [ -n "$_crs_cport" ] || continue
      if [ -n "$_crs_hip" ]; then set -- "$@" -p "$_crs_hip:$_crs_hport:$_crs_cport"; else set -- "$@" -p "$_crs_hport:$_crs_cport"; fi
    done <"$CTR_WORKDIR/ports"
  fi
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --dns "$_crs_line"; done <"$CTR_WORKDIR/dns"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --add-host "$_crs_line"; done <"$CTR_WORKDIR/extra-hosts"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --cap-add "$_crs_line"; done <"$CTR_WORKDIR/cap-add"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --cap-drop "$_crs_line"; done <"$CTR_WORKDIR/cap-drop"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --security-opt "$_crs_line"; done <"$CTR_WORKDIR/security-opt"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --device "$_crs_line"; done <"$CTR_WORKDIR/devices"
  while IFS='|' read -r _crs_path _crs_opts || [ -n "$_crs_path" ]; do
    [ -n "$_crs_path" ] || continue
    if [ -n "$_crs_opts" ]; then set -- "$@" --tmpfs "$_crs_path:$_crs_opts"; else set -- "$@" --tmpfs "$_crs_path"; fi
  done <"$CTR_WORKDIR/tmpfs"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --label "$_crs_line"; done <"$CTR_WORKDIR/labels"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --sysctl "$_crs_line"; done <"$CTR_WORKDIR/sysctls"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --log-opt "$_crs_line"; done <"$CTR_WORKDIR/log-opts"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --group-add "$_crs_line"; done <"$CTR_WORKDIR/group-add"
  while IFS= read -r _crs_line || [ -n "$_crs_line" ]; do [ -n "$_crs_line" ] && set -- "$@" --ulimit "$_crs_line"; done <"$CTR_WORKDIR/ulimits"

  if [ "${CTR_SPEC_HC_REPLAY:-0}" = 1 ]; then
    if [ "$(sed -n '1p' "$CTR_WORKDIR/hc-test")" = NONE ]; then
      set -- "$@" --no-healthcheck
    else
      set -- "$@" --health-cmd "$(sed -n '2p' "$CTR_WORKDIR/hc-test")"
      IFS='|' read -r _crs_hci _crs_hct _crs_hcs _crs_hcr <"$CTR_WORKDIR/hc-meta"
      [ -n "$_crs_hci" ] && [ "$_crs_hci" != 0s ] && set -- "$@" --health-interval "$_crs_hci"
      [ -n "$_crs_hct" ] && [ "$_crs_hct" != 0s ] && set -- "$@" --health-timeout "$_crs_hct"
      [ -n "$_crs_hcs" ] && [ "$_crs_hcs" != 0s ] && set -- "$@" --health-start-period "$_crs_hcs"
      [ -n "$_crs_hcr" ] && [ "$_crs_hcr" != 0 ] && set -- "$@" --health-retries "$_crs_hcr"
    fi
  fi

  _crs_entrypoint="$(sed -n '1p' "$CTR_WORKDIR/entrypoint")"
  [ -n "$_crs_entrypoint" ] && set -- "$@" --entrypoint "$_crs_entrypoint"
  set -- "$@" "$_crs_image"
  # Docker --entrypoint accepts only the executable. Preserve any additional
  # entrypoint argv by placing it before the saved Config.Cmd arguments.
  sed '1d' "$CTR_WORKDIR/entrypoint" >"$CTR_WORKDIR/entrypoint.rest"
  while IFS= read -r _crs_arg || [ -n "$_crs_arg" ]; do set -- "$@" "$_crs_arg"; done <"$CTR_WORKDIR/entrypoint.rest"
  while IFS= read -r _crs_arg || [ -n "$_crs_arg" ]; do set -- "$@" "$_crs_arg"; done <"$CTR_WORKDIR/cmd"

  if ! "$DOCKER_BIN" run -d "$@" >>"$LOG_FILE" 2>&1; then return 1; fi

  # The first line was used at docker run time. Attach remaining networks with
  # dynamic addresses for the candidate and their saved addresses for canonical.
  while IFS='|' read -r _crs_net _crs_ip _crs_aliases || [ -n "$_crs_net" ]; do
    [ -n "$_crs_net" ] || continue
    set -- network connect
    if [ "$_crs_mode" = canonical ]; then
      [ -n "$_crs_ip" ] && set -- "$@" --ip "$_crs_ip"
      if [ -n "$_crs_aliases" ]; then
        while IFS= read -r _crs_alias || [ -n "$_crs_alias" ]; do
          [ -n "$_crs_alias" ] && set -- "$@" --alias "$_crs_alias"
        done <<EOF
$(_ctr_alias_list "$_crs_aliases")
EOF
      fi
    fi
    "$DOCKER_BIN" "$@" "$_crs_net" "$_crs_name" >>"$LOG_FILE" 2>&1 || return 1
  done <"$CTR_WORKDIR/networks.extra"
  return 0
}

# container_restore_old NAME - replace NAME with the captured last-good image.
# Health verification is the caller's job (probes differ per target).
container_restore_old() {
  _cro_name="$1"
  [ -n "${CTR_OLD_IMAGE_ID:-}" ] || {
    log_error "no captured image ID to restore for '$_cro_name'"
    return 1
  }
  "$DOCKER_BIN" rm -f "$_cro_name" >/dev/null 2>&1 || true
  log_warn "container '$_cro_name': restoring previous image $CTR_OLD_IMAGE_ID"
  container_run_saved canonical "$_cro_name" "$CTR_OLD_IMAGE_ID"
}
