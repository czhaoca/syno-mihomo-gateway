#!/bin/sh
# ui.sh - interactive terminal helpers for install.sh (the guided installer).
#
# This module is the ONLY place that talks to a TTY (prompts, colors, menus). It
# is deliberately separate from scripts/lib/common.sh so the unattended cron job
# (scripts/auto_update.sh) never sources interactive code that could block on a
# prompt.
#
# POSIX /bin/sh (DSM BusyBox): no `read -p`, no `[[ ]]`/`=~`, no arrays, no
# `local`. Function-local vars are prefixed `_` by convention.

# --- colors (only when stdout is a TTY; honor NO_COLOR) -----------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$(printf '\033[0m');  C_BOLD=$(printf '\033[1m')
  C_RED=$(printf '\033[31m');   C_GREEN=$(printf '\033[32m')
  C_YELLOW=$(printf '\033[33m'); C_BLUE=$(printf '\033[36m')
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

# --- leveled output (to stderr so it never pollutes captured stdout) ----------
ui_info()  { printf '%s\n' "${C_BLUE}*${C_RESET} $*" >&2; }
ui_ok()    { printf '%s\n' "${C_GREEN}ok${C_RESET}  $*" >&2; }
ui_warn()  { printf '%s\n' "${C_YELLOW}WARN${C_RESET} $*" >&2; }
ui_error() { printf '%s\n' "${C_RED}ERROR${C_RESET} $*" >&2; }
ui_step()  { printf '\n%s\n' "${C_BOLD}== $* ==${C_RESET}" >&2; }
ui_say()   { printf '%s\n' "$*" >&2; }

# diagnose CONTEXT REMEDIATION - the consistent error model (req #6): a one-line
# diagnosis, a concrete fix, and where to look. Never dumps a raw failure.
diagnose() {
  ui_error "$1"
  [ -n "${2:-}" ] && printf '%s\n' "      ${C_BOLD}Try:${C_RESET} $2" >&2
  [ -n "${INSTALL_LOG:-}" ] && printf '%s\n' "      Details: $INSTALL_LOG" >&2
  return 0
}

# try DESC REMEDIATION -- COMMAND...  Run COMMAND; on failure emit a diagnosis
# (req #6) and return its exit code so callers can branch. Everything after the
# literal '--' is the command. Stdout/stderr of the command are shown.
try() {
  _desc="$1"; _fix="$2"; shift 2
  [ "$1" = "--" ] && shift
  if "$@"; then
    return 0
  else
    # Capture inside else: after a completed `if` compound, `$?` may be zero
    # even though the condition command failed (BusyBox ash included).
    _rc=$?
  fi
  diagnose "$_desc (exit $_rc)" "$_fix"
  return "$_rc"
}

# --- prompts ------------------------------------------------------------------
# _read_line VARNAME - read one line from the controlling terminal into VARNAME.
# Distinguishes EOF (Ctrl-D) from an empty line (Enter): on a pure EOF it QUITS
# the installer cleanly (Ctrl-D = quit, the expected behavior), restoring the
# terminal via the EXIT trap. An empty line returns 0 with an empty value so
# callers can apply their default. A partial (unterminated) line typed before
# EOF is accepted, not discarded. install.sh guarantees /dev/tty is readable.
_read_line() {
  _rl=""
  if IFS= read -r _rl </dev/tty; then eval "$1=\$_rl"; return 0; fi
  [ -n "$_rl" ] && { eval "$1=\$_rl"; return 0; }   # partial line before EOF
  printf '\n' >&2
  stty echo </dev/tty 2>/dev/null
  ui_say "$(msg quit 2>/dev/null || echo 'Quit.')"
  exit "${EXIT_OK:-0}"
}

# ui_ask VARNAME PROMPT [DEFAULT] - read a line into VARNAME, offering DEFAULT
# (Enter accepts it). Ctrl-D quits (via _read_line).
ui_ask() {
  _var="$1"; _prompt="$2"; _def="${3:-}"
  if [ -n "$_def" ]; then
    printf '%s [%s]: ' "$_prompt" "$_def" >&2
  else
    printf '%s: ' "$_prompt" >&2
  fi
  _read_line _ans
  [ -n "$_ans" ] || _ans="$_def"
  eval "$_var=\$_ans"
}

# ui_ask_secret VARNAME PROMPT - read a line with echo OFF (passwords/tokens).
# Ctrl-D quits (via _read_line, which restores echo first). install.sh guarantees
# /dev/tty is readable.
ui_ask_secret() {
  _var="$1"; _prompt="$2"
  printf '%s: ' "$_prompt" >&2
  stty -echo </dev/tty 2>/dev/null
  _read_line _ans
  stty echo </dev/tty 2>/dev/null
  printf '\n' >&2
  eval "$_var=\$_ans"
}

# ui_yesno PROMPT [DEFAULT=y|n] - return 0 for yes, 1 for no. Enter takes DEFAULT.
ui_yesno() {
  _prompt="$1"; _def="${2:-n}"
  case "$_def" in y|Y) _hint="Y/n" ;; *) _hint="y/N" ;; esac
  while :; do
    printf '%s [%s]: ' "$_prompt" "$_hint" >&2
    _read_line _a
    [ -n "$_a" ] || _a="$_def"
    case "$_a" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No)    return 1 ;;
      *) ui_warn "$(msg warn_yn 2>/dev/null || echo 'please answer y or n')" ;;
    esac
  done
}

# ui_menu_select VARNAME PROMPT ITEM1 [ITEM2 ...] - print a numbered menu, read a
# choice, set VARNAME to the chosen item text AND the global UI_MENU_INDEX to the
# 1-based index. Callers dispatch on UI_MENU_INDEX (stable under i18n, since the
# item TEXT is localized but the index is not). Returns 0 on a valid pick.
ui_menu_select() {
  _var="$1"; _prompt="$2"; shift 2
  UI_MENU_INDEX=0
  _n=0
  for _it in "$@"; do
    _n=$((_n + 1))
    printf '  %s) %s\n' "$_n" "$_it" >&2
  done
  while :; do
    printf '%s [1-%s]: ' "$_prompt" "$_n" >&2
    _read_line _c
    case "$_c" in
      ''|*[!0-9]*) ui_warn "$(msg warn_num 2>/dev/null || echo "enter a number 1-$_n")"; continue ;;
    esac
    if [ "$_c" -ge 1 ] && [ "$_c" -le "$_n" ]; then
      UI_MENU_INDEX="$_c"
      _i=0
      for _it in "$@"; do
        _i=$((_i + 1))
        [ "$_i" = "$_c" ] && { eval "$_var=\$_it"; return 0; }
      done
    fi
    ui_warn "$(msg warn_range 2>/dev/null || echo 'out of range')"
  done
}

# --- validators (return 0 if valid) -------------------------------------------
is_ipv4() {
  _ip="$1"
  case "$_ip" in
    ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
  esac
  # exactly three dots -> four fields
  _rest="$_ip"; _dots=0
  while [ "$_rest" != "${_rest#*.}" ]; do _rest="${_rest#*.}"; _dots=$((_dots + 1)); done
  [ "$_dots" -eq 3 ] || return 1
  _o1=${_ip%%.*}; _r=${_ip#*.}; _o2=${_r%%.*}; _r=${_r#*.}; _o3=${_r%%.*}; _o4=${_r#*.}
  for _o in "$_o1" "$_o2" "$_o3" "$_o4"; do
    case "$_o" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#_o}" -le 3 ] && [ "$_o" -le 255 ] || return 1
  done
  return 0
}

is_cidr() {
  case "$1" in
    */*) _ip=${1%/*}; _mask=${1#*/} ;;
    *) return 1 ;;
  esac
  is_ipv4 "$_ip" || return 1
  case "$_mask" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_mask" -ge 0 ] && [ "$_mask" -le 32 ]
}

is_port() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# is_hhmm HH:MM - 0 if a valid 24h clock time (00:00 .. 23:59). Accepts H:MM too.
is_hhmm() {
  case "$1" in
    [0-9][0-9]:[0-9][0-9]|[0-9]:[0-9][0-9]) : ;;
    *) return 1 ;;
  esac
  _h="${1%%:*}"; _m="${1#*:}"
  [ "$_h" -ge 0 ] && [ "$_h" -le 23 ] && [ "$_m" -ge 0 ] && [ "$_m" -le 59 ]
}

# is_dns_list - 0 if a non-empty comma-separated list where each entry looks like
# a DNS server: an IPv4, or a host/scheme (contains a '.' or '://', e.g.
# dns.google or https://dns.example/dns-query). Guards the .env DNS_* fields,
# which render_config.sh HARD-FAILS on when empty.
is_dns_list() {
  [ -n "$1" ] || return 1
  _dl_rest="$1"
  while [ -n "$_dl_rest" ]; do
    case "$_dl_rest" in
      *,*) _dl_tok="${_dl_rest%%,*}"; _dl_rest="${_dl_rest#*,}" ;;
      *)   _dl_tok="$_dl_rest"; _dl_rest="" ;;
    esac
    _dl_tok="${_dl_tok# }"; _dl_tok="${_dl_tok% }"   # trim one leading/trailing space
    [ -n "$_dl_tok" ] || return 1
    case "$_dl_tok" in
      *://*|*.*) : ;;        # scheme (DoH/DoT) or a dotted host / IPv4
      *) return 1 ;;
    esac
  done
  return 0
}

# ui_ask_validated VARNAME PROMPT DEFAULT VALIDATOR - re-prompt until VALIDATOR
# (a function name taking the value) accepts the input.
ui_ask_validated() {
  _v="$1"; _p="$2"; _d="$3"; _check="$4"; _tmp=""
  while :; do
    ui_ask _tmp "$_p" "$_d"
    if "$_check" "$_tmp"; then eval "$_v=\$_tmp"; return 0; fi
    ui_warn "$(msgf invalid_value "$_tmp")"
  done
}
