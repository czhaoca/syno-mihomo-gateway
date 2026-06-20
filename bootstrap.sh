#!/bin/sh
# bootstrap.sh - one-time post-unpack setup for an offline (release-zip) install.
#
# Run from the extracted folder on the NAS, after unpacking the release zip:
#   sh bootstrap.sh
#
# It is idempotent, writes NO secrets, and runs NOTHING privileged or networked.
# It only:
#   1. seeds persistent .env and subscription.txt from examples (if absent),
#   2. restores the executable bit the .zip extraction drops from scripts,
#   3. prints the next steps (which YOU run).
#
# POSIX /bin/sh, ASCII only. For the full guided setup, run: sh ./install.sh

DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
cd "$DIR" || { echo "FATAL: cannot cd to $DIR" >&2; exit 1; }
REPO_ROOT="$DIR"
# shellcheck source=scripts/lib/common.sh
. "$DIR/scripts/lib/common.sh"
ensure_persistent_state || {
  echo "FATAL: cannot create persistent data directory: $GATEWAY_DATA_DIR" >&2
  exit 1
}

# 1. Seed config from examples only if absent (never clobber a configured deploy).
if [ -f "$ENV_FILE" ]; then
  echo "ok    $ENV_FILE already exists - left untouched"
elif [ -f .env.example ]; then
  cp .env.example "$ENV_FILE" && chmod 600 "$ENV_FILE" \
    && echo "new   $ENV_FILE created from .env.example (chmod 600)"
else
  echo "WARN  .env.example missing - cannot seed .env" >&2
fi

if [ -f "$SUBSCRIPTION_FILE" ]; then
  echo "ok    $SUBSCRIPTION_FILE already exists - left untouched"
elif [ -f config/subscription.txt.example ]; then
  cp config/subscription.txt.example "$SUBSCRIPTION_FILE" \
    && chmod 600 "$SUBSCRIPTION_FILE" \
    && echo "new   $SUBSCRIPTION_FILE created from example"
else
  echo "WARN  config/subscription.txt.example missing - cannot seed subscription" >&2
fi

# 2. Restore exec bits the .zip extraction drops (tar.gz keeps most; safe either way).
if [ -d scripts ]; then
  chmod +x scripts/*.sh scripts/lib/*.sh 2>/dev/null
  echo "ok    restored +x on scripts/*.sh and scripts/lib/*.sh"
fi

# 3. Next steps - YOU run these (network, privileged, and the image mirror are your call).
cat <<'EOF'

Setup is guided. Run the interactive installer (recommended):

    sudo sh ./install.sh

It walks you through configuration, the network, the image source, and start-up.

Prefer to configure by hand? The manual steps are:
  1. Edit ../syno-mihomo-gateway-data/.env
  2. Edit ../syno-mihomo-gateway-data/config/subscription.txt
  3. sudo ./scripts/setup_network.sh
  4. sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d
  5. (optional) sh scripts/install_scheduler.sh   # auto-update schedule

See the START-HERE and INSTALL guides in docs/ for details.
EOF
