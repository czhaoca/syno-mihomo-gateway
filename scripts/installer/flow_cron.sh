#!/bin/sh
# flow_cron.sh - Flow B: configure the automatic image-update job (scripts/
# auto_update.sh). Confirms the schedule/timezone/kill-switch in .env, prints the
# recommended DSM Task Scheduler settings (persistent across DSM upgrades), offers
# a dry-run, and optionally installs the fallback crontab line.
#
# Requires the installer module set sourced. POSIX /bin/sh.

# install_fallback_crontab - append the auto-update line to /etc/crontab (DSM's
# crontab has a leading user column). Needs root. Warned as DSM-wipeable.
install_fallback_crontab() {
  if ! is_root; then
    ui_warn "installing a crontab line needs root."
    sudo_rerun_hint
    return 1
  fi
  _ct=/etc/crontab
  if [ ! -f "$_ct" ]; then
    diagnose "$_ct not found (not a cron/DSM host?)" "use the DSM Task Scheduler settings printed above instead"
    return 1
  fi
  if grep -Fq "scripts/auto_update.sh" "$_ct" 2>/dev/null; then
    ui_ok "an auto-update line already exists in $_ct - not adding a duplicate"
    return 0
  fi
  _min="$(echo "$UPDATE_SCHEDULE" | awk '{print $1}')"
  _hr="$(echo "$UPDATE_SCHEDULE" | awk '{print $2}')"
  _rest="$(echo "$UPDATE_SCHEDULE" | awk '{print $3, $4, $5}')"
  _cmd="cd $REPO_ROOT && /bin/sh scripts/auto_update.sh >> logs/auto-update.log 2>&1"
  # DSM crontab columns: min hour dom mon dow USER command
  if printf '%s\t%s\t%s\troot\tTZ=%s %s\n' \
       "$_min" "$_hr" "$_rest" "${UPDATE_TZ:-Asia/Shanghai}" "$_cmd" >> "$_ct"; then
    if synoservice --restart crond >/dev/null 2>&1 || synoservice -restart crond >/dev/null 2>&1; then
      ui_ok "fallback crontab line installed and crond reloaded"
    else
      ui_warn "line added to $_ct - reload cron manually: synoservice --restart crond"
    fi
    return 0
  fi
  diagnose "could not write to $_ct" "run as root (sudo)"
  return 1
}

flow_cron() {
  ui_step "Automatic update (cron) setup"
  if [ ! -f "$ENV_FILE" ]; then
    diagnose ".env not found" "run the end-to-end deploy first (main menu option 1)"
    return 1
  fi
  load_env

  ui_ask UPDATE_SCHEDULE "Update schedule (cron: minute hour day month weekday)" "$(env_get UPDATE_SCHEDULE || echo '0 9 * * *')"
  env_set UPDATE_SCHEDULE "\"$UPDATE_SCHEDULE\""     # quote: contains spaces + '*'
  ui_ask UPDATE_TZ "Timezone the schedule runs in" "$(env_get UPDATE_TZ || echo Asia/Shanghai)"
  env_set UPDATE_TZ "$UPDATE_TZ"
  if ui_yesno "Enable automatic updates?" y; then
    env_set UPDATE_ENABLED true
  else
    env_set UPDATE_ENABLED false
    ui_warn "auto-updates disabled (UPDATE_ENABLED=false) - the job will no-op until re-enabled"
  fi
  load_env

  ui_step "Synology DSM Task Scheduler settings (recommended)"
  sh "$REPO_ROOT/scripts/install_scheduler.sh"

  if ui_yesno "Run a dry-run now to validate the update pipeline (applies NOTHING)?" y; then
    ui_info "running: scripts/auto_update.sh --dry-run"
    sh "$REPO_ROOT/scripts/auto_update.sh" --dry-run \
      || ui_warn "dry-run exited non-zero - review the output above (this does not change the deploy)"
  fi

  if ui_yesno "Also install the FALLBACK crontab line now? (DSM may overwrite it on upgrade)" n; then
    install_fallback_crontab || ui_warn "fallback crontab not installed - use the DSM GUI task above"
  fi

  ui_ok "cron setup complete. The DSM GUI task is the recommended, upgrade-persistent method."
  return 0
}
