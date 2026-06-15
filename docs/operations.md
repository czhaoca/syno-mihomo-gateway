# Operations Runbook

[← README](../README.md) · [中文](zh/operations.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · **Operations** · [Troubleshooting](troubleshooting.md) · [Development](development.md)

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

DSM rewrites `/etc/crontab` on package updates, so use **Task Scheduler** (survives upgrades,
runs as root). Print the exact settings:

```bash
sh scripts/install_scheduler.sh
```

Create two tasks in **Control Panel → Task Scheduler** (User = **root**):

1. **Scheduled task → User-defined script** — the auto-updater, at your `UPDATE_SCHEDULE` time:
   ```
   cd /volume1/docker/syno-mihomo-gateway && /bin/sh scripts/auto_update.sh >> logs/auto-update.log 2>&1
   ```
   The script exports `TZ=$UPDATE_TZ`, so the `.env` timezone is authoritative. Optionally tick
   "send run details by email" to get notified on non-zero exit.
2. **Triggered task → Boot-up** — recreate the macvlan + TUN after a reboot (closes the
   "network missing at update time" hole):
   ```
   cd /volume1/docker/syno-mihomo-gateway && /bin/sh scripts/setup_network.sh
   ```

Schedule the updater comfortably after the nightly mirror (23:00 UTC) — e.g. `0 9 * * *`
Asia/Shanghai. It's idempotent, so exact timing doesn't matter.

## Running the updater by hand

```bash
sh scripts/auto_update.sh --dry-run   # pull + detect + report, NO swap
sh scripts/auto_update.sh             # real run
sh scripts/auto_update.sh --force     # ignore UPDATE_ENABLED=false kill-switch
```

Exit codes: `0` ok/no-op · `2` partial failure · `3` config/preflight · `4` locked · `5` ACR
login failed (see [Auto-Update › exit codes](auto-update.md#exit-codes)).

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

For cloudflared, if a cutover left a `cloudflared-candidate` running (rename failure), promote it:

```bash
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
