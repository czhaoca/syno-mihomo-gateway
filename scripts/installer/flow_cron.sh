#!/bin/sh
# flow_cron.sh - Flow B: configure the automatic image-update job (scripts/
# auto_update.sh). Asks a friendly daily time + timezone, then lets the operator
# choose HOW to schedule it: the DSM Task Scheduler web UI (recommended,
# persistent across DSM upgrades), a CLI crontab entry, or just a dry-run.
#
# Requires the installer module set sourced. POSIX /bin/sh.

# install_fallback_crontab - append the auto-update line to /etc/crontab (DSM's
# crontab has a leading user column). Needs root. Warned as DSM-wipeable.
install_fallback_crontab() {
  if ! is_root; then
    ui_warn "$(msg cron_need_root)"
    sudo_rerun_hint
    return 1
  fi
  _ct=/etc/crontab
  if [ ! -f "$_ct" ]; then
    diagnose "$(msgf diag_no_crontab "$_ct")" "$(msg diag_no_crontab_fix)"
    return 1
  fi
  if grep -Fq "scripts/auto_update.sh" "$_ct" 2>/dev/null; then
    ui_ok "$(msgf ok_cron_exists "$_ct")"
    return 0
  fi
  _min="$(echo "$UPDATE_SCHEDULE" | awk '{print $1}')"
  _hr="$(echo "$UPDATE_SCHEDULE" | awk '{print $2}')"
  _rest="$(echo "$UPDATE_SCHEDULE" | awk '{print $3, $4, $5}')"
  # mkdir -p logs FIRST: the '>>' redirect is opened by the shell before
  # auto_update.sh runs, so an absent logs/ would fail the job on first run.
  _cmd="cd $REPO_ROOT && mkdir -p logs && /bin/sh scripts/auto_update.sh >> logs/auto-update.log 2>&1"
  # DSM crontab columns: min hour dom mon dow USER command
  if printf '%s\t%s\t%s\troot\t%s\n' "$_min" "$_hr" "$_rest" "$_cmd" >> "$_ct"; then
    if synoservice --restart crond >/dev/null 2>&1 || synoservice -restart crond >/dev/null 2>&1; then
      ui_ok "$(msg ok_cron_installed)"
    else
      ui_warn "$(msgf warn_cron_reload "$_ct")"
    fi
    ui_warn "$(msg warn_cron_tz)"
    return 0
  fi
  diagnose "$(msgf diag_cron_write "$_ct")" "$(msg diag_cron_write_fix)"
  return 1
}

# _default_hhmm - derive a HH:MM default from the current UPDATE_SCHEDULE
# ("M H * * *"); falls back to 02:00 when it isn't a simple daily time.
_default_hhmm() {
  _s="$(env_get UPDATE_SCHEDULE || echo '0 2 * * *')"
  _m="$(echo "$_s" | awk '{print $1}')"
  _h="$(echo "$_s" | awk '{print $2}')"
  case "$_m$_h" in
    ''|*[!0-9]*) printf '02:00' ;;
    *) printf '%02d:%02d' "$_h" "$_m" ;;
  esac
}

flow_cron() {
  ui_step "$(msg step_cron)"
  if [ ! -f "$ENV_FILE" ]; then
    diagnose "$(msg diag_no_env)" "$(msg diag_no_env_fix)"
    return 1
  fi
  load_env

  # --- daily time (HH:MM, local) -> cron "M H * * *" ---
  ui_ask_validated _time "$(msg q_daily_time)" "$(_default_hhmm)" is_hhmm
  _hh="${_time%%:*}"; _mm="${_time#*:}"
  UPDATE_SCHEDULE="$(printf '%d %d * * *' "$_mm" "$_hh")"
  env_set UPDATE_SCHEDULE "\"$UPDATE_SCHEDULE\""   # quote: spaces + '*'

  # --- timezone (menu + free entry) ---
  ui_menu_select _tz "$(msg cron_tz_prompt)" \
    "Asia/Shanghai" "Asia/Hong_Kong" "Asia/Tokyo" "UTC" \
    "America/Los_Angeles" "America/New_York" "Europe/London" "$(msg cron_tz_other)"
  case "$UI_MENU_INDEX" in
    1) UPDATE_TZ="Asia/Shanghai" ;;
    2) UPDATE_TZ="Asia/Hong_Kong" ;;
    3) UPDATE_TZ="Asia/Tokyo" ;;
    4) UPDATE_TZ="UTC" ;;
    5) UPDATE_TZ="America/Los_Angeles" ;;
    6) UPDATE_TZ="America/New_York" ;;
    7) UPDATE_TZ="Europe/London" ;;
    *) ui_ask UPDATE_TZ "$(msg q_tz_freeform)" "$(env_get UPDATE_TZ || echo Asia/Shanghai)" ;;
  esac
  env_set UPDATE_TZ "$UPDATE_TZ"

  if ui_yesno "$(msg ask_enable_updates)" y; then
    env_set UPDATE_ENABLED true
  else
    env_set UPDATE_ENABLED false
    ui_warn "$(msg warn_updates_disabled)"
  fi
  load_env
  ui_ok "$(msgf ok_schedule "${_time}" "${UPDATE_TZ}")"

  # --- how to schedule it ---
  while :; do
    ui_say ""
    ui_menu_select _how "$(msg cron_how)" \
      "$(msg cron_how_dsm)" \
      "$(msg cron_how_cli)" \
      "$(msg cron_how_dry)" \
      "$(msg cron_how_done)"
    case "$UI_MENU_INDEX" in
      1) ui_step "$(msg step_dsm_sched)"
         sh "$REPO_ROOT/scripts/install_scheduler.sh" ;;
      2) install_fallback_crontab || ui_warn "$(msg warn_cron_not_installed)" ;;
      3) ui_info "$(msg info_dry_run)"
         sh "$REPO_ROOT/scripts/auto_update.sh" --dry-run \
           || ui_warn "$(msg warn_dry_run_nonzero)" ;;
      4) break ;;
    esac
  done

  ui_ok "$(msg ok_cron_complete)"
  return 0
}
