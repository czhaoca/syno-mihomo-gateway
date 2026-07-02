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
  if ! _schedule="$(cron_normalize "$UPDATE_SCHEDULE")"; then
    diagnose "invalid UPDATE_SCHEDULE" "enter a safe five-field numeric cron expression"
    return 1
  fi
  _cmd="$(scheduler_update_command)" || return 1
  # DSM crontab columns: min hour dom mon dow USER command
  if printf '%s\troot\t%s\n' "$_schedule" "$_cmd" >> "$_ct"; then
    if scheduler_reload_crond; then
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
  cron_daily_hhmm "$_s" 2>/dev/null || printf '02:00'
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
  env_set UPDATE_SCHEDULE "$UPDATE_SCHEDULE"       # env_set quotes safely

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

  # --- generic auto-update targets (optional per-container opt-in) ---
  if ui_yesno "$(msg ask_manage_targets)" n; then
    flow_targets
  fi

  # --- how to schedule it ---
  # Track what actually happened so choosing "Done" cannot masquerade as
  # success when nothing was scheduled (closed-loop guarantee):
  #   _fc_installed=1  a crontab entry really landed
  #   _fc_shown=1      the DSM Task Scheduler instructions were displayed
  #                    (the task itself is created manually in the web UI)
  _fc_installed=0
  _fc_shown=0
  while :; do
    ui_say ""
    ui_menu_select _how "$(msg cron_how)" \
      "$(msg cron_how_dsm)" \
      "$(msg cron_how_cli)" \
      "$(msg cron_how_dry)" \
      "$(msg cron_how_done)"
    case "$UI_MENU_INDEX" in
      1) ui_step "$(msg step_dsm_sched)"
         if sh "$REPO_ROOT/scripts/install_scheduler.sh"; then
           _fc_shown=1
         else
           ui_warn "$(msg warn_sched_show_failed)"
         fi ;;
      2) if install_fallback_crontab; then
           _fc_installed=1
         else
           ui_warn "$(msg warn_cron_not_installed)"
         fi ;;
      3) ui_info "$(msg info_dry_run)"
         sh "$REPO_ROOT/scripts/auto_update.sh" --dry-run \
           || ui_warn "$(msg warn_dry_run_nonzero)" ;;
      4) break ;;
    esac
  done

  if [ "$_fc_installed" = 1 ]; then
    ui_ok "$(msg ok_cron_complete)"
    return 0
  fi
  if [ "$(env_get UPDATE_ENABLED 2>/dev/null || echo true)" = true ]; then
    if [ "$_fc_shown" = 1 ]; then
      # Instructions were displayed; the DSM task is created manually.
      ui_warn "$(msg warn_cron_manual_pending)"
    else
      ui_warn "$(msg warn_cron_none)"
      if ui_yesno "$(msg ask_disable_updates)" n; then
        env_set UPDATE_ENABLED false
        ui_warn "$(msg warn_updates_disabled)"
      fi
    fi
  fi
  ui_ok "$(msg ok_cron_partial)"
  return 0
}
