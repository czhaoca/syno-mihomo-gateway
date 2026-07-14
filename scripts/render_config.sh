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
# Output override for the container entrypoint gate (scripts/mihomo_entrypoint.sh):
# it renders to a temp path and swaps over config.yaml only on a green `mihomo -t`.
# Unset (every other caller: CI, Pi systemd, installer flows) renders to
# config.yaml exactly as before - byte-identical behavior.
OUT="${MIHOMO_RENDER_OUT:-$CFG_DIR/config.yaml}"
TMP="$CFG_DIR/.config.yaml.tmp"
PRE="$CFG_DIR/.config.yaml.pre"
PRE2="$CFG_DIR/.config.yaml.pre2"
PRE4="$CFG_DIR/.config.yaml.pre4"
PRE5="$CFG_DIR/.config.yaml.pre5"
PRE6="$CFG_DIR/.config.yaml.pre6"
CG_GROUPS_FRAG="$CFG_DIR/.country_groups.frag"
CG_MEMBERS_FRAG="$CFG_DIR/.country_members.frag"

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
# Split-horizon DNS (privacy hardening, v2 foreign-by-default) is the ONLY
# profile (the legacy fallback dual-query - which copied every long-tail
# hostname to the domestic resolvers - was purged, proxy-groups-v2 epic
# 2026-07-14): the nameserver-policy entries and the foreign-by-default core
# render unconditionally, and BOTH lists are REQUIRED - validated in the
# mandatory-DNS loop below, failing loud with the variable named. A dead
# tunnel fails closed (SERVFAIL) instead of leaking to a domestic resolver.
# true appends ',no-resolve' to the GEOIP,CN rule so it stops forcing local
# lookups of unmatched domains (see the template comment for the trade-off).
: "${DNS_GEOIP_NO_RESOLVE:=false}"
case "$DNS_GEOIP_NO_RESOLVE" in
  true|false) : ;;
  *) echo "ERROR: DNS_GEOIP_NO_RESOLVE must be true or false" >&2; exit 1 ;;
esac
# Sniffer (SNI/HTTP/QUIC hostname recovery for raw-IP flows). Default OFF
# when unset so a pre-v1.3.10 .env renders byte-identical; .env.example
# ships true, so new installs (and .envs synced from it) sniff by default.
: "${SNIFFER_ENABLE:=false}"
case "$SNIFFER_ENABLE" in
  true|false) : ;;
  *) echo "ERROR: SNIFFER_ENABLE must be true or false" >&2; exit 1 ;;
esac
# Automatic-selection exclusion: a non-empty regexp2 pattern renders the
# Priority Nodes sibling group (nodes matching the pattern removed) as
# PROXY's first member. Empty/unset renders WITHOUT the group, byte-identical to the
# pre-feature output (upgrade compat; .env.example ships an HK default for
# new installs). An INVALID pattern panics mihomo at startup, so the two
# statically-detectable poison classes fail the render here: a backtick
# (mihomo's multi-pattern separator - never valid inside one pattern) and a
# whitespace-only value (an effectively-empty pattern matches - and would
# exclude - every node).
: "${AUTO_EXCLUDE_FILTER:=}"
if [ -n "$AUTO_EXCLUDE_FILTER" ]; then
  case "$AUTO_EXCLUDE_FILTER" in
    *\`*)
      echo "ERROR: AUTO_EXCLUDE_FILTER must not contain a backtick (mihomo's multi-pattern separator; an invalid pattern crashes mihomo at startup)" >&2
      exit 1 ;;
  esac
  case "$AUTO_EXCLUDE_FILTER" in
    *[![:space:]]*) : ;;
    *)
      echo "ERROR: AUTO_EXCLUDE_FILTER is whitespace-only - set a real pattern, or leave it empty/unset to disable the Priority Nodes group" >&2
      exit 1 ;;
  esac
fi
# Country groups: 'NAME=regex;NAME=regex' generates one url-test group per
# entry (nodes matching the regexp2 pattern; a multi-country regex IS the
# multi-country group) spliced into the PROXY and STREAMING selectors in
# spec order. Empty/unset renders WITHOUT any generated group, byte-identical
# to the pre-feature output. Validation is up here with the other knobs; the
# fragment build lives below yaml_dq() (it needs the escaper). Every poison
# class fails BEFORE anything is written: an invalid pattern panics mihomo at
# startup, and a name shadowing a built-in group corrupts routing.
: "${COUNTRY_GROUPS:=}"
if [ -n "$COUNTRY_GROUPS" ]; then
  case "$COUNTRY_GROUPS" in
    *\`*)
      echo "ERROR: COUNTRY_GROUPS must not contain a backtick (mihomo's multi-pattern separator; an invalid pattern crashes mihomo at startup)" >&2
      exit 1 ;;
  esac
  _cg_seen=";"
  _cg_old_ifs=$IFS; IFS=';'
  set -f
  # shellcheck disable=SC2086  # deliberate ';' field split of the spec
  set -- $COUNTRY_GROUPS
  set +f
  IFS=$_cg_old_ifs
  [ $# -gt 0 ] || { echo "ERROR: COUNTRY_GROUPS has no entries (expected NAME=regex;NAME=regex)" >&2; exit 1; }
  for _cg_entry in "$@"; do
    case "$_cg_entry" in
      '')
        echo "ERROR: COUNTRY_GROUPS has an empty entry (doubled or leading ';')" >&2
        exit 1 ;;
      *=*) : ;;
      *)
        echo "ERROR: COUNTRY_GROUPS entry '$_cg_entry' is malformed (expected NAME=regex)" >&2
        exit 1 ;;
    esac
    _cg_name=${_cg_entry%%=*}
    _cg_re=${_cg_entry#*=}
    [ -n "$_cg_name" ] || { echo "ERROR: COUNTRY_GROUPS entry '$_cg_entry' has an empty name" >&2; exit 1; }
    # Interior SPACES are legal in names ("Japan Auto" is a valid group);
    # leading/trailing whitespace (a stray space around ';' or '=') and any
    # non-space whitespace (tab/newline) still refuse loudly.
    case "$_cg_name" in
      ' '*|*' ')
        echo "ERROR: COUNTRY_GROUPS name '$_cg_name' has leading/trailing whitespace (no spaces around ';' or '=')" >&2
        exit 1 ;;
    esac
    case "$(printf '%s' "$_cg_name" | tr -d ' ')" in
      *[[:space:]]*)
        echo "ERROR: COUNTRY_GROUPS name '$_cg_name' contains whitespace other than interior spaces" >&2
        exit 1 ;;
    esac
    case "$_cg_name" in
      'All Nodes'|'Priority Nodes'|PROXY|STREAMING|DIRECT|REJECT|REJECT-DROP|PASS|COMPATIBLE|GLOBAL)
        echo "ERROR: COUNTRY_GROUPS name '$_cg_name' collides with a built-in group/adapter" >&2
        exit 1 ;;
    esac
    case "$_cg_re" in
      *[![:space:]]*) : ;;
      *)
        echo "ERROR: COUNTRY_GROUPS entry for '$_cg_name' has an empty regex" >&2
        exit 1 ;;
    esac
    case "$_cg_seen" in
      *";$_cg_name;"*)
        echo "ERROR: COUNTRY_GROUPS name '$_cg_name' is duplicated" >&2
        exit 1 ;;
    esac
    _cg_seen="$_cg_seen$_cg_name;"
  done
fi
if [ "$DNS_GEOIP_NO_RESOLVE" = true ]; then
  GEOIP_NO_RESOLVE=",no-resolve"
else
  GEOIP_NO_RESOLVE=""
fi
for _v in DNS_DEFAULT_NAMESERVER DNS_NAMESERVER \
          DNS_CN_NAMESERVER DNS_FOREIGN_NAMESERVER; do
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

# Country-group fragment build (spec validated up top with the other knobs;
# nothing here can fail). Two files: the group blocks (each ending in a blank
# line so the insertion leaves the original spacing) and the selector member
# lines, both inserted RAW at their {{COUNTRY_*}} marker lines below - names
# and regexes pass through yaml_dq only (no sed replacement is involved, so
# esc() is not needed and the pattern arrives verbatim).
if [ -n "$COUNTRY_GROUPS" ]; then
  : > "$CG_GROUPS_FRAG"
  : > "$CG_MEMBERS_FRAG"
  _cg_old_ifs=$IFS; IFS=';'
  set -f
  # shellcheck disable=SC2086  # deliberate ';' field split of the spec
  set -- $COUNTRY_GROUPS
  set +f
  IFS=$_cg_old_ifs
  for _cg_entry in "$@"; do
    _cg_name=${_cg_entry%%=*}
    _cg_re=${_cg_entry#*=}
    {
      printf '  - name: "%s"\n' "$(yaml_dq "$_cg_name")"
      printf '    type: url-test\n'
      printf '    use:\n'
      printf '      - my-airport\n'
      printf '    filter: "%s"\n' "$(yaml_dq "$_cg_re")"
      printf '    empty-fallback: REJECT\n'
      printf '    tolerance: 50\n'
      printf '\n'
    } >> "$CG_GROUPS_FRAG"
    printf '      - "%s"\n' "$(yaml_dq "$_cg_name")" >> "$CG_MEMBERS_FRAG"
  done
fi

# Pass 1 - fenced-block inclusion. Each block is fenced by '# {{X_BEGIN}}' /
# '# {{X_END}}' marker lines. Disabled: delete the whole fenced range. Enabled:
# delete only the two marker lines and keep the block (its tokens fill below).
#   TUN block       - kept when TUN_ENABLE=true (the transparent-gateway default).
#   EXTUI block     - kept when EXTERNAL_UI_DIR is non-empty (Pi bare-metal mode).
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
#   SNIFFER block   - kept when SNIFFER_ENABLE=true (hostname recovery for
#                     raw-IP flows from DNS-bypassing LAN clients).
if [ "$SNIFFER_ENABLE" = true ]; then
  sed -e '/{{SNIFFER_BEGIN}}/d' -e '/{{SNIFFER_END}}/d' "$PRE2" > "$PRE4"
else
  sed -e '/{{SNIFFER_BEGIN}}/,/{{SNIFFER_END}}/d' "$PRE2" > "$PRE4"
fi
#   PRIORITY blocks - the Priority Nodes group and its PROXY member line
#                     switch TOGETHER on AUTO_EXCLUDE_FILTER being non-empty
#                     (validated above).
if [ -n "$AUTO_EXCLUDE_FILTER" ]; then
  sed -e '/{{PRIORITY_BEGIN}}/d' -e '/{{PRIORITY_END}}/d' \
      -e '/{{PRIORITYMEMBER_BEGIN}}/d' -e '/{{PRIORITYMEMBER_END}}/d' "$PRE4" > "$PRE5"
else
  sed -e '/{{PRIORITY_BEGIN}}/,/{{PRIORITY_END}}/d' \
      -e '/{{PRIORITYMEMBER_BEGIN}}/,/{{PRIORITYMEMBER_END}}/d' "$PRE4" > "$PRE5"
fi
#   COUNTRY markers - single marker lines, not fences: replaced by the
#                     generated group/member fragments when the spec is set
#                     (awk raw-inserts the files - deterministic across
#                     GNU/BSD/BusyBox, unlike the sed r+d interplay), deleted
#                     when unset so the render stays byte-identical.
if [ -n "$COUNTRY_GROUPS" ]; then
  awk -v groups="$CG_GROUPS_FRAG" -v members="$CG_MEMBERS_FRAG" '
    function emit(f,  l) { while ((getline l < f) > 0) print l; close(f) }
    index($0, "{{COUNTRY_GROUPS}}")            { emit(groups); next }
    index($0, "{{COUNTRY_MEMBERS_PROXY}}")     { emit(members); next }
    index($0, "{{COUNTRY_MEMBERS_STREAMING}}") { emit(members); next }
    { print }
  ' "$PRE5" > "$PRE6"
else
  sed -e '/{{COUNTRY_GROUPS}}/d' \
      -e '/{{COUNTRY_MEMBERS_PROXY}}/d' \
      -e '/{{COUNTRY_MEMBERS_STREAMING}}/d' "$PRE5" > "$PRE6"
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
  -e "s|{{DNS_CN_NAMESERVER}}|$(esc "$DNS_CN_NAMESERVER")|g" \
  -e "s|{{DNS_FOREIGN_NAMESERVER}}|$(esc "$DNS_FOREIGN_NAMESERVER")|g" \
  -e "s|{{GEOIP_NO_RESOLVE}}|$(esc "$GEOIP_NO_RESOLVE")|g" \
  -e "s|{{TUN_AUTO_REDIRECT}}|$(esc "$TUN_AUTO_REDIRECT")|g" \
  -e "s|{{EXTERNAL_UI_DIR}}|$(esc "$(yaml_dq "$EXTERNAL_UI_DIR")")|g" \
  -e "s|{{AUTO_EXCLUDE_FILTER}}|$(esc "$(yaml_dq "$AUTO_EXCLUDE_FILTER")")|g" \
  "$PRE6" > "$TMP"
rm -f "$PRE" "$PRE2" "$PRE4" "$PRE5" "$PRE6" \
      "$CG_GROUPS_FRAG" "$CG_MEMBERS_FRAG"
mv "$TMP" "$OUT"
echo "Rendered $OUT"
