#!/bin/sh
# lifecycle.sh - read-only deployment inventory and narrowly scoped teardown.
#
# This module never prompts.  The interactive policy lives in
# scripts/installer/preprocess.sh, while these primitives are also suitable for
# tests and future non-interactive tooling.  Automatic removal is fail-closed:
# a named container is removable only when its Compose service and project
# labels are present and consistent, and a macvlan is removable only when every
# attached container is one of those verified containers. Cleanup removes the
# two fixed names directly; it never invokes project-wide orphan removal.
#
# Requires common.sh, compose.sh, and network.sh. POSIX /bin/sh.

LIFECYCLE_CONTAINERS_PRESENT=0
LIFECYCLE_CONTAINERS_SAFE=1
LIFECYCLE_NETWORK_PRESENT=0
LIFECYCLE_NETWORK_MATCHES=0
LIFECYCLE_NETWORK_SAFE=1
LIFECYCLE_ATTACHMENTS=""
LIFECYCLE_MIHOMO_STATUS=absent
LIFECYCLE_UI_STATUS=absent
LIFECYCLE_PANEL_STATUS=absent
LIFECYCLE_COMPOSE_PROJECT=""

_lifecycle_container_status() {
  _lc_name="$1"; _lc_service="$2"; _lc_d="$(_net_docker)"
  if ! "$_lc_d" inspect "$_lc_name" >/dev/null 2>&1; then
    printf '%s' absent
    return 0
  fi
  _lc_have="$("$_lc_d" inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$_lc_name" 2>/dev/null)"
  _lc_project="$("$_lc_d" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$_lc_name" 2>/dev/null)"
  if [ "$_lc_have" = "$_lc_service" ] && [ -n "$_lc_project" ]; then
    printf '%s' managed
  else
    printf '%s' ambiguous
  fi
}

_lifecycle_container_project() {
  _lcp_name="$1"; _lcp_d="$(_net_docker)"
  "$_lcp_d" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$_lcp_name" 2>/dev/null
}

lifecycle_inspect() {
  LIFECYCLE_CONTAINERS_PRESENT=0
  LIFECYCLE_CONTAINERS_SAFE=1
  LIFECYCLE_NETWORK_PRESENT=0
  LIFECYCLE_NETWORK_MATCHES=0
  LIFECYCLE_NETWORK_SAFE=1
  LIFECYCLE_ATTACHMENTS=""
  LIFECYCLE_COMPOSE_PROJECT=""

  LIFECYCLE_MIHOMO_STATUS="$(_lifecycle_container_status "$MIHOMO_CONTAINER" mihomo)"
  LIFECYCLE_UI_STATUS="$(_lifecycle_container_status "$METACUBEXD_CONTAINER" metacubexd)"
  LIFECYCLE_PANEL_STATUS="$(_lifecycle_container_status "${PANEL_CONTAINER:-mihomo-panel}" panel)"
  for _li_status in "$LIFECYCLE_MIHOMO_STATUS" "$LIFECYCLE_UI_STATUS" "$LIFECYCLE_PANEL_STATUS"; do
    [ "$_li_status" = absent ] || LIFECYCLE_CONTAINERS_PRESENT=1
    [ "$_li_status" != ambiguous ] || LIFECYCLE_CONTAINERS_SAFE=0
  done
  _li_m_project=""; _li_u_project=""; _li_p_project=""
  [ "$LIFECYCLE_MIHOMO_STATUS" != managed ] || _li_m_project="$(_lifecycle_container_project "$MIHOMO_CONTAINER")"
  [ "$LIFECYCLE_UI_STATUS" != managed ] || _li_u_project="$(_lifecycle_container_project "$METACUBEXD_CONTAINER")"
  [ "$LIFECYCLE_PANEL_STATUS" != managed ] || _li_p_project="$(_lifecycle_container_project "${PANEL_CONTAINER:-mihomo-panel}")"
  _li_proj_mismatch=0
  for _li_project in "$_li_m_project" "$_li_u_project" "$_li_p_project"; do
    [ -n "$_li_project" ] || continue
    if [ -z "$LIFECYCLE_COMPOSE_PROJECT" ]; then
      LIFECYCLE_COMPOSE_PROJECT="$_li_project"
    elif [ "$_li_project" != "$LIFECYCLE_COMPOSE_PROJECT" ]; then
      _li_proj_mismatch=1
    fi
  done
  # Mismatch keeps LIFECYCLE_COMPOSE_PROJECT empty: resolve.sh's preserve
  # branch treats a non-empty value as the single owning project.
  if [ "$_li_proj_mismatch" = 1 ]; then
    LIFECYCLE_CONTAINERS_SAFE=0
    LIFECYCLE_COMPOSE_PROJECT=""
  fi

  _li_net="${TPROXY_NETWORK:-tproxy_network}"
  if network_exists "$_li_net"; then
    LIFECYCLE_NETWORK_PRESENT=1
    _li_parent="${CHOSEN_IFACE:-${PARENT_INTERFACE:-}}"
    [ -n "$_li_parent" ] || _li_parent="$(detect_parent_interface "${ROUTER_IP:-}")"
    if [ -n "$_li_parent" ] && macvlan_matches "$_li_net" "$_li_parent" "${SUBNET_CIDR:-}" "${ROUTER_IP:-}"; then
      LIFECYCLE_NETWORK_MATCHES=1
    fi
    LIFECYCLE_ATTACHMENTS="$(network_attachments "$_li_net")"
    for _li_attached in $LIFECYCLE_ATTACHMENTS; do
      case "$_li_attached" in
        "$MIHOMO_CONTAINER") [ "$LIFECYCLE_MIHOMO_STATUS" = managed ] || LIFECYCLE_NETWORK_SAFE=0 ;;
        "$METACUBEXD_CONTAINER") [ "$LIFECYCLE_UI_STATUS" = managed ] || LIFECYCLE_NETWORK_SAFE=0 ;;
        "${PANEL_CONTAINER:-mihomo-panel}") [ "$LIFECYCLE_PANEL_STATUS" = managed ] || LIFECYCLE_NETWORK_SAFE=0 ;;
        *) LIFECYCLE_NETWORK_SAFE=0 ;;
      esac
    done
  fi
  export LIFECYCLE_CONTAINERS_PRESENT LIFECYCLE_CONTAINERS_SAFE
  export LIFECYCLE_NETWORK_PRESENT LIFECYCLE_NETWORK_MATCHES LIFECYCLE_NETWORK_SAFE
  export LIFECYCLE_ATTACHMENTS LIFECYCLE_MIHOMO_STATUS LIFECYCLE_UI_STATUS LIFECYCLE_PANEL_STATUS
  export LIFECYCLE_COMPOSE_PROJECT
}

lifecycle_remove_containers() {
  lifecycle_inspect
  [ "$LIFECYCLE_CONTAINERS_PRESENT" = 1 ] || return 0
  if [ "$LIFECYCLE_CONTAINERS_SAFE" != 1 ]; then
    log_error "refusing automatic container cleanup: a canonical name is not owned by this Compose deployment"
    return 1
  fi
  _lrc_d="$(_net_docker)"
  for _lrc_name in "$MIHOMO_CONTAINER" "$METACUBEXD_CONTAINER" "${PANEL_CONTAINER:-mihomo-panel}"; do
    if "$_lrc_d" inspect "$_lrc_name" >/dev/null 2>&1; then
      log_warn "removing verified project container: $_lrc_name"
      "$_lrc_d" rm -f "$_lrc_name" >>"${LOG_FILE:-/dev/null}" 2>&1 || {
        log_error "failed to remove $_lrc_name"
        return 1
      }
    fi
  done
  return 0
}

lifecycle_remove_network() {
  lifecycle_inspect
  [ "$LIFECYCLE_NETWORK_PRESENT" = 1 ] || return 0
  if [ "$LIFECYCLE_NETWORK_SAFE" != 1 ]; then
    log_error "refusing automatic network cleanup: ${TPROXY_NETWORK:-tproxy_network} has an unrelated attachment"
    return 1
  fi
  if [ -n "$LIFECYCLE_ATTACHMENTS" ]; then
    log_error "refusing network cleanup while verified project containers remain attached"
    return 1
  fi
  _lrn_d="$(_net_docker)"
  log_warn "removing verified gateway macvlan: ${TPROXY_NETWORK:-tproxy_network}"
  "$_lrn_d" network rm "${TPROXY_NETWORK:-tproxy_network}" >>"${LOG_FILE:-/dev/null}" 2>&1
}

lifecycle_print_container_commands() {
  _lpc_m="$(_lifecycle_shell_quote "$MIHOMO_CONTAINER")"
  _lpc_u="$(_lifecycle_shell_quote "$METACUBEXD_CONTAINER")"
  _lpc_p="$(_lifecycle_shell_quote "${PANEL_CONTAINER:-mihomo-panel}")"
  printf '%s\n' "  docker inspect $_lpc_m $_lpc_u $_lpc_p"
  printf '%s\n' "  # Continue only if service labels are mihomo/metacubexd/panel and the project labels match."
  printf '%s\n' "  docker rm -f $_lpc_m $_lpc_u $_lpc_p"
}

lifecycle_print_network_commands() {
  _lpn_n="$(_lifecycle_shell_quote "${TPROXY_NETWORK:-tproxy_network}")"
  printf '%s\n' "  docker network inspect $_lpn_n"
  printf '%s\n' "  docker network rm $_lpn_n"
}

_lifecycle_shell_quote() {
  _lsq_escaped="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" || return 1
  printf "'%s'" "$_lsq_escaped"
}
