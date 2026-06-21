# Architecture

[← README](../README.md) · [中文](zh/architecture.md)
Manual: **Architecture** · [Installation](installation.md) · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · [Operations](operations.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

---

## What this is

A transparent proxy **gateway** for a Synology NAS. [Mihomo](https://github.com/MetaCubeX/mihomo)
(Clash Meta) runs in a privileged container with its **own LAN IP** (Docker macvlan), so any
device on the home network can route through it just by setting that IP as its gateway/DNS —
no client software required. [MetaCubeXD](https://github.com/MetaCubeX/metacubexd) is a web
dashboard for managing Mihomo.

The deployment target is **mainland China**, where Docker Hub / ghcr.io are blocked. Image
updates therefore flow through a two-stage pipeline (mirror → pull) described below.

## Components

| Component | Where | Role |
|---|---|---|
| **mihomo** | this repo, container `mihomo` | The proxy engine. Privileged, on a macvlan with a static LAN IP (`MIHOMO_IP`). Serves DNS on `:53`, the RESTful controller on `:CONTROLLER_PORT`, and proxy ports `7890-7894`. Renders its own config at start from a template. |
| **metacubexd** | this repo, container `mihomo-ui` | Static web dashboard (bridge network, published on the NAS host IP at `WEB_UI_PORT`). A browser talks to the controller directly; the container is just serving the SPA. |
| **cloudflared** | **external** (not in this compose) | Optional Cloudflare Tunnel. Managed *by name* by the auto-updater via blue-green. Lets you reach the dashboard/NAS from outside without opening ports. |
| **auto_update.sh** | this repo, `scripts/` | DSM-scheduled job: pulls images from Alibaba ACR, detects real changes, redeploys safely (health-gate + rollback), notifies. |
| **docker-china-sync** | sibling repo `../docker-china-sync` | GitHub Actions on a self-hosted runner; mirrors upstream images → Alibaba ACR nightly. The "push" side of the pipeline. |

## Update pipeline (mirror → pull)

```mermaid
flowchart LR
  subgraph GH["docker-china-sync (GitHub Actions, self-hosted runner)"]
    A["images.txt<br/>(mihomo, metacubexd,<br/>cloudflared, ...)"] -->|nightly 23:00 UTC| B["pull upstream<br/>(Docker Hub / ghcr)"]
    B --> C["push to Alibaba ACR<br/>REGISTRY/NS/&lt;image:tag&gt;"]
  end
  subgraph NAS["Synology NAS (this repo)"]
    D["DSM Task Scheduler<br/>(root, daily)"] --> E["scripts/auto_update.sh"]
    E -->|"pull + digest diff"| C
    E -->|"compose up -d"| F["mihomo + metacubexd"]
    E -->|"blue-green by name"| G["cloudflared (external)"]
    E -->|"push notify + log"| H["synodsmnotify / webhook"]
  end
```

Plain-text fallback:

```
 docker-china-sync (GitHub Actions)                     Synology NAS (this repo)
 images.txt → pull upstream → push to ACR   ◄──pull──   DSM Task Scheduler → auto_update.sh
   (nightly 23:00 UTC)                                    ├─ compose up -d → mihomo + metacubexd
   ACR: REGISTRY/NS/<image:tag>                           ├─ blue-green → cloudflared (external)
                                                          └─ synodsmnotify + logs/auto-update.log
```

- **Push side** runs in the cloud (good global connectivity) and writes to ACR, which *is*
  reachable from inside China.
- **Pull side** runs on the NAS and only touches ACR. The two sides are decoupled; the NAS
  job is idempotent (it no-ops unless an image digest actually changed), so exact timing
  between them does not matter — just schedule the pull comfortably after the nightly mirror.

## Network model (macvlan)

`scripts/setup_network.sh` creates a Docker **macvlan** network `tproxy_network` whose parent
is the NAS's active interface (auto-detected via the route to `ROUTER_IP`). mihomo attaches to it
with the static `MIHOMO_IP`, so it appears as a **first-class device on your LAN** with its own IP
— it does not NAT through the NAS host and does not disturb host networking.

> **Open vSwitch note.** When the parent is an Open vSwitch port (`ovs_eth0`, present when DSM's
> Open vSwitch is enabled for VMM), the macvlan child still works: a Docker macvlan child IP **is
> reachable from peer LAN devices** on an OVS-backed parent (verified empirically — a clean container
> at a macvlan IP answered ping, ARP, and HTTP from a separate LAN device). OVS is **not** a cause of
> "dashboard/gateway times out". macvlan is the right driver for the forwarding role (ipvlan L2 demuxes
> by destination IP and will not deliver clients' forwarded frames), so keep `TPROXY_DRIVER=macvlan`.
> See [Troubleshooting](troubleshooting.md).

This is a **transparent gateway**. By default (`TUN_ENABLE=true`) the rendered config carries a
`tun:` block using the **`system` TUN stack** plus `allow-lan: true` and `enhanced-mode: fake-ip`
DNS. LAN devices point their **gateway + DNS at `MIHOMO_IP`** and route to the internet through the
airport/subscription with no client software. They can **also** use `MIHOMO_IP:7890` (http) /
`MIHOMO_IP:7891` (socks) as an explicit proxy, since `allow-lan` is set.

The critical detail is the **`system` stack**. Unlike `stack: mixed`/`gvisor` with `auto-route`, the
`system` stack does **not** hijack the `external-controller`'s reply path, so the dashboard backend at
`MIHOMO_IP:CONTROLLER_PORT` stays reachable from the LAN. This is what actually fixes
[mihomo #1493](https://github.com/MetaCubeX/mihomo/issues/1493): keep TUN **on** with `stack: system`,
do not turn TUN off.

Setting `TUN_ENABLE=false` drops the `tun:` block and runs mihomo as a **plain (non-gateway) proxy** —
reachable only via the `redir`/`tproxy`/`mixed`/`socks` ports, with no transparent interception of LAN
clients. Linux `auto-redirect` (`TUN_AUTO_REDIRECT`) is a further optional TCP optimization, off by
default because current nft-backed iptables userspace is incompatible with older DSM kernels. The
health gate requires the runtime TUN interface **only when `TUN_ENABLE=true`**; otherwise it gates on
the controller alone.

```
        LAN 192.168.1.0/24
   ┌──────────┬───────────────┬─────────────────┐
 Router     NAS host        mihomo (macvlan)   phone / AppleTV / PS5
192.168.1.1 192.168.1.x   192.168.1.100         set gateway+DNS → .100
                          :53 DNS  :9090 ctl
                          :7890-7894 proxy
```

> **macvlan isolation caveat (important):** by Linux macvlan design, the **NAS host cannot
> reach its own macvlan container's IP**. Other LAN devices can. So always open the dashboard
> and run client connectivity tests from a *different* device, and note that the updater's
> mihomo health probe runs **inside** the container (`docker exec`) precisely to sidestep this.
> See [Troubleshooting](troubleshooting.md#macvlan-self-reach).

## Config rendering

mihomo's real config is generated at container start, never committed:

```
config/config.template.yaml  ──(scripts/render_config.sh)──►  config/config.yaml
        {{TOKENS}}                  + subscription.txt              (gitignored)
        + .env values
```

`scripts/render_config.sh` substitutes the subscription URL (from `config/subscription.txt`)
and the `.env`-provided tokens (`CONTROLLER_*`, `DNS_*`) into the template. The **same script**
is what CI runs (`scripts/ci/render_check.py`), so the rendering path is actually tested. No
DNS server or network address is hardcoded in any committed file (a project rule); real values
live only in the gitignored `.env`. See [Configuration](configuration.md) and
[Development](development.md).

## Safety model ("safe-auto")

This container is the **gateway/DNS for the whole house** — a broken auto-update would take the
LAN offline. So "update automatically" is implemented as *safe-auto*:

1. **detect by digest** — do nothing unless an image actually changed;
2. **preflight** — abort (touching nothing) if compose flavor, image arch, the macvlan network,
   `/dev/net/tun`, or ACR login are not right;
3. **pull-then-swap** — never stop a running container before the new image is fully pulled;
4. **health-gate → auto-rollback** — after recreating, verify mihomo is healthy; if not, revert
   to the last-good image automatically;
5. **blue-green for cloudflared** — bring the new connector up and *prove it is connected*
   before retiring the old one, preserving the tunnel token.

Details in [Auto-Update](auto-update.md).
