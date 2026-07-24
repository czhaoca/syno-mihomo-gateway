#!/bin/sh
# resolve.sh - UI-free config resolution shared by the interactive wizards
# (scripts/installer/wizards.sh, preprocess.sh) and headless callers. Every
# function here takes env/args in and reports via stdout + return codes; none
# of them prompts, sources ui.sh, or renders i18n messages - callers own the
# presentation (the single-source-of-truth pattern network.sh documents).
#
# Requires common.sh and network.sh sourced first. resolve_images additionally
# needs envedit.sh (env_get/env_set/derive_ref/derive_images; its error channel
# is ui_error, which headless callers stub or route to log_error). The
# resolve_cleanup_* validators read the LIFECYCLE_* globals, so lifecycle.sh
# must be sourced and lifecycle_inspect run first.
#
# POSIX /bin/sh, BusyBox-safe (DSM). NO `set -e` - callers check return codes.

# resolve_notify_scan - hook invoked right before a free-IP scan (the scan can
# take a moment: ip_in_use may probe the LAN). Default no-op; the interactive
# wizard overrides it to tell the operator a scan is running.
resolve_notify_scan() { :; }

# resolve_mihomo_ip CUR SUBNET_CIDR ROUTER_IP [SCAN_IFACE]
# Suggest the gateway container's static IP:
#   - CUR still a usable host in SUBNET_CIDR (not a subnet edge, not the
#     router) -> echo CUR unchanged (idempotent re-runs).
#   - otherwise, when SCAN_IFACE is given and its IPv4 sits in SUBNET_CIDR,
#     scan for the next free address above it (skipping the router) and echo
#     that.
#   - otherwise echo nothing - the caller applies its own fallback.
# Always returns 0; emptiness is the "no suggestion" signal.
resolve_mihomo_ip() {
  _rmi_cur="$1"; _rmi_cidr="$2"; _rmi_router="$3"; _rmi_iface="${4:-}"
  if [ -n "$_rmi_cur" ] && ipv4_in_cidr "$_rmi_cur" "$_rmi_cidr" \
     && ! ipv4_is_edge_of_cidr "$_rmi_cur" "$_rmi_cidr" \
     && [ "$_rmi_cur" != "$_rmi_router" ]; then
    printf '%s' "$_rmi_cur"
    return 0
  fi
  if [ -n "$_rmi_iface" ]; then
    _rmi_nas="$(_iface_ipv4 "$_rmi_iface")"
    if [ -n "$_rmi_nas" ] && ipv4_in_cidr "$_rmi_nas" "$_rmi_cidr"; then
      resolve_notify_scan
      next_free_ipv4 "$_rmi_nas" "$_rmi_cidr" "$_rmi_router"
      return 0
    fi
  fi
  return 0
}

# resolve_images - derive + persist MIHOMO_IMAGE/METACUBEXD_IMAGE from the
# registry settings. REGISTRY_MODE comes from the caller's environment (falling
# back to the saved .env, then acr); the registry/namespace/tags are read from
# the saved .env - callers persist their inputs with env_set first, exactly as
# the image wizard does. Exports the resolved refs via derive_images.
resolve_images() {
  REGISTRY_MODE="${REGISTRY_MODE:-$(env_get REGISTRY_MODE 2>/dev/null || echo acr)}"
  DOCKER_REGISTRY="$(env_get DOCKER_REGISTRY 2>/dev/null || echo '')"
  ACR_NAMESPACE="$(env_get ACR_NAMESPACE 2>/dev/null || echo '')"
  MIHOMO_TAG="$(env_get MIHOMO_TAG 2>/dev/null || echo latest)"
  METACUBEXD_TAG="$(env_get METACUBEXD_TAG 2>/dev/null || echo latest)"
  export REGISTRY_MODE DOCKER_REGISTRY ACR_NAMESPACE MIHOMO_TAG METACUBEXD_TAG
  derive_images
}

# resolve_update_images - persist UPDATE_IMAGES (the exact refs the unattended
# updater is allowed to touch): the two gateway images plus the cloudflared ref
# when one is configured. Runs AFTER the optional cloudflared setup so a newly
# added CF_IMAGE is included. Returns 1 when the gateway refs are not resolved.
resolve_update_images() {
  _rui_m="${MIHOMO_IMAGE:-$(env_get MIHOMO_IMAGE 2>/dev/null || echo '')}"
  _rui_u="${METACUBEXD_IMAGE:-$(env_get METACUBEXD_IMAGE 2>/dev/null || echo '')}"
  [ -n "$_rui_m" ] && [ -n "$_rui_u" ] || return 1
  _rui_list="$_rui_m $_rui_u"
  _rui_p="${PANEL_IMAGE:-$(env_get PANEL_IMAGE 2>/dev/null || echo '')}"
  [ -z "$_rui_p" ] || _rui_list="$_rui_list $_rui_p"
  _rui_cf="$(env_get CF_IMAGE 2>/dev/null || echo '')"
  [ -z "$_rui_cf" ] || _rui_list="$_rui_list $_rui_cf"
  env_set UPDATE_IMAGES "$_rui_list"
}

# resolve_subscription_url RAW - echo RAW cleaned of the common paste artifacts
# (bracketed-paste wrappers, control chars, surrounding quotes, a leading
# "label=" prefix, stray whitespace). Returns 0 when the cleaned value is an
# http(s) URL, 1 otherwise - the cleaned value is echoed either way so callers
# can distinguish "empty" from "wrong scheme" in their own messaging.
resolve_subscription_url() {
  _rsu="$(_sanitize_url "$1")"
  printf '%s' "$_rsu"
  case "$_rsu" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

# _sanitize_url - clean the common paste artifacts that corrupt a pasted
# subscription URL ("the https link is not properly copied"):
#   * bracketed-paste wrappers: modern terminals send the pasted text wrapped in
#     ESC[200~ ... ESC[201~; a bare `read` captures them literally. Strip ALL
#     control chars (URLs never contain them; this also drops a stray CR) then
#     remove the leftover [200~ / [201~ markers.
#   * surrounding single/double quotes (users paste "https://...").
#   * a leading "label=" prefix (the documented Name=URL file format) so the
#     interactive wizard accepts the same form the file does.
#   * leading/trailing whitespace.
# Echoes the cleaned value; does not validate. POSIX/BusyBox-safe.
_sanitize_url() {
  printf '%s' "$1" \
    | tr -d '[:cntrl:]' \
    | sed -e 's/\[20[01]~//g' \
          -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" \
          -e 's/^[A-Za-z0-9_.-]*=//' \
          -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# subscription_current - echo the effective stored subscription URL line: the
# first non-comment, non-blank line of $SUBSCRIPTION_FILE, or nothing when the
# file is missing or still the shipped placeholder (byte-identical to
# $REPO_ROOT/config/subscription.txt.example).
subscription_current() {
  _sc_sub="$SUBSCRIPTION_FILE"
  _sc_example="$REPO_ROOT/config/subscription.txt.example"
  [ -f "$_sc_sub" ] || return 0
  if [ -f "$_sc_example" ] && cmp -s "$_sc_sub" "$_sc_example"; then
    return 0
  fi
  grep -v '^#' "$_sc_sub" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n1
}

# --- pre-deployment cleanup plan validation -----------------------------------
# The decision policy preprocess.sh's menus and headless callers share. Each
# validator checks one requested mode (preserve|auto|manual) against the
# LIFECYCLE_* inventory (lifecycle_inspect must have run), records the accepted
# mode in CLEANUP_CONTAINERS_MODE / CLEANUP_NETWORK_MODE, and on rejection sets
# RESOLVE_CLEANUP_REASON to a machine-readable token the caller renders:
#   ambiguous        - containers exist that are not verifiably ours
#   foreign_project  - the containers belong to a DIFFERENT Compose project (a
#                      legacy/older deployment); preserving them would make
#                      `compose up` die on a raw container-name conflict
#   drift            - the macvlan exists with a different configuration
#   unrelated        - the network has attachments that are not our containers
#   needs_containers - removing the network needs container cleanup too
#   invalid          - unknown mode requested

RESOLVE_CLEANUP_REASON=""

# resolve_cleanup_containers MODE - validate + record the container plan.
# Absent containers normalize to preserve regardless of the requested mode.
resolve_cleanup_containers() {
  RESOLVE_CLEANUP_REASON=""
  if [ "${LIFECYCLE_CONTAINERS_PRESENT:-0}" != 1 ]; then
    CLEANUP_CONTAINERS_MODE=preserve
    return 0
  fi
  case "$1" in
    preserve|auto)
      if [ "${LIFECYCLE_CONTAINERS_SAFE:-0}" != 1 ]; then
        RESOLVE_CLEANUP_REASON=ambiguous
        return 1
      fi
      # Managed containers from a DIFFERENT compose project (a legacy install)
      # cannot be preserved: this deploy's `compose up` would hit a raw
      # container-name conflict. auto (replace) is the remedy and stays valid.
      if [ "$1" = preserve ] && [ -n "${LIFECYCLE_COMPOSE_PROJECT:-}" ]; then
        _rcc_ours="$(compose_project_name 2>/dev/null || echo '')"
        if [ -n "$_rcc_ours" ] && [ "$LIFECYCLE_COMPOSE_PROJECT" != "$_rcc_ours" ]; then
          RESOLVE_CLEANUP_REASON=foreign_project
          return 1
        fi
      fi
      CLEANUP_CONTAINERS_MODE="$1" ;;
    manual)
      CLEANUP_CONTAINERS_MODE=manual ;;
    *)
      RESOLVE_CLEANUP_REASON=invalid
      return 1 ;;
  esac
  return 0
}

# resolve_cleanup_network MODE - validate + record the network plan. Reads
# CLEANUP_CONTAINERS_MODE for the attachments rule, so resolve the container
# half first. Absent network normalizes to preserve.
resolve_cleanup_network() {
  RESOLVE_CLEANUP_REASON=""
  if [ "${LIFECYCLE_NETWORK_PRESENT:-0}" != 1 ]; then
    CLEANUP_NETWORK_MODE=preserve
    return 0
  fi
  case "$1" in
    preserve)
      if [ "${LIFECYCLE_NETWORK_MATCHES:-0}" != 1 ]; then
        RESOLVE_CLEANUP_REASON=drift
        return 1
      fi
      CLEANUP_NETWORK_MODE=preserve ;;
    auto)
      if [ "${LIFECYCLE_NETWORK_SAFE:-0}" != 1 ]; then
        RESOLVE_CLEANUP_REASON=unrelated
        return 1
      fi
      if [ -n "${LIFECYCLE_ATTACHMENTS:-}" ] && [ "${CLEANUP_CONTAINERS_MODE:-preserve}" != auto ]; then
        RESOLVE_CLEANUP_REASON=needs_containers
        return 1
      fi
      CLEANUP_NETWORK_MODE=auto ;;
    manual)
      CLEANUP_NETWORK_MODE=manual ;;
    *)
      RESOLVE_CLEANUP_REASON=invalid
      return 1 ;;
  esac
  return 0
}

# resolve_cleanup_plan CONTAINERS_MODE NETWORK_MODE - the headless entry point:
# validate both halves in order and export the accepted plan for
# apply_predeployment_cleanup. Returns 1 (with RESOLVE_CLEANUP_REASON set) on
# the first rejected half.
resolve_cleanup_plan() {
  resolve_cleanup_containers "$1" || return 1
  resolve_cleanup_network "$2" || return 1
  export CLEANUP_CONTAINERS_MODE CLEANUP_NETWORK_MODE
  return 0
}
