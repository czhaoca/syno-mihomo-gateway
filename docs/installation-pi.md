# Installation — Raspberry Pi

[← README](../README.md) · [中文](zh/installation-pi.md)
Platform addendum: **Raspberry Pi / generic Linux**. The Synology DSM walkthrough is
[Installation](installation.md); the pages it links (Configuration, Auto-Update,
Troubleshooting…) apply to the Pi too unless this page says otherwise.

---

No Synology hardware? The gateway also runs on a **Raspberry Pi** (or any Debian-family
Linux box with systemd) via its own additive installer:

```bash
sudo sh ./install-pi.sh
```

The DSM path is untouched — `install.sh` stays Synology-only, `install-pi.sh` reuses the same
underlying machinery. Two install **modes** cover the hardware range:

- **Compose mode** — the same Docker stack as on DSM (mihomo + metacubexd containers,
  macvlan, digest-gated auto-updates with health gate and rollback). Preferred wherever the
  hardware allows, because the mature update safety model lives here.
- **Lite mode (bare metal)** — no Docker at all: the native mihomo binary runs under a
  systemd unit and serves the MetaCubeXD dashboard itself (`external-ui`). This is what makes
  the 512 MB tier (and, best-effort, ARMv6 boards) viable.

## Hardware & mode matrix

This section is **canonical** — other pages link here rather than restating it.

**Minimum RAM:** lite mode ≈ **256 MB tuned / 512 MB comfortable**; compose mode
**≥ 1 GB minimum (tuned) / ≥ 2 GB comfortable**. Basis: mihomo holds ~60–100 MB RSS steady
with TUN + fake-ip, Raspberry Pi OS Lite idles at ~100–125 MB, and dockerd + containerd add
another ~140–180 MB in compose mode — the compose stack totals roughly 450–550 MB before
client load. The biggest low-RAM levers are `.mrs` rule-sets and skipping Docker entirely
(see [Low-RAM operations](#low-ram-operations)).

> The 256/512 MB figures are projected from mihomo RSS measurements, not yet validated on
> real 512 MB hardware under sustained client load — treat the lite floor as guidance and
> leave headroom (zram helps absorb the geodata-load spike).

| | Compose mode | Lite mode |
|---|---|---|
| Engine | Docker compose (same stack as DSM) | native mihomo binary + systemd |
| Dashboard | metacubexd container | mihomo serves it at `http://<Pi-IP>:<CONTROLLER_PORT>/ui` |
| Network model | macvlan — the gateway gets its **own** LAN IP | host bind — the **Pi's own IP** is the clients' gateway/DNS |
| NIC | **wired Ethernet required** (macvlan breaks on Wi-Fi) | Ethernet or Wi-Fi |
| OS | **64-bit required** (no 32-bit dashboard image exists) | 64-bit or 32-bit (armv7/armv6 binaries) |
| RAM | ≥ 1 GB minimum, ≥ 2 GB comfortable | ≈ 256 MB tuned, 512 MB comfortable |
| Auto-update | `scripts/auto_update.sh`, unchanged (digest gate → health gate → rollback) | `scripts/pi/auto_update_lite.sh` (verify ladder → health gate → `.prev` rollback) |

Per-model verdicts (the installer detects the board and recommends accordingly):

| Tier | Models | Verdict |
|---|---|---|
| Not suitable for whole-home duty | Pi 1 A/B/B+ (ARMv6, 256–512 MB) | No container images exist for ARMv6, crypto tops out around 30–40 Mbps, and the NIC is absent or USB2-bound. Lite mode runs, but only behind the explicit [best-effort acknowledgment](#armv6-boards-best-effort-only). |
| Best-effort, lite only | Pi Zero / Zero W (ARMv6); Pi Zero 2 W (512 MB, Wi-Fi only); Pi 2B (1 GB, armv7, 100 Mbps NIC) | Native binary + built-in dashboard. The Zero 2 W is the nicest of these (ARMv8 quad-core) but its 512 MB and Wi-Fi-only NIC keep it in lite mode. |
| Officially supported | Pi 3B / 3B+ (1 GB) | Compose works on a **64-bit OS** with low-RAM tuning (`.mrs` rule-sets, zram); lite mode maximizes headroom. The installer offers both. |
| Recommended | Pi 4B with ≥ 2 GB (true Gigabit Ethernet) | The DSM topology unchanged — compose + TUN + macvlan, no tuning needed. |
| Overkill | Pi 5 | Effortless. |

Throughput expectations (ballpark upper bounds — a transparent gateway does roughly double
crypto work, so real-world numbers land below these): ARMv6 ~30–40 Mbps (cannot fill a
100 Mbps line); quad-A53 class (Pi 3, Zero 2 W) ~270 Mbps; Pi 4B ~760 Mbps — the first tier
that saturates Gigabit-adjacent lines.

**Early Pi verdict (the short answer):** ARMv6 boards are **not OK** for whole-home gateway
duty. The first genuinely OK models are the Pi 2B (lite, best-effort) and the Pi 3B/3B+
(officially supported, compose-capable on a 64-bit OS); a Pi 4B ≥ 2 GB is the recommended
sweet spot.

## Prerequisites

1. **Raspberry Pi OS** (or another Debian-family distro) **with systemd**. For compose mode
   the OS must be **64-bit**.
2. **Root / sudo** — deployment needs the TUN device, port 53, and (compose mode) Docker.
3. `curl` or `wget`. Resolving the *latest* mihomo release tag in lite mode needs `curl`
   specifically — or pin `MIHOMO_VERSION` and either works.
4. **Compose mode only:** Docker Engine + compose v2, and **wired Ethernet**.
5. Get the code onto the Pi — `git clone` or the offline
   [release zip](release-packaging.md). Unlike DSM there is **no required location**: any
   writable directory works (the installer checks writability, nothing else).

## Run the installer

```bash
sudo sh ./install-pi.sh
```

The first screen picks the UI language (persisted as `INSTALLER_LANG`), exactly like the DSM
installer, and the menu has the same six items — **Deploy / Redeploy / Cron / Modify /
Status / Quit** — under a live status banner. Two things are Pi-specific:

- **Deploy** starts with a **hardware banner + mode wizard**: it reads the board model,
  usable memory, and CPU architecture, then recommends a mode — ≥ 2 GB class → compose;
  ~1 GB class → compose with a low-RAM-tuning note (lite offered); 512 MB class or any
  32-bit OS → lite; ARMv6 additionally requires the explicit best-effort acknowledgment.
  You can override the recommendation (where the hardware allows a choice).
- **Status** dispatches on the recorded install mode: on a lite box it reports through
  [`lite_ctl`](#day-2-operations-lite_ctl) instead of inspecting containers.

The chosen flavor is recorded in `../syno-mihomo-gateway-data/state/install-mode`
(`pi-compose` or `pi-lite`); runtime data lives in the same sibling
`../syno-mihomo-gateway-data` directory as on DSM.

## Compose mode on a Pi

The deploy itself is the unchanged DSM pipeline — interface scan, express confirmation,
validation before teardown, health-gated start with rollback — so the
[Installation](installation.md) walkthrough applies verbatim from the deploy step on. The
Pi wrapper adds three guards up front:

- **`EXPECTED_ARCH` is pinned to the host automatically** (the seeded default `amd64` would
  otherwise fail the arch gate on every Pi). See
  [Auto-Update › architecture guard](auto-update.md#architecture-guard).
- **ACR arm64 prerequisite (read before your first pull).** `REGISTRY_MODE=acr` stays the
  default on the Pi, and the default
  [docker-china-sync](https://github.com/czhaoca/docker-china-sync) pipeline mirrors
  **amd64 only** — so on an ARM Pi your ACR namespace must mirror arm64 images **before**
  the first deploy, or every pull lands an image the arch guard refuses. Actionable fix: add
  arm64 to your mirror list (`--platform=linux/amd64,linux/arm64` against each image in
  `docker-china-sync/images.txt`), let a sync cycle run, then deploy. The installer prints
  this notice before anything is pulled. On an unfiltered network, `REGISTRY_MODE=docker`
  (upstream multi-arch manifests) works out of the box instead.
- **Wi-Fi is refused as the macvlan parent.** Wi-Fi drivers and AP client isolation
  typically break macvlan children, so compose mode requires **wired Ethernet**; the
  installer refuses a `wl*` parent interface everywhere a network can be (re)created. Use
  lite mode on a Wi-Fi-only box.

Everything after deploy — dashboard access from a non-host device, pointing clients at
`MIHOMO_IP`, the [auto-updater](auto-update.md) — behaves exactly as documented for DSM.

## Lite mode (bare metal)

Lite mode runs mihomo as a **native binary under systemd** — no Docker, no macvlan. mihomo
binds the Pi's interfaces directly: clients use the **Pi's own IP** as gateway/DNS, and the
dashboard is served by mihomo itself at `http://<Pi-IP>:<CONTROLLER_PORT>/ui` (default port
`9090`).

The wizard asks for: controller port and dashboard secret (same keep/`-`-to-clear semantics
as the DSM installer), the three DNS lists, timezone, then the lite-only artifact settings —
[`GH_MIRROR`](#gh_mirror-and-offline-sideload), an optional `MIHOMO_VERSION` pin, and (only
alongside a pin) an optional `MIHOMO_SHA256` integrity anchor. Your subscription is prompted
with the stock subscription wizard. If something else already listens on port 53 (a stock
resolver — see [Troubleshooting](troubleshooting.md#pi-lite-port-53-already-in-use)), the
wizard warns immediately rather than letting the first start fail mysteriously.

The install then runs fail-fast, nothing half-installed on error:

1. **Render the config first** — the same CI-tested renderer the containers use; a missing
   subscription or DNS value aborts before anything is downloaded.
2. **Resolve the release tag** — the `MIHOMO_VERSION` pin verbatim, else the
   `releases/latest` redirect followed *through* `GH_MIRROR`.
3. **Fetch + verify the binary** — fail-closed ladder: optional pinned sha256 → gzip
   integrity → execute-and-print-version smoke test → the reported version must match the
   tag. Only then is it moved into place (`bin/mihomo`), with the tag recorded in
   `state/lite/version`.
4. **Fetch the dashboard** — MetaCubexD's versioned `compressed-dist.tgz` release asset,
   unpacked to `ui/metacubexd` (where the rendered config's `external-ui` points).
5. **Prefetch geodata** (best-effort) — through the same CDN mirror URLs the rendered config
   already carries; mihomo fetches them itself on first start if this fails.
6. **Install the systemd unit** — `/etc/systemd/system/mihomo-gateway.service` — then
   enable + start it and wait for the controller to answer.

The unit is minimal and regenerated by the installer (do not hand-edit): `Restart=always`,
and an `ExecStartPre` that **re-renders the config on every start** — so editing
`subscription.txt` or `.env` takes effect with a plain
`sudo sh scripts/pi/lite_ctl.sh stop && sudo sh scripts/pi/lite_ctl.sh start` (or
`systemctl restart mihomo-gateway`).

## `GH_MIRROR` and offline sideload

Lite-mode artifacts (the mihomo binary, the dashboard archive, the latest-tag resolution)
download from the upstream Git host, which many networks block. Two escape hatches:

**Mirror prefix.** Set `GH_MIRROR` in `.env` to a gh-proxy-style mirror and every download
URL is prefixed with it (`<mirror>/<full-upstream-url>`); empty means direct. The
Chinese-locale wizard suggests this at the prompt. Pick your own mirror host — a public
gh-proxy instance or one you run; the choice stays in your gitignored `.env`. When your
downloads ride a third-party mirror, pin `MIHOMO_VERSION` **and** set `MIHOMO_SHA256`
(upstream publishes no checksums; the pin + sha256 anchor is what makes a tampering mirror a
hard failure instead of a silent wrong binary).

**Fully offline sideload** (mirrors the DSM [release-zip](release-packaging.md) pattern):
download on a machine that can, pre-place the files under the data directory, and the
installer/updater uses them instead of downloading — the same verify ladder still applies:

```
../syno-mihomo-gateway-data/bin/mihomo-linux-<arch>-<tag>.gz   # arch: arm64|armv7|armv6
../syno-mihomo-gateway-data/ui/compressed-dist.tgz             # the MetaCubexD release asset
```

Set `MIHOMO_VERSION=<tag>` so no network tag-resolution is attempted (the binary filename
must carry that same tag, e.g. `mihomo-linux-arm64-v1.19.28.gz`).

## Day-2 operations: `lite_ctl`

Lite mode has no containers for `gateway.sh`/`doctor.sh` to inspect, so it ships its own
small CLI (the installer's **Status** menu item calls it for you on a lite box):

```bash
sh scripts/pi/lite_ctl.sh {status|doctor|start|stop|update [--dry-run|--force]}
```

- `status` — read-only snapshot: install mode, installed version, service state, last
  updater run, dashboard URL.
- `doctor` — read-only diagnostics mirroring `doctor.sh`'s vocabulary and exit codes:
  `0` HEALTHY / `2` DEGRADED / `3` BROKEN. Checks the `.env` parse, systemd and the unit,
  the managed binary and version state, subscription presence + a render check (in a
  throwaway directory — the live config is never touched), the controller probe and TUN
  link, port-53 occupancy (naming the conflicting process), and whether the auto-update
  cron entry is actually deployed.
- `start` / `stop` — root-gated wrappers over the systemd unit.
- `update` — runs the [lite binary updater](auto-update.md#raspberry-pi-lite-mode-binary-updater)
  in the foreground with the same flags cron uses.

## Automatic updates on a Pi

Menu item **3 (Cron)** schedules the updater for **either** flavor — there is no DSM Task
Scheduler here, so it manages one line in `/etc/crontab` (kept idempotent: re-running with a
new time replaces the managed line, foreign lines are never touched). It asks for a daily
`HH:MM`, the updater timezone, and the `UPDATE_ENABLED` kill-switch, then installs the entry
for the recorded install mode — `scripts/auto_update.sh` (compose, unchanged from DSM) or
`scripts/pi/auto_update_lite.sh` (lite) — and offers an immediate `--dry-run`.

The lite updater mirrors the compose updater's operational contract — lock, kill-switch,
`--dry-run`/`--force`, rotating log, last-run JSON, notifications, exit codes — and rolls
back to the previous binary (and previous version state) when the new one fails the health
gate, so a bad release retries cleanly on the next scheduled run. Details:
[Auto-Update › Raspberry Pi lite-mode binary updater](auto-update.md#raspberry-pi-lite-mode-binary-updater).

## Low-RAM operations

Documentation-level guidance for the 512 MB–1 GB tiers (none of this is automated by the
installer):

- **`.mrs` rule-sets** — the single biggest mihomo memory lever: binary-format rule-sets
  load in a fraction of the RAM of classical providers. Prefer `.mrs` in your subscription /
  rule-provider setup where available. mihomo's default `geodata-loader: memconservative`
  already trades speed for memory.
- **zram swap** — compressed in-RAM swap absorbs the geodata-load spike on 512 MB boards
  (`zram-tools` on Raspberry Pi OS / Debian).
- **Log hygiene on SD cards** — journald `Storage=volatile` (journal in RAM) and/or
  `log2ram` keep the gateway's chatty logs from wearing the SD card; the project's own logs
  rotate themselves (`LOG_KEEP`).
- **Skip the desktop OS image** — Raspberry Pi OS **Lite** idles ~100–125 MB; the desktop
  variant burns hundreds more.

## ARMv6 boards: best-effort only

Pi 1 / Zero / Zero W get a working lite install (upstream ships an armv6 binary), but only
behind an explicit acknowledgment in the wizard, because the result is a **lab/single-device
curiosity, not a whole-home gateway**: ~30–40 Mbps crypto throughput, no/USB2-bound NIC, and
no container images exist for ARMv6 at all (compose mode is impossible). Expect to accept
that trade-off knowingly; issues on ARMv6 are handled best-effort.

## Troubleshooting

Pi-specific entries live in the main guide: [ACR image not mirrored for
arm64](troubleshooting.md#pi-acr-image-not-mirrored-for-arm64) · [lite update rolled
back](troubleshooting.md#pi-lite-update-rolled-back) · [macvlan on Wi-Fi
refused](troubleshooting.md#pi-macvlan-on-wi-fi-wlan0-refused) · [port 53 already in
use](troubleshooting.md#pi-lite-port-53-already-in-use). Everything not Pi-specific (DNS
symptoms, subscription, dashboard) is the same gateway — the whole
[Troubleshooting](troubleshooting.md) guide applies.
