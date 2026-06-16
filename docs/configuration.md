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
| `MIHOMO_IP` | ✅ | Static LAN IP assigned to the mihomo container. **Must be unused.** | `192.168.1.100` |

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

The auto-updater maps each `UPDATE_IMAGES` entry to a deploy target by an **exact match**
against these three vars — on the ACR path, set them to your ACR refs (see
[Auto-Update](auto-update.md#image-refs)).

> **ACR-only, fail-closed.** `MIHOMO_IMAGE` and `METACUBEXD_IMAGE` are required: `docker compose
> up` **fails** if either is unset — it never falls back to a direct Docker Hub / ghcr.io pull
> (blocked in China). Always set them to your ACR mirror.

| Key | Req | Description | Example |
|---|:--:|---|---|
| `MIHOMO_IMAGE` | ✅ | mihomo image ref (point at your ACR mirror in China). | `registry.cn-shenzhen.aliyuncs.com/myns/mihomo:latest` |
| `METACUBEXD_IMAGE` | ✅ | metacubexd image ref. | `registry.cn-shenzhen.aliyuncs.com/myns/metacubexd:latest` |
| `CF_IMAGE` | Upd | cloudflared image ref (ACR-mirrored). Leave blank if not managing cloudflared. | `registry.cn-shenzhen.aliyuncs.com/myns/cloudflared:latest` |

### Alibaba ACR (China mirror — pull side)

| Key | Upd | Sec | Description | Example |
|---|:--:|:--:|---|---|
| `DOCKER_REGISTRY` | ✅ | | ACR registry host (used for `docker login`). Empty skips the login step; the gateway still requires MIHOMO_IMAGE/METACUBEXD_IMAGE to be ACR refs. | `registry.cn-shenzhen.aliyuncs.com` |
| `DOCKER_USERNAME` | ✅ | | ACR username (shared by setup + updater). | `your_acr_user` |
| `ACR_PASSWORD` | ✅ | 🔒 | ACR password / access token (non-interactive `--password-stdin`). | `…` |
| `ACR_NAMESPACE` | | | ACR namespace (the `ALIYUN_NAME_SPACE` from docker-china-sync). Reference only. | `myns` |

### Auto-update orchestrator

| Key | Description | Default / Example |
|---|---|---|
| `UPDATE_ENABLED` | Master kill-switch. `false` makes a run exit immediately (unless `--force`). | `true` |
| `UPDATE_IMAGES` | Space-separated image refs to check/pull. Recommended: inherit the three image vars. | `"${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}"` |
| `UPDATE_SCHEDULE` | Cron expr — source of truth for the DSM task / fallback crontab. **Quote it.** | `"0 9 * * *"` |
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

Edit proxy **rules**, the `proxy-providers` block, ports, etc. directly in the template (they
are not parameterized). After editing, re-render by recreating mihomo
(`docker compose up -d mihomo`). To customize routing, edit the `rules:` list — the defaults
are `GEOSITE,CN,DIRECT` / `GEOIP,CN,DIRECT` / `MATCH,my-airport` (CN traffic direct, everything
else through the airport).

## Subscription format

`config/subscription.txt` — first non-comment, non-blank line wins. An optional `Name=` label
is stripped; the rest (the URL, including any `?token=…&flag=…`) is used verbatim.

```text
# both of these work:
Default=https://provider.example/api/v1/subscribe?token=abc&flag=1
https://provider.example/api/v1/subscribe?token=abc&flag=1
```
