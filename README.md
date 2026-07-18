# Syno-Mihomo-Gateway (Transparent Proxy Gateway)

[中文文档 (Chinese Docs)](docs/README_ZH.md)

A "git-pull-and-run" way to deploy **Mihomo (Clash Meta)** as a transparent gateway — born on a
**Synology NAS**, and it runs on **any Docker-capable Linux host (amd64 + arm64)**, Raspberry Pi
included. Any device at home (Apple TV, iPhone, consoles) can route through it just by setting its
gateway/DNS to the container's LAN IP — no client software. **MetaCubeXD** provides a web
dashboard. The NAS remains the canonical, release-validated deployment (the other platforms are
experimental — [support tiers](docs/installation-linux.md#support-tiers)). Built for **mainland
China**: by default image updates flow Docker Hub/ghcr → Alibaba ACR → your NAS
(`REGISTRY_MODE=docker` opts in to pulling upstream directly on an unfiltered host), and a
DSM-scheduled job keeps everything current and safely self-healing.

## Features
- 🚀 **Automated setup** — auto-detects the Synology interface (`eth0` / `ovs_eth0`).
- 🛡️ **Safe & isolated** — Docker macvlan; its own LAN IP, doesn't disturb host networking.
- 🧹 **Controlled redeploys** — independently reuse, safely dismantle, or manually handle
  existing gateway containers and macvlan.
- 🔧 **Everything in `.env`** — IPs, ports, DNS, registry; no secrets committed, and the repo
  templates carry only neutral placeholder values.
- 🔁 **Decoupled subscription** — your provider URL lives in one gitignored file.
- 🤖 **Safe auto-updates** — digest-detected, health-gated with auto-rollback; pulls from Alibaba
  ACR by default (`REGISTRY_MODE=docker` pulls upstream directly); blue-green for an external
  cloudflared (tunnel token preserved).
- 📦 **Update any container** — enroll standalone containers (`gateway.sh update --enable NAME`);
  they ride the same scheduled job with spec capture/replay and rollback on a failed health gate.

## Documentation

| Guide | What's inside |
|---|---|
| [Architecture](docs/architecture.md) | components, the mirror→pull pipeline, the macvlan model, the safety model |
| [Installation](docs/installation.md) | full DSM walkthrough (SSH, network, first run, dashboard) |
| [Installation — Generic Linux & Raspberry Pi](docs/installation-linux.md) | no Synology? the generic Linux port (amd64 + arm64): compose parity or bare-metal lite, support tiers, the Pi hardware & RAM sizing matrix, mirror/offline installs |
| [Release Zip](docs/release-packaging.md) | offline install where GitHub is blocked: build a zip, unpack on the NAS, no git |
| [Configuration](docs/configuration.md) | **complete `.env` reference**, template, subscription, rules |
| [Auto-Update](docs/auto-update.md) | ACR setup, the run sequence, health-gate/rollback, generic enrolled targets, cloudflared blue-green, exit codes |
| [Operations](docs/operations.md) | runbook: scheduling, dry-run, kill-switch, logs, notifications, rollback |
| [CLI Reference](docs/cli.md) | `gateway.sh` verbs, options, guardrails, exit codes (generated from `scripts/cli/spec.yaml`) |
| [Troubleshooting](docs/troubleshooting.md) | FAQ + exit codes + concrete failure fixes |
| [Development](docs/development.md) | internals (scripts, renderer, CI), coding rules, how to extend |

---

## DSM compatibility

- **Minimum: DSM 7.2** (the Container Manager era). **Recommended: DSM 7.3.1+** (ships a newer
  Docker engine, ~24.x).
- The stack's containers are **visible** in Container Manager's *Container* tab, but the stack
  must **never** be managed from the *Project* tab: the UI's *Build/Update* flow re-pulls and
  recreates containers with **no digest gate, no health gate, and no rollback**, bypassing the
  safety model this project exists for. Container Manager also cannot create the macvlan network
  or manage privileged capabilities from its GUI, and CLI-created compose stacks do not appear as
  Projects anyway — the SSH installer (`sh ./install.sh`) and `scripts/gateway.sh` are the
  supported management surfaces.

## Quick Start

> Condensed; see [Installation](docs/installation.md) for the detailed walkthrough and
> [Configuration](docs/configuration.md) for every setting.
>
> **No GitHub on the NAS (mainland China)?** Use the
> [release zip](docs/release-packaging.md) instead of step 1's clone.
>
> **No Synology at all?** The gateway also runs on **any Docker-capable Linux host**
> (`sh ./install-linux.sh`) or a **Raspberry Pi** (`sh ./install-pi.sh`) — support tiers,
> hardware sizing, and walkthrough:
> [Installation — Generic Linux & Raspberry Pi](docs/installation-linux.md).

```bash
# 1. Clone (on the NAS, over SSH)
cd /volume1/docker
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway

# 2. Create persistent runtime data beside the release directory
sh bootstrap.sh
vi ../syno-mihomo-gateway-data/.env       # set ROUTER_IP, MIHOMO_IP, DNS, ACR creds + image refs (or REGISTRY_MODE=docker)

# 3. Subscription (outside the replaceable release tree)
vi ../syno-mihomo-gateway-data/config/subscription.txt

# 4. Network + TUN (root)
sudo chmod +x scripts/setup_network.sh && sudo ./scripts/setup_network.sh

# 5. Start
sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d
```

**Dashboard:** from a LAN device *other than the NAS*, open `http://<NAS_IP>:<WEB_UI_PORT>` and add
backend `Host=<MIHOMO_IP>`, `Port=<CONTROLLER_PORT>` (default `9090`), `Secret=<CONTROLLER_SECRET>`.

> **macvlan note:** the NAS host can't reach its own macvlan container IP — use another device for
> the dashboard and tests. See [Architecture](docs/architecture.md#network-model-macvlan).
>
> For guided installation or an existing/partial deployment, run `sudo sh ./install.sh`.
> Cleanup choices are applied only after all non-destructive validation succeeds.

## Client setup

- **Single device:** set its Router/Gateway and DNS to `MIHOMO_IP`.
- **Whole home:** announce `MIHOMO_IP` as the gateway in your router's DHCP. ⚠️ If the container
  stops, those devices lose internet.

## Automatic updates

Because Docker Hub/ghcr are blocked in China, [`docker-china-sync`](https://github.com/czhaoca/docker-china-sync) mirrors
images to Alibaba ACR nightly (the default source; `REGISTRY_MODE=docker` pulls upstream directly),
and `scripts/auto_update.sh` (run as root by DSM Task Scheduler) pulls, verifies, and redeploys
only what changed. Compose v2 applies the checked local image with `--pull never`; apply or health
failure triggers rollback. The same job also updates any **enrolled standalone container** (ACR
mode only): manage the list with `sudo sh scripts/gateway.sh update --enable NAME` /
`--disable NAME` / `--list-targets`, and inspect the last run with `update --last`. Targets apply
blast-radius first: generic containers, then cloudflared (blue-green, tunnel token preserved),
then the gateway pair last. Print the scheduler settings with `sh scripts/install_scheduler.sh`
and dry-run with `sudo sh scripts/auto_update.sh --dry-run`.

> **Reboot persistence:** the macvlan network and `/dev/net/tun` don't survive an NAS reboot on
> their own — add a second DSM task with the **Boot-up** trigger (user `root`) running
> `scripts/setup_network.sh` so they self-heal; `sh scripts/install_scheduler.sh` prints both
> task settings.

Full details: [Auto-Update](docs/auto-update.md) · [Operations](docs/operations.md).

## Maintenance

```bash
# update subscription (a re-render requires --force-recreate)
vi ../syno-mihomo-gateway-data/config/subscription.txt
sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo
# or in one step: sudo sh scripts/gateway.sh modify --subscription URL --yes

# health check (read-only; no root or --yes needed)
sh scripts/gateway.sh status    # snapshot (--json for scripts)
sh scripts/gateway.sh doctor    # full diagnostics (--egress probes real egress)

# update the repo
git pull && sudo sh ./install.sh
```

See [Operations](docs/operations.md) for the full runbook.
