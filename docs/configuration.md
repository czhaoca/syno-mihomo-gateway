# Configuration Reference

[← README](../README.md) · [中文](zh/configuration.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · **Configuration** · [Auto-Update](auto-update.md) · [Operations](operations.md) · [CLI](cli.md) · [Troubleshooting](troubleshooting.md) · [Development](development.md)

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
| `TPROXY_DRIVER` | | L2 driver for the gateway network: `macvlan` (default) or `ipvlan`. Keep `macvlan` — it is required for the gateway's **forwarding** role, and a macvlan child IS reachable from LAN peers even on an **Open vSwitch** parent (`ovs_eth0`) (verified empirically; OVS does not break this). `ipvlan` demuxes by destination IP and will **not** route LAN clients through the proxy, so do not use it for the gateway. | `macvlan` |

### Mihomo TUN

| Key | Req | Description | Default |
|---|:--:|---|---|
| `TUN_ENABLE` | | Transparent-gateway TUN. Default **`true`** (ON) — the rendered config carries a `tun:` block using the **`system` stack** (with `allow-lan: true` and `enhanced-mode: fake-ip`), so LAN devices set gateway + DNS to `MIHOMO_IP` and route to the internet through the airport, and may also use `MIHOMO_IP:7890`/`:7891` as an explicit proxy. The `system` stack does **not** hijack the controller's reply path, so the dashboard backend stays reachable — this is how mihomo #1493 is actually fixed (do not turn TUN off). Set `TUN_ENABLE=false` to run a **plain, non-gateway proxy** (reachable only via the redir/tproxy/mixed/socks ports, no transparent interception of LAN clients). Only lowercase `true`/`false`. | `true` |
| `TUN_AUTO_REDIRECT` | | Only consulted when `TUN_ENABLE=true`: optional Linux TCP redirect optimization. Keep `false` on DSM unless the installer's disposable iptables compatibility probe succeeds. Only lowercase `true`/`false` are accepted. | `false` |

### Ports & controller

| Key | Req | Description | Example |
|---|:--:|---|---|
| `WEB_UI_PORT` | ✅ | Host port for the MetaCubeXD dashboard (published on the NAS IP). | `8080` |
| `CONTROLLER_PORT` | ✅ | Mihomo RESTful controller port (bound `0.0.0.0`; reached at `MIHOMO_IP:PORT`). | `9090` |
| `CONTROLLER_SECRET` | | Controller auth secret. Empty = no auth; the installer offers to auto-generate a random one when left empty (explicit opt-out keeps it open). On installer re-runs, pressing **Enter** keeps the saved secret and typing `-` clears it. The renderer escapes `&`, `\|`, `\`, but the installer **rejects** a secret containing `\|` — avoid it. | `` |

### DNS (injected into the config template)

Comma-separated lists → rendered as YAML flow sequences. **The first three are required**
(the renderer fails loudly if any is empty — no DNS is hardcoded in the repo). A `#auto`
suffix on a server is mihomo's group-detour fragment syntax: that resolver is dialed
**through** the group literally named `auto` in the shipped template (rename both together;
CI verifies every fragment names a real group). The detour rides `auto` — the url-test
group — rather than the `PROXY` selector on purpose: `auto` always picks a live node by
health, so DNS keeps working even when you pin `PROXY` to `DIRECT` in the dashboard. Every
shipped entry is a plain IP or a **DoH-on-IP** URL, so no entry depends on resolving a
hostname first — no bootstrap chicken-and-egg on a cold start.

| Key | Req | Description | Example |
|---|:--:|---|---|
| `DNS_DEFAULT_NAMESERVER` | ✅ | Bootstrap resolvers — used only to resolve DoH/DoT server **hostnames** appearing elsewhere in this section (idle while every entry is IP-hosted). Must stay plain-IP, domestic-reachable, **untunneled**. | `223.5.5.5,119.29.29.29` |
| `DNS_NAMESERVER` | ✅ | What the bootstrap pins (geodata mirror, health-check host, airport panel) resolve through, **and** — rendered as `proxy-server-nameserver` — what resolves the airport node hostnames before any proxy exists (see below). With the split-horizon pair unset (legacy profile) it is also the general upstream. DoH-on-IP, domestic, **never** fragment-suffixed. | `https://223.5.5.5/dns-query,https://120.53.53.53/dns-query` |
| `DNS_FALLBACK` | ✅ | **Legacy profile only:** overseas anti-pollution resolvers for the fallback dual-query, consulted when an answer's geoip is not CN. With split-horizon set this is unused and **not rendered at all** — v2 has no fallback, because the dual-query is what copied every long-tail hostname to the domestic resolvers. Kept required so flipping back to legacy always renders. | `https://1.1.1.1/dns-query#auto,tls://8.8.8.8:853#auto` |
| `DNS_CN_NAMESERVER` | | **Split-horizon pair (a):** domains on mihomo's `geosite:cn` list resolve ONLY here — domestic, dialed direct. Set together with `DNS_FOREIGN_NAMESERVER` or not at all: exactly one set refuses to render; **neither** set renders the legacy profile byte-identical to the pre-1.3.8 config (existing `.env` files keep working unchanged — the redeploy wizard offers the upgrade). | `https://223.5.5.5/dns-query,https://120.53.53.53/dns-query` |
| `DNS_FOREIGN_NAMESERVER` | | **Split-horizon pair (b), v2 foreign-by-default:** rendered as the **default** `nameserver` — every domain *not* matched by a policy entry (geosite-listed foreign **and** the unlisted long tail) resolves ONLY here — overseas, tunneled via `#auto`. Those names never reach a domestic operator; a dead tunnel fails **closed** (SERVFAIL) instead of silently leaking. | `https://1.1.1.1/dns-query#auto,https://8.8.8.8/dns-query#auto` |
| `DNS_GEOIP_NO_RESOLVE` | | `true` renders `no-resolve` onto the `GEOIP,CN,DIRECT` rule so it never forces a lookup at all. Under v2 the forced lookup already rides the tunneled foreign list (private), so the default stays `false` and unlisted CN domains keep their DIRECT short-circuit. Trade-off of `true`: CN domains missing from `geosite:cn` ride the proxy via `MATCH` (see [troubleshooting](troubleshooting.md#niche-domestic-site-slow-or-unreachable-after-enabling-no-resolve)). Only lowercase `true`/`false`. | `false` |
| `SNIFFER_ENABLE` | | Renders the traffic **sniffer** (TLS SNI / HTTP Host / QUIC, `parse-pure-ip` + `override-destination`): raw-IP flows from LAN clients that resolve DNS **outside** the gateway recover their hostname, so domain rules (incl. `STREAMING`) still route them and poisoned client-side answers are re-dialed by hostname at the node. Unset/`false` renders without the block, byte-identical to pre-v1.3.10 (upgrade compat); `.env.example` ships `true`. Routing self-heals, but bypassing clients' *privacy* still requires pointing their DNS at the gateway — see [troubleshooting](troubleshooting.md#lan-clients-bypass-the-gateways-dns-dnsleaktest-still-shows-domestic-resolvers). | `true` |
| `AUTO_EXCLUDE_FILTER` | | Renders the **`auto-x`** url-test group — provider nodes matching this regex removed — as **`PROXY`'s first member**, i.e. the routing default. The shipped default excludes Hong Kong: many sites block HK egress IPs, and an HK-heavy pool makes latency-based `auto` land on an HK node almost every time. `auto` itself keeps the **full** pool (the split-horizon DNS detour rides it), one dashboard click away. Syntax: regexp2 (.NET flavor) — case-sensitive unless `(?i)`, **unanchored substring** match (`香港` matches `香港01`), `\|` alternates; a **backtick refuses to render** (an invalid pattern crashes mihomo at startup). A pattern matching *every* node makes `auto-x` **REJECT** (fail closed — never a silent unproxied bypass; the doctor flags it — see [troubleshooting](troubleshooting.md#doctor-reports-an-empty-filtered-group-proxy_groups-auto-x-rejects--a-country-group-has-no-nodes)). Unset/empty renders without the group, byte-identical to the pre-feature config (existing `.env` files unchanged). | `香港\|HK\|(?i)hong ?kong` |
| `COUNTRY_GROUPS` | | Per-country auto-selection: `NAME=regex;NAME=regex;…` generates one **url-test** group per entry — the dashboard shows `NAME` and auto-picks the fastest node matching `regex` (regexp2, same flavor as `AUTO_EXCLUDE_FILTER`; anchor short Latin codes as `US\d\|^US`). A regex spanning several countries **is** a multi-country group (e.g. `亚洲=日本\|新加坡`). Groups appear in **both** `PROXY` and `STREAMING`, after the auto groups, in spec order; no own health probe (zero extra traffic); a zero-match group **REJECT**s when selected (fail closed; the doctor flags it). `NAME` may be CJK, no spaces, must not shadow `auto`/`auto-x`/`PROXY`/`STREAMING`/`DIRECT`/`REJECT`; backtick, empty parts, duplicates and malformed entries **refuse to render**. Tune the shipped example to *your* airport's node names. Unset/empty renders without any generated group (existing `.env` files unchanged). | `美国=美国\|US\d\|^US;新加坡=…` (see `.env.example`) |

**Who can observe your DNS queries** (with the shipped split-horizon v2 defaults):

| Observer | Sees | What changes it |
|---|---|---|
| Domestic resolver operators — AliDNS (Alibaba), DNSPod (Tencent) | CN-listed domain names over encrypted DoH, plus the bootstrap pins (geodata mirror, health-check host, airport panel, node hostnames). **Nothing else** — foreign-listed and long-tail names never arrive here, and a dnsleaktest.com extended test from a LAN client shows no domestic resolver. | Unsetting the split-horizon pair (legacy profile) sends **all** names here — pre-v1.3.10 renders also leaked the long tail via the `GEOIP,CN` lookup + fallback dual-query; `doctor` reports the profile as `dns_privacy`. |
| Your ISP / anyone on the wire path | Only that the gateway talks DoH to well-known resolver IPs — the query names are encrypted, and the tunneled entries do not even appear as DNS on the wire. | Plain-UDP entries (e.g. bare `223.5.5.5` in `DNS_NAMESERVER`) would put names back on the wire; the shipped defaults avoid that. |
| Airport (proxy) operator | The foreign connections it proxies anyway, which include your tunneled DNS (now covering the long tail too). The subscription-refresh fetch is dialed direct (recorded residual — its SNI is wire-visible). | Inherent to proxying — choose the airport accordingly. |
| Foreign DoH vendors — Cloudflare, Google | Foreign-listed **and long-tail** domain names, arriving **through the tunnel** (they observe the airport's exit IP, not your home IP). | The vendor set in `DNS_FOREIGN_NAMESERVER` is yours to edit. |

**`proxy-server-nameserver` — the cold-start invariant.** The rendered config reuses
`DNS_NAMESERVER` as mihomo's `proxy-server-nameserver`: airport node hostnames resolve via the
domestic list, dialed **direct**, outside every tunnel-dependent path. Node IPs are usually
non-CN, so under the legacy profile the geoip fallback-filter would divert them to tunneled
resolvers, and under v2 the default resolver itself is tunneled — either way unreachable
**before any node is up**. Without this, a fresh start or an expired node cache dead-ends with
`dns resolve failed` on every node — observed in production (2026-07-10). This is why
`DNS_NAMESERVER` must stay domestic and must never carry a `#group` fragment; CI asserts both
properties on every rendered variant.

**Bootstrap DNS pins (v1.3.8; gstatic added in v1.3.10).** `proxy-server-nameserver` covers node
hostnames only — three more hosts must resolve **before any node is up** or a cold start can
never bootstrap: the geodata mirror, the health-check host `www.gstatic.com` (delay probes and
the empty-group `COMPATIBLE` placeholder dial it DIRECT), and your airport panel itself (its
hostname is derived from `subscription.txt` at render time). All are pinned in
`nameserver-policy` to `DNS_NAMESERVER` (domestic, dialed direct) in **every** mode — legacy and
split-horizon alike, no knob — and the mirror + panel are excluded from fake-ip. Without the pins
these hosts would resolve through a tunnel that does not exist yet, and the provider could never
fetch its node list (the 2026-07-12 outage). An IP-literal subscription host needs no DNS, so the
panel pin is skipped automatically; the provider also caches its node list at the stable path
`config/proxies/my-airport.yaml`, which `scripts/seed_provider.sh` can (re)write when a live
fetch is impossible (see
[troubleshooting](troubleshooting.md#provider-has-no-nodes-foreign-sites-dead-node-list-empty)).

The shipped `.env.example` defaults match the mainland-China posture of `REGISTRY_MODE=acr`
(split-horizon v2 on, everything encrypted, foreign + long-tail path tunneled); on an unfiltered
network `1.1.1.1,8.8.8.8` everywhere — with the split-horizon pair left unset — is fine. These
settings configure the **gateway** — the NAS's own resolvers (DSM Control Panel → Network) must
be reachable too, and `doctor` probes them (`host_dns`) and reports the rendered profile
(`dns_privacy`). Deploys also pre-seed the geo databases via CDN mirrors (`GEODATA_MIRRORS`
overrides the mirror list) so a first start never blocks on a cross-border fetch — the
`geosite:` lists in `nameserver-policy` and the routing rules make that pre-seed load-bearing
for DNS and routing alike.

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
| `REGISTRY_MODE` | ✅ | `acr` (default; your private mirror) or `docker` (upstream public; needs unfiltered internet). In `docker` mode **no generic auto-update targets are eligible** (see below). | `acr` |
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
| `ACR_PASSWORD` | ✅ | 🔒 | Registry password / access token (non-interactive `--password-stdin`). Least privilege: a dedicated **pull-only** ACR sub/RAM account, distinct from the `docker-china-sync` push account. | `…` |
| `ACR_NAMESPACE` | ✅ | | Registry namespace your images live under (combined with the host + tag to derive the refs). | `myns` |

### Auto-update orchestrator

| Key | Description | Default / Example |
|---|---|---|
| `UPDATE_ENABLED` | Master kill-switch. `false` makes a run exit immediately (unless `--force`). | `true` |
| `UPDATE_IMAGES` | Space-separated image refs to check/pull. Both Compose refs are required; when `CF_IMAGE` is non-empty it is required too. The installer persists concrete resolved refs. | `"${MIHOMO_IMAGE} ${METACUBEXD_IMAGE} ${CF_IMAGE}"` |
| `UPDATE_SCHEDULE` | Five-field numeric cron expression used to configure DSM Task Scheduler / the fallback crontab. It is range-validated before output. **Quote it.** | `"0 2 * * *"` |
| `UPDATE_TZ` | Timezone used for updater log timestamps. The DSM trigger itself follows the NAS Regional Options timezone. | `Asia/Shanghai` |
| `EXPECTED_ARCH` | Guard against the amd64-only mirror landing on an ARM box. `amd64` / `arm64` / `arm` (32-bit, e.g. an armv7 Raspberry Pi). The Pi installer pins it to the host automatically. | `amd64` |

### Generic auto-update targets

Enrollment does **not** live in `.env`: the managed list is
`<data-dir>/state/update-targets` (records `name|strategy|probe`), edited via
`gateway.sh update --enable/--disable` or the installer's update flow, and shown by
`update --list-targets`. `recreate` is the **only** v1 strategy (blue-green stays
cloudflared-exclusive). Enrollment alone is not enough: a target is eligible only when
its running image is under `DOCKER_REGISTRY`/`ACR_NAMESPACE` — with `REGISTRY_MODE=docker`
**no** generic targets are eligible. Engine details:
[Auto-Update → Generic targets](auto-update.md#generic-targets-any-enrolled-container).
Related state written by the updater: `state/last-run.json` (the last run's outcome —
timestamp, exit code, dry-run flag, updated/unchanged/failed/rolled-back counts + names —
surfaced by `gateway.sh status` and `update --last`) and `state/last-good/<name>` (the
proven-good image ID + spec digest per target, kept for cross-run rollback).

| Var | Meaning | Default |
|---|---|---|
| `UPDATE_DENY_CONTAINERS` | Optional space-separated glob list; matching container names are never auto-updated even when enrolled. | *(empty)* |

Per-target probes (third field of a record, screened at enroll time): `exec:<cmd>` runs
inside the container via `docker exec`; `log:<regex>` greps `docker logs`. Without a probe
the gate is running + stable restarts + the image's own healthcheck when defined.

### cloudflared (external container, blue-green by name)

| Key | Sec | Description | Default / Example |
|---|:--:|---|---|
| `CF_CONTAINER_NAME` | | Canonical name of the running cloudflared container. | `cloudflared` |
| `CF_TUNNEL_TOKEN` | 🔒 | Token **override**. Blank = reuse the token from the running container (preferred) — the installer detects an existing `cloudflared` container and offers reuse, only requiring a token when provisioning the first one. Required for first-time provisioning when no container exists. | `` |
| `CF_HEALTH_TIMEOUT` | | Seconds to wait for the new connector to report "connected" before cutover. | `60` |
| `CF_DNS` | | Explicit `--dns` resolvers for the tunnel container (comma-separated IPv4s) so it stops inheriting the host's resolv.conf — an unreachable host resolver otherwise silently kills the tunnel. Applied on the next provision/blue-green update; empty = inherit. | `223.5.5.5,119.29.29.29` |

### Reporting & system

| Key | Description | Default / Example |
|---|---|---|
| `NOTIFY_WEBHOOK_URL` | Optional webhook (Bark/Gotify/Slack-style JSON POST). Fires whenever configured — independent of DSM push (`synodsmnotify`), which is best-effort only and never suppresses the webhook. | `` |
| `NOTIFY_ON_NOCHANGE` | `1` = also notify on no-op runs. | `0` |
| `UPDATE_LOG` | Orchestrator log path (relative resolves under the persistent data directory). | `./logs/auto-update.log` |
| `LOG_KEEP` | Rotated log generations to keep. | `7` |
| `TZ` | Container timezone. | `Asia/Shanghai` |
| `INSTALLER_LANG` | Language of the `install.sh` UI (`en` or `zh`). The installer's first screen sets it; saved here so re-runs skip the prompt. | `en` |

### Raspberry Pi lite mode

Consumed by [`install-pi.sh`](installation-pi.md) and the lite updater; harmless and unused
on DSM (`.env.example` ships them commented out).

| Key | Description | Default / Example |
|---|---|---|
| `GH_MIRROR` | Mirror prefix applied to upstream release-download URLs (mihomo binary, dashboard, latest-tag resolution): `<mirror>/<full-upstream-url>`. Empty = direct. | `` |
| `MIHOMO_VERSION` | Pin the mihomo release tag for lite installs/updates. Empty = latest. | `` |
| `MIHOMO_SHA256` | Optional integrity anchor for a **pinned** release (upstream publishes no checksums): when set, the downloaded archive must match before anything is installed — recommended whenever downloads ride a third-party mirror. | `` |
| `EXTERNAL_UI_DIR` | Folder mihomo serves the dashboard from (rendered into `external-ui` **only when set**; the lite wizard sets it, the DSM/compose path leaves it unset so its render stays byte-identical). | `` |

### Advanced tunables (optional `.env` overrides)

These have sensible defaults in `scripts/lib/common.sh` (`TPROXY_NETWORK` in
`scripts/lib/network.sh`); override only if needed.

| Key | Default | Meaning |
|---|---|---|
| `GATEWAY_DATA_DIR` | `../syno-mihomo-gateway-data` | Persistent data directory (`.env`, `config/`, `logs/`, `state/`), a sibling of the release checkout. Honored by compose and every script. **Export it in the environment** — it locates `.env`, so it cannot live in `.env` itself. |
| `LOG_MAX_BYTES` | `1048576` | Rotate `UPDATE_LOG` when it exceeds this size. |
| `PULL_RETRIES` / `PULL_RETRY_DELAY` | `3` / `10` | `docker pull` retry count / delay (s). |
| `DOCKER_READY_TIMEOUT` / `DOCKER_READY_INTERVAL` | `120` / `5` | How long a DSM scheduled/boot task waits for Container Manager and how often it retries (s). |
| `HEALTH_RETRIES` / `HEALTH_INTERVAL` | `6` / `10` | mihomo health-gate attempts / interval (s). |
| `HEALTH_MAX_RESTARTS` | `3` | Generic-target crash-loop threshold: the health gate fails (early) once a freshly updated container has restarted this many times. |
| `LOCK_DIR` | `/tmp/syno-mihomo-update.lock` | Mutex lock directory. |
| `TPROXY_NETWORK` | `tproxy_network` | Macvlan network name the preflight checks. |
| `TUN_DEVICE` | `mihomo-tun` | TUN interface name the host-side health gate looks for. Must match the template's hardcoded `device: mihomo-tun` — override only if you rename the device there. |

## `config/config.template.yaml`

Holds the Mihomo config with placeholders the renderer fills:

| Placeholder | Source key |
|---|---|
| `{{AIRPORT_URL}}` | first line of `../syno-mihomo-gateway-data/config/subscription.txt` (label stripped) |
| `{{CONTROLLER_PORT}}` / `{{CONTROLLER_SECRET}}` | `.env` |
| `{{DNS_DEFAULT_NAMESERVER}}` / `{{DNS_NAMESERVER}}` / `{{DNS_FALLBACK}}` | `.env` |
| `{{DNS_CN_NAMESERVER}}` / `{{DNS_FOREIGN_NAMESERVER}}` | `.env` (split-horizon pair; also selects which fenced DNS core renders — v2 foreign-by-default when set, legacy `nameserver`+`fallback` when unset) |
| `{{GEOIP_NO_RESOLVE}}` | `.env` `DNS_GEOIP_NO_RESOLVE` (renders `,no-resolve` onto the GEOIP rule when `true`) |
| `{{TUN_AUTO_REDIRECT}}` | `.env` (defaults to `false` when absent) |

Edit proxy **rules**, the `proxy-groups` / `proxy-providers` blocks, ports, etc. directly in the
template (they are not parameterized). After editing, re-render with a **forced recreate**:

```sh
docker compose --env-file ../syno-mihomo-gateway-data/.env up -d --force-recreate mihomo
```

(or `sudo sh scripts/gateway.sh redeploy --yes`). A plain `up -d mihomo` is a **no-op** when
the image and compose model are unchanged — the entrypoint only re-renders on recreate, so a
template-only edit is silently ignored. To customize routing, edit the `rules:` list — the
defaults are `GEOIP,LAN,DIRECT,no-resolve` / `GEOSITE,NETFLIX,STREAMING` / `GEOSITE,CN,DIRECT` /
`GEOSITE,GEOLOCATION-!CN,PROXY` / `GEOIP,CN,DIRECT` / `MATCH,PROXY`: private/link-local
destinations never ride the tunnel (`LAN` is hardcoded in mihomo — no geo database needed),
streaming rides its own pinnable group, CN traffic goes direct, listed-foreign domains ride
the proxy **without** any local DNS lookup, and the GEOIP fallthrough catches the rest. `PROXY` is a selectable group
that defaults to `auto` (the fastest node from your subscription) and also offers `DIRECT` /
`REJECT`; `STREAMING` is a second selector that defaults to `PROXY` — pin a
streaming-unlock-capable node there from MetaCubeXD to move **only** streaming traffic
(`auto` picks nodes by latency, which is rarely an unlock node). Rules must target a
**proxy-group**, never a `proxy-provider` directly, and the geosite categories (`netflix`,
`cn`, `geolocation-!cn`) come from the community-maintained lists already shipped in the
pre-seeded `geosite.dat` — no extra downloads.

The template also carries a `geo-auto-update` / `geox-url` block that points the geo-database
downloads (needed by the `GEOSITE`/`GEOIP` rules) at a jsdelivr CDN mirror — mihomo's default
source is blocked in mainland China, and a hung geo download prevents mihomo from ever
finishing startup. If that mirror is blocked for you, replace the three URLs in the template
(and re-render as above).

## Subscription format

`../syno-mihomo-gateway-data/config/subscription.txt` — first non-comment, non-blank line
wins. An optional `Name=` label is stripped; the rest (the URL, including any
`?token=…&flag=…`) is used verbatim. After editing it, re-render with the same
`--force-recreate` command as above (or `sudo sh scripts/gateway.sh modify --subscription URL --yes`,
which edits and re-renders in one step).

```text
# both of these work:
Default=https://provider.example/api/v1/subscribe?token=abc&flag=1
https://provider.example/api/v1/subscribe?token=abc&flag=1
```
