# Auto-Update

[← README](../README.md) · [中文](zh/auto-update.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · **Auto-Update** · [Operations](operations.md) · [CLI](cli.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

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
`MIHOMO_IMAGE` / `METACUBEXD_IMAGE` / `CF_IMAGE` at those ACR refs. Least privilege: create
a dedicated **pull-only** ACR sub/RAM account for the NAS, distinct from the push account
`docker-china-sync` uses — the updater only ever pulls.

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

## Why not Container Manager's own update button?

Container Manager's *Project* tab offers a Build/Update flow — do **not** use it on this stack.
It re-pulls `:latest` and recreates containers with no digest comparison, no health gate, and no
rollback; a bad upstream image would take the gateway (and the whole LAN's egress) down with no
automatic recovery. The scheduled `auto_update.sh` below exists precisely to add those gates.

## The run sequence

Each invocation, in order (everything is logged to `UPDATE_LOG` — a relative path resolves under
the persistent data directory, so the default lands at
`../syno-mihomo-gateway-data/logs/auto-update.log`; defaults for every tunable named below,
`DOCKER_READY_TIMEOUT`, `HEALTH_RETRIES`, `NOTIFY_WEBHOOK_URL`, …, live in
[Configuration](configuration.md#auto-update-orchestrator) and its
[Advanced tunables](configuration.md#advanced-tunables-optional-env-overrides) table):

1. **Lock** — an atomic, PID-aware `mkdir` lock. A second concurrent run exits cleanly with
   code `4` and *does not* touch the live run's lock (only the holder can release it). The lock
   self-heals: a stale lock whose recorded PID is dead is reclaimed automatically, and a PID-less
   lock gets a 2-second grace (the holder may still be writing its PID) before being treated as
   crashed. Ctrl-C / TERM terminate the run cleanly (exit `130`/`143`), still releasing the lock.
2. **Kill-switch validation** — a typo such as `UPDATE_ENABLED=False` fails loudly.
3. **Kill-switch** — exits `0` if `UPDATE_ENABLED=false` (unless `--force`), without requiring
   otherwise complete deployment settings.
4. **Configuration validation** — rejects malformed numbers, wildcard or unsafe image references,
   either missing Compose service, and a configured `CF_IMAGE` missing from `UPDATE_IMAGES`.
5. **Preflight** (abort, touching nothing, on any failure):
   - **Docker readiness** — waits up to `DOCKER_READY_TIMEOUT` for Container Manager, the daemon,
     and Compose; this handles DSM boot-task races;
   - **[architecture guard](#architecture-guard)** — the NAS (host) arch must equal `EXPECTED_ARCH`;
   - **TUN** — `/dev/net/tun` must exist;
   - **network** — `tproxy_network` must exist and its macvlan parent still match the live
     interface;
   - **Compose model** — validates `docker-compose.yml` plus `.env` before any registry pull;
   - **ACR login** — non-interactive `--password-stdin`; on `401` it notifies and aborts (code `5`).
6. **Detect changes** — for the gateway trio *and* every eligible enrolled
   [generic target](#generic-targets-any-enrolled-container): `docker pull` each image (with
   retries), require the pulled reference to be locally inspectable, check the pulled image's
   arch against the host, then compare the **running container's** content-addressed image ID
   against the freshly pulled local ID. Different (or absent) means deploy. A pull failure whose
   error clearly signals a missing manifest carries the hint that the image is probably not
   mirrored in ACR yet.
7. **Short-circuits** — a clean no-op exits `0` here, *silently* unless `NOTIFY_ON_NOCHANGE=1`
   (set it for a nightly heartbeat). `--dry-run` reports the would-apply set and stops here too,
   only *noting* that the TUN probe below would gate the compose apply — a dry run never runs a
   privileged container.
8. **TUN auto-redirect probe** — real runs only, when the compose pair changed and
   `TUN_AUTO_REDIRECT=true`: proves the target image can create an iptables NAT chain against the
   DSM kernel in a disposable network namespace. Incompatibility skips the Compose apply
   (reported as failed) while generic targets and cloudflared stay eligible.
9. **Apply** — strictly serial, lowest blast radius first (DEC-5), so every earlier step still
   rides a known-good gateway:
   1. **Generic targets** — in-place recreate + tiered health gate + auto-restore, see
      [below](#generic-targets-any-enrolled-container);
   2. **cloudflared** — [blue-green](#cloudflared-blue-green) by name;
   3. **Compose services LAST** — Compose v2 runs `docker compose up -d --pull never`: the exact
      local images just pulled and checked are used, with no second registry race. Legacy
      Compose v1 falls back to its cached-image behavior and emits a warning. A failed Compose
      apply *or* failed [health gate](#health-gate--rollback-mihomo) verifies the old image IDs
      still exist, re-tags them, recreates with implicit pulls disabled, re-runs health, and
      sends a failure notification.
10. **Prune** dangling layers (only on full success, so rollback targets remain available).
11. **Notify** — the summary opens with counts (`updated:N unchanged:N failed:N
    rolled_back:N`) followed by per-target bullets; sent via webhook (when `NOTIFY_WEBHOOK_URL` is set) + best-effort Synology push + log,
    on failure *and* success (no-change runs are silent — see step 7). The reliable default alert path is DSM Task Scheduler's
    *send-run-details email*, driven by the exit codes below — `synodsmnotify` is unreliable on
    DSM 7 (needs package-registered strings) and never gates the webhook.
12. **Record** — every terminal path (via the `EXIT` trap) atomically writes
    `state/last-run.json`:

    ```json
    {"ts":"…","exit_code":2,"dry_run":0,"updated":1,"unchanged":3,"failed":1,
     "rolled_back":0,"updated_names":"…","failed_names":"…","rolled_back_names":"…"}
    ```

    Counters default to `0` on early-abort paths; a lock-denied run (exit `4`) never clobbers
    the live run's record. It is surfaced verbatim as `last_update` in
    `gateway.sh status --json` and by `gateway.sh update --last`.

### Architecture guard

`docker-china-sync` mirrors `linux/amd64` by default. If your NAS is ARM, an amd64 `:latest`
is unrunnable. The guard has two layers: preflight verifies the **NAS itself** matches
`EXPECTED_ARCH` (catching a stale `.env` after a hardware move), then during change detection
the updater inspects each pulled image's `Architecture` and **refuses to deploy** any image
that does not match the host (never tears down a running container against an unrunnable
image). For an ARM NAS: either mirror arm64 images in `docker-china-sync/images.txt` and set
`EXPECTED_ARCH=arm64`, or keep an amd64 NAS.

### Health-gate & rollback (mihomo)

After recreating, "running" is not enough — mihomo could be up but routing nothing. The gate
(`HEALTH_RETRIES` × `HEALTH_INTERVAL`):

- confirms the container is `Running` and **not crash-looping**: `RestartCount` must be stable
  across the interval *and* must not have grown by `HEALTH_MAX_RESTARTS` (default `3`) or more
  since the gate started — momentary stability cannot whitewash a restart loop;
- probes the controller `GET /version` **inside the container** (`docker exec`), including the
  bearer token when configured. A missing probe tool or failed response fails the gate;
- when `TUN_ENABLE=true` (the default — this *is* a gateway), verifies the in-container
  `mihomo-tun` interface and IPv4 forwarding, so a responsive controller cannot hide a broken
  transparent-proxy dataplane. With `TUN_ENABLE=false` (plain-proxy mode) there is no TUN
  dataplane and this probe is a no-op;
- checks metacubexd is running (warn-only — the UI is non-critical).

The [TUN auto-redirect probe](#the-run-sequence) is separate: it runs *before* the Compose
apply (real runs only), never as part of this gate.

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
canonical replacement (a pinned MAC address is likewise never replayed on a candidate — two
containers sharing one L2 address flap ARP). Connectivity checking falls back to cloudflared's
registration log when the image has no native healthcheck.

The run summary distinguishes the three failure shapes: a candidate that never connects leaves
the old connector **untouched** (candidate discarded); a failed cutover restored from the saved
image counts as **rolled_back**; and when neither canonical version can be restored the run
reports **MANUAL ATTENTION** — the `-candidate` container may then be the only live connector,
so do not remove it.

## Generic targets (any enrolled container)

Beyond the gateway trio, the updater refreshes **any running container you enroll** whose
image already lives on your ACR (`DOCKER_REGISTRY/ACR_NAMESPACE/...`). There is deliberately
**no upstream→ACR name translation**: if a container runs a Docker Hub ref, mirror the image
first (add it to `docker-china-sync/images.txt`), redeploy the container from the ACR ref,
then enroll it.

**Enroll / manage** (both edit the same managed list at
`<data-dir>/state/update-targets`, never `.env`):

```sh
sudo sh scripts/gateway.sh update --enable <container> --yes
sh scripts/gateway.sh update --list-targets     # read-only, shows live eligibility
sh scripts/gateway.sh update --last             # read-only, last run's outcome
sudo sh scripts/gateway.sh update --disable <container> --yes
```

or interactively via the installer's update flow (it scans running ACR-ref containers and
toggles each). Concurrent enroll/remove calls serialize through a short lock on the list;
`--enable` warns when the named container is absent or stopped (a typo'd name would
otherwise be enrolled and never update) and warns loudly on database-like images:
recreation has no quiesce.

Two distinct exclusion layers:

- **Eligibility (discovery time, warn-and-skip):** the gateway trio (their own paths update
  them), compose-managed or partially-labeled containers (never hand-recreated), anything
  matching `UPDATE_DENY_CONTAINERS` globs, stopped/absent containers, and any image not under
  `DOCKER_REGISTRY/ACR_NAMESPACE`. These are logged and skipped; the run is otherwise
  unaffected. Note that `REGISTRY_MODE=docker` leaves `DOCKER_REGISTRY`/`ACR_NAMESPACE`
  unset, which disables the generic-target engine entirely (a warning, zero eligible targets).
- **Replayability (apply time, fail-closed refusal):** `--rm`/`container:*`-mode containers,
  static IPv6 addresses, exec-form healthcheck overrides, values with embedded newlines, and
  anything the parity guard cannot faithfully reproduce (`PublishAllPorts`/`-P`, `OomScoreAdj`,
  device cgroup rules, userns mode, … — it names the offending setting). A refusal leaves the
  container **untouched** but is reported as `REFUSED (not replayable - container untouched)`,
  counted as failed, and the run exits `2` — an enrolled `--rm` container makes every scheduled
  run report a partial failure until you de-enroll it.

**How a generic target updates** (strictly serial, before cloudflared, with the gateway
pair always LAST): the full run spec is captured from `docker inspect` (mounts —
anonymous volumes retained by name — ports, networks/aliases, capabilities, devices,
limits, log config...), the container is recreated in place from the new image, and a
tiered health gate must pass: running → stable, non-crash-looping restart count (the
`HEALTH_MAX_RESTARTS` ceiling fails immediately once crossed — `RestartCount` only ever
grows, so remaining retries would be wasted) → the image's own healthcheck (when defined)
→ your optional per-target probe. Capture is override-aware: env/cmd/entrypoint — like
labels and the healthcheck — are replayed only as **overrides relative to the old image**,
so values inherited unchanged are left to the new image; only a *user-requested* static IP
(`IPAMConfig`) is pinned, dynamically assigned addresses replay dynamic (default-bridge
containers replay fine); an empty restart policy replays as `no`. On failure the saved
spec + old image are restored automatically (`ROLLED BACK` in the summary; an unrestorable
target reports `MANUAL ATTENTION`). On success the proven-good image ID is persisted under
`<data-dir>/state/last-good/` (surviving later prunes), and `state/last-run.json` records
the run — see [the run sequence](#the-run-sequence).

**Per-target probes**: `exec:<cmd>` runs inside the container via `docker exec`;
`log:<regex>` greps `docker logs` output on the **host** side (nothing runs in the
container's netns) — see
[Configuration › Generic auto-update targets](configuration.md#generic-auto-update-targets).
`update --enable` takes no probe argument: to attach one, hand-edit the third field of
`<data-dir>/state/update-targets` (`name|strategy|probe`). The list is re-validated
fail-loud on every run; shell metacharacters, `|` and newlines in a probe are refused.

## Acceptance runbook (required before relying on updater changes)

Real-container behavior is **not** covered by CI (a deliberate decision: granting the CI
runner a docker socket is a homelab security call — the owner can upgrade later by marking
the repo trusted in the Woodpecker admin UI and adding a dind step; until then this runbook
is the required manual gate). On the NAS:

1. **Dry-run smoke** — `sudo sh scripts/auto_update.sh --dry-run`: the report must list
   exactly the expected would-update set across all three buckets and change nothing.
2. **Canary** — enroll one non-critical container, then:

   ```sh
   sudo sh scripts/state_diff.sh snapshot <name> /tmp/canary-before
   sudo sh scripts/gateway.sh update --yes
   sudo sh scripts/state_diff.sh compare <name> /tmp/canary-before
   ```

   `state_diff.sh` snapshots with the updater's own capture engine, so "state retained"
   is a mechanical equality check (image/identity fields exempt). Any `DRIFT:` line is a
   failed acceptance — with one narrow exception: `labels`/`env`/`cmd`/`entrypoint`/
   `hc-test`/`hc-meta` are compared as overrides relative to each side's own image, so if
   the NEW image bakes in the same override verbatim they can drift falsely; confirm with
   `docker inspect` before treating those as real regressions.
3. **Gateway pair** — verify via [Operations › Manual health checks](operations.md#manual-health-checks).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success or clean no-op |
| `2` | partial failure (something failed; see the notification/log) |
| `3` | config / preflight error — nothing was changed |
| `4` | another run holds the lock |
| `5` | ACR login failed — nothing attempted |
| `130` / `143` | interrupted (Ctrl-C / TERM) — the lock is released and workdirs cleaned |

Driving the updater through `gateway.sh update` can additionally return the wrapper's own
`6` (needs root) and `7` (mutating verb without `--yes`) — see the [CLI reference](cli.md).
DSM Task Scheduler can email on non-zero exit as a second safety net.

## Scheduling

See [Operations › Scheduling on DSM](operations.md#scheduling-on-dsm). `scripts/install_scheduler.sh`
validates `UPDATE_SCHEDULE` and prints a shell-quoted command with an absolute working directory,
an explicit `/bin/sh`, and no duplicate log redirection. DSM Task Scheduler fires in the NAS
system timezone; `UPDATE_TZ` controls timestamps inside the updater only.

After creating the task, use **Run** once and verify the log at
`../syno-mihomo-gateway-data/logs/auto-update.log` — a relative `UPDATE_LOG` resolves under the
persistent data directory, never the release tree, and once `gateway.sh` has run that file is a
symlink into the unified `gateway.log`. A dry run pulls and inspects images but never swaps a
container:

```sh
sudo sh scripts/auto_update.sh --dry-run
```

## Upstream behavior references

- [Synology DSM 7 Task Scheduler](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/system_taskscheduler?version=7)
- [Synology Task Scheduler scripting tips](https://kb.synology.com/en-global/DSM/tutorial/common_mistake_in_task_scheduler_script)
- [Docker image pull](https://docs.docker.com/reference/cli/docker/image/pull/)
- [Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/)
