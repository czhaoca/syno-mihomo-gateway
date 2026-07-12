#!/bin/sh
# render_config.sh - render config.yaml from config.template.yaml.
# Substitutes the subscription URL (from subscription.txt) and the env-provided
# tokens (CONTROLLER_*, DNS_*, TUN_*, EXTERNAL_UI_DIR). Used by the mihomo
# container entrypoint, the Pi bare-metal path (staged by the raspberry-pi-port
# epic), and CI (scripts/ci/render_check.py, scripts/ci/pi_installer_check.sh),
# so the exact same renderer is what gets tested.
# POSIX /bin/sh (BusyBox-safe). Fails loud (non-zero, no output file) on bad input.
set -eu

CFG_DIR="${MIHOMO_CONFIG_DIR:-/root/.config/mihomo}"
TEMPLATE="${MIHOMO_TEMPLATE:-$CFG_DIR/config.template.yaml}"
SUB_FILE="$CFG_DIR/subscription.txt"
OUT="$CFG_DIR/config.yaml"
TMP="$CFG_DIR/.config.yaml.tmp"
PRE="$CFG_DIR/.config.yaml.pre"
PRE2="$CFG_DIR/.config.yaml.pre2"
PRE3="$CFG_DIR/.config.yaml.pre3"

# Port/secret may default; DNS must come from .env (CLAUDE.md: no hardcoded DNS).
: "${CONTROLLER_PORT:=9090}"
: "${CONTROLLER_SECRET:=}"
# TUN is ON by default: this is a transparent gateway, so the default render KEEPS the
# tun block (stack: system, which does NOT hijack the controller reply path - mihomo
# #1493). Set TUN_ENABLE=false to render WITHOUT tun and run as a plain proxy instead.
: "${TUN_ENABLE:=true}"
case "$TUN_ENABLE" in
  true|false) : ;;
  *) echo "ERROR: TUN_ENABLE must be true or false" >&2; exit 1 ;;
esac
: "${TUN_AUTO_REDIRECT:=false}"
case "$TUN_AUTO_REDIRECT" in
  true|false) : ;;
  *) echo "ERROR: TUN_AUTO_REDIRECT must be true or false" >&2; exit 1 ;;
esac
# Embedded dashboard dir (Pi bare-metal mode). Empty (the default, and always on
# the DSM compose path) removes the fenced external-ui block entirely, so the
# render stays byte-identical to the pre-fence template output.
: "${EXTERNAL_UI_DIR:=}"
# Split-horizon DNS (privacy hardening, v2 foreign-by-default): BOTH lists set
# keeps the fenced nameserver-policy entries AND swaps the dns core - the
# default resolver becomes the tunneled foreign list with NO fallback
# dual-query (a dead tunnel fails closed instead of leaking long-tail
# hostnames to the domestic resolvers). BOTH empty/unset keeps the legacy
# core, rendering byte-identical to the pre-split-horizon output so existing
# .env files keep working untouched. Exactly ONE set is a half-configuration
# - fail loud, write nothing.
: "${DNS_CN_NAMESERVER:=}"
: "${DNS_FOREIGN_NAMESERVER:=}"
if [ -n "$DNS_CN_NAMESERVER" ] && [ -z "$DNS_FOREIGN_NAMESERVER" ]; then
  echo "ERROR: DNS_CN_NAMESERVER is set but DNS_FOREIGN_NAMESERVER is empty - set both (split-horizon) or neither (legacy)" >&2
  exit 1
fi
if [ -z "$DNS_CN_NAMESERVER" ] && [ -n "$DNS_FOREIGN_NAMESERVER" ]; then
  echo "ERROR: DNS_FOREIGN_NAMESERVER is set but DNS_CN_NAMESERVER is empty - set both (split-horizon) or neither (legacy)" >&2
  exit 1
fi
# true appends ',no-resolve' to the GEOIP,CN rule so it stops forcing local
# lookups of unmatched domains (see the template comment for the trade-off).
: "${DNS_GEOIP_NO_RESOLVE:=false}"
case "$DNS_GEOIP_NO_RESOLVE" in
  true|false) : ;;
  *) echo "ERROR: DNS_GEOIP_NO_RESOLVE must be true or false" >&2; exit 1 ;;
esac
if [ "$DNS_GEOIP_NO_RESOLVE" = true ]; then
  GEOIP_NO_RESOLVE=",no-resolve"
else
  GEOIP_NO_RESOLVE=""
fi
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

# Bootstrap DNS pin for the airport panel (nameserver-policy + fake-ip-filter
# entries in the template): the ONE domain mihomo must resolve BEFORE any node
# exists is the panel itself - the fallback-filter would otherwise divert it to
# fallback resolvers that are dead at cold start, and the provider could never
# bootstrap (the 2026-07-12 outage). Userinfo and a :port are stripped from the
# URL host. An IP-literal host (IPv4 digits-and-dots, or bracketed IPv6) needs
# no DNS at all - both pin lines render as comments instead; the mirror pin
# above them keeps the nameserver-policy mapping non-empty either way.
AIRPORT_HOST=$(printf '%s' "$SUB_URL" \
  | sed -n 's|^[A-Za-z][A-Za-z0-9+.-]*://\([^/?#]*\).*|\1|p' \
  | sed -e 's/^.*@//' -e 's/:[0-9]*$//')
AIRPORT_PIN_ON=1
case "$AIRPORT_HOST" in
  '') AIRPORT_PIN_ON=0 ;;        # unparseable URL - degrade, never fail the render
  \[*) AIRPORT_PIN_ON=0 ;;       # bracketed IPv6 literal
  *[!0-9.]*) : ;;                # has a letter/dash -> a real domain
  *) AIRPORT_PIN_ON=0 ;;         # digits-and-dots only -> IPv4 literal
esac
if [ "$AIRPORT_PIN_ON" = 1 ]; then
  AIRPORT_DNS_PIN="'$AIRPORT_HOST': [ $DNS_NAMESERVER ]"
  AIRPORT_FAKEIP_PIN="- '$AIRPORT_HOST'"
else
  echo "NOTE: no panel DNS pin (subscription host '${AIRPORT_HOST:-}' is an IP literal or unparseable)" >&2
  AIRPORT_DNS_PIN="# (panel DNS pin skipped: subscription host is an IP literal or unparseable)"
  AIRPORT_FAKEIP_PIN="# (panel fake-ip pin skipped: subscription host is an IP literal or unparseable)"
fi

# Two escaping layers, applied in order for values that land inside a YAML
# double-quoted scalar; only the sed layer for bare/flow-sequence values.
#
# esc - escape sed replacement-side specials so a value renders verbatim through
#   `sed s|...|...|`: backslash FIRST, then & (whole-match ref) and the '|'
#   delimiter. URLs join params with &; '|' is our delimiter.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\\&/g' -e 's/|/\\|/g'; }
#
# yaml_dq - escape a value for a YAML DOUBLE-QUOTED scalar ("..."): backslash
#   FIRST, then the double-quote. The template wraps the subscription URL and the
#   controller secret in double quotes, so an unescaped " would close the string
#   early (invalid YAML -> mihomo crash-loops) and a \ would be read as a YAML
#   escape. Compose UNDER esc() so sed then emits the escaped form verbatim:
#   esc "$(yaml_dq "$value")". Bare/flow values (port, DNS) must NOT use this -
#   \" is only meaningful inside double quotes.
yaml_dq() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# Pass 1 - fenced-block inclusion. Each block is fenced by '# {{X_BEGIN}}' /
# '# {{X_END}}' marker lines. Disabled: delete the whole fenced range. Enabled:
# delete only the two marker lines and keep the block (its tokens fill below).
#   TUN block       - kept when TUN_ENABLE=true (the transparent-gateway default).
#   EXTUI block     - kept when EXTERNAL_UI_DIR is non-empty (Pi bare-metal mode).
#   DNS fences      - three blocks switch TOGETHER on the split-horizon
#                     condition (validated above: both or neither, so testing
#                     one suffices). ON: keep the DNSPOLICY entries + the
#                     DNSSPLIT core (foreign-by-default nameserver, no
#                     fallback), delete the DNSLEGACY core. OFF: delete
#                     DNSPOLICY + DNSSPLIT, keep the DNSLEGACY core (domestic
#                     nameserver + fallback + fallback-filter) so a pre-1.3.8
#                     .env renders byte-identical to its old output.
if [ "$TUN_ENABLE" = true ]; then
  sed -e '/{{TUN_BEGIN}}/d' -e '/{{TUN_END}}/d' "$TEMPLATE" > "$PRE"
else
  sed -e '/{{TUN_BEGIN}}/,/{{TUN_END}}/d' "$TEMPLATE" > "$PRE"
fi
if [ -n "$EXTERNAL_UI_DIR" ]; then
  sed -e '/{{EXTUI_BEGIN}}/d' -e '/{{EXTUI_END}}/d' "$PRE" > "$PRE2"
else
  sed -e '/{{EXTUI_BEGIN}}/,/{{EXTUI_END}}/d' "$PRE" > "$PRE2"
fi
if [ -n "$DNS_CN_NAMESERVER" ]; then
  sed -e '/{{DNSPOLICY_BEGIN}}/d' -e '/{{DNSPOLICY_END}}/d' \
      -e '/{{DNSSPLIT_BEGIN}}/d' -e '/{{DNSSPLIT_END}}/d' \
      -e '/{{DNSLEGACY_BEGIN}}/,/{{DNSLEGACY_END}}/d' "$PRE2" > "$PRE3"
else
  sed -e '/{{DNSPOLICY_BEGIN}}/,/{{DNSPOLICY_END}}/d' \
      -e '/{{DNSSPLIT_BEGIN}}/,/{{DNSSPLIT_END}}/d' \
      -e '/{{DNSLEGACY_BEGIN}}/d' -e '/{{DNSLEGACY_END}}/d' "$PRE2" > "$PRE3"
fi

# Pass 2 - token substitution (a disabled fence simply leaves no token behind;
# EXTERNAL_UI_DIR renders inside a YAML double-quoted scalar like the secret).
sed \
  -e "s|{{AIRPORT_URL}}|$(esc "$(yaml_dq "$SUB_URL")")|g" \
  -e "s|{{AIRPORT_DNS_PIN}}|$(esc "$AIRPORT_DNS_PIN")|g" \
  -e "s|{{AIRPORT_FAKEIP_PIN}}|$(esc "$AIRPORT_FAKEIP_PIN")|g" \
  -e "s|{{CONTROLLER_PORT}}|$(esc "$CONTROLLER_PORT")|g" \
  -e "s|{{CONTROLLER_SECRET}}|$(esc "$(yaml_dq "$CONTROLLER_SECRET")")|g" \
  -e "s|{{DNS_DEFAULT_NAMESERVER}}|$(esc "$DNS_DEFAULT_NAMESERVER")|g" \
  -e "s|{{DNS_NAMESERVER}}|$(esc "$DNS_NAMESERVER")|g" \
  -e "s|{{DNS_FALLBACK}}|$(esc "$DNS_FALLBACK")|g" \
  -e "s|{{DNS_CN_NAMESERVER}}|$(esc "$DNS_CN_NAMESERVER")|g" \
  -e "s|{{DNS_FOREIGN_NAMESERVER}}|$(esc "$DNS_FOREIGN_NAMESERVER")|g" \
  -e "s|{{GEOIP_NO_RESOLVE}}|$(esc "$GEOIP_NO_RESOLVE")|g" \
  -e "s|{{TUN_AUTO_REDIRECT}}|$(esc "$TUN_AUTO_REDIRECT")|g" \
  -e "s|{{EXTERNAL_UI_DIR}}|$(esc "$(yaml_dq "$EXTERNAL_UI_DIR")")|g" \
  "$PRE3" > "$TMP"
rm -f "$PRE" "$PRE2" "$PRE3"
mv "$TMP" "$OUT"
echo "Rendered $OUT"

# One-time provider-cache adoption: pre-1.3.8 renders had no provider `path:`,
# so mihomo cached the fetched node list under its md5-of-URL default filename
# (also where the documented seed recovery used to write it). The stable
# `path: ./proxies/my-airport.yaml` in the template reads the named file only -
# adopt an existing hash-named cache so an upgrade never cold-starts node-less
# when a live fetch happens to be impossible at that moment.
PROV_NAMED="$CFG_DIR/proxies/my-airport.yaml"
if [ ! -f "$PROV_NAMED" ] && command -v md5sum >/dev/null 2>&1; then
  _hash=$(printf '%s' "$SUB_URL" | md5sum | awk '{print $1}')
  if [ -f "$CFG_DIR/proxies/$_hash" ]; then
    if cp "$CFG_DIR/proxies/$_hash" "$PROV_NAMED" 2>/dev/null; then
      echo "Adopted provider cache proxies/$_hash -> proxies/my-airport.yaml"
    else
      echo "WARN: failed to adopt provider cache proxies/$_hash" >&2
    fi
  fi
fi
