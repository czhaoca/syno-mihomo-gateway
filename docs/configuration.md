# Configuration Reference

[← README](../README.md) · [中文](zh/configuration.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · **Configuration** · [Auto-Update](auto-update.md) · [Operations](operations.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

---

This is the **single source of truth** for every configuration key. All real values live in
`.env` (copied from `.env.example`, `chmod 600`, gitignored). The committed config template
contains only `{{PLACEHOLDERS}}` — no DNS server or network address is hardcoded.

## Files

| File | Tracked? | Purpose |
|---|---|---|
| `.env` | no (gitignored) | All your settings + secrets. Copy from `.env.example`. |
| `.env.example` | yes | Documented template for `.env`. |
| `config/subscription.txt` | no (gitignored) | Your airport/provider URL (`Name=URL`, first valid line used). |
| `config/subscription.txt.example` | yes | Template for the above. |
| `config/config.template.yaml` | yes | Mihomo config with `{{PLACEHOLDERS}}`. |
| `config/config.yaml` | no (gitignored) | Rendered at container start by `scripts/render_config.sh`. Never edit by hand. |

## `.env` reference

Legend — **Req**: required for the gateway to run · **Upd**: required for auto-update ·
**Sec**: secret (keep `.env` `chmod 600`).

### Network

| Key | Req | Description | Example |
|---|:--:|---|---|
| `ROUTER_IP` | ✅ | Your router/gateway IP. Used to auto-detect the macvlan parent interface. | `192.168.1.1` |
| `SUBNET_CIDR` | ✅ | Your LAN subnet for the macvlan network. | `192.168.1.0/24` |
| `MIHOMO_IP` | ✅ | Static LAN IP assigned to the mihomo container. **Must be unused** (the installer checks for a conflict). | `192.168.1.100` |
| `PARENT_INTERFACE` | | Macvlan parent NIC. The installer fills this from the interface scan; blank = auto-detect (the boot-up self-heal task auto-detects too). | `eth0` |

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
| `DOCKER_REGISTRY` | ✅ | | Registry host (used for `docker login` and to derive the refs). In `docker` mode the installer clears it so login is skipped. | `registry.cn-shenzhen.aliyuncs.com` |
| `DOCKER_USERNAME` | ✅ | | Registry username (shared by the installer + updater). | `your_registry_user` |
| `ACR_PASSWORD` | ✅ | 🔒 | Registry password / access token (non-interactive `--password-stdin`). | `…` |
| `ACR_NAMESPACE` | ✅ | | Registry namespace your images live under (combined with the host + tag to derive the refs). | `myns` |

### Auto-update orchestrator

| Key | Description | Default / Example |
|---|---|---|
| `UPDATE_ENABLED` | Master kill-switch. `false` makes a run exit immediately (unless `--force`). | `true` |
| `UPDATE_IMAGES` | Space-separated image refs to check/pull. Recommended: inherit the three image vars. | `"${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}"` |
| `UPDATE_SCHEDULE` | Cron expr — source of truth for the DSM task / fallback crontab. **Quote it.** The installer sets it from a daily HH:MM prompt. | `"0 2 * * *"` |
| `UPDATE_TZ` | Timezone the schedule runs in (the script exports it as `TZ`). | `Asia/Shanghai` |
| `EXPECTED_ARCH` | Guard against the amd64-only mirror landing on an ARM NAS. `amd64`/`arm64`. | `amd64` |

### cloudflared (external container, blue-green by name)

| Key | Sec | Description | Default / Example |
|---|:--:|---|---|
| `CF_CONTAINER_NAME` | | Canonical name of the running cloudflared container. | `cloudflared` |
| `CF_TUNNEL_TOKEN` | 🔒 | Token **override**. Blank = reuse the token from the running container (preferred). Required only for first-time provisioning when no container exists. | `` |
| `CF_HEALTH_TIMEOUT` | | Seconds to wait for the new connector to report "connected" before cutover. | `60` |

### Reporting & system

| Key | Description | Default / Example |
|---|---|---|
| `NOTIFY_WEBHOOK_URL` | Optional fallback webhook (Bark/Gotify/Slack-style JSON POST) when `synodsmnotify` is absent. | `` |
| `NOTIFY_ON_NOCHANGE` | `1` = also notify on no-op runs. | `0` |
| `UPDATE_LOG` | Orchestrator log path (relative resolves under the repo). | `./logs/auto-update.log` |
| `LOG_KEEP` | Rotated log generations to keep. | `7` |
| `TZ` | Container timezone. | `Asia/Shanghai` |
| `INSTALLER_LANG` | Language of the `install.sh` UI (`en` or `zh`). The installer's first screen sets it; saved here so re-runs skip the prompt. | `en` |

### Advanced tunables (optional `.env` overrides)

These have sensible defaults in `scripts/lib/common.sh` / `registry.sh`; override only if needed.

| Key | Default | Meaning |
|---|---|---|
| `LOG_MAX_BYTES` | `1048576` | Rotate `UPDATE_LOG` when it exceeds this size. |
| `PULL_RETRIES` / `PULL_RETRY_DELAY` | `3` / `10` | `docker pull` retry count / delay (s). |
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
