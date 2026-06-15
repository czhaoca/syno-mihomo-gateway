#!/bin/sh
# render_config.sh - render config.yaml from config.template.yaml.
# Substitutes the subscription URL (from subscription.txt) and the env-provided
# tokens (CONTROLLER_*, DNS_*). Used by BOTH the mihomo container entrypoint and
# CI (scripts/ci/render_check.py), so the exact same renderer is what gets tested.
# POSIX /bin/sh (BusyBox-safe). Fails loud (non-zero, no output file) on bad input.
set -eu

CFG_DIR="${MIHOMO_CONFIG_DIR:-/root/.config/mihomo}"
TEMPLATE="$CFG_DIR/config.template.yaml"
SUB_FILE="$CFG_DIR/subscription.txt"
OUT="$CFG_DIR/config.yaml"
TMP="$CFG_DIR/.config.yaml.tmp"

# Port/secret may default; DNS must come from .env (CLAUDE.md: no hardcoded DNS).
: "${CONTROLLER_PORT:=9090}"
: "${CONTROLLER_SECRET:=}"
for _v in DNS_DEFAULT_NAMESERVER DNS_NAMESERVER DNS_FALLBACK; do
  eval "_val=\${$_v:-}"
  [ -n "$_val" ] || { echo "ERROR: $_v must be set in .env (see .env.example)" >&2; exit 1; }
done

[ -f "$TEMPLATE" ] || { echo "ERROR: template not found: $TEMPLATE" >&2; exit 1; }
[ -f "$SUB_FILE" ] || { echo "ERROR: subscription.txt not found: $SUB_FILE" >&2; exit 1; }

# First non-comment, non-blank line of subscription.txt. Strip an OPTIONAL leading
# "label=" prefix and trailing whitespace, while PRESERVING every '=' inside the URL
# itself (e.g. ?token=abc&flag=1). A bare URL line (https://...) is left intact because
# the leading run [A-Za-z0-9_.-]* stops at ':' before any '='.
SUB_URL=$(grep -v '^#' "$SUB_FILE" | grep -v '^[[:space:]]*$' | head -n1 \
  | sed -e 's/^[A-Za-z0-9_.-]*=//' -e 's/[[:space:]]*$//')
[ -n "$SUB_URL" ] || { echo "ERROR: subscription.txt has no usable URL" >&2; exit 1; }

# Escape sed replacement-side specials so values containing & | \ render verbatim
# (URLs join params with &; '|' is our sed delimiter). Order matters: backslash first.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\\&/g' -e 's/|/\\|/g'; }

sed \
  -e "s|{{AIRPORT_URL}}|$(esc "$SUB_URL")|g" \
  -e "s|{{CONTROLLER_PORT}}|$(esc "$CONTROLLER_PORT")|g" \
  -e "s|{{CONTROLLER_SECRET}}|$(esc "$CONTROLLER_SECRET")|g" \
  -e "s|{{DNS_DEFAULT_NAMESERVER}}|$(esc "$DNS_DEFAULT_NAMESERVER")|g" \
  -e "s|{{DNS_NAMESERVER}}|$(esc "$DNS_NAMESERVER")|g" \
  -e "s|{{DNS_FALLBACK}}|$(esc "$DNS_FALLBACK")|g" \
  "$TEMPLATE" > "$TMP"
mv "$TMP" "$OUT"
echo "Rendered $OUT"
