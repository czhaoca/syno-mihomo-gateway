#!/bin/sh
# install_scheduler.sh - print the exact DSM Task Scheduler settings (and a fallback
# crontab line) for the auto-updater, derived from .env (UPDATE_SCHEDULE / UPDATE_TZ).
# This does NOT modify DSM: registering a root scheduled task is a one-time GUI step
# that survives DSM upgrades, whereas hand-edited /etc/crontab gets rewritten.

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/lib/common.sh"
# shellcheck source=scripts/lib/scheduler.sh
. "$SELF_DIR/lib/scheduler.sh"

ensure_persistent_state || {
  echo "FATAL: cannot create persistent data directory: $GATEWAY_DATA_DIR" >&2
  exit "$EXIT_CONFIG"
}
if [ -f "$ENV_FILE" ]; then
  dotenv_load "$ENV_FILE" || exit "$EXIT_CONFIG"
fi
: "${UPDATE_SCHEDULE:=0 2 * * *}"
: "${UPDATE_TZ:=Asia/Shanghai}"

if ! UPDATE_SCHEDULE="$(cron_normalize "$UPDATE_SCHEDULE")"; then
  log_error "invalid UPDATE_SCHEDULE: expected a safe five-field numeric cron expression"
  exit "$EXIT_CONFIG"
fi
CMD="$(scheduler_update_command)" || exit "$EXIT_CONFIG"
BOOT_CMD="$(scheduler_network_command)" || exit "$EXIT_CONFIG"

# Parse the cron "minute hour" fields into a friendly daily time for the GUI.
if DAILY_TIME="$(cron_daily_hhmm "$UPDATE_SCHEDULE")"; then
  SCHED_DESC="Daily, first run time $DAILY_TIME"
else
  SCHED_DESC="Custom schedule (cron: $UPDATE_SCHEDULE) - set the DSM trigger to match"
fi

cat <<EOF
========================================================================
 Synology DSM Task Scheduler - auto-update setup
========================================================================
Recommended (persists across DSM upgrades, runs as root):

  Control Panel -> Task Scheduler -> Create -> Scheduled Task -> User-defined script
   General  : Task = "mihomo-auto-update"   User = root
   Schedule : $SCHED_DESC
              (DSM fires the task in the NAS Regional Options timezone; set
               Control Panel > Regional Options > Time accordingly. UPDATE_TZ=$UPDATE_TZ
               only labels the in-job log timestamps.)
   Task Settings -> Run command -> User-defined script:

     $CMD

   Enable "Send run details by email" + "only when the script terminates
   abnormally" - this is the DEFAULT notification path: every entry point
   exits non-zero on failure states (see the exit-code table in the README),
   so DSM emails you exactly when something needs attention. The optional
   webhook (NOTIFY_WEBHOOK_URL in .env) adds rich push on top; DSM 7's
   synodsmnotify is NOT reliable from plain scripts and is best-effort only.
   Task Scheduler Settings -> "Save output results" also works. The updater
   writes its own rotating log at UPDATE_LOG; do not add another >> redirection.

 Also recommended: a second task with the "Boot-up" trigger (User = root) running
   $BOOT_CMD
 so the macvlan network + /dev/net/tun self-heal after a reboot.

------------------------------------------------------------------------
Fallback (raw crontab - may be wiped by DSM updates; DSM cron has a user column):

  $UPDATE_SCHEDULE	root	$CMD

  Reload is DSM-build-specific (synosystemctl on DSM 7; synoservice on older
  builds). The installer probes both. If reload fails, use Task Scheduler.
  Note: BusyBox crond fires in the NAS SYSTEM timezone (it ignores a per-line TZ=).
========================================================================
EOF
