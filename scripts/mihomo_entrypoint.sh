#!/bin/sh
# mihomo_entrypoint.sh - container entrypoint gate (issue #36).
# Renders to a TEMP config, tests it with `mihomo -t`, and swaps it over the
# live config.yaml ONLY on green - so a hand-edited .env that poisons the
# render (an invalid regexp2 pattern panics mihomo at startup - unguarded
# regexp2.MustCompile in the group parser, verified against Meta v1.19.28)
# can no longer crash-loop the gateway under restart:always or destroy the
# last-known-good config.
#
# Owner-ratified contract (issue #36, 2026-07-13):
#   render-failed OR config-test-failed, last-good config.yaml EXISTS
#     -> write $REJ (0600, secrets scrubbed) + shout, start mihomo on the
#        last-good config: the gateway stays up, the bad edit is visibly
#        NOT applied until .env is fixed and redeployed.
#   first boot (no last-good) -> write $REJ, fail hard: nothing safe to run.
#   green -> whole-file swap, clear any stale $REJ, exec mihomo.
# The renderer itself is untouched (shared by CI and the Pi host-side path);
# this script only wraps it. POSIX /bin/sh (BusyBox-safe). Fails loud.
set -eu

CFG_DIR="${MIHOMO_CONFIG_DIR:-/root/.config/mihomo}"
MIHOMO_BIN="${MIHOMO_BIN:-/mihomo}"
SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
LIVE="$CFG_DIR/config.yaml"
NEXT="$CFG_DIR/.config.yaml.next"
REJ="$CFG_DIR/.config.yaml.rejected"
CAP="$CFG_DIR/.config.yaml.stageout"

# mask - scrub the two secret-bearing values (subscription URL, controller
# secret) from captured stage output: a config error can quote the offending
# line verbatim, and the marker exists to be read/pasted later. Literal
# match via awk index() (no regex/escaping traps); values ride ENVIRON so
# backslashes survive - passed as assignment-prefixes so they live ONLY in
# the awk process, never in this shell (the fallback path execs mihomo,
# which must not inherit the raw subscription URL).
mask() {
  _m_sub=$(grep -v '^#' "$CFG_DIR/subscription.txt" 2>/dev/null \
    | grep -v '^[[:space:]]*$' | head -n1 \
    | sed -e 's/^[A-Za-z0-9_.-]*=//' -e 's/[[:space:]]*$//') || _m_sub=''
  EP_MASK_SUB="$_m_sub" EP_MASK_SEC="${CONTROLLER_SECRET:-}" awk '
    BEGIN { s = ENVIRON["EP_MASK_SUB"]; c = ENVIRON["EP_MASK_SEC"] }
    {
      if (s != "") while ((i = index($0, s)) > 0)
        $0 = substr($0, 1, i - 1) "<redacted>" substr($0, i + length(s))
      if (c != "") while ((i = index($0, c)) > 0)
        $0 = substr($0, 1, i - 1) "<redacted>" substr($0, i + length(c))
      print
    }'
}

reject() { # $1 = render-failed | config-test-failed; stage output in $CAP
  (
    umask 077
    rm -f "$REJ"
    {
      printf 'reason: %s\n' "$1"
      printf 'time: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      mask < "$CAP"
    } > "$REJ"
  )
  mask < "$CAP" >&2
  rm -f "$CAP" "$NEXT"
  echo "!!! CONFIG REJECTED ($1) - details in $REJ" >&2
  if [ -f "$LIVE" ]; then
    echo "!!! running on the PREVIOUS config - the last .env edit is NOT applied; fix .env and redeploy" >&2
    exec "$MIHOMO_BIN" -d "$CFG_DIR"
  fi
  echo "ERROR: first boot with no previous config.yaml - refusing to start" >&2
  exit 1
}

rm -f "$NEXT" "$CAP"
# Seed MISSING dynamic-policy provider files before render + `mihomo -t`
# (issue #63): the rendered config's rule-providers point at these paths,
# and the panel's write contract expects them to exist. Zero-byte is the
# DEC-A-proven inert seed (empty classical text = the RULE-SET matches
# nothing). Idempotent - an EXISTING file (the panel's live policy) is
# never touched, and a failed render/-t below leaves the seeds in place.
mkdir -p "$CFG_DIR/providers"
for _pf in dyn-full-direct.txt dyn-full-tunnel.txt; do
  [ -f "$CFG_DIR/providers/$_pf" ] || : > "$CFG_DIR/providers/$_pf"
done
if ! MIHOMO_RENDER_OUT="$NEXT" sh "$SELF_DIR/render_config.sh" > "$CAP" 2>&1; then
  reject render-failed
fi
cat "$CAP"   # the renderer's own output belongs in the container log
if ! "$MIHOMO_BIN" -t -d "$CFG_DIR" -f "$NEXT" > "$CAP" 2>&1; then
  reject config-test-failed
fi
echo "Config test passed - activating the new config"
mv "$NEXT" "$LIVE"
rm -f "$CAP" "$REJ"
exec "$MIHOMO_BIN" -d "$CFG_DIR"
