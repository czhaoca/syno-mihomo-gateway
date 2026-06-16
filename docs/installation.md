# Installation

[← README](../README.md) · [中文](zh/installation.md)
Manual: [Architecture](architecture.md) · **Installation** · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · [Operations](operations.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

---

This is the detailed walkthrough. For the condensed version see the
[README quick start](../README.md#quick-start).

## Prerequisites

1. **Synology NAS** with **Container Manager** (Docker) installed (Package Center).
2. **SSH access** enabled: Control Panel → Terminal & SNMP → *Enable SSH service*.
3. **Root / sudo** — creating the macvlan network and the TUN device requires root.
4. An **x86_64 (Intel) NAS** is assumed by default (`EXPECTED_ARCH=amd64`). If your model is ARM,
   see [Auto-Update › architecture guard](auto-update.md#architecture-guard).
5. (China) An **Alibaba Container Registry (ACR)** namespace and the `docker-china-sync` mirror
   already pushing your images — see [Auto-Update › ACR setup](auto-update.md#acr-setup).

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

> The path `/volume1/docker/syno-mihomo-gateway` is assumed throughout (the DSM scheduler
> command and the docs use it). If you install elsewhere, adjust those paths.

## 2. Configure `.env`

```bash
cp .env.example .env
chmod 600 .env          # it holds secrets (ACR password, tunnel token, controller secret)
vi .env
```

At minimum set `ROUTER_IP`, `SUBNET_CIDR`, `MIHOMO_IP`, your DNS servers, and (for China) the
ACR registry/credentials and image refs. Every key is documented in
[Configuration](configuration.md). `.env` is gitignored.

## 3. Add your subscription

```bash
cp config/subscription.txt.example config/subscription.txt
vi config/subscription.txt
```

One line, `Name=URL`; the first valid line is used. The URL may contain `?token=…&flag=…` —
those `=`/`&` are handled correctly. `config/subscription.txt` is gitignored so your token is
never committed.

```text
Default=https://your-provider.com/api/v1/subscribe?token=abc&flag=1
```

## 4. Create the network + TUN device

```bash
sudo chmod +x scripts/setup_network.sh
sudo ./scripts/setup_network.sh
```

This script:
- creates `/dev/net/tun` if missing and fixes its permissions;
- auto-detects the parent interface (the one that routes to `ROUTER_IP`; falls back to the
  default route) — supports `eth0` and `ovs_eth0`;
- (re)creates the `tproxy_network` macvlan with your `SUBNET_CIDR` / `ROUTER_IP`;
- optionally logs in to your registry and pulls images (non-interactive when `ACR_PASSWORD`
  is set, otherwise it prompts).

## 5. Start the stack

```bash
sudo docker compose up -d
```

On start, the mihomo entrypoint renders `config/config.yaml` from the template + your
subscription + `.env`, then launches mihomo. If the subscription URL or DNS values are missing
it **fails loudly** (the container won't run a poisoned config). Check logs:

```bash
docker logs mihomo
docker compose ps
```

## 6. Open the dashboard

From a **LAN device that is not the NAS** (see the macvlan caveat in
[Architecture](architecture.md#network-model-macvlan)):

1. Browse to `http://<NAS_IP>:<WEB_UI_PORT>` (e.g. `http://192.168.1.10:8080`) — the **NAS** IP,
   not the mihomo IP.
2. Add backend: **Host** = `MIHOMO_IP` (e.g. `192.168.1.100`), **Port** = `CONTROLLER_PORT`
   (default `9090`), **Secret** = your `CONTROLLER_SECRET` (blank if empty).

## 7. Point devices at the gateway

- **Single device:** set its Router/Gateway and DNS to `MIHOMO_IP`.
- **Whole home:** announce `MIHOMO_IP` as the gateway via your router's DHCP. ⚠️ If the
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
sh scripts/auto_update.sh --dry-run
```

## Updating the repo itself

```bash
cd /volume1/docker/syno-mihomo-gateway
git pull
docker compose up -d        # picks up compose/template/script changes
```

Your `.env`, `config/subscription.txt`, and `config/config.yaml` are gitignored and untouched
by `git pull`.

> Installed via Option B (release zip)? There is no `git pull` — update by rebuilding and
> re-unpacking the zip: see
> [Release Zip › Updating an offline install](release-packaging.md#updating-an-offline-install).
