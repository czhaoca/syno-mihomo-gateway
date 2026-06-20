#!/bin/sh
# install_scheduler.sh - print the exact DSM Task Scheduler settings (and a fallback
# crontab line) for the auto-updater, derived from .env (UPDATE_SCHEDULE / UPDATE_TZ).
# This does NOT modify DSM: registering a root scheduled task is a one-time GUI step
# that survives DSM upgrades, whereas hand-edited /etc/crontab gets rewritten.

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SELF_DIR/lib/common.sh"

if [ -f "$ENV_FILE" ]; then
  dotenv_load "$ENV_FILE" || exit "$EXIT_CONFIG"
fi
: "${UPDATE_SCHEDULE:=0 2 * * *}"
: "${UPDATE_TZ:=Asia/Shanghai}"

# mkdir -p logs FIRST: the '>>' redirect is opened by the shell before
# auto_update.sh can create logs/, so a fresh install would otherwise fail.
CMD="cd $REPO_ROOT && mkdir -p logs && /bin/sh scripts/auto_update.sh >> logs/auto-update.log 2>&1"

# Parse the cron "minute hour" fields into a friendly daily time for the GUI.
MIN="$(echo "$UPDATE_SCHEDULE" | awk '{print $1}')"
HOUR="$(echo "$UPDATE_SCHEDULE" | awk '{print $2}')"
case "$MIN$HOUR" in
  ''|*[!0-9]*) SCHED_DESC="Custom schedule (cron: $UPDATE_SCHEDULE) - set the DSM trigger to match" ;;
  *)           SCHED_DESC="Daily, first run time $(printf '%02d:%02d' "$HOUR" "$MIN")" ;;
esac

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

 Also recommended: a second task with the "Boot-up" trigger (User = root) running
   cd $REPO_ROOT && /bin/sh scripts/setup_network.sh
 so the macvlan network + /dev/net/tun self-heal after a reboot.

------------------------------------------------------------------------
Fallback (raw crontab - may be wiped by DSM updates; DSM cron has a user column):

  $MIN $HOUR $(echo "$UPDATE_SCHEDULE" | awk '{print $3, $4, $5}')	root	$CMD

  Then reload: synoservice --restart crond   (older DSM: synoservice -restart crond)
  Note: BusyBox crond fires in the NAS SYSTEM timezone (it ignores a per-line TZ=).
========================================================================
EOF
