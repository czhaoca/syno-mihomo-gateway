#!/bin/sh
# package.sh - build an offline release bundle of syno-mihomo-gateway.
#
# BUILD-HOST tool: run this on a machine that HAS git and internet, NOT on the
# NAS. It produces a source-only release archive an operator in mainland China
# (where github.com is unreachable) can transfer to the NAS and unpack into
# /volume1/docker/ without any GitHub access.
#
# Container images are intentionally out of scope here - they reach the NAS via
# the docker-china-sync ACR mirror (see docs/release-packaging.md), not this zip.
#
# Built with `git archive`, so ONLY tracked-and-committed files ship: untracked
# secrets (.env, config/subscription.txt, config/config.yaml), logs/, .git/ are
# structurally incapable of leaking into the bundle - no exclude list to rot.
#
# POSIX /bin/sh, ASCII only, no `set -e` (explicit return-code checks). Mirrors
# the logging style of scripts/lib/common.sh. NOT a NAS runtime script.
#
# Usage: scripts/package.sh [--version X.Y.Z] [--allow-dirty] [--no-zip] [--no-tar]
# Output: dist/syno-mihomo-gateway-<version>.{tar.gz,zip} (+ .sha256 sidecars)

PREFIX=syno-mihomo-gateway/
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
DIST="$REPO_ROOT/dist"

EXIT_OK=0
EXIT_CONFIG=3

VERSION_OVERRIDE=""
ALLOW_DIRTY=0
DO_ZIP=1
DO_TAR=1

_ts() { date '+%Y-%m-%d %H:%M:%S %z'; }
log()       { printf '%s [%s] %s\n' "$(_ts)" "$1" "$2" >&2; }
log_info()  { log INFO  "$*"; }
log_warn()  { log WARN  "$*"; }
log_error() { log ERROR "$*"; }

usage() {
  cat >&2 <<'EOF'
Usage: scripts/package.sh [options]

  --version X.Y.Z   Override the version (default: ./VERSION, else git describe)
  --allow-dirty     Package even with uncommitted changes (archives HEAD, not edits)
  --no-zip          Skip the .zip artifact
  --no-tar          Skip the .tar.gz artifact
  -h, --help        Show this help

Builds dist/syno-mihomo-gateway-<version>.{tar.gz,zip} from tracked files only.
EOF
}

# emit_sha256 <file> - write a BusyBox `sha256sum -c`-compatible sidecar (basename).
emit_sha256() {
  _file="$1"
  _dir="$(dirname "$_file")"
  _base="$(basename "$_file")"
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$_dir" && sha256sum "$_base" > "${_base}.sha256" )
  elif command -v shasum >/dev/null 2>&1; then
    ( cd "$_dir" && shasum -a 256 "$_base" > "${_base}.sha256" )
  else
    log_warn "no sha256sum/shasum found - skipping checksum for $_base"
    return 0
  fi
  log_info "checksum -> ${_base}.sha256"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { log_error "--version requires a value"; exit "$EXIT_CONFIG"; }
      VERSION_OVERRIDE="$2"; shift 2 ;;
    --version=*) VERSION_OVERRIDE="${1#*=}"; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --no-zip) DO_ZIP=0; shift ;;
    --no-tar) DO_TAR=0; shift ;;
    -h|--help) usage; exit "$EXIT_OK" ;;
    *) log_error "unknown option: $1"; usage; exit "$EXIT_CONFIG" ;;
  esac
done

# --- guard: must run from the source git checkout, not an extracted release ---
if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log_error "not a git repository: $REPO_ROOT"
  log_error "package.sh must run from the source clone, not an unpacked release bundle."
  exit "$EXIT_CONFIG"
fi

# --- guard: refuse to build if a secret path is TRACKED (git archive would ship it).
# This is the root invariant behind the leak-proof guarantee: secrets stay out of the
# bundle only because they are untracked. If one was ever `git add`ed, fail loudly. ---
_tracked_secrets="$(git -C "$REPO_ROOT" ls-files -- .env config/subscription.txt config/config.yaml 'logs/*')"
if [ -n "$_tracked_secrets" ]; then
  log_error "refusing to build: secret path(s) are tracked by git and would ship in the archive:"
  printf '%s\n' "$_tracked_secrets" >&2
  log_error "untrack them first (e.g. git rm --cached <path>) - see .gitignore."
  exit "$EXIT_CONFIG"
fi

# --- resolve version: --version > ./VERSION > git describe > 0.0.0 ---
VERSION=""
if [ -n "$VERSION_OVERRIDE" ]; then
  VERSION="$VERSION_OVERRIDE"
elif [ -f "$REPO_ROOT/VERSION" ]; then
  VERSION="$(tr -d ' \t\r\n' < "$REPO_ROOT/VERSION")"
fi
if [ -z "$VERSION" ]; then
  VERSION="$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null)"
fi
[ -n "$VERSION" ] || VERSION="0.0.0"

# --- refuse a dirty tree unless explicitly allowed (git archive ships HEAD) ---
if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || \
   ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
  if [ "$ALLOW_DIRTY" = 1 ]; then
    log_warn "working tree is dirty: archiving committed HEAD, NOT your local edits."
    VERSION="${VERSION}-dirty"
  else
    log_error "working tree has uncommitted changes."
    log_error "commit them first, or pass --allow-dirty (archives HEAD, not your edits)."
    exit "$EXIT_CONFIG"
  fi
fi

mkdir -p "$DIST" || { log_error "cannot create $DIST"; exit "$EXIT_CONFIG"; }

built=0

if [ "$DO_TAR" = 1 ]; then
  TARBALL="$DIST/syno-mihomo-gateway-${VERSION}.tar.gz"
  if git -C "$REPO_ROOT" archive --format=tar.gz -9 --prefix="$PREFIX" -o "$TARBALL" HEAD; then
    log_info "built $(basename "$TARBALL")"
    emit_sha256 "$TARBALL"
    built=$((built + 1))
  else
    log_error "failed to build $TARBALL"
    exit "$EXIT_CONFIG"
  fi
fi

if [ "$DO_ZIP" = 1 ]; then
  ZIPFILE="$DIST/syno-mihomo-gateway-${VERSION}.zip"
  if git -C "$REPO_ROOT" archive --format=zip -9 --prefix="$PREFIX" -o "$ZIPFILE" HEAD; then
    log_info "built $(basename "$ZIPFILE")"
    emit_sha256 "$ZIPFILE"
    built=$((built + 1))
  else
    log_error "failed to build $ZIPFILE"
    exit "$EXIT_CONFIG"
  fi
fi

if [ "$built" = 0 ]; then
  log_error "nothing to build (both --no-zip and --no-tar given)."
  exit "$EXIT_CONFIG"
fi

log_info "release ${VERSION} ready in ${DIST}:"
ls -lh "$DIST" >&2
log_info "Next: transfer to the NAS, unpack into /volume1/docker, run 'sh bootstrap.sh'."
log_info "Full offline-install flow: docs/release-packaging.md"
exit "$EXIT_OK"
