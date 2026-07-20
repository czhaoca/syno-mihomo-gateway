# Installation — Generic Linux & Raspberry Pi

[← README](../README.md) · [中文](zh/installation-linux.md)
Platform addendum: **generic Linux & Raspberry Pi**. The Synology DSM walkthrough is
[Installation](installation.md); the pages it links (Configuration, Auto-Update,
Troubleshooting…) apply to these hosts too unless this page says otherwise.

---

No Synology hardware? The gateway was born on a Synology NAS, but it also runs on **any
Docker-capable Linux host (amd64 + arm64)** — a mini-PC, a home-lab VM, an arm64 board, or a
**Raspberry Pi** — via its own additive installers:

```bash
sudo sh ./install-linux.sh   # generic Linux host (amd64 / arm64)
sudo sh ./install-pi.sh      # Raspberry Pi (same engine + the Pi hardware wizard)
```

The DSM path is untouched — `install.sh` stays Synology-only; both entries reuse the same
underlying machinery. On a Raspberry Pi use `install-pi.sh` (it knows the board tiers below);
on everything else use `install-linux.sh`. Two install **modes** cover the hardware range:

- **Compose mode** — the same Docker stack as on DSM (mihomo + metacubexd containers,
  macvlan, digest-gated auto-updates with health gate and rollback). Preferred wherever the
  hardware allows, because the mature update safety model lives here.
- **Lite mode (bare metal)** — no Docker at all: the native mihomo binary runs under a
  systemd unit and serves the MetaCubeXD dashboard itself (`external-ui`). This is what makes
  small boards viable — and it is the sanctioned answer on
  [macvlan-hostile hosts](#macvlan-hostile-hosts-cloud--vm) (cloud VMs, Wi-Fi-only boxes).

## Support tiers

This matrix is **canonical** — the README and other pages link here rather than restating it.

| Platform | Tier | What that means |
|---|---|---|
| **Synology DSM (NAS)** | **Required owner validation** | The canonical deployment. Every release is validated on real NAS hardware before it is tagged; the DSM test suites are frozen gates. |
| **Raspberry Pi** | Experimental | Works and is CI-covered, but releases are not validated on Pi hardware; support is best-effort. |
| **Generic Linux (amd64 + arm64)** | Experimental | Same tier as the Pi: CI-covered, community/best-effort, no per-release hardware validation. |

## Hardware & mode matrix

This section is **canonical** — other pages link here rather than restating it.

**Generic hosts:** any 64-bit (amd64/arm64) machine with ≥ 1 GB RAM and wired Ethernet
handles compose mode; smaller or Wi-Fi-only hosts, and
[macvlan-hostile environments](#macvlan-hostile-hosts-cloud--vm), use lite mode. The RAM
floors below apply to any Linux host, not just Pis.

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
| Dashboard | metacubexd container | mihomo serves it at `http://<host-IP>:<CONTROLLER_PORT>/ui` |
| Network model | macvlan — the gateway gets its **own** LAN IP | host bind — the **host's own IP** is the clients' gateway/DNS |
| NIC | **wired Ethernet required** (macvlan breaks on Wi-Fi) | Ethernet or Wi-Fi |
| OS | **64-bit required** (no 32-bit dashboard image exists) | 64-bit or 32-bit (armv7/armv6 binaries) |
| RAM | ≥ 1 GB minimum, ≥ 2 GB comfortable | ≈ 256 MB tuned, 512 MB comfortable |
| Auto-update | `scripts/auto_update.sh`, unchanged (digest gate → health gate → rollback) | `scripts/pi/auto_update_lite.sh` (verify ladder → health gate → `.prev` rollback) |

### Raspberry Pi models

Per-model verdicts (`install-pi.sh` detects the board and recommends accordingly). This
table ranks **Pi hardware** for the gateway role; release-level support for every Pi is the
[Support tiers](#support-tiers) matrix above:

| Tier | Models | Verdict |
|---|---|---|
| Not suitable for whole-home duty | Pi 1 A/B/B+ (ARMv6, 256–512 MB) | No container images exist for ARMv6, crypto tops out around 30–40 Mbps, and the NIC is absent or USB2-bound. Lite mode runs, but only behind the explicit [best-effort acknowledgment](#armv6-boards-best-effort-only). |
| Best-effort, lite only | Pi Zero / Zero W (ARMv6); Pi Zero 2 W (512 MB, Wi-Fi only); Pi 2B (1 GB, armv7, 100 Mbps NIC) | Native binary + built-in dashboard. The Zero 2 W is the nicest of these (ARMv8 quad-core) but its 512 MB and Wi-Fi-only NIC keep it in lite mode. |
| Capable (with tuning) | Pi 3B / 3B+ (1 GB) | Compose works on a **64-bit OS** with low-RAM tuning (`.mrs` rule-sets, zram); lite mode maximizes headroom. The installer offers both. |
| Recommended | Pi 4B with ≥ 2 GB (true Gigabit Ethernet) | The DSM topology unchanged — compose + TUN + macvlan, no tuning needed. |
| Overkill | Pi 5 | Effortless. |

Throughput expectations (ballpark upper bounds — a transparent gateway does roughly double
crypto work, so real-world numbers land below these): ARMv6 ~30–40 Mbps (cannot fill a
100 Mbps line); quad-A53 class (Pi 3, Zero 2 W) ~270 Mbps; Pi 4B ~760 Mbps — the first tier
that saturates Gigabit-adjacent lines. Any recent amd64 mini-PC or NUC-class box clears
Gigabit with headroom.

**Early Pi verdict (the short answer):** ARMv6 boards are **not OK** for whole-home gateway
duty. The first genuinely OK models are the Pi 2B (lite, best-effort) and the Pi 3B/3B+
(capable, compose on a 64-bit OS with tuning); a Pi 4B ≥ 2 GB is the recommended
sweet spot.

## Macvlan-hostile hosts (cloud / VM)

Compose mode puts the gateway on a **macvlan** child interface with its own LAN IP — and
that only works where the network fabric delivers frames for a second, unknown MAC on the
port: cloud VPCs (AWS/GCP/Alibaba/…) filter unknown source MACs, and some hypervisor
vswitches drop them. `install-linux.sh` therefore runs a **macvlan-viability guard**: when it
detects a virtualized/cloud host (via `systemd-detect-virt`, with a DMI fallback) it warns,
recommends lite mode, and requires an explicit acknowledgment (default **No**) before any
macvlan deploy — declining at deploy time steers the install into lite mode instead of
aborting, while on the redeploy/Modify paths a decline **aborts before anything is torn
down**, leaving the existing deployment intact (switching an installed stack to lite goes
through **Deploy**'s mode wizard). The detection is a heuristic by design: a bridged home-lab VM (Proxmox/ESXi with
an open vswitch) where macvlan works fine may still trip it — acknowledge the warning there
and deploy compose as usual. See
[Troubleshooting](troubleshooting.md#generic-linux-macvlan-hostile-host-cloud-vm--vpc--wi-fi).

## Prerequisites

1. A **systemd-based Linux** (Raspberry Pi OS or another Debian-family distro is the tested
   path). For compose mode the OS must be **64-bit**.
2. **Root / sudo** — deployment needs the TUN device, port 53, and (compose mode) Docker.
3. `curl` or `wget`. Lite mode resolves *latest* release tags with `curl` specifically —
   for both the mihomo binary and the dashboard. A `MIHOMO_VERSION` pin covers only the
   binary: on a `curl`-less host, also pre-place the dashboard archive
   (`../syno-mihomo-gateway-data/ui/compressed-dist.tgz` — see the
   [offline sideload](#gh_mirror-and-offline-sideload)) or install `curl`.
4. **Compose mode only:** Docker Engine + compose v2, **wired Ethernet**, and a
   [macvlan-viable network](#macvlan-hostile-hosts-cloud--vm).
5. Get the code onto the host — `git clone` or the offline
   [release zip](release-packaging.md). Unlike DSM there is **no required location**: any
   writable directory works (the installer checks writability, nothing else).
6. **Automatic updates only:** a system cron that reads `/etc/crontab` (present by default
   on Debian-family distros incl. Raspberry Pi OS; install `cron`/`cronie` on distros that
   ship without one — menu item 3 fails loudly when `/etc/crontab` is absent).

## Run the installer

```bash
sudo sh ./install-linux.sh   # on a Raspberry Pi: sudo sh ./install-pi.sh
```

The first screen picks the UI language (persisted as `INSTALLER_LANG`), exactly like the DSM
installer, and the menu has the same six items — **Deploy / Redeploy / Cron / Modify /
Status / Quit** — under a live status banner. Beyond the DSM flow, these entries add:

- **Deploy** starts with a **hardware banner + mode wizard**: it reads the machine (on a Pi,
  the board model), usable memory, and CPU architecture, then recommends a mode — ≥ 2 GB
  class → compose; ~1 GB class → compose with a low-RAM-tuning note (lite offered); 512 MB
  class or any 32-bit OS → lite; ARMv6 additionally requires the explicit best-effort
  acknowledgment. You can override the recommendation (where the hardware allows a choice).
  On `install-linux.sh` the [macvlan-viability guard](#macvlan-hostile-hosts-cloud--vm) runs
  between the wizard and a compose deploy.
- **The image-source wizard defaults differ per entry** (compose mode): `install-linux.sh`
  offers **`REGISTRY_MODE=docker`** (upstream Docker Hub / ghcr.io multi-arch manifests) as
  the default — the right choice outside mainland China, no mirror pipeline needed — with
  `acr` selectable for mainland-China users (plus the arm64 mirroring notice below).
  `install-pi.sh` keeps the DSM-style `acr` default. Either way the choice lands only in
  your gitignored `.env`.
- **Status** dispatches on the recorded install mode: on a lite box it reports through
  [`lite_ctl`](#day-2-operations-lite_ctl) instead of inspecting containers.

The chosen flavor is recorded in `../syno-mihomo-gateway-data/state/install-mode`
(the marker tokens keep their `pi-compose` / `pi-lite` names on every entry); runtime data
lives in the same sibling `../syno-mihomo-gateway-data` directory as on DSM.

## Compose mode

The deploy itself is the unchanged DSM pipeline — interface scan, express confirmation,
validation before teardown, health-gated start with rollback — so the
[Installation](installation.md) walkthrough applies verbatim from the deploy step on. The
generic/Pi wrapper adds four guards up front:

- **`EXPECTED_ARCH` is pinned to the host automatically** (the seeded default `amd64` would
  otherwise fail the arch gate on every arm64 host). See
  [Auto-Update › architecture guard](auto-update.md#architecture-guard).
- **The macvlan-viability guard** (`install-linux.sh` only) — see
  [Macvlan-hostile hosts](#macvlan-hostile-hosts-cloud--vm).
- **ACR arm64 prerequisite (read before your first pull if you pick `acr`).** The default
  [docker-china-sync](https://github.com/czhaoca/docker-china-sync) pipeline mirrors
  **amd64 only** — so on an arm64 host your ACR namespace must mirror arm64 images
  **before** the first deploy, or every pull lands an image the arch guard refuses.
  Actionable fix: add arm64 to your mirror list (`--platform=linux/amd64,linux/arm64`
  against each image in `docker-china-sync/images.txt`), let a sync cycle run, then deploy.
  The installer prints this notice before anything is pulled. On an unfiltered network,
  `REGISTRY_MODE=docker` (upstream multi-arch manifests — the `install-linux.sh` default)
  works out of the box instead.
- **Wi-Fi is refused as the macvlan parent.** Wi-Fi drivers and AP client isolation
  typically break macvlan children, so compose mode requires **wired Ethernet**; the
  installer refuses a `wl*` parent interface everywhere a network can be (re)created. Use
  lite mode on a Wi-Fi-only box.

Everything after deploy — dashboard access from a non-host device, pointing clients at
`MIHOMO_IP`, the [auto-updater](auto-update.md) — behaves exactly as documented for DSM.

## Lite mode (bare metal)

Lite mode runs mihomo as a **native binary under systemd** — no Docker, no macvlan. mihomo
binds the host's interfaces directly: clients use the **host's own IP** as gateway/DNS, and
the dashboard is served by mihomo itself at `http://<host-IP>:<CONTROLLER_PORT>/ui` (default
port `9090`).

The wizard asks for: controller port and dashboard secret (same keep/`-`-to-clear semantics
as the DSM installer), the two DNS lists (bootstrap + domestic; the split-horizon pair ships
pre-set in `.env` and is not prompted), timezone, then the lite-only artifact settings —
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
URL is prefixed with it (`<mirror>/<full-upstream-url>`); empty means direct. The wizard
suggests this at the prompt. Pick your own mirror host — a public
gh-proxy instance or one you run; the choice stays in your gitignored `.env`. When your
downloads ride a third-party mirror, pin `MIHOMO_VERSION` **and** set `MIHOMO_SHA256`
(upstream publishes no checksums; the pin + sha256 anchor is what makes a tampering mirror a
hard failure instead of a silent wrong binary).

**Fully offline sideload** (mirrors the DSM [release-zip](release-packaging.md) pattern):
download on a machine that can, pre-place the files under the data directory, and the
installer/updater uses them instead of downloading — the same verify ladder still applies:

```
../syno-mihomo-gateway-data/bin/mihomo-linux-<arch>-<tag>.gz   # arch: amd64|arm64|armv7|armv6
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
- `update` — runs the
  [lite binary updater](auto-update.md#lite-mode-binary-updater-generic-linux--raspberry-pi)
  in the foreground with the same flags cron uses.

## Automatic updates

Menu item **3 (Cron)** schedules the updater for **either** flavor — there is no DSM Task
Scheduler on these hosts, so it manages one line in `/etc/crontab` (the file must already
exist — see [Prerequisites](#prerequisites); kept idempotent:
re-running with a new time replaces the managed line, foreign lines are never touched). It
asks for a daily `HH:MM`, the updater timezone, and the `UPDATE_ENABLED` kill-switch, then
installs the entry for the recorded install mode — `scripts/auto_update.sh` (compose,
unchanged from DSM) or `scripts/pi/auto_update_lite.sh` (lite) — and offers an immediate
`--dry-run`.

The lite updater mirrors the compose updater's operational contract — lock, kill-switch,
`--dry-run`/`--force`, rotating log, last-run JSON, notifications, exit codes — and rolls
back to the previous binary (and previous version state) when the new one fails the health
gate, so a bad release retries cleanly on the next scheduled run. Details:
[Auto-Update › Lite-mode binary updater](auto-update.md#lite-mode-binary-updater-generic-linux--raspberry-pi).

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

Platform-specific entries live in the main guide: [macvlan-hostile host (cloud VM / VPC /
Wi-Fi)](troubleshooting.md#generic-linux-macvlan-hostile-host-cloud-vm--vpc--wi-fi) ·
[ACR image not mirrored for
arm64](troubleshooting.md#pi-acr-image-not-mirrored-for-arm64) · [lite update rolled
back](troubleshooting.md#pi-lite-update-rolled-back) · [macvlan on Wi-Fi
refused](troubleshooting.md#pi-macvlan-on-wi-fi-wlan0-refused) · [port 53 already in
use](troubleshooting.md#pi-lite-port-53-already-in-use). Everything not platform-specific
(DNS symptoms, subscription, dashboard) is the same gateway — the whole
[Troubleshooting](troubleshooting.md) guide applies.
