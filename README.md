# Syno-Mihomo-Gateway (Synology DSM Transparent Proxy)

[中文文档 (Chinese Docs)](docs/README_ZH.md)

A simple, "git-pull-and-run" solution to deploy **Mihomo (Clash Meta)** on Synology NAS as a transparent gateway. This setup allows any device in your home (Apple TV, iPhone, Gaming Consoles) to bypass censorship by simply setting their Gateway/Router IP to this container.

## Features
- 🚀 **Automated Setup:** Script auto-detects your Synology network interface (supports `eth0` and `ovs_eth0` automatically).
- 🛡️ **Safe & Isolated:** Uses Docker Macvlan. Does not mess with your NAS's host networking.
- 🔧 **Easy Config:** Simple `.env` file for IP, Subnet, and Port settings.
- 🔁 **Decoupled Subscription:** Keeps your config safe; just update the URL in a text file.

---

## Prerequisites
1.  **Synology NAS** with Container Manager (Docker) installed.
2.  **SSH Access** enabled (Control Panel -> Terminal & SNMP).
3.  **Root/Sudo access** (needed to create network interface).

---

## Quick Start Guide

### 1. Clone the Repository
SSH into your NAS and navigate to your docker folder:
```bash
cd /volume1/docker
git clone https://github.com/czhaoca/syno-mihomo-gateway.git
cd syno-mihomo-gateway

```

### 2. Configuration

Copy the template and edit your settings:

```bash
cp .env.example .env
vi .env

```

* **ROUTER_IP:** Your router's IP (e.1. `192.168.1.1`).
* **MIHOMO_IP:** The new IP for this proxy (e.g., `192.168.1.100`, must be unused).

*   **DOCKER_REGISTRY (Optional):** If you are in an environment where Docker Hub is restricted (e.g., China) or using a private registry, set this to your registry's address (e.g., `registry.cn-shenzhen.aliyuncs.com`).
*   **DOCKER_USERNAME (Optional):** Your Docker registry username. The setup script will prompt you for it if left empty and `DOCKER_REGISTRY` is set.
*   **MIHOMO_IMAGE (Optional):** Full image path for Mihomo (e.g., `registry.cn-shenzhen.aliyuncs.com/your_name/mihomo:latest`). Defaults to `metacubex/mihomo:latest`.
*   **METACUBEXD_IMAGE (Optional):** Full image path for Metacubexd UI (e.g., `registry.cn-shenzhen.aliyuncs.com/your_name/metacubexd:latest`). Defaults to `ghcr.io/metacubex/metacubexd:latest`.

### 3. Add Subscription

Edit the subscription file:

```bash
vi config/subscription.txt

```

Paste your Airport/Provider URL in this format:

```text
Default=[https://your-provider.com/api/v1/subscribe?token=123](https://your-provider.com/api/v1/subscribe?token=123)...

```

### 4. Run the Setup Script

This script fixes TUN permissions, creates the necessary Macvlan network, and optionally handles Docker registry login and image pulling if `DOCKER_REGISTRY` is configured in your `.env` file.

```bash
sudo chmod +x scripts/setup_network.sh
sudo ./scripts/setup_network.sh

```

### 5. Start the Container

```bash
sudo docker-compose up -d

```

### 6. Access Dashboard

* Open browser: `http://YOUR_NAS_IP:8080` (Use your NAS IP, not the Mihomo IP)
* Add Backend:
* **Host:** `YOUR_MIHOMO_IP` (e.g., `192.168.1.100`)
* **Port:** `9090`



---

## Client Setup (How to use it)

### Option A: Single Device (Recommended)

On your iPhone, Apple TV, or PC:

1. Go to Network Settings.
2. Set **Router / Gateway** to `192.168.1.100` (Your Mihomo IP).
3. Set **DNS** to `192.168.1.100`.

### Option B: Whole Home (Advanced)

Update your Router's DHCP settings to announce `192.168.1.100` as the default gateway. **Warning:** If the container stops, your home internet goes down.

---

## Maintenance

**Update Subscription:**

1. Update `config/subscription.txt`.
2. Restart container: `docker-compose restart mihomo`.

**Update Mihomo Core:**

```bash
docker-compose pull
docker-compose up -d

```
