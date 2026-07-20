# Troubleshooting & FAQ

[← README](../README.md) · [中文](zh/troubleshooting.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · [Operations](operations.md) · [CLI](cli.md) · **Troubleshooting** · [Development](development.md)

---

## Dashboard symptom index

Three distinct failure modes look alike. Pick by the exact symptom — always testing from a
**non-NAS** LAN device, because the NAS cannot reach its own macvlan child:

| `curl http://MIHOMO_IP:CONTROLLER_PORT/version` … | Failure mode | Go to |
|---|---|---|
| **times out** | wrong TUN stack / TUN off hijacks the controller | [Dashboard times out](#dashboard-times-out-wrong-tun-stack-hijacks-the-controller--most-common) |
| returns JSON, but MetaCubeXD still says *"cannot connect to backend"* | CORS block | [Dashboard can't connect to the backend](#dashboard-cant-connect-to-the-backend) |
| returns `401 Unauthorized` | `CONTROLLER_SECRET` mismatch between dashboard and `.env` | [checklist](#dashboard-cant-connect-to-the-backend) |

## Exit codes (auto_update.sh)

| Code | Meaning | What to do |
|---|---|---|
| `0` | success / no-op | nothing |
| `2` | partial failure | read the notification + `../syno-mihomo-gateway-data/logs/auto-update.log` (a link into `gateway.log` when `gateway.sh` ran first) |
| `3` | config / preflight error | fix the reported precondition; nothing was changed |
| `4` | another run holds the lock | wait — see the stale-lock note below |
| `5` | ACR login failed | check `ACR_PASSWORD` / token expiry / registry host |

A lock whose recorded pid is dead is reclaimed **automatically** (`stale lock (pid …) - reclaiming.`;
a pid-less lock gets a 2-second grace period first), so exit `4` means a run with a *live* pid holds
it. Removing `LOCK_DIR` (default `/tmp/syno-mihomo-update.lock`) by hand is only needed in the rare
pid-recycled edge case.

The unified CLI (`sh scripts/gateway.sh`, see [CLI](cli.md)) shares codes `0/2/3/4/5` and adds
`6` (mutating verb needs root) and `7` (mutating verb refused without `--yes`) — both mean nothing
was changed. `gateway.sh status` and `gateway.sh doctor` (both support `--json`) are the supported
diagnostic verbs over the raw scripts referenced below.

## `required variable MIHOMO_IMAGE is missing a value`

**Symptom:** any `docker compose` command aborts immediately with
`required variable MIHOMO_IMAGE is missing a value: set MIHOMO_IMAGE in .env - run ./install.sh`
(or the `METACUBEXD_IMAGE` twin).

**Cause:** `docker-compose.yml` deliberately uses fail-closed `${VAR:?…}` references, and the live
`.env` lives at `../syno-mihomo-gateway-data/.env` — a bare `docker compose up -d` cannot see it.
You ran compose without `--env-file`, from the wrong directory, or before `install.sh` ever wrote
the data-dir `.env`.

**Fix:** always pass the env file:

```sh
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d
```

If `../syno-mihomo-gateway-data/.env` does not exist yet, run `sh ./install.sh` first.

## macvlan self-reach

**Symptom:** from the NAS, `curl http://MIHOMO_IP:9090` or the dashboard "Add backend" times
out, but other devices work.

**Cause:** by Linux macvlan design a host **cannot** reach its own macvlan container's IP. This
is expected, not a bug.

**Fix / workaround:**
- Open the dashboard and run connectivity tests from a **different LAN device**.
- The updater's mihomo health probe already runs *inside* the container (`docker exec`) to avoid
  this; from the NAS you can do the same: `docker exec mihomo wget -qO- http://127.0.0.1:9090/version`.
- If you genuinely need host→container reach, add a macvlan shim interface on the NAS (advanced).

## Architecture mismatch (ARM NAS)

**Symptom:** updater logs `arch mismatch for … image=amd64 host=arm64 - refusing to deploy.`,
or a container crash-loops with `exec format error`.

**Cause:** `docker-china-sync` mirrors `linux/amd64` by default; your NAS is ARM.

**Fix:** add arm64 to the mirror (`--platform=linux/amd64,linux/arm64` in
`docker-china-sync/images.txt`) and set `EXPECTED_ARCH=arm64`; or run on an Intel NAS. The guard
refusing to deploy is *protecting* you from a crash-loop — it's working as intended.

## Network missing after reboot

**Symptom:** after a NAS reboot, `docker compose --env-file ../syno-mihomo-gateway-data/.env up -d`
or the updater fails with `network tproxy_network … could not be found`, or the updater preflight
aborts (code `3`).

**Cause:** a CLI-created macvlan does not always survive a reboot / Container Manager restart;
the parent interface can also change (`eth0` ↔ `ovs_eth0`).

**Fix:** add the **Boot-up** Task Scheduler entry that runs `scripts/setup_network.sh` (see
[Operations › Scheduling](operations.md#scheduling-on-dsm)). To recover now:
`sudo ./scripts/setup_network.sh && docker compose --env-file ../syno-mihomo-gateway-data/.env up -d`.

## TUN silently dead after a reboot (boot-order race)

**Symptom:** `doctor.sh` reports `ERROR in-container TUN gateway is not ready` while everything
else passes (mihomo running, controller answering); `docker logs mihomo` shows
`Start TUN listening error: configure tun interface: no such file or directory`; clients using
the explicit proxy ports still work, so the degradation is easy to miss.

**Cause:** Docker autostarted mihomo **before** the boot task created `/dev/net/tun`, so the
container's device bind captured nothing. The boot task then creates the host node, but the
already-running container keeps its empty bind — TUN stays down until the container restarts.

**Fix:** `sudo docker restart mihomo` (the bind is re-evaluated at start; verify with
`docker exec mihomo ls /sys/class/net/` — `mihomo-tun` must be listed, then re-run
`sudo sh scripts/doctor.sh`). To prevent it, keep the Boot-up task for `setup_network.sh`
**earliest** in the boot order; it creates `/dev/net/tun` before Container Manager brings
containers up.

## Network exists but with different settings

**Symptom:** `setup_network.sh` (or the installer) logs
`docker network 'tproxy_network' exists with different settings; refusing implicit removal` /
`run <installer> and choose automatic or manual network cleanup` (the installer name matches
your entry: `install.sh` on DSM, `install-linux.sh` / `install-pi.sh` on the generic/Pi
hosts); or the updater preflight aborts
(code `3`) with `macvlan parent mismatch: network='…' live='…'` or
`macvlan configuration drift: expected parent=… subnet=… gateway=…`.

**Cause:** the existing docker network's parent/subnet/gateway no longer match `.env` or the live
routing — typically the parent interface changed (`eth0` ↔ `ovs_eth0`) or `SUBNET_CIDR`/`ROUTER_IP`
was edited. The scripts refuse to delete a mismatched network implicitly.

**Fix:** re-run your installer (`sh ./install.sh` on DSM; `sudo sh ./install-linux.sh` /
`sudo sh ./install-pi.sh` on generic Linux/Pi) and choose automatic (or manual) network cleanup
when prompted. Or, if you are sure nothing else uses the network, remove it yourself (stop
attached containers first): `docker network rm tproxy_network && sudo ./scripts/setup_network.sh`,
then redeploy.

## Dashboard can't connect to the backend

Checklist:
- Using the **NAS IP** (`http://NAS_IP:WEB_UI_PORT`) for the UI, and the **mihomo IP** + 
  `CONTROLLER_PORT` for the *backend*?
- Testing from a non-NAS device (macvlan self-reach)?
- `CONTROLLER_SECRET` entered if you set one?
- Is the controller actually enabled? `docker exec mihomo wget -qO- http://127.0.0.1:9090/version`
  should return JSON. If not, check `docker logs mihomo` for a render/start error.

**Most common cause: CORS.** If the backend is reachable from a LAN device
(`curl http://MIHOMO_IP:CONTROLLER_PORT/version` returns JSON) but MetaCubeXD still reports
*"cannot connect to backend" / "无法连接后端"*, it is a cross-origin block — **not** a network or
secret problem. The dashboard is served from `http://NAS_IP:WEB_UI_PORT` while the controller
answers on `MIHOMO_IP:CONTROLLER_PORT` (a different origin), and recent mihomo ships a
**restrictive** default CORS allow-list (only the bundled/hosted dashboards, not arbitrary LAN
addresses). Confirm in the browser DevTools (F12) → Console — you'll see a CORS error. The config
template now sets:

```yaml
external-controller-cors:
  allow-origins:
    - '*'        # the secret still gates real API access
  allow-private-network: true
```

so a fresh deploy already allows your dashboard. On a gateway deployed **before** this was added,
update `config/config.template.yaml` and re-render with
`docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo`
(or `sudo sh scripts/gateway.sh redeploy --yes`). Do **not** edit the rendered
`…-data/config/config.yaml` instead — the entrypoint regenerates it from the template on every
container start, so that edit is clobbered by the very restart meant to apply it.

## Dashboard times out (wrong TUN stack hijacks the controller) — MOST COMMON

**Symptom:** from a **non-NAS LAN device**, `curl http://MIHOMO_IP:CONTROLLER_PORT/version`
**times out** (not "connection refused", not a CORS error, not 401), yet the deploy reported healthy
and `docker exec mihomo wget -qO- http://127.0.0.1:9090/version` returns JSON.

**Cause:** the `tun:` block is using a `gvisor`/`mixed` stack with `auto-route`, **or** TUN was turned
off and the gateway lost its dataplane. With `stack: mixed`/`gvisor` + `auto-route`, mihomo installs
policy routing (a high-priority `ip rule` → table 2022) that **captures the controller's reply packets
into `mihomo-tun`** instead of sending them back out the LAN NIC, so the external TCP connection never
completes ([mihomo #1493](https://github.com/MetaCubeX/mihomo/issues/1493)). The in-container
`127.0.0.1` probe still passes because loopback bypasses the policy rule — which is why the deploy
looked healthy while the dashboard could not connect.

**Fix:** keep TUN **on** (`TUN_ENABLE=true`, the default) with the **`system` TUN stack**. Unlike
`mixed`/`gvisor` + `auto-route`, the `system` stack does **not** hijack the controller's reply path, so
the dashboard backend at `MIHOMO_IP:CONTROLLER_PORT` stays reachable from the LAN while transparent
gateway forwarding keeps working. This is the verified, working configuration — do **not** turn TUN off
to work around #1493. Redeploy a current build, or fix an older deployment in place: confirm the
rendered `…-data/config/config.yaml` has `tun.enable: true` with `tun.stack: system` (and
`allow-lan: true`, `enhanced-mode: fake-ip`) — if it doesn't, set `TUN_ENABLE=true` in
`../syno-mihomo-gateway-data/.env` or fix the template (never the rendered file; it is regenerated
on every start) — then
`docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo`.
Confirm with:

```sh
docker exec mihomo ip rule                       # no high-priority rule diverting replies into tun
docker network inspect tproxy_network -f '{{.Driver}} {{index .Options "parent"}}'
```

Setting `TUN_ENABLE=false` runs mihomo as a **plain (non-gateway) proxy** (reachable only on the
redir/tproxy/mixed/socks ports) — it does **not** transparently intercept LAN clients, so don't use it
as a #1493 workaround.

## Open vSwitch is **not** the cause of a dashboard/gateway timeout

Earlier guidance blamed an **Open vSwitch** parent (`ovs_eth0`) for "the dashboard/gateway times out
from LAN devices" and suggested switching to `ipvlan` or disabling OVS. That was a **misdiagnosis.** A
Docker **macvlan child IP IS reachable from peer LAN devices on an OVS-backed parent** — verified
empirically: a clean container at a macvlan IP answered ping, ARP, and HTTP from a separate LAN device.
The real root cause of the timeout was a **config regression** (TUN turned off with the TUN stack set
to `mixed`), fixed by the TUN-stack model above, **not** by a networking change. Keep
`TPROXY_DRIVER=macvlan`; do not switch to `ipvlan` or disable OVS for this symptom.

(`ipvlan` would in fact break the gateway: it demultiplexes by destination IP and will **not** route
LAN clients that use `MIHOMO_IP` as their gateway.)

## Containers are healthy but LAN clients have no internet

Run the read-only structural diagnostic first:

```bash
sudo sh scripts/doctor.sh --egress
```

It checks the host TUN device, macvlan, Compose model, image architecture, controller, and the
in-container `mihomo-tun` dataplane. Exit `0` is structurally healthy, `2` is degraded — an
optional service or egress warning (the dashboard container not running, or the `--egress` probe
failing / having no downloader available) — and `3` is a local configuration/runtime failure.
`sudo sh scripts/gateway.sh doctor --json` runs the same check set and emits one JSON object
(see [CLI](cli.md)). If it passes, test gateway and DNS from a different LAN device because the
NAS cannot reach its own macvlan child.

## mihomo won't start / crash-loops

```bash
docker logs mihomo --tail 80
```
Common causes:
- **First boot with a broken config** — the entrypoint gate refuses to start when there is no
  previous config to fall back on: the renderer fails loudly
  (`ERROR: subscription.txt has no usable URL`, `ERROR: DNS_… must be set`) or `mihomo -t`
  rejects the render. Fix the **live** files
  `../syno-mihomo-gateway-data/config/subscription.txt` / the `DNS_*` keys in
  `../syno-mihomo-gateway-data/.env` (the in-repo `config/` only ships the `.example`), then
  `docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo`.
  On an **already-running install** the same errors do NOT crash-loop anymore — the gateway
  keeps running on the previous config instead; see
  [Config test failed](#config-test-failed--gateway-running-on-the-previous-config) below.
- **`/dev/net/tun` missing** — run `sudo ./scripts/setup_network.sh`.
- **`iptables (nf_tables): Could not fetch rule set generation id`** — the image's nft-backed
  iptables is incompatible with the DSM kernel. Set `TUN_AUTO_REDIRECT=false` in `.env` and
  redeploy; the `system` TUN stack still provides the gateway dataplane.
- **Wrong arch image** — see above.

## Subscription URL looks wrong in config.yaml

The renderer strips only an optional leading `Name=` label and preserves everything else,
including `?token=…&flag=…`. If your provider URL itself contains a literal `|` or `\`, those are
escaped for `sed`; a stray newline in `subscription.txt` is ignored (first valid line only).
Verify the rendered value:

```bash
docker exec mihomo grep -m1 'url:' /root/.config/mihomo/config.yaml
```

## ACR login fails (code 5)

- Confirm `DOCKER_REGISTRY` host, `DOCKER_USERNAME`, and `ACR_PASSWORD` (the latter is a secret;
  ensure `.env` is `chmod 600`).
- ACR access tokens can expire — regenerate in the Alibaba console.
- Test by hand: `printf '%s' "$ACR_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USERNAME" --password-stdin`.

## Pulls are slow / time out

Network flakiness to ACR. The updater retries pulls (`PULL_RETRIES`/`PULL_RETRY_DELAY`) and
pulls **before** swapping, so a failed pull aborts without touching the running container.
Increase the retry env vars if needed, or schedule further from the mirror window.

**`manifest unknown` is not flakiness:** when the pull error says the manifest is unknown, the
notification appends `(not mirrored in ACR? add the upstream image to docker-china-sync/images.txt)`
— the tag simply does not exist in your ACR namespace (the hint applies to the trio and to enrolled
generic targets alike). Retries won't help; mirror the image first.

## DSM 7 scheduled task does not run

1. In **Control Panel → Task Scheduler**, verify the task is enabled and runs as **root**.
2. Re-run `sh scripts/install_scheduler.sh` and copy its exact absolute-path command.
3. Confirm the Schedule time against **Regional Options**; `UPDATE_TZ` only affects log timestamps.
4. Select the task and click **Run**, then inspect its saved result and
   `../syno-mihomo-gateway-data/logs/auto-update.log`.
5. Exit code `3` with a Docker readiness message means Container Manager did not become ready
   within `DOCKER_READY_TIMEOUT`; verify the package is running or increase the timeout.

If each line appears twice or rotation looks wrong, remove any outer
`>> logs/auto-update.log 2>&1` from the DSM command. The updater logs internally.

## Compose apply failed during auto-update

The updater now treats a failed `compose up` as a rollback event, not only an unhealthy start.
Look for `ROLLED BACK` in the notification/log. If rollback is incomplete, do not prune images:
verify the old IDs with `docker image inspect <id>`, then follow
[Operations › Manual rollback](operations.md#manual-rollback).

## Update summary says `compose: SKIPPED (TUN auto-redirect incompatible…)`

With `TUN_AUTO_REDIRECT=true` and a pending compose change, the updater probes the new mihomo
image's iptables frontend against the DSM kernel (in a throwaway privileged container) **before**
recreating anything. If the probe fails, the compose pair is skipped and counted as failed — the
running containers are untouched, and generic targets / cloudflared still proceed. A `--dry-run`
never runs the probe; it only notes that the probe would gate the real apply.

**Fix:** set `TUN_AUTO_REDIRECT=false` in `../syno-mihomo-gateway-data/.env` and redeploy — the
`system` TUN stack still provides the gateway dataplane. Same root cause as the
`iptables (nf_tables)` crash-loop above; the probe exists to prevent that crash-loop.

## An enrolled (generic) update target failed

Enrolled containers (managed via `gateway.sh update --enable/--disable NAME`) are updated by an
in-place recreate with a health gate. The notification line tells you which outcome you got:

- `NAME: FAILED health -> ROLLED BACK to last-good (now healthy)` — the automatic rollback worked;
  investigate the new image at leisure.
- `NAME: REFUSED (not replayable - container untouched; see log, or de-enroll it)` — capture found
  a setting the replay engine cannot faithfully reproduce (embedded newlines in values, a static
  IPv6 address, `-P`/`PublishAllPorts`, `OomScoreAdj`, device cgroup rules, …). Nothing was
  changed. Recreate the container without the unsupported setting, or de-enroll it:
  `sudo sh scripts/gateway.sh update --disable NAME --yes`.
- `NAME: FAILED AND rollback incomplete -> MANUAL ATTENTION NEEDED` — recreate the container by
  hand; the last-good spec is saved under `../syno-mihomo-gateway-data/state/last-good/NAME`.
- `generic targets: INVALID enrollment list (see log)` — the managed list
  (`../syno-mihomo-gateway-data/state/update-targets`) failed validation and **no** generic target
  was processed. Inspect it with `sh scripts/gateway.sh update --list-targets` and re-enroll.

`sh scripts/gateway.sh update --last` shows the outcome of the last run (`state/last-run.json`,
including `updated_names`/`failed_names`/`rolled_back_names`).

## cloudflared tunnel down after an update

The staged path verifies a temporary connector before replacing the canonical container. A failed
update reports one of three distinct outcomes: `update FAILED (candidate discarded; the old
connector is untouched)` (nothing to do), `update FAILED -> ROLLED BACK to the previous connector
(now connected)` (automatic recovery), or `FAILED AND canonical not restored -> MANUAL ATTENTION
NEEDED` — in that last case the candidate is kept because it may be the only live connector. If
only `cloudflared-candidate` is running, do not remove it:

```bash
docker ps -a | grep cloudflared
docker logs --tail 100 cloudflared-candidate
```

Recreate the canonical container from the original run settings while the candidate remains live.
Emergency fallback: rename the candidate to `cloudflared`; its temporary dynamic IP and omitted
host-port bindings remain until you reconstruct the full canonical specification.

## "no image changes" but I expected an update

The updater compares the **running** container's image to the freshly-pulled tag, and only
deploys refs that match `MIHOMO_IMAGE`/`METACUBEXD_IMAGE`/`CF_IMAGE`. If you set `UPDATE_IMAGES`
to a ref that differs from those three, it's pulled **cache-only** and you'll see a `WARN`. Align
them (see [Auto-Update › image refs](auto-update.md#image-refs)). Also confirm the mirror actually
pushed a new digest (check the `docker-china-sync` GitHub Actions run).

## "the previous deployment was ALREADY REMOVED during cleanup"

The installer tears the old stack down only after all non-destructive validation passed, but a
late failure (usually macvlan creation) can still land after that teardown. This message means
the gateway is **down** — nothing is serving LAN clients. Fix the reported issue (typically the
parent interface or an IP conflict) and run Deploy again; `sh scripts/doctor.sh` shows what is
currently present. The next installer run's preprocessing step re-inventories any partial state.

## Cron setup said "no schedule is active yet"

The cron flow saves `UPDATE_SCHEDULE`/`UPDATE_TZ`/`UPDATE_ENABLED` to `.env`, but a schedule only
runs once a DSM Task Scheduler task (recommended) or a crontab entry exists. If you chose *Done*
without either, the installer warns and offers to set `UPDATE_ENABLED=false` so the state stays
honest. Re-run the cron flow and pick one of the two scheduling methods, or use
`sh scripts/gateway.sh cron --apply-crontab --yes` as root.

## Container Manager shows the containers oddly / a "stuck" Project

CLI-created compose stacks do not register as Container Manager *Projects*, and script-driven
recreates (the auto-updater's gated deploys) can leave a manually created Project entry out of
sync ("stuck"). That is cosmetic: the source of truth is `docker`/`docker compose` state, which
`sh scripts/doctor.sh` and the installer's Status menu report. Do not press the Project tab's
Build/Update to "fix" it - that bypasses the digest gate, health gate, and rollback. If you
created a Project entry manually, delete the Project (not the containers) and manage the stack
via the installer/CLI only.

## Generic Linux: macvlan-hostile host (cloud VM / VPC / Wi-Fi)

**Symptom:** `install-linux.sh` warned "virtualized/cloud host detected … macvlan children
often cannot forward LAN traffic here" — or compose mode deployed cleanly but no LAN device
can reach `MIHOMO_IP` (ping/ARP dead), typically on a cloud VM (AWS/GCP/Alibaba/…) or under
a hypervisor vswitch.

**Cause:** macvlan puts the gateway on a second, unknown MAC address on the host's port.
Cloud VPCs filter frames from unknown source MACs, and some hypervisor vswitches drop them —
the container comes up healthy but its frames never reach the LAN. Wi-Fi breaks the same
way ([macvlan on Wi-Fi refused](#pi-macvlan-on-wi-fi-wlan0-refused)).

**Fix:** lite mode is the sanctioned answer on these hosts — re-run the installer, choose
**Deploy** (the mode wizard runs there; Redeploy keeps the saved compose flavor), and pick
lite: the gateway binds the host's own IP, no macvlan involved. Afterwards take the stranded
compose pair down (`docker compose --env-file ../syno-mihomo-gateway-data/.env down`) and
point clients at the host's IP. The guard's detection is a heuristic;
on a bridged home-lab VM (Proxmox/ESXi with MAC filtering off) where macvlan does work,
acknowledge the warning and keep compose. Background:
[Installation — Generic Linux & Raspberry Pi](installation-linux.md#macvlan-hostile-hosts-cloud--vm).

## Generic Linux: which image source (REGISTRY_MODE)?

**Symptom:** unsure whether to pick `docker` or `acr` in the `install-linux.sh` image
wizard — or pulls fail right after picking one.

**Cause:** the two sources serve different networks. `docker` pulls the upstream public
registries (Docker Hub / ghcr.io) via multi-arch manifests — works out of the box on any
unfiltered network, blocked in mainland China. `acr` pulls your private Alibaba ACR mirror —
the mainland-China answer, but it needs your own mirror pipeline, and the default pipeline
copies amd64 only.

**Fix:** outside mainland China keep the wizard's `docker` default. In mainland China pick
`acr` and set up the mirror pipeline ([Auto-Update › ACR setup](auto-update.md#acr-setup));
on an arm64 host also mirror arm64 first — the next entry's guard fires on any arm64 host,
not just Pis.

## Pi: ACR image not mirrored for arm64

**Symptom:** on a Raspberry Pi in compose mode (`install-pi.sh`), the deploy/update fails at
the pull, or the arch guard refuses with `arch mismatch for … image=amd64 host=arm64` — right
after the installer printed an ACR architecture notice.

**Cause:** `REGISTRY_MODE=acr` is the default on the Pi too, and the default
`docker-china-sync` pipeline mirrors `linux/amd64` only — your ACR namespace has no arm64
copy of the images yet.

**Fix:** mirror arm64 first (`--platform=linux/amd64,linux/arm64` per image in
`docker-china-sync/images.txt`), let a sync cycle run, then deploy — or switch to
`REGISTRY_MODE=docker` on an unfiltered network. Same guard as
[Architecture mismatch (ARM NAS)](#architecture-mismatch-arm-nas): the refusal is the
protection, not the bug. Background:
[Installation — Generic Linux & Raspberry Pi](installation-linux.md#compose-mode).

## Pi lite: update rolled back

**Symptom:** the update notification says `rolled back`, `state/lite/last-run.json` shows
`"rolled_back":1`, exit code `2`.

**Cause:** the freshly installed mihomo binary failed the post-restart health gate (service
active + restart-count stability + controller probe + TUN link), so the updater restored
`bin/mihomo.prev` — including the recorded version state, which is what makes the next
scheduled run retry the update cleanly.

**Fix:** usually nothing — the gateway is running on the previous binary. Check
`journalctl -u mihomo-gateway -n 50` and `logs/auto-update.log` for why the new one failed;
pin `MIHOMO_VERSION` to skip a bad release. If the notification says `MANUAL ATTENTION`
instead, the restore itself failed — run `sh scripts/pi/lite_ctl.sh doctor` and fix what it
reports.

## Pi: macvlan on Wi-Fi (wlan0) refused

**Symptom:** `install-pi.sh` refuses the chosen/detected parent interface (`wlan0`) in
compose mode.

**Cause:** macvlan children present extra MAC addresses on the parent link; Wi-Fi drivers and
AP client isolation typically drop those frames, so the stack would deploy and then be
unreachable from the LAN.

**Fix:** use wired Ethernet for compose mode — or lite mode, which binds the Pi's own IP and
works over Wi-Fi. This is a Pi-specific fail-fast; the
[OVS discussion](#open-vswitch-is-not-the-cause-of-a-dashboardgateway-timeout) is unrelated.

## Pi lite: port 53 already in use

**Symptom:** the lite install warned about port 53; `lite_ctl doctor` warns and names a
process (commonly `systemd-resolved` or `dnsmasq`); client DNS is dead or mihomo restarts in
a loop.

**Cause:** mihomo's DNS must bind `:53`, and stock Raspberry Pi OS / Debian images often ship
a resolver already listening there.

**Fix:** disable the conflicting listener or move it off port 53 (for `systemd-resolved` its
stub listener; for `dnsmasq` its DNS port), then `sudo sh scripts/pi/lite_ctl.sh start` and
re-run `doctor` — it should now report port 53 served by mihomo.

## CI didn't run

The pipeline triggers on branches `main` **and** `master`. If you use another branch name, add
it to `.woodpecker.yml`'s `when.branch`.

## Whole house lost internet

If devices use `MIHOMO_IP` as gateway/DNS and mihomo is down, they're cut off. Quickest
recovery: point the affected device's gateway/DNS back to the router, then fix mihomo
(`docker compose --env-file ../syno-mihomo-gateway-data/.env up -d mihomo`, check logs). Consider
the kill-switch + maintenance windows for risky changes.

## The NAS itself cannot reach vendor services (dead host resolvers)

**Symptom:** DSM cannot reach its vendor services / Package Center; every name lookup on the
NAS fails; bridge containers (which inherit the NAS's `resolv.conf`) are DNS-dead too — while
the gateway keeps forwarding LAN clients (they use mihomo's DNS, not the NAS's).

**Cause:** the NAS's own DNS (Control Panel → Network → General) points at resolvers that are
unreachable from the deploy network — a `1.1.1.1`-only setup on a filtered network is the
classic case.

**Fix:** set reachable resolvers (domestic ones on a filtered network, e.g. `223.5.5.5` and
`119.29.29.29`). `doctor` / `gateway.sh doctor --json` now probe every configured resolver
(the `host_dns` check) and degrade with the dead ones named.

## cloudflared tunnel down although the network is up

**Symptom:** the tunnel stays disconnected even though raw TCP to the tunnel edge works.

**Cause:** bridge containers copy the host `resolv.conf` when they START; with a dead host
resolver (previous entry) cloudflared cannot resolve the edge hostname.

**Fix:** fix the host DNS, then `docker restart cloudflared`. To decouple permanently, set
`CF_DNS` in `.env` (comma-separated IPv4s) and run `sudo sh scripts/gateway.sh update --yes` —
the blue-green replay applies it as `--dns`. `doctor` reports `cloudflared` ok/down/absent
whenever the container exists.

## First start hangs downloading geo databases

**Symptom:** mihomo never finishes its first start; logs show a stalled geo-database download.

**Cause:** the `GEOSITE,CN` / `GEOIP,CN` rules need the geo databases; when uncached, mihomo
fetches them at start via a CDN that filtered networks often block.

**Fix:** deploys now pre-seed `GeoSite.dat` + `geoip.metadb` into the data dir with mirror
fallback (`scripts/lib/geodata.sh`; override the list with `GEODATA_MIRRORS`). `doctor` warns
(the `geodata` check) while they are uncached; re-running the deploy pre-seeds again.

## Niche domestic site slow or unreachable after enabling no-resolve

**Symptom:** with `DNS_GEOIP_NO_RESOLVE=true`, a small/regional Chinese site loads slowly or
refuses access, while the big Chinese sites are fine.

**Cause:** `no-resolve` stops the `GEOIP,CN,DIRECT` rule from resolving domains, so a CN domain
missing from `geosite:cn` no longer short-circuits to DIRECT — it falls through to `MATCH` and
rides the proxy. That is the knob's documented trade-off, not a fault: the site usually still
works (tunneled), and only breaks when it rejects out-of-country visitors.

**Fix:** set `DNS_GEOIP_NO_RESOLVE=false` in `.env` and redeploy. Under split-horizon v2 the
rule's lookups ride the tunneled foreign resolvers, so leaving the knob `false` costs no
privacy — see the [configuration DNS matrix](configuration.md#dns-injected-into-the-config-template).

## LAN clients bypass the gateway's DNS (dnsleaktest still shows domestic resolvers)

**Symptom:** with the privacy profile live and `doctor` reporting `dns_privacy: v2`, a LAN
device's dnsleaktest.com extended test STILL lists AliDNS/DNSPod; facebook/netflix and many
blocked sites fail while youtube may work; `docker logs mihomo` shows almost only raw-IP flows
(`--> 1.2.3.4:443 match Match`) and nearly no hostname-tagged flows.

**Cause:** the device never sends its DNS to the gateway, so nothing the gateway does can help
it. Two structural bypasses: **(1)** DHCP hands out the **router** (or ISP resolver) as DNS —
client→router:53 is same-subnet traffic that never crosses the gateway, so the `any:53` hijack
cannot see it; **(2)** client-side **encrypted DNS** — browser "secure DNS" (Chrome silently
upgrades a domestic system resolver to that provider's DoH), Android Private DNS, or a
Cloudflare WARP/1.1.1.1-type app — rides port 443/853 and cannot be hijacked. Without
hostnames the domain rules cannot match: streaming never reaches the `Streaming Sites` group, and
the device dials whatever (often GFW-poisoned) addresses its own resolver returned. In fake-ip
mode every gateway-resolved flow logs WITH a hostname, so a hostname-free log is proof of
bypass, not a gateway fault.

**Diagnosis:** on the device run `nslookup facebook.com` — a `198.18.x.x` answer means it uses
the gateway; a real/public address means bypass.

**Fix:** make the router's DHCP hand out `MIHOMO_IP` as **both gateway and the only DNS**
(see [Installation §7](installation.md#7-point-devices-at-the-gateway)), renew the client's
lease, disable browser secure-DNS / Android Private DNS, uninstall or disable WARP/1.1.1.1
apps, and turn off router IPv6 (see the next entry — an IPv6 path skips the whole gateway,
not just its DNS).
Since v1.3.10 the **sniffer** (`SNIFFER_ENABLE=true`) recovers hostnames from raw-IP flows via
SNI, so *routing* self-heals even for bypassing clients — streaming reaches its group and
poisoned client answers are re-dialed by hostname at the node — but such clients' queries
still leak to whatever resolver they use: only pointing their DNS at the gateway fixes
*privacy*. Optional hardening against plain DoT: add `DST-PORT,853,REJECT` to the template
rules (Android *strict* Private DNS then fails closed — set devices to automatic). If many
sites stall through the tunnel in bursts, also check the airport's entry relay:
`docker logs mihomo | grep 'connect error'` — repeated `i/o timeout` on the provider's entry
host is airport-side flakiness, not a gateway rule problem.

## Dual-stack IPv6 carries traffic around the gateway (leaks persist, Netflix keeps failing)

**Symptom:** DNS still leaks "sometimes" and IPv6-capable services — Netflix first among
them — stay broken even though `doctor` is otherwise green, the sniffer is on, and the
client's IPv4 DNS points at the gateway; `doctor` warns `ipv6_bypass: exposed`.

**Cause:** the gateway is IPv4-only — a v4 macvlan joined to the LAN, `ipv6: false` in its
DNS. When the router announces IPv6 on the LAN (RA/RDNSS/DHCPv6), every dual-stack client
gets a global IPv6 address, an IPv6 default route, and usually an IPv6 resolver — a complete
path that **never crosses the gateway**. Lookups leak to the ISP resolvers over v6, and
services that prefer IPv6 (Netflix does) connect directly over the ISP's v6 — blocked or
geo-wrong on a filtered network — so they fail even though the v4 path through the gateway
is healthy. The sniffer cannot help here: these packets never arrive at the gateway.

**Diagnosis:** `doctor` warns `ipv6_bypass: exposed` when the NAS's LAN interface carries an
internet-routable IPv6 address (public, starting `2` or `3`) — the NAS sits on the same L2
segment as the clients, so an address there proves the router's announcements reach everyone.
On a client, such an address in `ipconfig` / `ip -6 addr` means that client has the bypass
path. A private `fd…` (ULA) address alone is **not** the bypass — Matter/Thread border
routers (an Apple HomePod/TV, for example) announce one for smart-home traffic; it cannot
route to the internet and `doctor` reports it ok.

**Fix:** turn IPv6 off at the router, so no client is handed a path around the gateway. On
UniFi: Settings → Internet → your WAN → **IPv6 Connection = Disabled**, and Settings →
Networks → your LAN → **IPv6 = Off** (this stops the RA/RDNSS announcements). On other
routers, disable LAN IPv6 or at minimum its RA/RDNSS + DHCPv6 announcements. Then renew
client leases or reboot clients — RA-assigned addresses live until their advertised lifetime
expires, so `doctor` may keep warning for a while after the router change. Disabling IPv6
per-device also works but does not scale. Proxying IPv6 natively (dual-stack fake-ip plus a
v6 macvlan) is a much larger feature; on a filtered network the correct posture today is
v4-only, with everything steered through the gateway.

## Netflix (or another streaming service) says "not available in your region"

**Symptom:** general foreign browsing works through the gateway, but Netflix shows a region /
"you seem to be using an unblocker or proxy" error, or another streaming service refuses to
play.

**Cause:** streaming services blacklist most datacenter exit IPs. The `<Country> Auto` group
your `Country Pick` selection rides picks its node by **latency within that country**, and the
lowest-latency node is rarely a streaming-unlock node — so Netflix rides a working tunnel
whose exit is refused by Netflix. This is a node property, not a rule fault: the
`GEOSITE,NETFLIX,Streaming Sites` rule (and its audio-service twins — Spotify, Tidal, Deezer,
SoundCloud) routes these sites deterministically into their own `Streaming Sites` selector
(default: `Proxy Mode`, i.e. day-one behavior is unchanged).

**Fix:** open MetaCubeXD → Proxies → `Streaming Sites` and pin a node your airport marks as
streaming/Netflix-capable (often named `NF`, `流媒体`, `解锁`…) — or pin a `<Country> Auto`
group for one-click region pinning — then reload the title. Only streaming traffic moves;
everything else keeps riding `Proxy Mode`. If it still fails on an
unlock node: some devices (smart TVs, Android **Private DNS**) bypass the gateway's DNS and
connect by raw IP — since v1.3.10 the sniffer recovers those flows' hostnames from SNI so they
still reach `Streaming Sites`, but a device whose own resolver returns poisoned garbage may still
misbehave; disable its private/hardcoded DNS so the gateway answers its lookups (see the
"LAN clients bypass the gateway's DNS" entry above). And if `doctor` warns
`ipv6_bypass: exposed`, fix that first: a dual-stack device streams over the ISP's IPv6 and
never reaches the gateway at all (see the IPv6 entry above).

## Unlisted-domain lookups fail while the airport is down

**Symptom:** with the airport expired/unreachable, Chinese sites keep working but *everything
else* — including small foreign sites — fails at the DNS step (SERVFAIL / no answer), even
though under v1.3.9 those lookups still returned answers.

**Cause:** by design. Split-horizon v2 resolves every non-CN-listed domain **only** through
the tunneled foreign resolvers and removed the legacy fallback dual-query — a dead tunnel now
fails **closed** instead of silently answering from a domestic resolver (which is exactly the
leak dnsleaktest used to show). The flows those lookups would feed are unreachable without the
tunnel anyway.

**Fix:** restore the airport (renew / replace the subscription — split-horizon v2 is the only
DNS profile, so there is no legacy fallback mode to switch back to). Note the DNS detour rides
the **hidden** `All Nodes` anchor group (the full pool, kept alive solely for DNS — MetaCubeXD
does not show its card), so pinning `Proxy Mode` to `DIRECT` — or an empty `Country Pick`
selection — does **not** break resolution; only a genuinely dead provider does. Also expect the **first** lookup of a
new domain to add one tunneled round-trip (~hundreds of ms); mihomo's DNS cache is in-memory,
so caches start cold after every restart.

## Provider has no nodes (foreign sites dead, node list empty)

**Symptom:** the dashboard's Proxies view shows only the group cards — `Proxy Mode` /
`Streaming Sites` / `Country Pick` / your `<Country> Auto` groups — with **no airport nodes**
inside them (the `All Nodes` url-test still exists but is hidden from the dashboard); foreign
sites time out while domestic sites stay fine, and the mihomo log repeats
`[Provider] my-airport pull error: …`.

**Cause:** mihomo cannot fetch the subscription from inside the container **and** has no usable
on-disk provider cache (`config/proxies/my-airport.yaml`) to load at startup. Since v1.3.8 the
airport panel's hostname is pinned to the domestic resolvers and excluded from fake-ip precisely
so a cold start can fetch the node list before any node exists; a network-side block, a carrier
IP flap, or an expired subscription can still leave the provider empty (the 2026-07-12 outage).

**Fix:**

```bash
sudo sh scripts/seed_provider.sh
```

It fetches the subscription **on the NAS host** (a different network path than the container),
validates it, writes the provider cache under the data dir (both the stable name and the legacy
md5 name), restarts mihomo, and verifies **real** nodes appear — built-ins and the `COMPATIBLE`
placeholder of an empty group are never counted. mihomo keeps loaded nodes when a background
pull fails, so the seed survives restarts until the fetch path heals. If the host fetch itself
fails with a `4xx`, re-copy the subscription URL from the airport panel (token rotated / plan
expired); on a timeout, the panel is unreachable from your network at that moment.

## Doctor reports an empty country group (`proxy_groups`: default-empty / country-empty)

**Symptom:** `doctor` shows `ERROR the Country Pick selection '…' has NO nodes …` (result
BROKEN, state `default-empty`) or `WARN country group(s) match no provider node: …` (DEGRADED,
state `country-empty`); selecting the named group in the dashboard rejects every connection
instead of routing it.

**Cause:** a `COUNTRY_GROUPS` regex matches zero provider nodes. `default-empty` is the bad
one: the empty group is the country **`Country Pick` is currently riding**, so default-route
traffic is REJECTed. `country-empty` means some *other* country group is empty — the default
route still works, but selecting that country would reject. Either way the regex no longer
fits the airport's node naming — airports rename nodes (香港01 → HK-01) without notice, and a
city-named pool (东京/大阪) never matched `日本|JP\d|^JP` to begin with. The groups fail
**closed** by design (`empty-fallback: REJECT`): traffic is blocked, never silently routed
DIRECT out the uplink — the doctor is how you find out *why*.

**Fix:** compare the pattern against the live node names (dashboard Proxies view), adjust that
`COUNTRY_GROUPS` entry's regex in `.env` (syntax notes in
[configuration](configuration.md)), then re-render with **Redeploy** (`sudo sh ./install.sh`).
Stopgap while you fix it: pick another country in the dashboard's `Country Pick` selector. If
doctor instead reports `provider-empty` — **every** url-test group empty — the provider itself
has no nodes: that is the [Provider has no nodes](#provider-has-no-nodes-foreign-sites-dead-node-list-empty)
condition above, not a regex problem (`sudo sh scripts/seed_provider.sh`).

## Dashboard picks reset once after the group-model upgrade

**Symptom:** after upgrading to the streamlined group model, every MetaCubeXD selection is
back to its first member — your streaming pin and mode choice are gone.

**Cause:** mihomo's `cache.db` keys dashboard selections by **group name**. The streamline
renamed the selectors and removed the old filtered default group, so saved pins no longer
match any group and every renamed/removed group falls back to its first member. This happens
**once**, by design; new picks persist normally.

**Fix:** re-pin in MetaCubeXD (`Proxy Mode`, `Streaming Sites`, `Country Pick`). Defaults are
sane meanwhile: `Country Pick` rides your **first** `COUNTRY_GROUPS` entry — a pre-existing
`.env` keeps its own entry order, so your default country is *your* first entry. If you
hand-edit `.env` instead of re-running the installer: delete the retired filter-knob lines the
render error names (see [configuration](configuration.md#dns-injected-into-the-config-template)
— Removed knobs), make sure `COUNTRY_GROUPS` is set, and leave the `DNS_*` values alone — they
need no change.

## Config test failed — gateway running on the previous config

**Symptom:** you edited `.env` (or the subscription) and redeployed, but the change is not in
effect; `docker logs mihomo` shouts `!!! CONFIG REJECTED (render-failed)` or
`!!! CONFIG REJECTED (config-test-failed)`, and
`../syno-mihomo-gateway-data/config/.config.yaml.rejected` exists.

**Cause:** the entrypoint gate renders every candidate config to a temp file and tests it with
`mihomo -t` before activating it. Your last edit produced a config that failed the render
(e.g. a backtick in or a malformed/missing `COUNTRY_GROUPS` spec, missing DNS, a `DNS_*` entry
detouring `#some-group` that no longer renders, or a leftover retired filter-knob line — the
error names the exact lines to delete) or failed the config test (e.g. an invalid
`COUNTRY_GROUPS` regex — an unguarded pattern would otherwise panic mihomo and crash-loop the
gateway). Rather than take the LAN down, the gateway **keeps running the last-known-good
config**; your edit is simply not applied yet.

**Fix:** read the marker — its first line names the failing stage, the rest is that stage's
output (with the subscription URL and controller secret scrubbed):

```bash
cat ../syno-mihomo-gateway-data/config/.config.yaml.rejected
```

Correct the named `.env` key (or subscription line), then **Redeploy**
(`sudo sh ./install.sh`) or
`docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo`.
A green render activates the new config and removes the marker automatically. On a **first
boot** (no previous config) the container fails hard instead of falling back — fix the config
and recreate.

The **doctor** reports this state on every pass while the marker exists: the
`config_rejected` check shows `render-failed`/`config-test-failed` (result BROKEN, also in
`gateway.sh doctor --json`), returning to ok after the next green redeploy. Note that the
scheduled auto-update's health gate does **not** read the marker — a gateway running on its
last-good config looks healthy to it — so an on-demand doctor run (installer menu 5, or
`gateway.sh doctor`) is what surfaces a rejected edit.
