#!/bin/sh
# bootstrap.sh - one-time post-unpack setup for an offline (release-zip) install.
#
# Run from the extracted folder on the NAS, after unpacking the release zip:
#   sh bootstrap.sh
#
# It is idempotent, writes NO secrets, and runs NOTHING privileged or networked.
# It only:
#   1. seeds .env and config/subscription.txt from the shipped examples (if absent),
#   2. restores the executable bit the .zip extraction drops from scripts,
#   3. prints the next steps (which YOU run).
#
# POSIX /bin/sh, ASCII only. See docs/release-packaging.md.

DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
cd "$DIR" || { echo "FATAL: cannot cd to $DIR" >&2; exit 1; }

# 1. Seed config from examples only if absent (never clobber a configured deploy).
if [ -f .env ]; then
  echo "ok    .env already exists - left untouched"
elif [ -f .env.example ]; then
  cp .env.example .env && chmod 600 .env && echo "new   .env created from .env.example (chmod 600)"
else
  echo "WARN  .env.example missing - cannot seed .env" >&2
fi

if [ -f config/subscription.txt ]; then
  echo "ok    config/subscription.txt already exists - left untouched"
elif [ -f config/subscription.txt.example ]; then
  cp config/subscription.txt.example config/subscription.txt \
    && echo "new   config/subscription.txt created from example"
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

Next steps:
  1. Edit .env                      ROUTER_IP, MIHOMO_IP, DNS; (China) ACR creds + image refs
  2. Edit config/subscription.txt   your real subscription URL
  3. Images: make sure they are mirrored to your Alibaba ACR via docker-china-sync,
     and that MIHOMO_IMAGE / METACUBEXD_IMAGE in .env point at that ACR.
     (No GitHub/registry access is needed on the NAS once images are in your ACR.)
  4. sudo ./scripts/setup_network.sh
  5. sudo docker compose up -d
  6. (optional) sh scripts/install_scheduler.sh   # DSM auto-update task

Full guide: docs/release-packaging.md
EOF
