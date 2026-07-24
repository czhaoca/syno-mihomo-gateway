#!/bin/sh
# envedit.sh - safe .env read/write + image-ref derivation for the installer.
#
# Two responsibilities:
#   1. env_get / env_set : read and idempotently upsert a single KEY=VALUE in
#      $ENV_FILE, PRESERVING every other line/comment. Implemented with awk +
#      tmp + mv (NOT `sed -i`): the values are URLs / ACR refs containing '/',
#      '&', '|', ':' that would collide with sed delimiters/replacements. The
#      value is passed through the environment (ENVIRON[]) so awk never
#      interprets backslashes in it.
#   2. derive_ref / derive_images : turn the REGISTRY_MODE flag + registry +
#      namespace + tag into fully-qualified image refs, so the operator types
#      the ACR host/namespace ONCE, not per image (req #4).
#
# Requires common.sh (ENV_FILE) and ui.sh (ui_error) sourced first.
# POSIX /bin/sh, BusyBox-safe (BusyBox awk supports ENVIRON).

# Upstream public sources for REGISTRY_MODE=docker. These are installer
# constants - they are NEVER written to .env.example (which stays ACR-only so
# the committed-file CI policy is unaffected), only into the gitignored .env.
MIHOMO_UPSTREAM="docker.io/metacubex/mihomo"
METACUBEXD_UPSTREAM="ghcr.io/metacubex/metacubexd"
# The panel has NO third-party upstream: its docker-mode ref must come from
# the operator (PANEL_UPSTREAM here or a hand-set PANEL_IMAGE). The empty
# default keeps the shipped installer identity-free (package.sh leak-gate).
PANEL_UPSTREAM="${PANEL_UPSTREAM:-}"
CF_UPSTREAM="docker.io/cloudflare/cloudflared"

# env_get KEY - print the current value of KEY from $ENV_FILE (one layer of
# surrounding double-quotes stripped). Returns 1 if absent or empty (so callers
# can fall back to their own default).
env_get() {
  _val="$(dotenv_get "$1")" || return 1
  [ -n "$_val" ] || return 1
  printf '%s' "$_val"
}

# env_set KEY VALUE - upsert KEY=VALUE in $ENV_FILE (replace the first
# uncommented KEY= line, else append). Re-chmods 600 (it can hold secrets).
# SELF-VERIFYING (#59): the rename status is honest, the temp file is removed
# on every failure path, and success is only reported once the DECODED value
# reads back equal - a failed or lying rename can never claim success. chmod
# stays best-effort (the kept-backup precedent in wizards.sh): content is
# authoritative, mode hardening is not.
# Caller contract under set -e: because the rc is honest, a BARE call with
# errexit active (e.g. inside a $(fn) capture under sh -eu) stops the caller
# mid-flight on a failed write. That is the intended fail-closed default -
# add `|| :` only where masking the failure is the deliberate choice.
env_set() {
  _k="$1"; _v="$2"
  # The strict loader's key charset, enforced up front: writing a key
  # dotenv_load refuses would corrupt the env file, and a regex-metachar
  # key could never be matched (or verified) literally by the awk paths.
  case "$_k" in ''|[0-9]*|*[!A-Za-z0-9_]*)
    ui_error "invalid .env key: $_k"; return 1 ;;
  esac
  if [ ! -f "${ENV_FILE:-}" ]; then
    : > "$ENV_FILE" || { ui_error "cannot create $ENV_FILE"; return 1; }
    chmod 600 "$ENV_FILE" 2>/dev/null || :
  fi
  # Compose-compatible double quoting. The strict loader reverses these
  # escapes without evaluating the value as shell code.
  _encoded="$(printf '%s' "$_v" | sed \
    -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/$$/g')"
  _encoded="\"$_encoded\""
  _tmp="${ENV_FILE}.tmp.$$"
  if ! ENV_K="$_k" ENV_V="$_encoded" awk '
        BEGIN { k = ENVIRON["ENV_K"]; v = ENVIRON["ENV_V"]; done = 0 }
        (done == 0) && ($0 ~ "^" k "=") { print k "=" v; done = 1; next }
        { print }
        END { if (done == 0) print k "=" v }
      ' "$ENV_FILE" > "$_tmp"; then
    rm -f "$_tmp" 2>/dev/null
    ui_error "failed to update $_k in $ENV_FILE"
    return 1
  fi
  if ! mv "$_tmp" "$ENV_FILE"; then
    rm -f "$_tmp" 2>/dev/null
    ui_error "failed to update $_k in $ENV_FILE"
    return 1
  fi
  chmod 600 "$ENV_FILE" 2>/dev/null || :
  # Presence-aware read-back: a missing key must fail verification even when
  # the requested value is empty ("key absent" and "value empty" differ).
  if ! _rb="$(dotenv_get "$_k" 2>/dev/null)" || [ "$_rb" != "$_v" ]; then
    rm -f "$_tmp" 2>/dev/null   # a lying rename leaves the temp behind
    ui_error "failed to update $_k in $ENV_FILE (write did not verify)"
    return 1
  fi
  # A lying rename can leave the temp even when verification passes (the
  # file already held the requested value) - never orphan it.
  rm -f "$_tmp" 2>/dev/null || :
  return 0
}

# derive_ref BASENAME [TAG] - print the fully-qualified ref for one image under
# the current REGISTRY_MODE. BASENAME is mihomo|metacubexd|cloudflared.
derive_ref() {
  _base="$1"; _tag="${2:-latest}"; _mode="${REGISTRY_MODE:-acr}"
  case "$_mode" in
    acr)
      [ -n "${DOCKER_REGISTRY:-}" ] && [ -n "${ACR_NAMESPACE:-}" ] || return 1
      # image-name mapping: the panel publishes as 'mihomo-panel' on both
      # sides (GHCR upstream + the ACR mirror keep the same last segment)
      _name="$_base"
      [ "$_base" = panel ] && _name=mihomo-panel
      printf '%s/%s/%s:%s' "$DOCKER_REGISTRY" "$ACR_NAMESPACE" "$_name" "$_tag" ;;
    docker)
      case "$_base" in
        mihomo)      printf '%s:%s' "$MIHOMO_UPSTREAM" "$_tag" ;;
        metacubexd)  printf '%s:%s' "$METACUBEXD_UPSTREAM" "$_tag" ;;
        panel)
          [ -n "$PANEL_UPSTREAM" ] || return 1
          printf '%s:%s' "$PANEL_UPSTREAM" "$_tag" ;;
        cloudflared) printf '%s:%s' "$CF_UPSTREAM" "$_tag" ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# derive_images - resolve MIHOMO_IMAGE + METACUBEXD_IMAGE from REGISTRY_MODE and
# write them (plus REGISTRY_MODE) to .env. In 'docker' mode also clears
# DOCKER_REGISTRY so acr_login() (registry.sh) cleanly no-ops. Cloudflared is
# optional/external and is handled by the image wizard, not here. Exports the
# resolved vars so the current process (compose/auto_update) sees them.
derive_images() {
  _mode="${REGISTRY_MODE:-acr}"
  case "$_mode" in
    acr)
      [ -n "${DOCKER_REGISTRY:-}" ] || { ui_error "REGISTRY_MODE=acr but DOCKER_REGISTRY is empty"; return 1; }
      [ -n "${ACR_NAMESPACE:-}" ]   || { ui_error "REGISTRY_MODE=acr but ACR_NAMESPACE is empty"; return 1; } ;;
    docker) : ;;
    *) ui_error "REGISTRY_MODE must be 'acr' or 'docker' (got '$_mode')"; return 1 ;;
  esac

  MIHOMO_IMAGE="$(derive_ref mihomo "${MIHOMO_TAG:-latest}")" \
    || { ui_error "could not derive MIHOMO_IMAGE"; return 1; }
  METACUBEXD_IMAGE="$(derive_ref metacubexd "${METACUBEXD_TAG:-latest}")" \
    || { ui_error "could not derive METACUBEXD_IMAGE"; return 1; }
  # Tolerant, unlike the pair: docker mode has no derivable panel ref until
  # the operator supplies PANEL_UPSTREAM (or PANEL_IMAGE directly). Any
  # existing value is kept - a previously working ref beats a blank - and
  # compose stays fail-closed (${PANEL_IMAGE:?}) until one exists.
  if _di_p="$(derive_ref panel "${PANEL_TAG:-latest}")"; then
    PANEL_IMAGE="$_di_p"
    env_set PANEL_IMAGE "$PANEL_IMAGE" || return 1
  else
    ui_warn "PANEL_IMAGE not derivable in docker mode - keeping the current value; set PANEL_UPSTREAM or PANEL_IMAGE in .env" 2>/dev/null \
      || printf '%s\n' "WARN: PANEL_IMAGE not derivable in docker mode - set PANEL_UPSTREAM or PANEL_IMAGE in .env" >&2
  fi

  env_set REGISTRY_MODE "$_mode" || return 1
  env_set MIHOMO_IMAGE "$MIHOMO_IMAGE" || return 1
  env_set METACUBEXD_IMAGE "$METACUBEXD_IMAGE" || return 1
  if [ "$_mode" = "docker" ]; then
    DOCKER_REGISTRY=""
    env_set DOCKER_REGISTRY "" || return 1
  fi
  export REGISTRY_MODE MIHOMO_IMAGE METACUBEXD_IMAGE PANEL_IMAGE DOCKER_REGISTRY
  return 0
}
