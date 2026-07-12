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
`run install.sh and choose automatic or manual network cleanup`; or the updater preflight aborts
(code `3`) with `macvlan parent mismatch: network='…' live='…'` or
`macvlan configuration drift: expected parent=… subnet=… gateway=…`.

**Cause:** the existing docker network's parent/subnet/gateway no longer match `.env` or the live
routing — typically the parent interface changed (`eth0` ↔ `ovs_eth0`) or `SUBNET_CIDR`/`ROUTER_IP`
was edited. The scripts refuse to delete a mismatched network implicitly.

**Fix:** re-run `sh ./install.sh` and choose automatic (or manual) network cleanup when prompted.
Or, if you are sure nothing else uses the network, remove it yourself (stop attached containers
first): `docker network rm tproxy_network && sudo ./scripts/setup_network.sh`, then redeploy.

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
- **Empty/garbled subscription or DNS** — the renderer fails loudly:
  `ERROR: subscription.txt has no usable URL` or `ERROR: DNS_… must be set`. Fix the **live**
  files `../syno-mihomo-gateway-data/config/subscription.txt` / the `DNS_*` keys in
  `../syno-mihomo-gateway-data/.env` (the in-repo `config/` only ships the `.example`), then
  `docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo`.
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
[Installation — Raspberry Pi](installation-pi.md#compose-mode-on-a-pi).

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

**Fix:** set `DNS_GEOIP_NO_RESOLVE=false` in `.env` and redeploy — the rule resolves unlisted
domains via the domestic resolvers again, which is the privacy residual documented in the
[configuration DNS matrix](configuration.md#dns-injected-into-the-config-template).

## Upgrading from a legacy flat install

**Symptom:** after unpacking a release next to an old everything-in-one-folder install,
`doctor` reports `.env is missing`, and a preserve-mode deploy is refused because the existing
`mihomo`/`mihomo-ui` containers belong to a **foreign/legacy Compose project**
(`foreign_project` cleanup reason).

**Fix:** run `sudo sh scripts/migrate_legacy.sh --yes` first (auto-detects the legacy dir;
`--from DIR` / `--dry-run` supported) — it copies the subscription, geo databases and
`cache.db` into the data dir and prints `.env` hints, never touching the legacy install.
Then `sudo sh ./install.sh` → deploy, choosing **automatic cleanup** when the planner flags
the legacy containers, so the new stack takes over the container names.

## Provider has no nodes (foreign sites dead, node list empty)

**Symptom:** the dashboard's Proxies view shows only `auto` / `DIRECT` / `REJECT` — no airport
nodes — foreign sites time out while domestic sites stay fine, and the mihomo log repeats
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
