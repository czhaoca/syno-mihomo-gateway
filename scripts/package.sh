#!/bin/sh
# package.sh - build an offline release bundle of the gateway.
#
# BUILD-HOST tool: run this on a machine that HAS git and internet, NOT on the
# NAS. It produces a source-only release archive an operator can transfer to the
# NAS and unpack into the Docker shared folder, then run `sh ./install.sh`.
#
# Two profiles:
#   --profile dev      the full tracked tree (docs, CI, metadata).
#                      Internal use; what CI's package check builds.
#   --profile enduser  (default) the curated, self-contained distribution: runtime files +
#                      the interactive installer + the plain-text guides, with all
#                      developer/internal files removed and a leak-gate that fails
#                      the build if any identifying string would ship.
#
# Container images are intentionally out of scope here - they reach the NAS via a
# registry mirror, not this zip.
#
# Built with `git archive`, so ONLY tracked-and-committed files ship: untracked
# secrets (.env, config/subscription.txt, config/config.yaml), logs/, .git/ are
# structurally incapable of leaking into the bundle.
#
# POSIX /bin/sh, ASCII only, no `set -e` (explicit return-code checks).
#
# Usage: scripts/package.sh [--profile dev|enduser] [--version X.Y.Z]
#                           [--allow-dirty] [--no-zip] [--no-tar]
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
PROFILE=enduser

# Files removed from the --profile enduser bundle: developer/CI/internal metadata
# and the maintainer-only packager. The leak-gate below is the belt-and-suspenders
# that fails the build if any identifying string survives anyway. ('.' = include
# everything tracked, then subtract.) No entry contains a space.
ENDUSER_EXCLUDES=". :(exclude)README.md :(exclude)AGENTS.md :(exclude)CLAUDE.md :(exclude).woodpecker.yml :(exclude).gitignore :(exclude)docs/*.md :(exclude)docs/zh :(exclude)scripts/ci :(exclude)scripts/package.sh"

_ts() { date '+%Y-%m-%d %H:%M:%S %z'; }
log()       { printf '%s [%s] %s\n' "$(_ts)" "$1" "$2" >&2; }
log_info()  { log INFO  "$*"; }
log_warn()  { log WARN  "$*"; }
log_error() { log ERROR "$*"; }

usage() {
  cat >&2 <<'EOF'
Usage: scripts/package.sh [options]

  --profile dev|enduser   enduser (default) = curated self-contained distribution;
                          dev = full tracked tree for internal use
  --version X.Y.Z         Override the version (default: ./VERSION, else git describe)
  --allow-dirty           Package even with uncommitted changes (archives HEAD)
  --no-zip                Skip the .zip artifact
  --no-tar                Skip the .tar.gz artifact
  -h, --help              Show this help

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

# leak_scan <dir> - grep the assembled tree for any developer/identifying string.
# Returns non-zero (and prints offenders) if ANY is present. Fixed strings are
# matched case-insensitively; a generic email regex is the author-email catch-all.
leak_scan() {
  _dir="$1"; _hit=0
  for _s in github gitlab bitbucket gitea git@ czhaoca chao.zhao Nimbus docker-china-sync woodpecker ALIYUN_NAME_SPACE; do
    _m="$(grep -rInF -i -e "$_s" "$_dir" 2>/dev/null)"
    if [ -n "$_m" ]; then printf 'LEAK [%s]:\n%s\n' "$_s" "$_m" >&2; _hit=1; fi
  done
  _e="$(grep -rInE -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+' "$_dir" 2>/dev/null)"
  if [ -n "$_e" ]; then printf 'LEAK [email]:\n%s\n' "$_e" >&2; _hit=1; fi
  [ "$_hit" -eq 0 ]
}

# ea_archive <format> <outfile> - git archive the enduser pathspec (prefix +
# excludes). `set -f` disables shell globbing so the `*` in a pathspec reaches git.
ea_archive() {
  _fmt="$1"; _out="$2"
  set -f
  # shellcheck disable=SC2086  # intentional word-split of the pathspec list (no spaces); globbing disabled
  # NOTE: -o must precede the `-- <pathspec>`; anything after `--` is a pathspec.
  git -C "$REPO_ROOT" archive --format="$_fmt" -9 --prefix="$PREFIX" -o "$_out" HEAD -- $ENDUSER_EXCLUDES
  _rc=$?
  set +f
  return "$_rc"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { log_error "--profile requires a value"; exit "$EXIT_CONFIG"; }
      PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
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

case "$PROFILE" in
  dev|enduser) : ;;
  *) log_error "--profile must be 'dev' or 'enduser' (got '$PROFILE')"; exit "$EXIT_CONFIG" ;;
esac

# --- guard: must run from the source git checkout, not an extracted release ---
if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log_error "not a git repository: $REPO_ROOT"
  log_error "package.sh must run from the source clone, not an unpacked release bundle."
  exit "$EXIT_CONFIG"
fi

# --- guard: refuse to build if a secret path is TRACKED (git archive would ship it).
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

TARBALL="$DIST/syno-mihomo-gateway-${VERSION}.tar.gz"
ZIPFILE="$DIST/syno-mihomo-gateway-${VERSION}.zip"
built=0

if [ "$PROFILE" = enduser ]; then
  # Stage the curated tree (tracked-only, excludes applied) and prove it carries
  # no identifying string BEFORE writing any artifact.
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/smg-pkg.XXXXXX")" || { log_error "mktemp failed"; exit "$EXIT_CONFIG"; }
  # shellcheck disable=SC2064  # expand STAGE now so the trap removes this exact dir
  trap "rm -rf \"$STAGE\"" EXIT INT TERM
  _staged_tar="$STAGE/tree.tar"
  set -f
  # shellcheck disable=SC2086  # intentional word-split; globbing disabled
  git -C "$REPO_ROOT" archive --format=tar -o "$_staged_tar" HEAD -- $ENDUSER_EXCLUDES
  _rc=$?
  set +f
  [ "$_rc" -eq 0 ] || { log_error "failed to stage the tracked tree for scanning"; exit "$EXIT_CONFIG"; }
  mkdir -p "$STAGE/tree" || { log_error "cannot create stage dir"; exit "$EXIT_CONFIG"; }
  if ! ( cd "$STAGE/tree" && tar -xf "$_staged_tar" ); then
    log_error "failed to extract the staged tree"; exit "$EXIT_CONFIG"
  fi

  if ! leak_scan "$STAGE/tree"; then
    log_error "IDENTITY LEAK: the enduser bundle would ship a forbidden string (above)."
    log_error "scrub it from the offending tracked file and rebuild. NO artifact written."
    exit "$EXIT_CONFIG"
  fi
  log_info "leak-gate passed: no developer/identifying strings in the staged bundle"

  if [ "$DO_TAR" = 1 ]; then
    if ea_archive tar.gz "$TARBALL"; then
      log_info "built $(basename "$TARBALL") (enduser)"; emit_sha256 "$TARBALL"; built=$((built + 1))
    else
      log_error "failed to build $TARBALL"; exit "$EXIT_CONFIG"
    fi
  fi
  if [ "$DO_ZIP" = 1 ]; then
    if ea_archive zip "$ZIPFILE"; then
      log_info "built $(basename "$ZIPFILE") (enduser)"; emit_sha256 "$ZIPFILE"; built=$((built + 1))
    else
      log_error "failed to build $ZIPFILE"; exit "$EXIT_CONFIG"
    fi
  fi
else
  # dev profile: the full tracked tree (unchanged behavior).
  if [ "$DO_TAR" = 1 ]; then
    if git -C "$REPO_ROOT" archive --format=tar.gz -9 --prefix="$PREFIX" -o "$TARBALL" HEAD; then
      log_info "built $(basename "$TARBALL")"; emit_sha256 "$TARBALL"; built=$((built + 1))
    else
      log_error "failed to build $TARBALL"; exit "$EXIT_CONFIG"
    fi
  fi
  if [ "$DO_ZIP" = 1 ]; then
    if git -C "$REPO_ROOT" archive --format=zip -9 --prefix="$PREFIX" -o "$ZIPFILE" HEAD; then
      log_info "built $(basename "$ZIPFILE")"; emit_sha256 "$ZIPFILE"; built=$((built + 1))
    else
      log_error "failed to build $ZIPFILE"; exit "$EXIT_CONFIG"
    fi
  fi
fi

if [ "$built" = 0 ]; then
  log_error "nothing to build (both --no-zip and --no-tar given)."
  exit "$EXIT_CONFIG"
fi

log_info "release ${VERSION} (${PROFILE}) ready in ${DIST}:"
ls -lh "$DIST" >&2
if [ "$PROFILE" = enduser ]; then
  log_info "Next: transfer to the NAS, unpack into the Docker shared folder, run 'sh ./install.sh'."
else
  log_info "dev bundle (internal). For the distributable archive use: --profile enduser"
fi
exit "$EXIT_OK"
