#!/bin/sh
# targets.sh - enrollment and discovery for the generic auto-update driver.
#
# The enrollment list is the DEC-1 safety boundary: a container is updated by
# the generic driver only when (a) it is explicitly enrolled here AND (b) it
# already runs an image from the configured ACR registry/namespace. There is
# deliberately NO upstream->ACR name translation: mirror-repo name-flattening
# conventions are ambiguous, so only refs that already resolve in ACR are
# eligible; everything else is reported, never guessed.
#
# List file: $GATEWAY_DATA_DIR/state/update-targets, one record per line:
#   name|strategy|probe
#   - name     docker container name ([A-Za-z0-9][A-Za-z0-9_.-]*)
#   - strategy "recreate" (the only v1 strategy; blue-green stays cloudflared's)
#   - probe    "" | exec:<command> | log:<regex>  (consumed by the driver)
#
# Policy refusals here (eligibility) are distinct from container.sh's engine
# refusals (replayability): compose-managed and ambiguous containers, the
# gateway trio, and operator deny patterns never reach the engine at all.
#
# Requires common.sh (log_*, GATEWAY_DATA_DIR) and DOCKER_BIN. POSIX /bin/sh.
# shellcheck disable=SC2016 # Docker Go templates are intentionally single quoted.

TARGETS_FILE="${TARGETS_FILE:-$GATEWAY_DATA_DIR/state/update-targets}"

_targets_state_dir() {
  _tsd_dir="$(dirname "$TARGETS_FILE")"
  mkdir -p "$_tsd_dir" 2>/dev/null || {
    log_error "cannot create targets state directory: $_tsd_dir"
    return 1
  }
  chmod 700 "$_tsd_dir" 2>/dev/null || true
}

# The gateway trio always stays on its bespoke paths.
_targets_reserved_name() {
  case "$1" in
    "${MIHOMO_CONTAINER:-mihomo}"|"${METACUBEXD_CONTAINER:-metacubexd}"|"${CF_CONTAINER_NAME:-cloudflared}") return 0 ;;
  esac
  return 1
}

_targets_valid_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*) return 1 ;;
    [!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}

_targets_valid_strategy() {
  case "$1" in recreate) return 0 ;; esac
  return 1
}

# Probes later reach `docker exec`/`grep` and are stored in a pipe-delimited
# record; refuse shell metacharacters, the field delimiter, and newlines
# rather than trusting a hand-edited state file.
_TARGETS_NL="$(printf '\nx')"; _TARGETS_NL="${_TARGETS_NL%x}"
_targets_valid_probe() {
  case "$1" in
    '') return 0 ;;
    *"|"*|*"$_TARGETS_NL"*) return 1 ;;
    *[\;\&\<\>\`\$\'\"\\]*) return 1 ;;
    exec:?*|log:?*) return 0 ;;
  esac
  return 1
}

# Container names may contain '.', the one BRE metacharacter in the allowed
# charset; escape it so record matching stays exact, never wildcarded.
_targets_name_pattern() {
  printf '%s' "$1" | sed 's/[.]/\\./g'
}

# targets_validate - fail-loud structural check of the enrollment list.
targets_validate() {
  [ -f "$TARGETS_FILE" ] || return 0
  _tv_line=0
  while IFS= read -r _tv_rec || [ -n "$_tv_rec" ]; do
    _tv_line=$((_tv_line + 1))
    [ -n "$_tv_rec" ] || continue
    case "$_tv_rec" in \#*) continue ;; esac
    _tv_rest="$_tv_rec"
    _tv_name="${_tv_rest%%|*}"; _tv_rest="${_tv_rest#*|}"
    [ "$_tv_name" != "$_tv_rec" ] || {
      log_error "update-targets line $_tv_line: expected name|strategy|probe"
      return 1
    }
    _tv_strategy="${_tv_rest%%|*}"; _tv_probe="${_tv_rest#*|}"
    [ "$_tv_strategy" != "$_tv_rest" ] || {
      log_error "update-targets line $_tv_line: expected name|strategy|probe"
      return 1
    }
    case "$_tv_probe" in *"|"*)
      log_error "update-targets line $_tv_line: too many fields"
      return 1 ;;
    esac
    _targets_valid_name "$_tv_name" || {
      log_error "update-targets line $_tv_line: invalid container name '$_tv_name'"
      return 1
    }
    _targets_valid_strategy "$_tv_strategy" || {
      log_error "update-targets line $_tv_line: unknown strategy '$_tv_strategy'"
      return 1
    }
    _targets_valid_probe "$_tv_probe" || {
      log_error "update-targets line $_tv_line: invalid probe '$_tv_probe'"
      return 1
    }
  done <"$TARGETS_FILE"
  return 0
}

# Mutations are serialized through a short mkdir lock so two concurrent
# enroll/remove calls cannot rewrite the list from the same snapshot and
# silently drop each other's records. Readers need no lock (atomic mv).
_targets_lock() {
  _tl_dir="$TARGETS_FILE.lock"
  _tl_tries=0
  while ! mkdir "$_tl_dir" 2>/dev/null; do
    _tl_tries=$((_tl_tries + 1))
    if [ "$_tl_tries" -ge 5 ]; then
      log_error "update-targets list is locked by another process ($_tl_dir); remove it if no enroll/remove is running"
      return 1
    fi
    sleep 1
  done
  return 0
}

_targets_unlock() {
  rmdir "$TARGETS_FILE.lock" 2>/dev/null || true
}

# target_enroll NAME [STRATEGY] [PROBE] - add or update one record atomically.
target_enroll() {
  _te_name="$1"; _te_strategy="${2:-recreate}"; _te_probe="${3:-}"
  _targets_valid_name "$_te_name" || {
    log_error "invalid container name: '$_te_name'"
    return 1
  }
  _targets_reserved_name "$_te_name" && {
    log_error "'$_te_name' is a gateway container managed by its own update path; it cannot be enrolled"
    return 1
  }
  _targets_valid_strategy "$_te_strategy" || {
    log_error "unknown update strategy: '$_te_strategy' (supported: recreate)"
    return 1
  }
  _targets_valid_probe "$_te_probe" || {
    log_error "invalid probe: '$_te_probe' (exec:<cmd> or log:<regex>, no shell metacharacters)"
    return 1
  }
  _targets_state_dir || return 1
  _targets_lock || return 1
  [ -f "$TARGETS_FILE" ] || : >"$TARGETS_FILE" || { _targets_unlock; return 1; }
  grep -v "^$(_targets_name_pattern "$_te_name")|" "$TARGETS_FILE" >"$TARGETS_FILE.next" 2>/dev/null || : >"$TARGETS_FILE.next"
  printf '%s|%s|%s\n' "$_te_name" "$_te_strategy" "$_te_probe" >>"$TARGETS_FILE.next" || { _targets_unlock; return 1; }
  chmod 600 "$TARGETS_FILE.next" 2>/dev/null || { _targets_unlock; return 1; }
  mv "$TARGETS_FILE.next" "$TARGETS_FILE" || { _targets_unlock; return 1; }
  _targets_unlock
  log_info "enrolled '$_te_name' for auto-update (strategy=$_te_strategy)"
}

# target_remove NAME - drop one record; unknown names fail loudly.
target_remove() {
  _tr_name="$1"
  _tr_pat="$(_targets_name_pattern "$_tr_name")"
  if [ ! -f "$TARGETS_FILE" ] || ! grep -q "^$_tr_pat|" "$TARGETS_FILE"; then
    log_error "'$_tr_name' is not enrolled"
    return 1
  fi
  _targets_lock || return 1
  grep -v "^$_tr_pat|" "$TARGETS_FILE" >"$TARGETS_FILE.next" || : >"$TARGETS_FILE.next"
  chmod 600 "$TARGETS_FILE.next" 2>/dev/null || { _targets_unlock; return 1; }
  mv "$TARGETS_FILE.next" "$TARGETS_FILE" || { _targets_unlock; return 1; }
  _targets_unlock
  log_info "removed '$_tr_name' from auto-update"
}

# targets_classify_container NAME -> absent|managed|ambiguous|standalone
# Generic sibling of lifecycle.sh's _lifecycle_container_status: no expected
# service name to compare against, so both compose labels present = managed,
# a partial label set = ambiguous (never touched), neither = standalone.
targets_classify_container() {
  _tcc_name="$1"
  "$DOCKER_BIN" inspect "$_tcc_name" >/dev/null 2>&1 || { printf '%s' absent; return 0; }
  _tcc_labels="$("$DOCKER_BIN" inspect -f '{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project"}}' "$_tcc_name" 2>/dev/null)"
  _tcc_service="${_tcc_labels%%|*}"
  _tcc_project="${_tcc_labels#*|}"
  if [ -n "$_tcc_service" ] && [ -n "$_tcc_project" ]; then
    printf '%s' managed
  elif [ -n "$_tcc_service" ] || [ -n "$_tcc_project" ]; then
    printf '%s' ambiguous
  else
    printf '%s' standalone
  fi
}

# targets_image_databaselike REF - 0 when the image basename looks like a data
# store. There is no generic safe quiesce, so enrollment surfaces a warning.
targets_image_databaselike() {
  _tid_base="${1##*/}"
  _tid_base="${_tid_base%%:*}"
  case "$_tid_base" in
    postgres|postgresql|mysql|mariadb|mongo|mongodb|redis|valkey|influxdb|clickhouse|cassandra|elasticsearch) return 0 ;;
  esac
  return 1
}

_targets_denied_by_pattern() {
  # set -f: split the pattern list into words WITHOUT pathname expansion - a
  # file in $CWD matching a pattern would otherwise replace the pattern word
  # and silently disable the operator's deny rule.
  set -f
  for _tdp_pat in ${UPDATE_DENY_CONTAINERS:-}; do
    # shellcheck disable=SC2254 # deliberate glob match against the pattern list
    case "$1" in $_tdp_pat) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

# targets_discover - emit eligible records (name|image|strategy|probe) on
# stdout, one per line; every exclusion is logged with its reason. Filtering
# is per-record: one bad target never blocks the others.
targets_discover() {
  targets_validate || return 1
  [ -f "$TARGETS_FILE" ] || return 0
  if [ -z "${DOCKER_REGISTRY:-}" ] || [ -z "${ACR_NAMESPACE:-}" ]; then
    log_warn >&2 "targets: DOCKER_REGISTRY/ACR_NAMESPACE unset (REGISTRY_MODE=docker?) - no generic targets are eligible"
    return 0
  fi
  while IFS='|' read -r _td_name _td_strategy _td_probe || [ -n "$_td_name" ]; do
    [ -n "$_td_name" ] || continue
    case "$_td_name" in \#*) continue ;; esac
    if _targets_reserved_name "$_td_name"; then
      log_warn >&2 "targets: '$_td_name' is a gateway container - excluded (managed by its own update path)"
      continue
    fi
    if _targets_denied_by_pattern "$_td_name"; then
      log_warn >&2 "targets: '$_td_name' matches UPDATE_DENY_CONTAINERS - excluded"
      continue
    fi
    case "$(targets_classify_container "$_td_name")" in
      absent)
        log_warn >&2 "targets: '$_td_name' is enrolled but no such container exists - skipped"
        continue ;;
      managed)
        log_warn >&2 "targets: '$_td_name' is compose-managed - excluded (compose containers are never hand-recreated)"
        continue ;;
      ambiguous)
        log_warn >&2 "targets: '$_td_name' carries a partial compose label set - excluded (ambiguous ownership)"
        continue ;;
    esac
    if [ "$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$_td_name" 2>/dev/null)" != true ]; then
      log_warn >&2 "targets: '$_td_name' is not running - skipped"
      continue
    fi
    _td_image="$("$DOCKER_BIN" inspect -f '{{.Config.Image}}' "$_td_name" 2>/dev/null)"
    case "$_td_image" in
      "$DOCKER_REGISTRY/$ACR_NAMESPACE/"*) : ;;
      *)
        log_warn >&2 "targets: '$_td_name' runs '$_td_image', which is not under $DOCKER_REGISTRY/$ACR_NAMESPACE - excluded. Mirror it first: push the upstream image into your ACR namespace, then redeploy the container from the ACR ref."
        continue ;;
    esac
    printf '%s|%s|%s|%s\n' "$_td_name" "$_td_image" "${_td_strategy:-recreate}" "$_td_probe"
  done <"$TARGETS_FILE"
  return 0
}
