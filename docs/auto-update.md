# Auto-Update

[← README](../README.md) · [中文](zh/auto-update.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Configuration](configuration.md) · **Auto-Update** · [Operations](operations.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

---

`scripts/auto_update.sh` is the DSM-side half of the [update pipeline](architecture.md#update-pipeline-mirror--pull):
it pulls images from Alibaba ACR, detects which actually changed, and redeploys them safely. It
is designed to run unattended on a schedule and to **never leave the gateway broken**.

## ACR setup

The "push" side lives in the sibling repo **`docker-china-sync`**. In short:

1. Create an Alibaba **Container Registry (ACR)** instance + namespace (`myns`).
2. In `docker-china-sync`, set the four GitHub secrets (`ALIYUN_REGISTRY`, `ALIYUN_NAME_SPACE`,
   `ALIYUN_REGISTRY_USER`, `ALIYUN_REGISTRY_PASSWORD`) and list your images in `images.txt`
   (it already includes `mihomo`, `metacubexd`, `cloudflared`). It mirrors nightly (23:00 UTC).
3. ACR naming is `REGISTRY/NAMESPACE/<image:tag>` (no namespace prefix unless an image *name*
   collides). So `metacubex/mihomo:latest` → `registry.cn-….aliyuncs.com/myns/mihomo:latest`.

On the NAS, set in `.env`: `DOCKER_REGISTRY`, `DOCKER_USERNAME`, `ACR_PASSWORD`, and point
`MIHOMO_IMAGE` / `METACUBEXD_IMAGE` / `CF_IMAGE` at those ACR refs.

## Image refs

The deploy dispatch matches each `UPDATE_IMAGES` entry **exactly** against `MIHOMO_IMAGE`,
`METACUBEXD_IMAGE`, `CF_IMAGE`. Keep `UPDATE_IMAGES` inheriting those three vars:

```dotenv
UPDATE_IMAGES="${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}"
```

If an `UPDATE_IMAGES` entry doesn't match any of the three, it is **pulled but not deployed**
(cache-only) and the run logs a `WARN`. That's the signal you set `UPDATE_IMAGES` to a ref that
differs from the deploy vars. Keep them aligned with `docker-china-sync/images.txt`.

## The run sequence

Each invocation, in order (everything is logged to `UPDATE_LOG`):

1. **Lock** — an atomic, PID-aware `mkdir` lock. A second concurrent run exits cleanly with
   code `4` and *does not* touch the live run's lock (only the holder can release it).
2. **Kill-switch** — exits `0` if `UPDATE_ENABLED=false` (unless `--force`).
3. **Preflight** (abort, touching nothing, on any failure):
   - **compose flavor** — prefers `docker compose` (v2), falls back to `docker-compose` (v1);
   - **[architecture guard](#architecture-guard)** — image arch must equal `EXPECTED_ARCH`;
   - **network** — `tproxy_network` must exist and its macvlan parent still match the live
     interface;
   - **TUN** — `/dev/net/tun` must exist;
   - **ACR login** — non-interactive `--password-stdin`; on `401` it notifies and aborts (code `5`).
4. **Detect changes** — `docker pull` each image (with retries), then compare the **running
   container's** image ID against the freshly-pulled local image ID. Different (or container
   absent) ⇒ needs deploy. This is robust to `--dry-run` and idempotent: no change ⇒ no-op.
5. **Apply (compose services)** — a single `docker compose up -d` recreates only mihomo /
   metacubexd that changed (pull-then-swap; never stop-then-pull).
6. **Health-gate** — see below. On failure ⇒ **auto-rollback** to the last-good image, re-health,
   and a FAILURE notification.
7. **Apply (cloudflared)** — [blue-green](#cloudflared-blue-green), only after its own pull/verify.
8. **Prune** dangling layers (only on full success, so a rollback target is never removed mid-run).
9. **Notify** — Synology push (`synodsmnotify`) + log, on failure *and* success.

### Architecture guard

`docker-china-sync` mirrors `linux/amd64` by default. If your NAS is ARM, an amd64 `:latest`
is unrunnable. The updater inspects each pulled image's `Architecture` and **refuses to deploy**
(never tears down a running container against an unrunnable image) unless it equals
`EXPECTED_ARCH`. For an ARM NAS: either mirror arm64 images in `docker-china-sync/images.txt`
and set `EXPECTED_ARCH=arm64`, or keep an amd64 NAS.

### Health-gate & rollback (mihomo)

After recreating, "running" is not enough — mihomo could be up but routing nothing. The gate
(`HEALTH_RETRIES` × `HEALTH_INTERVAL`):

- confirms the container is `Running` and **not crash-looping** (stable `RestartCount` across
  the interval);
- probes the controller `GET /version` **inside the container** (`docker exec`), which
  sidesteps the [macvlan self-reach](troubleshooting.md#macvlan-self-reach) limitation. If the
  image has no `wget`/`curl`, this degrades to the stability check (logged, not failed);
- checks metacubexd is running (warn-only — the UI is non-critical).

If the gate fails, the updater **re-tags the last-good image** (captured before the swap) and
`docker compose up -d` again, re-runs the gate, and notifies FAILURE with the details. The new
image is kept (not pruned) so the rollback target exists.

> Deeper egress/DNS probing from the NAS is limited by macvlan self-reach; run those from
> another LAN device. See [Operations › Manual health checks](operations.md#manual-health-checks).

### cloudflared blue-green

cloudflared is **external** (not in this compose) and managed by container name:

1. **Clone** the running container's full run spec via `docker inspect` — all env (so a token
   via `TUNNEL_TOKEN` and settings like `TUNNEL_METRICS` are preserved), published ports, bind
   mounts, the primary network + static IP, extra networks, restart policy, and the original
   command. Only the **image** is bumped to `CF_IMAGE`. `CF_TUNNEL_TOKEN` (if set) overrides.
2. Start it as `<name>-candidate` **alongside** the old one. Cloudflare allows multiple
   connectors per tunnel, so the live tunnel never drops.
3. **Prove connected** before cutover — native healthcheck if present, else the "Registered
   tunnel connection" log marker, within `CF_HEALTH_TIMEOUT`. If it never connects, the
   candidate is removed and the old container is left **untouched** (no cutover).
4. **Cutover** — stop+remove old, then `docker rename` candidate → canonical (retried). If
   rename keeps failing, the candidate (the only live connector) is **kept** and the run tells
   you to `docker rename` it manually — the cleanup trap will not reap it.

First-time provisioning (no existing container) requires `CF_TUNNEL_TOKEN`; thereafter the
token is read from the running container and you don't need it in `.env`.

> **Prerequisite:** start your external cloudflared with `--metrics 127.0.0.1:<port>` so the
> connected-check is precise (it falls back to log scraping otherwise). Because the updater now
> replays the full run spec, that `--metrics` setting is preserved across updates.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success or clean no-op |
| `2` | partial failure (something failed; see the notification/log) |
| `3` | config / preflight error — nothing was changed |
| `4` | another run holds the lock |
| `5` | ACR login failed — nothing attempted |

DSM Task Scheduler can email on non-zero exit as a second safety net.

## Scheduling

See [Operations › Scheduling on DSM](operations.md#scheduling-on-dsm). `scripts/install_scheduler.sh`
prints the exact task command and a fallback crontab line derived from `UPDATE_SCHEDULE` /
`UPDATE_TZ`. Schedule it comfortably **after** the nightly mirror (23:00 UTC); idempotent digest
detection means exact timing isn't critical.
