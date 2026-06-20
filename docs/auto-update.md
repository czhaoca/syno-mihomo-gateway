# Auto-Update

[← README](../README.md) · [中文](zh/auto-update.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · **Auto-Update** · [Operations](operations.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

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

`MIHOMO_IMAGE` / `METACUBEXD_IMAGE` / `CF_IMAGE` are **derived** by `install.sh` from
`REGISTRY_MODE` (`acr` default, or `docker` for upstream public images) + `DOCKER_REGISTRY` +
`ACR_NAMESPACE` + the `*_TAG` values — see [Configuration › Container images](configuration.md).
Whichever mode is active, the three resolved refs are written to `.env`, and the deploy dispatch
matches each `UPDATE_IMAGES` entry **exactly** against them. Keep `UPDATE_IMAGES` inheriting those
three vars:

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
2. **Kill-switch validation** — a typo such as `UPDATE_ENABLED=False` fails loudly.
3. **Kill-switch** — exits `0` if `UPDATE_ENABLED=false` (unless `--force`), without requiring
   otherwise complete deployment settings.
4. **Configuration validation** — rejects malformed numbers, wildcard or unsafe image references,
   either missing Compose service, and a configured `CF_IMAGE` missing from `UPDATE_IMAGES`.
5. **Preflight** (abort, touching nothing, on any failure):
   - **Docker readiness** — waits up to `DOCKER_READY_TIMEOUT` for Container Manager, the daemon,
     and Compose; this handles DSM boot-task races;
   - **Compose model** — validates `docker-compose.yml` plus `.env` before any registry pull;
   - **[architecture guard](#architecture-guard)** — image arch must equal `EXPECTED_ARCH`;
   - **network** — `tproxy_network` must exist and its macvlan parent still match the live
     interface;
   - **TUN** — `/dev/net/tun` must exist;
   - **ACR login** — non-interactive `--password-stdin`; on `401` it notifies and aborts (code `5`).
6. **Detect changes** — `docker pull` each image (with retries), require the pulled reference to
   be locally inspectable, then compare the **running container's** content-addressed image ID
   against the freshly pulled local ID. Different (or absent) means deploy.
7. **Apply (Compose services)** — Compose v2 runs
   `docker compose up -d --pull never`: the exact local images just pulled and checked are used,
   with no second registry race. Legacy Compose v1 falls back to its cached-image behavior and
   emits a warning.
8. **Health-gate and rollback** — see below. A failed Compose apply *or* failed health gate verifies
   the old image IDs still exist, re-tags them, recreates with implicit pulls disabled, re-runs
   health, and sends a failure notification.
9. **Apply (cloudflared)** — [blue-green](#cloudflared-blue-green), only after its own pull/verify.
10. **Prune** dangling layers (only on full success, so rollback targets remain available).
11. **Notify** — Synology push (`synodsmnotify`) + log, on failure *and* success.

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
- probes the controller `GET /version` **inside the container** (`docker exec`), including the
  bearer token when configured. A missing probe tool or failed response fails the gate;
- verifies the in-container `mihomo-tun` interface and IPv4 forwarding, so a responsive
  controller cannot hide a broken transparent-proxy dataplane;
- when `TUN_AUTO_REDIRECT=true`, first proves the target image can create an iptables NAT chain
  against the DSM kernel in a disposable network namespace; incompatibility skips Compose apply;
- checks metacubexd is running (warn-only — the UI is non-critical).

If the gate fails, the updater verifies and **re-tags the last-good image** (captured before the
swap), recreates with implicit pulls disabled, re-runs the gate, and notifies FAILURE with the
details. The failed image is not pruned during that run.

> Deeper egress/DNS probing from the NAS is limited by macvlan self-reach; run those from
> another LAN device. See [Operations › Manual health checks](operations.md#manual-health-checks).

### cloudflared blue-green

cloudflared is **external** (not in this compose) and managed by container name:

1. **Capture** the old image ID and replayable run specification in a private temporary directory:
   environment/token, exact command arguments, entrypoint, restart policy, user/workdir,
   mounts, ports, networks/static IPs, DNS, capabilities, devices, security options, and tmpfs.
   Unsupported container-network or auto-remove modes fail before touching the old connector.
2. Start `<name>-candidate` beside the old connector, deliberately omitting published host ports
   and static IPs so it cannot collide with the live container. Extra networks use temporary
   dynamic addresses.
3. **Prove the candidate connected** using native health status or the registration log marker.
   Failure removes only the candidate; the canonical connector remains untouched.
4. Stop/remove the old container, recreate the canonical name from `CF_IMAGE` with the complete
   saved port/network specification, and verify it while the candidate keeps the tunnel live.
5. On success remove the candidate. On failure recreate and verify the canonical container from
   the saved old image ID/specification. If neither canonical version can be restored, keep the
   connected candidate and report manual recovery instead of reaping the only connector.

First-time provisioning (no existing container) requires `CF_TUNNEL_TOKEN`; thereafter the
token is read from the running container and you don't need it in `.env`.

Published metrics ports are omitted only from the temporary candidate and restored on the
canonical replacement. Connectivity checking falls back to cloudflared's registration log when
the image has no native healthcheck.

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
validates `UPDATE_SCHEDULE` and prints a shell-quoted command with an absolute working directory,
an explicit `/bin/sh`, and no duplicate log redirection. DSM Task Scheduler fires in the NAS
system timezone; `UPDATE_TZ` controls timestamps inside the updater only.

After creating the task, use **Run** once and verify `logs/auto-update.log`. A dry run pulls and
inspects images but never swaps a container:

```sh
sudo sh scripts/auto_update.sh --dry-run
```

## Upstream behavior references

- [Synology DSM 7 Task Scheduler](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/system_taskscheduler?version=7)
- [Synology Task Scheduler scripting tips](https://kb.synology.com/en-global/DSM/tutorial/common_mistake_in_task_scheduler_script)
- [Docker image pull](https://docs.docker.com/reference/cli/docker/image/pull/)
- [Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/)
