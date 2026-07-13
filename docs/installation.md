# Installation

[← README](../README.md) · [中文](zh/installation.md)
Manual: [Architecture](architecture.md) · **Installation** · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · [Operations](operations.md) · [CLI](cli.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

---

This is the detailed walkthrough. For the condensed version see the
[README quick start](../README.md#quick-start).

## Prerequisites

1. **Synology NAS** on **DSM 7.2 or newer** (7.3.1+ recommended - newer Docker engine) with
   **Container Manager** installed (Package Center).
2. **SSH access** enabled: Control Panel → Terminal & SNMP → *Enable SSH service*.
3. **Root / sudo** — creating the macvlan network and the TUN device requires root.
4. An **x86_64 (Intel) NAS** is assumed by default (`EXPECTED_ARCH=amd64`). If your model is ARM,
   see [Auto-Update › architecture guard](auto-update.md#architecture-guard).
5. (China) An **Alibaba Container Registry (ACR)** namespace and the `docker-china-sync` mirror
   already pushing your images — see [Auto-Update › ACR setup](auto-update.md#acr-setup).

### Container Manager coexistence (important)

After deployment the containers show up in Container Manager's **Container** tab - that is fine
for viewing logs or state. Do **not** manage the stack from the **Project** tab, and never press
its *Build/Update* action: the UI flow re-pulls and recreates containers with no digest gate, no
health gate, and no rollback, bypassing this project's gated update path (`auto_update.sh`).
Container Manager's GUI also cannot create macvlan networks or manage privileged capabilities,
and a CLI-created compose stack does not register as a Project. Use `sh ./install.sh`,
`scripts/gateway.sh` (see the [CLI reference](cli.md)), or the scheduled updater instead.

## 1. Get the code

Pick the path that matches your network.

### Option A — git clone (you have GitHub access)

SSH into the NAS and clone into your docker share:

```bash
cd /volume1/docker
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway
```

### Option B — release zip (mainland China / no GitHub)

If the NAS cannot reach github.com, don't clone. Build a release zip on a machine that can,
transfer it to the NAS, and unpack it into `/volume1/docker/syno-mihomo-gateway` — then come back
here for steps 2-8. Full procedure: [Release Zip](release-packaging.md).

> The bundle **must** live under the Docker shared folder — any `/volumeN/docker`
> (`/volume1` is just the common case). This is a hard requirement, not a convention: the
> Docker daemon bind-mounts `./config` and `./scripts` from wherever `docker-compose.yml`
> sits. `install.sh` checks this first and refuses to proceed elsewhere, printing the exact
> `sudo mv` commands. The docs assume `/volume1/docker/syno-mihomo-gateway`; adjust the volume
> number to match yours.

## Choose an install path

- **Guided (recommended):** `sudo sh ./install.sh` — the interactive installer described next.
  It fills `.env` for you, validates everything before touching a running stack, and rolls
  back on failure.
- **Manual:** steps 2–8 below — edit `.env` yourself, run `setup_network.sh`, then drive
  `docker compose` directly.
- **Raspberry Pi (no Synology)?** This page is the DSM walkthrough — the Pi has its own
  additive installer (`sudo sh ./install-pi.sh`), a hardware/RAM sizing matrix, and a
  bare-metal mode for small boards: [Installation — Raspberry Pi](installation-pi.md).

### Guided install (recommended)

```bash
sudo sh ./install.sh
```

The first screen picks the UI language (English/中文, persisted as `INSTALLER_LANG`); every
later message renders in that language. The main menu has six items — **Deploy / Redeploy /
Cron / Modify / Status / Quit** — under a live status banner (not deployed / partial / running
with the gateway IP and dashboard URL). The **Status / diagnose** item is a read-only summary
of the containers, network, and TUN mode plus an optional `scripts/doctor.sh` run — so "is my
gateway up?" never requires starting a flow.

**Deploy** runs end-to-end:

- Its **first** step inventories the gateway containers and macvlan and asks independently
  whether to reuse them, dismantle verified project resources automatically, or show commands
  for manual handling — running this decision up front keeps the subsequent interface
  detection clean. Unrelated resources always require manual resolution; the external
  cloudflared container is never part of this cleanup.
- The interface scan lists only NICs that carry an IPv4 address and auto-fills `ROUTER_IP` /
  `SUBNET_CIDR` from the chosen one; the static-IP prompt suggests the next free address above
  the NAS's own IP (probed with arping/ping), and the chosen IP is conflict-probed again right
  before the network is created.
- When everything was detected (or saved from a previous run), a single **express
  confirmation screen** shows all values at once; declining it falls back to the per-item
  wizards. A saved `MIHOMO_IP` that falls outside a re-picked subnet is re-asked rather than
  silently kept.
- An empty `CONTROLLER_SECRET` triggers an offer to **auto-generate** one (declining is the
  explicit "leave the dashboard unauthenticated" opt-out). On a re-run, pressing Enter keeps
  the saved secret and `-` clears it.
- Teardown of an existing stack happens only **after** image, architecture, rendered-config,
  Compose, and network validation pass — a failed re-deploy never dismantles your running
  gateway. The deploy itself is health-gated with automatic rollback, and the success report
  points at menu option **3** (Cron) for scheduling automatic updates.

**Redeploy** is also the recovery path after an IP conflict or a failed first deploy: it
reuses everything saved in `.env`, offers *deploy as-is / edit settings / change `MIHOMO_IP` /
re-pick interface*, re-validates, then force-recreates with the same health-gated rollback.

If something fails, diagnostics point at the install log:
`../syno-mihomo-gateway-data/logs/install.log` (a link into the unified `gateway.log` when
`gateway.sh` ran first; otherwise its own file).
Ctrl-D quits any prompt cleanly; Ctrl-C mid-flow is safe — the temporary config staging
directory (which holds your subscription token) is removed, and any partial state is detected
and offered for cleanup by the next run's inventory step.

The rest of this page is the manual path.

## 2. Configure `.env`

```bash
sh bootstrap.sh
vi ../syno-mihomo-gateway-data/.env
```

At minimum set `ROUTER_IP`, `SUBNET_CIDR`, `MIHOMO_IP`, your DNS servers, and the image refs —
the refs are required for **every** install, not just China: `docker-compose.yml` uses the
fail-closed `${MIHOMO_IMAGE:?}` form, and `.env.example` ships non-pullable ACR placeholders
(`registry.cn-shenzhen.aliyuncs.com/your-namespace/...`). `REGISTRY_MODE` selects the image
source: `acr` (default) pulls from your private ACR mirror — set `DOCKER_REGISTRY`,
`ACR_NAMESPACE`, the `*_TAG`s, and credentials (see
[Auto-Update › ACR setup](auto-update.md#acr-setup)); `docker` pulls upstream (Docker Hub /
ghcr.io — only works on a NAS with unfiltered internet access). On the manual path, replace
the placeholder refs yourself; the guided installer derives them from `REGISTRY_MODE` for you.
Every key is documented in [Configuration](configuration.md). Runtime data is stored outside
the release directory so a ZIP upgrade cannot delete it. `bootstrap.sh` also migrates a legacy
in-tree `.env` automatically.

## 3. Add your subscription

```bash
vi ../syno-mihomo-gateway-data/config/subscription.txt
```

One line, `Name=URL`; the first valid line is used. The URL may contain `?token=…&flag=…` —
those `=`/`&` are handled correctly. The file is outside the repository, so your token is never
committed or replaced by an extracted release.

```text
Default=https://provider.example/api/v1/subscribe?token=REPLACE_ME&flag=1
```

## 4. Create the network + TUN device

```bash
sudo chmod +x scripts/setup_network.sh
sudo ./scripts/setup_network.sh
```

This headless script (it is also the DSM boot-up self-heal task):
- creates `/dev/net/tun` if missing and fixes its permissions;
- auto-detects the parent interface (the one that routes to `ROUTER_IP`; falls back to the
  default route);
- creates or reuses a matching `tproxy_network` (macvlan by default, ipvlan when
  `TPROXY_DRIVER=ipvlan`) with your `SUBNET_CIDR` / `ROUTER_IP`; it refuses to remove a mismatched
  existing network;
- brings the gateway stack up from local images if it is deployed but not running (it skips
  cleanly when the image refs are unset, no usable subscription exists, or the mihomo container
  was deliberately taken down); a start that genuinely fails exits `2`, so the DSM scheduler's
  failure email fires.

It performs **no registry login and no image pulls** — that happens in the guided installer's
deploy flow, or implicitly when `docker compose up` pulls missing images in step 5.

An **Open vSwitch** parent (`ovs_eth0`) prints a non-fatal heads-up on every network-creation
path: a macvlan child IS LAN-reachable on a typical OVS parent (verified empirically), but some
OVS configurations do not flood the child's fresh MAC to peer ports. Keep
`TPROXY_DRIVER=macvlan` — the guided installer additionally offers to switch to `ipvlan`
(default No), but that is a dashboard-only escape hatch: `ipvlan` cannot route LAN clients.
See [Troubleshooting](troubleshooting.md).

For first-time interactive setup or an existing/partial deployment, use the
[guided installer](#guided-install-recommended) instead — its up-front inventory step handles
the reuse/cleanup decisions safely.

## 5. Start the stack

```bash
sudo docker compose --env-file ../syno-mihomo-gateway-data/.env up -d
```

On start, the mihomo entrypoint renders a **candidate** config into the persistent data
directory (`../syno-mihomo-gateway-data/config/`, mounted at `/root/.config/mihomo` in the
container — not the release tree's `config/`) from the template + your subscription + `.env`,
tests it with `mihomo -t`, and only then activates it. If the render or the test fails (missing
subscription URL/DNS, or an invalid `AUTO_EXCLUDE_FILTER`/`COUNTRY_GROUPS` pattern), the
**previous** config keeps running and `.config.yaml.rejected` records why — on a first install
with no previous config it **fails loudly** instead (the container never runs a poisoned
config). Check logs:

```bash
docker logs mihomo
docker compose --env-file ../syno-mihomo-gateway-data/.env ps
sudo sh scripts/doctor.sh          # needs root; add --egress for a real GET through the proxy
```

At this point `doctor.sh` reports **DEGRADED** with two scheduler warnings — no scheduled task
runs `auto_update.sh`, and no Boot-up task runs `setup_network.sh`. That is expected on a fresh
install: both go away once you set up scheduling in step 8.

## 6. Open the dashboard

From a **LAN device that is not the NAS** (see the macvlan caveat in
[Architecture](architecture.md#network-model-macvlan)):

1. Browse to `http://<NAS_IP>:<WEB_UI_PORT>` (e.g. `http://192.168.1.10:8080`) — the **NAS** IP,
   not the mihomo IP.
2. Add backend: **Host** = `MIHOMO_IP` (e.g. `192.168.1.100`), **Port** = `CONTROLLER_PORT`
   (default `9090`), **Secret** = your `CONTROLLER_SECRET` (blank if empty).

## 7. Point devices at the gateway

- **Single device:** set its Router/Gateway **and DNS** to `MIHOMO_IP`.
- **Whole home:** announce `MIHOMO_IP` as **both the gateway AND the DNS server** via your
  router's DHCP — and make it the **only** DNS server (a router/ISP secondary silently takes
  over on any hiccup and re-leaks every lookup). Gateway-only DHCP is the classic
  half-deployment: traffic routes through mihomo but clients keep resolving at the router
  (same-subnet traffic the gateway never sees), so domain rules can't match, dnsleaktest
  still shows the domestic resolvers, and blocked sites break — see
  [Troubleshooting](troubleshooting.md#lan-clients-bypass-the-gateways-dns-dnsleaktest-still-shows-domestic-resolvers).
  Verify from a client after renewing its DHCP lease: `nslookup facebook.com` must return a
  `198.18.x.x` answer. Also disable IPv6 on the router's LAN — not just its DNS
  announcements — because the gateway is IPv4-only: a device holding a global IPv6 address
  resolves *and routes* around the gateway entirely (see
  [Troubleshooting](troubleshooting.md#dual-stack-ipv6-carries-traffic-around-the-gateway-leaks-persist-netflix-keeps-failing);
  `doctor` warns `ipv6_bypass: exposed` while the path exists). ⚠️ If the
  container stops, those devices lose internet — keep `restart: always` (default) and consider
  the boot-up network task below.

## 8. Enable automatic updates (recommended)

Set up the DSM Task Scheduler entries so images update themselves and the network self-heals
after a reboot. See [Operations › Scheduling](operations.md#scheduling-on-dsm); print the exact
settings with:

```bash
sh scripts/install_scheduler.sh
```

Dry-run first to confirm everything is wired:

```bash
sudo sh scripts/auto_update.sh --dry-run
```

## Updating the repo itself

```bash
cd /volume1/docker/syno-mihomo-gateway
git pull
sudo sh ./install.sh        # choose Redeploy; validates and force-recreates safely
```

Your `.env`, subscription, rendered config, and logs live in the sibling
`/volume1/docker/syno-mihomo-gateway-data` directory and are untouched by `git pull` or release
directory replacement.

> Installed via Option B (release zip)? There is no `git pull` — update by rebuilding and
> re-unpacking the zip: see
> [Release Zip › Updating an offline install](release-packaging.md#updating-an-offline-install).
