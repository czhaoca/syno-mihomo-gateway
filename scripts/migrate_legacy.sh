#!/bin/sh
# migrate_legacy.sh - import runtime state from a pre-split FLAT installation
# (the pre-1.3 layout where config.yaml, subscription.txt, the geo databases
# and docker-compose.yml all lived in one docker-shared folder) into the
# persistent data dir the current release uses (../syno-mihomo-gateway-data).
#
#   sudo sh scripts/migrate_legacy.sh [--from DIR] [--dry-run] [--yes]
#
# Imports by COPY - never move - so the legacy install keeps working until the
# new stack replaces it: the subscription URL (only when the new one is
# missing or still the shipped placeholder), the geo databases (so the first
# start needs no cross-border download), and mihomo's connection cache.
# Prints .env hints read from the legacy compose/config; it never writes .env.
# Idempotent: existing target files are left untouched.
#
# Exit: 0 imported or clean no-op | 2 some file could not be copied |
#       3 no legacy dir / bad arguments | 6 needs root | 7 refused without --yes
# POSIX /bin/sh (BusyBox-safe). English-only output (house rule for the
# non-interactive entry points, like doctor.sh and setup_network.sh).

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/lib/common.sh"

NO_LOG_INIT=1
export NO_LOG_INIT

usage() {
  printf '%s\n' 'Usage: sudo sh scripts/migrate_legacy.sh [--from DIR] [--dry-run] [--yes]' \
    '  --from DIR   the legacy flat install (default: auto-detect)' \
    '  --dry-run    print the import plan only; no root needed, nothing written' \
    '  --yes        confirm the import (required for the mutating run)'
}

FROM=""; DRY_RUN=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from)
      [ $# -ge 2 ] || { echo "ERROR: --from needs a directory" >&2; usage >&2; exit "$EXIT_CONFIG"; }
      FROM="$2"; shift 2 ;;
    --from=*) FROM="${1#--from=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit "$EXIT_OK" ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit "$EXIT_CONFIG" ;;
  esac
done

ok()   { printf 'ok    %s\n' "$*"; }
plan() { printf 'plan  %s\n' "$*"; }
skip() { printf 'skip  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }

if [ -n "$FROM" ]; then
  LEGACY="$FROM"
else
  LEGACY="$(legacy_install_detect)" || {
    echo "ERROR: no legacy flat install found (probed the docker shared folders for config.yaml + docker-compose.yml + subscription.txt) - pass --from DIR" >&2
    exit "$EXIT_CONFIG"
  }
fi
for _need in config.yaml docker-compose.yml subscription.txt; do
  [ -f "$LEGACY/$_need" ] || {
    echo "ERROR: $LEGACY does not look like a legacy flat install (missing $_need)" >&2
    exit "$EXIT_CONFIG"
  }
done
ok "legacy install: $LEGACY"
ok "data dir:       $GATEWAY_DATA_DIR"

if [ "$DRY_RUN" = 0 ]; then
  if ! is_root; then
    echo "ERROR: the import copies into the root-owned data dir - re-run with sudo (or preview with --dry-run)" >&2
    exit "$EXIT_ROOT"
  fi
  if [ "$ASSUME_YES" != 1 ]; then
    echo "ERROR: refusing to import without --yes (preview with --dry-run)" >&2
    exit "$EXIT_CONFIRM"
  fi
  ensure_persistent_state || {
    echo "ERROR: cannot create the persistent data directory: $GATEWAY_DATA_DIR" >&2
    exit "$EXIT_CONFIG"
  }
fi

RC="$EXIT_OK"

# _import SRC DST - copy once with tight permissions; never clobber.
_import() {
  _im_src="$1"; _im_dst="$2"
  [ -f "$_im_src" ] || return 0
  if [ -f "$_im_dst" ]; then
    skip "$(basename "$_im_dst") already exists - left untouched"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    plan "copy $_im_src -> $_im_dst"
    return 0
  fi
  if cp "$_im_src" "$_im_dst"; then
    chmod 600 "$_im_dst" 2>/dev/null || true
    ok "imported $(basename "$_im_dst")"
  else
    warn "could not copy $_im_src"
    RC="$EXIT_PARTIAL"
  fi
}

# 1) Subscription: import only when the stored one is missing or still the
#    shipped placeholder - a configured URL is never overwritten.
_sub_needed=1
if [ -f "$SUBSCRIPTION_FILE" ]; then
  if [ -f "$REPO_ROOT/config/subscription.txt.example" ] \
     && cmp -s "$SUBSCRIPTION_FILE" "$REPO_ROOT/config/subscription.txt.example"; then
    : # still the placeholder - import over it
  else
    _sub_needed=0
    skip "a configured subscription is already stored - left untouched"
  fi
fi
if [ "$_sub_needed" = 1 ]; then
  if [ "$DRY_RUN" = 1 ]; then
    plan "copy $LEGACY/subscription.txt -> $SUBSCRIPTION_FILE"
  elif cp "$LEGACY/subscription.txt" "$SUBSCRIPTION_FILE"; then
    chmod 600 "$SUBSCRIPTION_FILE" 2>/dev/null || true
    ok "imported subscription.txt"
  else
    warn "could not import subscription.txt"
    RC="$EXIT_PARTIAL"
  fi
fi

# 2) Geo databases (every spelling mihomo reads/writes) + connection cache.
for _file in GeoSite.dat geosite.dat GeoIP.dat geoip.dat geoip.metadb \
             country.mmdb Country.mmdb cache.db; do
  _import "$LEGACY/$_file" "$CONFIG_STATE_DIR/$_file"
done

# 3) .env hints parsed from the legacy files (print-only; nothing is written -
#    the guided installer remains the only writer of .env).
echo
echo "Suggested .env values read from the legacy install (NOT applied):"
_hint_ip="$(sed -n 's/^[[:space:]]*ipv4_address:[[:space:]]*//p' "$LEGACY/docker-compose.yml" 2>/dev/null | head -n1 | tr -d '"' | tr -d "'" | awk '{print $1}')"
[ -n "$_hint_ip" ] && echo "  MIHOMO_IP=$_hint_ip"
_hint_port="$(sed -n 's/^external-controller:.*:\([0-9][0-9]*\).*$/\1/p' "$LEGACY/config.yaml" 2>/dev/null | head -n1)"
[ -n "$_hint_port" ] && echo "  CONTROLLER_PORT=$_hint_port"
if grep -q '^secret:[[:space:]]*"..*"' "$LEGACY/config.yaml" 2>/dev/null; then
  echo "  CONTROLLER_SECRET=<the legacy config carries one - reuse it or generate a new one in the wizard>"
fi
echo "  (legacy DNS servers are informational only - the shipped defaults stand)"
echo
echo "Next: run 'sudo sh ./install.sh' and deploy. The legacy containers keep"
echo "running until the new deploy replaces them; when the cleanup planner"
echo "flags them as a legacy/foreign project, choose automatic cleanup."
exit "$RC"
