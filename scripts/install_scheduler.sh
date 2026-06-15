#!/bin/sh
# install_scheduler.sh - print the exact DSM Task Scheduler settings (and a fallback
# crontab line) for the auto-updater, derived from .env (UPDATE_SCHEDULE / UPDATE_TZ).
# This does NOT modify DSM: registering a root scheduled task is a one-time GUI step
# that survives DSM upgrades, whereas hand-edited /etc/crontab gets rewritten.

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SELF_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
: "${UPDATE_SCHEDULE:=0 9 * * *}"
: "${UPDATE_TZ:=Asia/Shanghai}"

CMD="cd $REPO_ROOT && /bin/sh scripts/auto_update.sh >> logs/auto-update.log 2>&1"

# Parse the cron "minute hour" fields into a friendly daily time for the GUI.
MIN="$(echo "$UPDATE_SCHEDULE" | awk '{print $1}')"
HOUR="$(echo "$UPDATE_SCHEDULE" | awk '{print $2}')"

cat <<EOF
========================================================================
 Synology DSM Task Scheduler - auto-update setup
========================================================================
Recommended (persists across DSM upgrades, runs as root):

  Control Panel -> Task Scheduler -> Create -> Scheduled Task -> User-defined script
   General  : Task = "mihomo-auto-update"   User = root
   Schedule : Daily, first run time ${HOUR:-9}:${MIN:-00}  (timezone: $UPDATE_TZ
              -> set Control Panel > Regional Options > Time to $UPDATE_TZ,
                 or rely on UPDATE_TZ which the script exports as TZ)
   Task Settings -> Run command -> User-defined script:

     $CMD

 Also recommended: a second task with the "Boot-up" trigger (User = root) running
   cd $REPO_ROOT && /bin/sh scripts/setup_network.sh
 so the macvlan network + /dev/net/tun self-heal after a reboot.

------------------------------------------------------------------------
Fallback (raw crontab - may be wiped by DSM updates; DSM cron has a user column):

  $MIN $HOUR $(echo "$UPDATE_SCHEDULE" | awk '{print $3, $4, $5}')	root	TZ=$UPDATE_TZ $CMD

  Then reload: synoservice --restart crond   (older DSM: synoservice -restart crond)
========================================================================
EOF
