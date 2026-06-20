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
env_set() {
  _k="$1"; _v="$2"
  if [ ! -f "${ENV_FILE:-}" ]; then
    : > "$ENV_FILE" || { ui_error "cannot create $ENV_FILE"; return 1; }
    chmod 600 "$ENV_FILE" 2>/dev/null
  fi
  # Compose-compatible double quoting. The strict loader reverses these
  # escapes without evaluating the value as shell code.
  _encoded="$(printf '%s' "$_v" | sed \
    -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/$$/g')"
  _encoded="\"$_encoded\""
  _tmp="${ENV_FILE}.tmp.$$"
  if ENV_K="$_k" ENV_V="$_encoded" awk '
        BEGIN { k = ENVIRON["ENV_K"]; v = ENVIRON["ENV_V"]; done = 0 }
        (done == 0) && ($0 ~ "^" k "=") { print k "=" v; done = 1; next }
        { print }
        END { if (done == 0) print k "=" v }
      ' "$ENV_FILE" > "$_tmp"; then
    mv "$_tmp" "$ENV_FILE" && chmod 600 "$ENV_FILE" 2>/dev/null
    return 0
  fi
  rm -f "$_tmp" 2>/dev/null
  ui_error "failed to update $_k in $ENV_FILE"
  return 1
}

# derive_ref BASENAME [TAG] - print the fully-qualified ref for one image under
# the current REGISTRY_MODE. BASENAME is mihomo|metacubexd|cloudflared.
derive_ref() {
  _base="$1"; _tag="${2:-latest}"; _mode="${REGISTRY_MODE:-acr}"
  case "$_mode" in
    acr)
      [ -n "${DOCKER_REGISTRY:-}" ] && [ -n "${ACR_NAMESPACE:-}" ] || return 1
      printf '%s/%s/%s:%s' "$DOCKER_REGISTRY" "$ACR_NAMESPACE" "$_base" "$_tag" ;;
    docker)
      case "$_base" in
        mihomo)      printf '%s:%s' "$MIHOMO_UPSTREAM" "$_tag" ;;
        metacubexd)  printf '%s:%s' "$METACUBEXD_UPSTREAM" "$_tag" ;;
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

  env_set REGISTRY_MODE "$_mode" || return 1
  env_set MIHOMO_IMAGE "$MIHOMO_IMAGE" || return 1
  env_set METACUBEXD_IMAGE "$METACUBEXD_IMAGE" || return 1
  if [ "$_mode" = "docker" ]; then
    DOCKER_REGISTRY=""
    env_set DOCKER_REGISTRY "" || return 1
  fi
  export REGISTRY_MODE MIHOMO_IMAGE METACUBEXD_IMAGE DOCKER_REGISTRY
  return 0
}
