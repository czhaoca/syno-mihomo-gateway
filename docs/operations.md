# Operations Runbook

[← README](../README.md) · [中文](zh/operations.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · **Operations** · [CLI](cli.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

---

Day-2 operations. All commands run on the NAS over SSH, from the repo dir
`/volume1/docker/syno-mihomo-gateway`. Runtime state (the live `.env`, rendered config,
logs, updater state) lives in the sibling data dir `../syno-mihomo-gateway-data`.

## CLI at a glance

`scripts/gateway.sh` is the supported day-2 command surface (full reference: [CLI](cli.md)):

```bash
sudo sh scripts/gateway.sh status --json        # read-only deployment state (incl. last updater run)
sudo sh scripts/gateway.sh doctor --json        # read-only diagnostics (wraps scripts/doctor.sh)
sudo sh scripts/gateway.sh update --dry-run     # updater dry-run; `update --yes` for a real run
sudo sh scripts/gateway.sh cron --time 04:30 --yes   # persist the auto-update schedule
sudo sh scripts/gateway.sh redeploy --yes       # re-render + force-recreate from the saved .env
```

Mutating verbs (`deploy`, `redeploy`, `modify`, `update`, `cron --apply-crontab`) require root
(exit `6` otherwise) and an explicit `--yes` (exit `7` otherwise); `status`/`doctor` need neither.
Secrets are never accepted on argv — set them in `.env`.

## Everyday commands

```bash
# status / logs
docker compose --env-file ../syno-mihomo-gateway-data/.env ps
docker logs mihomo --tail 100
docker logs mihomo-ui --tail 50

# re-render + restart mihomo (e.g. after editing the template)
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo

# stop / start the whole stack
docker compose --env-file ../syno-mihomo-gateway-data/.env down
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d
```

> Always pass `--env-file`: the live `.env` is `../syno-mihomo-gateway-data/.env`, and the
> compose file fail-closes (`set MIHOMO_IMAGE in .env`) without it. And `--force-recreate`
> matters: the config render runs in the container entrypoint, which only re-runs when the
> container is recreated — with an unchanged image, plain `up -d mihomo` is a no-op and a
> template/subscription edit is silently NOT applied. `sudo sh scripts/gateway.sh redeploy --yes`
> does the same thing with validation and a health gate.

> Use `docker compose` (v2). On older setups the v1 binary `docker-compose` may exist instead;
> the auto-updater auto-detects either, but prefer v2 in manual commands.

## Container Manager: look, don't touch

The containers are visible in DSM's Container Manager (*Container* tab) - viewing state and logs
there is fine. Never use the *Project* tab's **Build/Update** on this stack: it re-pulls and
recreates containers with no digest gate, no health gate, and no rollback. All updates go through
`scripts/auto_update.sh` (scheduled) or the installer/CLI.

## Update the subscription

```bash
sudo sh scripts/gateway.sh modify --subscription 'https://provider.example/path' --yes
```

Or by hand (the re-render needs `--force-recreate`, see above):

```bash
vi ../syno-mihomo-gateway-data/config/subscription.txt
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo
```

## Acceptance after updater changes

Any change to the auto-update machinery must pass the
[acceptance runbook](auto-update.md#acceptance-runbook-required-before-relying-on-updater-changes)
on the NAS (dry-run smoke → `state_diff.sh` canary → gateway-pair checks). This is the
**required** manual gate: real-container behavior is deliberately not exercised in CI.

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
   output results**. Do not append a `>> …` log redirection of your own: the updater already owns
   and rotates its log under `../syno-mihomo-gateway-data/logs/`, and a second redirection
   duplicates lines and breaks rotation.
2. **Triggered task → Boot-up** — recreate the macvlan + TUN after a reboot (closes the
   "network missing at update time" hole):
   ```
   cd '/volume1/docker/syno-mihomo-gateway' && exec /bin/sh '/volume1/docker/syno-mihomo-gateway/scripts/setup_network.sh'
   ```
   The boot helper waits for Container Manager/Docker before touching the macvlan.

The schedule itself is persisted in `.env` — set it with
`sudo sh scripts/gateway.sh cron --time HH:MM --yes` (`--time` requires the colon) or
`cron --schedule 'EXPR' --yes`. As a headless alternative to Task Scheduler,
`cron --apply-crontab --yes` writes (and on later runs rewrites) its own `/etc/crontab`
entry — the DSM UI remains the recommended surface.

DSM schedules against the timezone configured in **Control Panel → Regional Options**.
`UPDATE_TZ` (or `cron --tz`) changes updater log timestamps only. Schedule comfortably after
the mirror window, then select the task and click **Run** once. Confirm a zero result and
inspect `../syno-mihomo-gateway-data/logs/auto-update.log` before relying on unattended runs.

## Running the updater by hand

```bash
sudo sh scripts/auto_update.sh --dry-run   # pull + inspect + report, NO container swap
sudo sh scripts/auto_update.sh             # real run
sudo sh scripts/auto_update.sh --force     # ignore UPDATE_ENABLED=false kill-switch
```

CLI equivalents: `sudo sh scripts/gateway.sh update --dry-run` / `update --yes` /
`update --force --yes`.

Exit codes: `0` ok/no-op · `2` partial failure · `3` config/preflight · `4` locked · `5` ACR
login failed (see [Auto-Update › exit codes](auto-update.md#exit-codes)). Ctrl-C/TERM
terminate cleanly (`130`/`143`).

Exit `4` means another run holds the lock (`/tmp/syno-mihomo-update.lock`). A lock left by a
crashed run self-heals: the next run probes the recorded pid and reclaims a stale lock (a
pid-less lock gets a 2-second grace first). Never remove the lock dir of a live run by hand.

Before a release or after changing updater logic, run the same DSM/BusyBox regression suite used
by CI:

```bash
sh scripts/ci/dsm_installer_check.sh
sh scripts/ci/lifecycle_check.sh
sh scripts/ci/auto_update_check.sh
sh scripts/ci/cloudflared_check.sh
sh scripts/ci/generic_update_check.sh
sh scripts/ci/gateway_cli_check.sh
sh scripts/ci/migrate_legacy_check.sh
docker compose --env-file .env.example config --quiet
```

CI additionally runs the Python gates — `scripts/ci/render_check.py`,
`cli_contract_check.py`, `compose_policy_check.py`, `package_check.py`,
`privacy_check.py` — plus shellcheck (see `.woodpecker.yml`).

## Kill-switch

To pause all auto-updates without removing the task:

```bash
sudo sh scripts/gateway.sh cron --disable --yes   # sets UPDATE_ENABLED=false in the live .env
```

Or edit `../syno-mihomo-gateway-data/.env` directly (a repo-root `.env` is only a one-time
legacy migration source and is ignored afterwards):

```dotenv
# ../syno-mihomo-gateway-data/.env
UPDATE_ENABLED=false
```

A scheduled run then exits `0` immediately. Re-enable with `cron --enable --yes` or by setting
`true` (or run once with `--force`). The value is strict: only the exact strings `true`/`false`
are accepted — a typo like `False` aborts the run with exit `3` and a notification instead of
silently disabling.

## Logs

- Tool logs: `../syno-mihomo-gateway-data/logs/` — the installer writes `install.log`, the
  updater `auto-update.log`, and every `gateway.sh` verb `gateway.log` (with `verb=`/`run=`
  audit fields). When `gateway.sh` is the first tool to run, it links the other two names to
  `gateway.log` so all three share one file. Self-rotated at `LOG_MAX_BYTES` keeping
  `LOG_KEEP` generations — no dependency on `logrotate`. (A relative `UPDATE_LOG` is resolved
  under the data dir, not the repo.)
- Container logs: `docker logs mihomo` / `docker logs mihomo-ui` / `docker logs cloudflared`.

```bash
tail -f ../syno-mihomo-gateway-data/logs/gateway.log
```

## Updater state files

Under `../syno-mihomo-gateway-data/state/`:

- `last-run.json` — outcome of the most recent updater run, written atomically on every terminal
  path (except when a run is refused by the lock). Fields: `ts`, `exit_code`, `dry_run`,
  `updated`, `unchanged`, `failed`, `rolled_back`, plus `updated_names` / `failed_names` /
  `rolled_back_names`. Read it with `sudo sh scripts/gateway.sh update --last` (it is also
  embedded in `status --json`).
- `last-good/<name>` — per generic target, the proven-good `image_id` + `spec_digest`, written
  only after the health gate passes; survives `docker image prune`, so a manual recovery can
  re-tag that image id.
- `update-targets` — the generic-target enrollment list (one `name|strategy|probe` record per
  line); manage it with `sudo sh scripts/gateway.sh update --list-targets` / `--enable NAME` /
  `--disable NAME`. See [Auto-Update › Generic targets](auto-update.md#generic-targets-any-enrolled-container).

## Notifications

**Default path — DSM Task Scheduler email.** Every entry point exits non-zero on failure
states, so enable *"send run details by email (only when the script terminates abnormally)"* on
the scheduled task — DSM then emails you exactly when something needs attention. This is the
documented default because it needs nothing besides DSM's own notification settings.

**Opt-in rich channel — webhook.** Set `NOTIFY_WEBHOOK_URL` in `.env` (Bark/Gotify/
Slack-compatible JSON POST). It fires on failure **and** on success with changes; set
`NOTIFY_ON_NOCHANGE=1` to also get quiet "nothing changed" pings. The URL (which often embeds a
token) is passed to curl via a stdin config, never argv.

**Best-effort only — DSM push.** `synodsmnotify` requires package-registered message strings on
DSM 7, so from a plain script it can exit 0 without delivering anything. It is still attempted
(it works on DSM 6 and does not route through the gateway), but it is never relied on and never
suppresses the webhook.

## Manual health checks

Start with the purpose-built read-only diagnostic — it probes from inside the container's
network namespace via `docker exec`, so it is immune to the macvlan self-reach caveat:

```bash
sudo sh scripts/doctor.sh                  # exit 0 healthy · 2 degraded · 3 broken
sudo sh scripts/doctor.sh --egress         # also probe real egress through the proxy
sudo sh scripts/gateway.sh doctor --json   # same checks (compose, tun_gateway, controller,
                                           # image_arch, dashboard, update_task, boot_task,
                                           # subscription, …) as one JSON object
```

The `update_task` / `boot_task` checks verify the DSM Task Scheduler deployment (a scheduled
task running `auto_update.sh`, and a Boot-up task running `setup_network.sh` — what keeps TUN
alive across reboots); `unknown` means the box has no searchable scheduler.

Three further checks cover the host side. `host_dns` probes every resolver in the NAS's
`/etc/resolv.conf` and warns on dead ones — the failure where the NAS cannot reach its own
services because host DNS is dead. `geodata` reports whether the geo databases are already
cached in the config directory — missing means the first start must fetch them across a
possibly filtered network. `cloudflared` reports the tunnel container ok/down, and is only
shown when that container exists.

To verify from the LAN side, run the raw probes below from **another LAN device**, not the NAS
(because of [macvlan self-reach](troubleshooting.md#macvlan-self-reach)):

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
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo
```

For an enrolled generic target, the proven-good image id is recorded in
`../syno-mihomo-gateway-data/state/last-good/<name>` — re-tag it the same way, then re-run the
updater (see [Auto-Update › Generic targets](auto-update.md#generic-targets-any-enrolled-container)).

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
`config/config.template.yaml`, then re-render and restart with
`docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo`
(or `sudo sh scripts/gateway.sh redeploy --yes`).
See [Configuration](configuration.md#configconfigtemplateyaml).
