# Configuration Reference

[← README](../README.md) · [中文](zh/configuration.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · **Configuration** · [Auto-Update](auto-update.md) · [Operations](operations.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

---

This is the **single source of truth** for every configuration key. All real values live in
`../syno-mihomo-gateway-data/.env` (copied from `.env.example`, `chmod 600`). The committed config template
contains only `{{PLACEHOLDERS}}` — no DNS server or network address is hardcoded.

## Files

| File | Tracked? | Purpose |
|---|---|---|
| `../syno-mihomo-gateway-data/.env` | no (outside repo) | All your settings + secrets. Seeded by `bootstrap.sh`. |
| `.env.example` | yes | Documented template for `.env`. |
| `../syno-mihomo-gateway-data/config/subscription.txt` | no (outside repo) | Your provider URL (`Name=URL`, first valid line used). |
| `config/subscription.txt.example` | yes | Template for the above. |
| `config/config.template.yaml` | yes | Mihomo config with `{{PLACEHOLDERS}}`. |
| `../syno-mihomo-gateway-data/config/config.yaml` | no (outside repo) | Rendered at container start. Never edit by hand. |

## `.env` reference

Legend — **Req**: required for the gateway to run · **Upd**: required for auto-update ·
**Sec**: secret (keep `.env` `chmod 600`).

The installer reads `.env` as dotenv data, never as a shell program. Generated values are
Compose-compatible quoted strings, so passwords containing spaces, `&`, `#`, `$`, quotes, or
backslashes round-trip safely. When editing by hand, keep one `KEY=VALUE` assignment per line.

### Network

| Key | Req | Description | Example |
|---|:--:|---|---|
| `ROUTER_IP` | ✅ | Your router/gateway IP. Used to auto-detect the macvlan parent interface. | `192.168.1.1` |
| `SUBNET_CIDR` | ✅ | Your LAN subnet for the macvlan network. | `192.168.1.0/24` |
| `MIHOMO_IP` | ✅ | Static LAN IP assigned to the mihomo container. **Must be unused** — the installer suggests the next free address above the NAS's own IP on the chosen interface (scanned with arping/ping) and re-checks for a conflict before deploy. | `192.168.1.100` |
| `PARENT_INTERFACE` | | Macvlan parent NIC. The installer fills this from the interface scan (address-less NICs are hidden); blank = auto-detect (the boot-up self-heal task auto-detects too). | `eth0` |
| `TPROXY_DRIVER` | | L2 driver for the gateway network: `macvlan` (default) or `ipvlan`. macvlan is required for the gateway's **forwarding** role; on an **Open vSwitch** parent (`ovs_eth0`) a macvlan child is unreachable by LAN peers, so prefer a **non-OVS NIC or disabling OVS**. `ipvlan` traverses OVS and restores the **dashboard only** — it demuxes by destination IP and will **not** route LAN clients through the proxy. | `macvlan` |

### Mihomo TUN

| Key | Req | Description | Default |
|---|:--:|---|---|
| `TUN_AUTO_REDIRECT` | | Optional Linux TCP redirect optimization. Keep `false` on DSM unless the installer's disposable iptables compatibility probe succeeds. TUN `auto-route` remains enabled either way. Only lowercase `true`/`false` are accepted. | `false` |

### Ports & controller

| Key | Req | Description | Example |
|---|:--:|---|---|
| `WEB_UI_PORT` | ✅ | Host port for the MetaCubeXD dashboard (published on the NAS IP). | `8080` |
| `CONTROLLER_PORT` | ✅ | Mihomo RESTful controller port (bound `0.0.0.0`; reached at `MIHOMO_IP:PORT`). | `9090` |
| `CONTROLLER_SECRET` | | Controller auth secret. Empty = no auth. `&`, `\|`, `\` are handled by the renderer. | `` |

### DNS (injected into the config template)

Comma-separated lists → rendered as YAML flow sequences. **All three are required** (the
renderer fails loudly if any is empty — no DNS is hardcoded in the repo).

| Key | Req | Description | Example |
|---|:--:|---|---|
| `DNS_DEFAULT_NAMESERVER` | ✅ | Bootstrap resolvers (plain IPs, used to resolve the others). | `114.114.114.114,223.5.5.5` |
| `DNS_NAMESERVER` | ✅ | Primary/domestic resolvers. | `114.114.114.114,223.5.5.5` |
| `DNS_FALLBACK` | ✅ | Overseas / anti-pollution resolvers. | `8.8.8.8,8.8.4.4` |

### Container images

The three image refs are **derived** by `install.sh` from `REGISTRY_MODE` + the registry host +
namespace + the per-component tag, so you enter the registry/namespace **once** instead of per
image. The auto-updater maps each `UPDATE_IMAGES` entry to a deploy target by an **exact match**
against the three resolved refs (see [Auto-Update](auto-update.md#image-refs)).

> **Fail-closed, ACR by default.** `docker-compose.yml` reads `${MIHOMO_IMAGE:?}` /
> `${METACUBEXD_IMAGE:?}`, so `docker compose up` **fails loudly** if a ref is unset rather than
> pulling something unexpected. `REGISTRY_MODE` ships as `acr` (the safe default for mainland China,
> where the public registries are blocked); set `docker` only on a NAS with unfiltered internet.

| Key | Req | Description | Example |
|---|:--:|---|---|
| `REGISTRY_MODE` | ✅ | `acr` (default; your private mirror) or `docker` (upstream public; needs unfiltered internet). | `acr` |
| `MIHOMO_TAG` | | Tag used to derive the mihomo ref. | `latest` |
| `METACUBEXD_TAG` | | Tag used to derive the metacubexd ref. | `latest` |
| `CF_TAG` | | Tag used to derive the optional cloudflared ref. | `latest` |
| `MIHOMO_IMAGE` | ✅ | Resolved mihomo image ref (the installer rewrites it from the above). | `registry.cn-shenzhen.aliyuncs.com/myns/mihomo:latest` |
| `METACUBEXD_IMAGE` | ✅ | Resolved metacubexd image ref. | `registry.cn-shenzhen.aliyuncs.com/myns/metacubexd:latest` |
| `CF_IMAGE` | Upd | Resolved cloudflared ref. Blank if not managing cloudflared. | `registry.cn-shenzhen.aliyuncs.com/myns/cloudflared:latest` |

### Private registry / Alibaba ACR (used when `REGISTRY_MODE=acr`)

| Key | Upd | Sec | Description | Example |
|---|:--:|:--:|---|---|
| `DOCKER_REGISTRY` | ✅ | | Registry host (used for `docker login` and to derive the refs); the installer pre-fills `registry.cn-shenzhen.aliyuncs.com` as the default. In `docker` mode the installer clears it so login is skipped. | `registry.cn-shenzhen.aliyuncs.com` |
| `DOCKER_USERNAME` | ✅ | | Registry username (shared by the installer + updater). | `your_registry_user` |
| `ACR_PASSWORD` | ✅ | 🔒 | Registry password / access token (non-interactive `--password-stdin`). | `…` |
| `ACR_NAMESPACE` | ✅ | | Registry namespace your images live under (combined with the host + tag to derive the refs). | `myns` |

### Auto-update orchestrator

| Key | Description | Default / Example |
|---|---|---|
| `UPDATE_ENABLED` | Master kill-switch. `false` makes a run exit immediately (unless `--force`). | `true` |
| `UPDATE_IMAGES` | Space-separated image refs to check/pull. Both Compose refs are required; when `CF_IMAGE` is non-empty it is required too. The installer persists concrete resolved refs. | `"${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}"` |
| `UPDATE_SCHEDULE` | Five-field numeric cron expression used to configure DSM Task Scheduler / the fallback crontab. It is range-validated before output. **Quote it.** | `"0 2 * * *"` |
| `UPDATE_TZ` | Timezone used for updater log timestamps. The DSM trigger itself follows the NAS Regional Options timezone. | `Asia/Shanghai` |
| `EXPECTED_ARCH` | Guard against the amd64-only mirror landing on an ARM NAS. `amd64`/`arm64`. | `amd64` |

### cloudflared (external container, blue-green by name)

| Key | Sec | Description | Default / Example |
|---|:--:|---|---|
| `CF_CONTAINER_NAME` | | Canonical name of the running cloudflared container. | `cloudflared` |
| `CF_TUNNEL_TOKEN` | 🔒 | Token **override**. Blank = reuse the token from the running container (preferred) — the installer detects an existing `cloudflared` container and offers reuse, only requiring a token when provisioning the first one. Required for first-time provisioning when no container exists. | `` |
| `CF_HEALTH_TIMEOUT` | | Seconds to wait for the new connector to report "connected" before cutover. | `60` |

### Reporting & system

| Key | Description | Default / Example |
|---|---|---|
| `NOTIFY_WEBHOOK_URL` | Optional fallback webhook (Bark/Gotify/Slack-style JSON POST) when `synodsmnotify` is absent. | `` |
| `NOTIFY_ON_NOCHANGE` | `1` = also notify on no-op runs. | `0` |
| `UPDATE_LOG` | Orchestrator log path (relative resolves under the persistent data directory). | `./logs/auto-update.log` |
| `LOG_KEEP` | Rotated log generations to keep. | `7` |
| `TZ` | Container timezone. | `Asia/Shanghai` |
| `INSTALLER_LANG` | Language of the `install.sh` UI (`en` or `zh`). The installer's first screen sets it; saved here so re-runs skip the prompt. | `en` |

### Advanced tunables (optional `.env` overrides)

These have sensible defaults in `scripts/lib/common.sh` / `registry.sh`; override only if needed.

| Key | Default | Meaning |
|---|---|---|
| `LOG_MAX_BYTES` | `1048576` | Rotate `UPDATE_LOG` when it exceeds this size. |
| `PULL_RETRIES` / `PULL_RETRY_DELAY` | `3` / `10` | `docker pull` retry count / delay (s). |
| `DOCKER_READY_TIMEOUT` / `DOCKER_READY_INTERVAL` | `120` / `5` | How long a DSM scheduled/boot task waits for Container Manager and how often it retries (s). |
| `HEALTH_RETRIES` / `HEALTH_INTERVAL` | `6` / `10` | mihomo health-gate attempts / interval (s). |
| `LOCK_DIR` | `/tmp/syno-mihomo-update.lock` | Mutex lock directory. |
| `TPROXY_NETWORK` | `tproxy_network` | Macvlan network name the preflight checks. |

## `config/config.template.yaml`

Holds the Mihomo config with placeholders the renderer fills:

| Placeholder | Source key |
|---|---|
| `{{AIRPORT_URL}}` | first line of `config/subscription.txt` (label stripped) |
| `{{CONTROLLER_PORT}}` / `{{CONTROLLER_SECRET}}` | `.env` |
| `{{DNS_DEFAULT_NAMESERVER}}` / `{{DNS_NAMESERVER}}` / `{{DNS_FALLBACK}}` | `.env` |
| `{{TUN_AUTO_REDIRECT}}` | `.env` (defaults to `false` when absent) |

Edit proxy **rules**, the `proxy-groups` / `proxy-providers` blocks, ports, etc. directly in the
template (they are not parameterized). After editing, re-render by recreating mihomo
(`docker compose up -d mihomo`). To customize routing, edit the `rules:` list — the defaults
are `GEOSITE,CN,DIRECT` / `GEOIP,CN,DIRECT` / `MATCH,PROXY` (CN traffic direct, everything
else through the `PROXY` group). `PROXY` is a selectable group that defaults to `auto` (the
fastest node from your subscription) and also offers `DIRECT` / `REJECT`; rules must target a
**proxy-group** (e.g. `PROXY`), never a `proxy-provider` directly.

## Subscription format

`config/subscription.txt` — first non-comment, non-blank line wins. An optional `Name=` label
is stripped; the rest (the URL, including any `?token=…&flag=…`) is used verbatim.

```text
# both of these work:
Default=https://provider.example/api/v1/subscribe?token=abc&flag=1
https://provider.example/api/v1/subscribe?token=abc&flag=1
```
