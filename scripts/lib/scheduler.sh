#!/bin/sh
# scheduler.sh - DSM Task Scheduler / BusyBox cron validation and command output.
# Requires common.sh (REPO_ROOT, log_error, EXIT_CONFIG).

# cron_normalize EXPR
# Validate a five-field numeric BusyBox cron expression and print it with one
# space between fields. Names such as MON are intentionally rejected so DSM and
# BusyBox variants cannot interpret the same .env differently.
cron_normalize() {
  printf '%s\n' "$1" | awk '
    function uint(s) { return s ~ /^[0-9]+$/ }
    function part(s, lo, hi,   n,p,m,r,a,b) {
      n=split(s,p,"/")
      if (n > 2 || p[1] == "") return 0
      if (n == 2 && (!uint(p[2]) || p[2] < 1 || p[2] > (hi-lo+1))) return 0
      if (p[1] == "*") return 1
      m=split(p[1],r,"-")
      if (m == 1) return uint(r[1]) && r[1] >= lo && r[1] <= hi
      if (m != 2 || !uint(r[1]) || !uint(r[2])) return 0
      a=r[1]+0; b=r[2]+0
      return a >= lo && b <= hi && a <= b
    }
    function field(s, lo, hi,   n,v,i) {
      n=split(s,v,",")
      if (n < 1) return 0
      for (i=1; i<=n; i++) if (!part(v[i],lo,hi)) return 0
      return 1
    }
    NR > 1 { bad=1 }
    NR == 1 {
      if (NF != 5 || !field($1,0,59) || !field($2,0,23) ||
          !field($3,1,31) || !field($4,1,12) || !field($5,0,7)) bad=1
      out=$1 " " $2 " " $3 " " $4 " " $5
    }
    END { if (bad || NR != 1) exit 1; print out }
  '
}

# cron_daily_hhmm EXPR - print HH:MM only for a simple daily schedule.
cron_daily_hhmm() {
  _cd_schedule="$(cron_normalize "$1")" || return 1
  printf '%s\n' "$_cd_schedule" | awk '
    $3 == "*" && $4 == "*" && $5 == "*" &&
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      printf "%02d:%02d\n", $2, $1
      ok=1
    }
    END { exit !ok }
  '
}

# shell_quote VALUE - one POSIX-shell argument, safe for DSM task command text.
shell_quote() {
  _sq_escaped="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" || return 1
  printf "'%s'" "$_sq_escaped"
}

# scheduler_update_command - exact DSM Task Scheduler command. auto_update.sh
# owns UPDATE_LOG and rotation, so do not add a second shell redirection here.
scheduler_update_command() {
  _su_root="$(shell_quote "$REPO_ROOT")" || return 1
  _su_script="$(shell_quote "$REPO_ROOT/scripts/auto_update.sh")" || return 1
  printf 'cd %s && exec /bin/sh %s' "$_su_root" "$_su_script"
}

# scheduler_network_command - exact DSM boot-up task command. Keep the same
# absolute-path and explicit-shell guarantees as the scheduled updater.
scheduler_network_command() {
  _sn_root="$(shell_quote "$REPO_ROOT")" || return 1
  _sn_script="$(shell_quote "$REPO_ROOT/scripts/setup_network.sh")" || return 1
  printf 'cd %s && exec /bin/sh %s' "$_sn_root" "$_sn_script"
}

# scheduler_reload_crond - best-effort compatibility for the unsupported raw
# /etc/crontab fallback. DSM Task Scheduler does not need this function.
scheduler_reload_crond() {
  for _sr_ctl in /usr/syno/bin/synosystemctl /usr/local/bin/synosystemctl; do
    [ -x "$_sr_ctl" ] || continue
    "$_sr_ctl" restart crond >/dev/null 2>&1 && return 0
  done
  if command -v synosystemctl >/dev/null 2>&1; then
    synosystemctl restart crond >/dev/null 2>&1 && return 0
  fi
  for _sr_ctl in /usr/syno/sbin/synoservice /usr/syno/sbin/synoservicecfg; do
    [ -x "$_sr_ctl" ] || continue
    "$_sr_ctl" --restart crond >/dev/null 2>&1 && return 0
    "$_sr_ctl" -restart crond >/dev/null 2>&1 && return 0
  done
  if command -v synoservice >/dev/null 2>&1; then
    synoservice --restart crond >/dev/null 2>&1 && return 0
    synoservice -restart crond >/dev/null 2>&1 && return 0
  fi
  return 1
}
