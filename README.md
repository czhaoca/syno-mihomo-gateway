# Syno-Mihomo-Gateway (Synology DSM Transparent Proxy)

[中文文档 (Chinese Docs)](docs/README_ZH.md)

A "git-pull-and-run" way to deploy **Mihomo (Clash Meta)** on a Synology NAS as a transparent
gateway. Any device at home (Apple TV, iPhone, consoles) can route through it just by setting its
gateway/DNS to the container's LAN IP — no client software. **MetaCubeXD** provides a web
dashboard. Built for **mainland China**: image updates flow Docker Hub/ghcr → Alibaba ACR →
your NAS, and a DSM-scheduled job keeps everything current and safely self-healing.

## Features
- 🚀 **Automated setup** — auto-detects the Synology interface (`eth0` / `ovs_eth0`).
- 🛡️ **Safe & isolated** — Docker macvlan; its own LAN IP, doesn't disturb host networking.
- 🧹 **Controlled redeploys** — independently reuse, safely dismantle, or manually handle
  existing gateway containers and macvlan.
- 🔧 **Everything in `.env`** — IPs, ports, DNS, registry; no secrets or DNS hardcoded in the repo.
- 🔁 **Decoupled subscription** — your provider URL lives in one gitignored file.
- 🤖 **Safe auto-updates** — pulls from Alibaba ACR, digest-detected, health-gated with
  auto-rollback; blue-green for an external cloudflared (tunnel token preserved).

## Documentation

| Guide | What's inside |
|---|---|
| [Architecture](docs/architecture.md) | components, the mirror→pull pipeline, the macvlan model, the safety model |
| [Installation](docs/installation.md) | full DSM walkthrough (SSH, network, first run, dashboard) |
| [Release Zip](docs/release-packaging.md) | offline install where GitHub is blocked: build a zip, unpack on the NAS, no git |
| [Configuration](docs/configuration.md) | **complete `.env` reference**, template, subscription, rules |
| [Auto-Update](docs/auto-update.md) | ACR setup, the run sequence, health-gate/rollback, cloudflared blue-green, exit codes |
| [Operations](docs/operations.md) | runbook: scheduling, dry-run, kill-switch, logs, notifications, rollback |
| [CLI Reference](docs/cli.md) | `gateway.sh` verbs, options, guardrails, exit codes (generated from `scripts/cli/spec.yaml`) |
| [Troubleshooting](docs/troubleshooting.md) | FAQ + exit codes + concrete failure fixes |
| [Development](docs/development.md) | internals (scripts, renderer, CI), coding rules, how to extend |

---

## Quick Start

> Condensed; see [Installation](docs/installation.md) for the detailed walkthrough and
> [Configuration](docs/configuration.md) for every setting.
>
> **No GitHub on the NAS (mainland China)?** Use the
> [release zip](docs/release-packaging.md) instead of step 1's clone.

```bash
# 1. Clone (on the NAS, over SSH)
cd /volume1/docker
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway

# 2. Create persistent runtime data beside the release directory
sh bootstrap.sh
vi ../syno-mihomo-gateway-data/.env       # set ROUTER_IP, MIHOMO_IP, DNS, (China) ACR creds + image refs

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
images to Alibaba ACR nightly, and `scripts/auto_update.sh` (run as root by DSM Task Scheduler)
pulls, verifies, and redeploys only what changed. Compose v2 applies the checked local image with
`--pull never`; apply or health failure triggers rollback. External cloudflared uses blue-green.
Print the scheduler settings with
`sh scripts/install_scheduler.sh` and dry-run with `sh scripts/auto_update.sh --dry-run`.
Full details: [Auto-Update](docs/auto-update.md) · [Operations](docs/operations.md).

## Maintenance

```bash
# update subscription
vi ../syno-mihomo-gateway-data/config/subscription.txt
sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d mihomo

# update the repo
git pull && sudo sh ./install.sh
```

See [Operations](docs/operations.md) for the full runbook.
