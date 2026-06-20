# Operations Runbook

[← README](../README.md) · [中文](zh/operations.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · **Operations** · [Troubleshooting](troubleshooting.md) · [Development](development.md)

---

Day-2 operations. All commands run on the NAS over SSH, from the repo dir
`/volume1/docker/syno-mihomo-gateway`.

## Everyday commands

```bash
# status / logs
docker compose ps
docker logs mihomo --tail 100
docker logs mihomo-ui --tail 50

# restart just mihomo (e.g. after editing the template)
docker compose up -d mihomo          # re-renders config.yaml on start

# stop / start the whole stack
docker compose down
docker compose up -d
```

> Use `docker compose` (v2). On older setups the v1 binary `docker-compose` may exist instead;
> the auto-updater auto-detects either, but prefer v2 in manual commands.

## Update the subscription

```bash
vi config/subscription.txt
docker compose up -d mihomo          # re-renders + restarts mihomo
```

## Scheduling on DSM

On DSM 7, use **Control Panel → Task Scheduler** rather than editing `/etc/crontab`.
The supported UI persists the task, lets you run it manually, and can retain or email abnormal
output. Print the validated settings:

```bash
sh scripts/install_scheduler.sh
```

Create two tasks in **Control Panel → Task Scheduler** (User = **root**):

1. **Scheduled task → User-defined script** — the auto-updater, at your `UPDATE_SCHEDULE` time:
   ```
   cd '/volume1/docker/syno-mihomo-gateway' && exec /bin/sh '/volume1/docker/syno-mihomo-gateway/scripts/auto_update.sh'
   ```
   Use the exact command printed for your actual path. Select **root**, enable the task, and tick
   **Send run details only when the script terminates abnormally** or enable **Settings → Save
   output results**. Do not append `>> logs/auto-update.log`: the updater already owns and rotates
   that log, and a second redirection duplicates lines and breaks rotation.
2. **Triggered task → Boot-up** — recreate the macvlan + TUN after a reboot (closes the
   "network missing at update time" hole):
   ```
   cd '/volume1/docker/syno-mihomo-gateway' && exec /bin/sh '/volume1/docker/syno-mihomo-gateway/scripts/setup_network.sh'
   ```
   The boot helper waits for Container Manager/Docker before touching the macvlan.

DSM schedules against the timezone configured in **Control Panel → Regional Options**.
`UPDATE_TZ` changes updater log timestamps only. Schedule comfortably after the mirror window,
then select the task and click **Run** once. Confirm a zero result and inspect
`logs/auto-update.log` before relying on unattended runs.

## Running the updater by hand

```bash
sh scripts/auto_update.sh --dry-run   # pull + inspect + report, NO container swap
sh scripts/auto_update.sh             # real run
sh scripts/auto_update.sh --force     # ignore UPDATE_ENABLED=false kill-switch
```

Exit codes: `0` ok/no-op · `2` partial failure · `3` config/preflight · `4` locked · `5` ACR
login failed (see [Auto-Update › exit codes](auto-update.md#exit-codes)).

Before a release or after changing updater logic, run the same DSM/BusyBox regression suite used
by CI:

```bash
sh scripts/ci/dsm_installer_check.sh
sh scripts/ci/auto_update_check.sh
sh scripts/ci/cloudflared_check.sh
docker compose --env-file .env.example config --quiet
```

## Kill-switch

To pause all auto-updates without removing the task:

```dotenv
# .env
UPDATE_ENABLED=false
```

A scheduled run then exits `0` immediately. Re-enable by setting `true` (or run once with
`--force`).

## Logs

- Orchestrator log: `logs/auto-update.log` (path = `UPDATE_LOG`), self-rotated at `LOG_MAX_BYTES`
  keeping `LOG_KEEP` generations — no dependency on `logrotate`.
- Container logs: `docker logs mihomo` / `docker logs mihomo-ui` / `docker logs cloudflared`.

```bash
tail -f logs/auto-update.log
```

## Notifications

Results are pushed via Synology `synodsmnotify @administrators` (delivered to the DS finder /
mobile app via Synology's relay — it does **not** route through the mihomo gateway, so it still
arrives when the gateway is down). Set `NOTIFY_WEBHOOK_URL` for a Bark/Gotify/Slack fallback.
Notifications fire on **failure and rollback**, not just success; set `NOTIFY_ON_NOCHANGE=1` to
also get quiet "nothing changed" pings.

## Manual health checks

Because of [macvlan self-reach](troubleshooting.md#macvlan-self-reach), run these from **another
LAN device**, not the NAS:

```bash
# controller reachable?
curl -s http://MIHOMO_IP:9090/version          # add: -H "Authorization: Bearer <secret>" if set
# egress actually proxies?
curl -s -x http://MIHOMO_IP:7890 -m 10 -o /dev/null -w '%{http_code}\n' http://www.gstatic.com/generate_204   # expect 204
# DNS served by mihomo?
dig @MIHOMO_IP gstatic.com +short
```

From the NAS itself you can still inspect the controller from inside the container:

```bash
docker exec mihomo wget -qO- http://127.0.0.1:9090/version
```

## Manual rollback

The updater auto-rolls-back on a failed health-gate. To revert manually (e.g. a bad image you
pulled outside the updater): pin the previous image and recreate.

```bash
docker images registry.cn-….aliyuncs.com/myns/mihomo      # find the previous IMAGE ID
docker tag <OLD_IMAGE_ID> "$MIHOMO_IMAGE"                  # re-point the tag
docker compose up -d mihomo
```

If only `cloudflared-candidate` is running, treat it as the live recovery connector and do not
remove it. Inspect its logs, then recreate the canonical container from the original run settings
while the candidate keeps the tunnel available. As an emergency name-only recovery you can rename
the candidate, but its temporary dynamic IP and omitted host-port bindings will remain:

```bash
docker logs --tail 100 cloudflared-candidate
docker rename cloudflared-candidate cloudflared
```

## Disk hygiene

The updater prunes dangling layers after a successful run. To reclaim more manually:

```bash
docker image prune -f          # dangling only (safe)
```

Avoid `docker system prune -a` — it can remove the last-good images you'd want for a rollback.

## Changing routing rules

Edit the `rules:` list (and `proxy-providers`, ports, etc.) in
`config/config.template.yaml`, then `docker compose up -d mihomo` to re-render and restart.
See [Configuration](configuration.md#configconfigtemplateyaml).
