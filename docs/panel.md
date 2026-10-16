# Gateway Panel

The **gateway panel** (`mihomo-panel`, the compose `panel` service) is the third
container of the stack: a small FastAPI app that owns **dynamic per-device
policy** (flip a device between *full-tunnel*, *full-direct*, and the default
routing without touching `.env` or restarting anything) and **persistent
traffic statistics**. It writes SRC-IP rule files into mihomo's config volume
and hot-reloads them over the controller API — mihomo itself is never
restarted for a policy change.

- Web UI: `http://<PANEL_IP>:<PANEL_PORT>/ui/` (default port 8090), bilingual,
  same-origin only.
- CLI: `gateway.sh policy --list` / `--set <ip> --mode full-tunnel|full-direct|default`
  ([CLI reference](cli.md)).
- HTTP API: [generated reference](panel-api.md) — additive-only `/v1` contract.
- Doctor: `companion_health` (panel down/degraded, a stale collector, a slow
  poll, `stats.db` near its cap, or mihomo memory over a threshold ⇒ warn) and
  `policy_parity` (panel state vs mihomo rules drift ⇒ **error, exit 3**).

## How a policy change flows

1. A mutation reaches the panel (UI, CLI, or API) and is validated fail-closed
   (canonical `/32` for bare IPs, overlap and self-address refusal).
2. The desired state is written to SQLite (`policy.db`), then rendered into
   `providers/dyn-full-direct.txt` / `dyn-full-tunnel.txt` (tmp + rename).
3. The panel PUTs the matching rule providers on the mihomo controller and
   re-reads the rule counts (**count parity**). The response's honest
   `applied` / `parity` fields say whether the change is LIVE, not just saved.
4. On apply failure the panel goes **fail-static**: the marker
   `panel-apply-failed` is set, the webhook (if configured) fires, and the
   doctor's `policy_parity` reports drift until an apply converges.

The rule files sit **above** the general routing (directly under the LAN
exemption `GEOIP,LAN,DIRECT`), so a device policy beats GEOSITE/GEOIP routing,
while LAN destinations always stay direct — a full-tunnel device still
reaches the NAS.

## Precedence and the band

The static `.env` band (`FULL_PROXY_SOURCES`) still renders at deploy time;
the **dynamic entries outrank it**. The UI shows band membership on each
device row and asks for confirmation before overriding a band address
(the panel, not `.env`, is the operational authority for day-to-day flips —
the band remains the declarative baseline that survives a panel reset).

## The web UI

Four tabs, and **Stats is the one it opens on** — the question you open a
gateway panel with is what the network is doing, not which policy row to
edit.

- **Stats** — a range selector (48h / 7 days / 30 days / long-term daily), a
  traffic sparkline, and per-device totals with aliases resolved onto them.
  The window it lands on is the `stats_default_range` **setting**, not a
  constant in the bundle, so changing it does not mean shipping a new panel.
  Notes appear only when they have something to say: collection gaps (honest
  holes, never interpolated), the share of traffic attributable to an app
  together with the window that share was measured over, and — on the daily
  range — a warning when the *definition of a day* changed inside the window
  you asked about.

  Every range covers its **whole window** (with the shipped retention
  settings — see below). Since v1.11 every poll is written to the minute
  *and* the hour rows, so the 48-hour range reads the minute rows and the
  7- and 30-day ranges read the hour rows, which already include the last
  48 hours. Hours older than 90 days roll up into day rows, so the daily
  range reads the day rows *plus* the hour rows not rolled up yet, and so
  includes the last 90 days. Days the panel has not rolled up yet are keyed
  under the current timezone and day start — the stamp they will carry once
  rolled — so a window that spans a changed day boundary still shows the
  seam. (Before v1.10.3 the browser picked one tier and the newest part of
  each window was silently missing.) The API exposes the same presets as
  `range=48h|7d|30d|daily`; a request with only `tier` still reads that one
  table, as it always has. Coarser rows are never split back into finer
  ones, so a window still ends at its resolution's retention: lowering
  `PANEL_STATS_MINUTE_HOURS` below 48 or `PANEL_STATS_HOUR_DAYS` below 30
  shortens the 48-hour or 30-day view to that retention, as it did before.
- **Devices** — the policy editor, with the band badge, the confirm before
  overriding a band address, and the apply badge described above.
- **Audit** — one screenful at a time through the server's existing
  `offset`. Below 760px each entry is a card with labelled fields; above it,
  a table. Timestamps, addresses and requester IPs never wrap mid-token.
  Only the newest page auto-refreshes: re-fetching a raw offset while new
  entries push rows down would duplicate some and skip others, so an older
  page says it is paused rather than shuffling under you.
- **Settings** — timezone, the hour a stats day starts, the landing range,
  and device aliases. Each setting shows whether the value is **yours or
  inherited**, and clearing a field reverts it to the shipped default rather
  than storing an empty string.

The panel is a single-page app served **same-origin** from the panel itself,
which is why the API needs no CORS headers at all. It makes **zero external
requests** — no fonts, no CDN, nothing — which is enforced at runtime in a
real browser rather than by reading the source. Writes are token-gated: the
first one prompts for `PANEL_SECRET` and the token is kept only in that
browser.

Warnings never ride on `alert()`. A browser can switch dialogs off for a
page, which would silently swallow the one message that matters most — that
the gateway may not match what the panel is showing. They render in-page, on
a banner that stays put when you scroll and stacks rather than overwriting an
unread one.

## Device names (aliases)

A name and a routing policy are separate things: the shipped `devices` table
requires a mode on every row, so naming a host there would force a routing
decision onto it. Aliases therefore live in their own sidecar, keyed on the
host address, and a device can be named whether or not it carries a policy.
Naming applies no policy and triggers no reconcile — there is nothing for
the gateway to *do* about a label.

Every alias records **where it came from**, and that provenance decides who
may overwrite it:

- **An alias you typed outranks every importer.** A sync leaves those rows
  untouched and reports each one as `skipped`.
- **The consequence is deliberate, and worth knowing before you use it:**
  once you name a host in the panel, it stops following later renames on the
  vendor side. To hand that host back to the sync, clear its alias — or
  re-run the sync with `--adopt`, attended.
- An importer may always update a row **it** wrote, and may claim a row whose
  provenance is unknown (only raw SQL that omitted the column can produce
  one, so it carries no authority).

Import a batch from the host with `gateway.sh alias --sync --from <source>`
(`--list` prints what is stored). Two sources ship: `unifi` reads a
controller through `UNIFI_*` in `.env`, and `file` reads an
`{"entries":[{"ip":…,"alias":…}]}` document from
`<data-dir>/identity/aliases.json` — the same path a Nimbus export or a
hand-written list uses. The output is a **per-row ledger**:
`applied` / `unchanged` / `skipped` / `rejected`, and a row that met an
existing alias also reports the alias and provenance already stored, so a
skip names who owns the name it declined to overwrite. (A `rejected` row
never reached the store, so it carries only the address and the reason.) A
skip is a designed refusal, not a failure — the run still exits 0 — and a
bare total would hide exactly the rows the rule exists to protect.

The panel itself stays vendor-agnostic and **never holds a vendor
credential**. `POST /v1/identities/import` knows only `{ip, alias, source}`;
no vendor code ships inside the panel image. The adapter runs on the host in
a **one-shot container** built from the panel image and used purely as a
python runtime, and the credential reaches it on **stdin** — never on the
command line (`ps` shows argv on both sides) and never in the container's
environment. `alias --sync` requires root whichever source it uses: it reads
its input out of the root-owned data dir (`unifi` the credential in `.env`,
`file` the document beside it) and starts a container — more than the
`policy` verbs' "only the panel's own authenticated API" exemption covers,
with `unifi` the sharpest case since the credential then also leaves the
host. `--adopt` requires `--yes` as well, because it is the one mode that
can overwrite a name a human typed.

### Which name you see

A name has exactly **one home**. A single host (`/32`) is named by its alias
— the identity-layer name: it survives the device's policy being removed,
and yours outranks every importer. A range cannot carry an alias (an alias
is keyed on a single host), so its policy-scoped `name` on the `devices` row
is the only name it can have.

- **Rename writes whichever layer the address can carry** — one control, no
  choice to make.
- **Upgrading does not change any name you see.** Older versions could hold
  a second, policy-scoped label on a host; the upgrade migration moves a
  label that had no alias into the identity layer as your own edit, and
  retires one an alias had already displaced into the audit trail
  (`rename 'old' -> ''`), where the text stays recoverable. The name each
  device displays is identical before and after.

TLS certificates are **verified by default**. A UniFi console ships a
self-signed certificate, so the first sync against one fails on purpose;
`UNIFI_INSECURE=true` in `.env` is the explicit opt-out, rather than a
silent downgrade on a credential-bearing call.

## Deployment

The panel deploys with the stack — `install.sh` (fresh) prompts for
`PANEL_IP` (a spare LAN address on the gateway's subnet, conflict-checked)
and **generates `PANEL_SECRET`** (32 hex chars); an upgrade migrates a
pre-panel `.env` the same way and folds `PANEL_IMAGE` into `UPDATE_IMAGES`.
Compose fails loudly (`${PANEL_IMAGE:?}` / `${PANEL_IP:?}`) until the knobs
exist. The image comes from your ACR in `acr` mode (mirrored by the image
pipeline) or from an operator-supplied `PANEL_UPSTREAM` in `docker` mode —
see [configuration](configuration.md) for every `PANEL_*` knob.

Least privilege: the container runs as uid 10001 and mounts ONLY the
provider write surface and its own `state/panel` subdirectory — never the
data-dir root and never `state/` itself (the auto-updater's metadata lives
there). The installer hands both mounts to that uid before `compose up`.

## Data, retention, backups

`state/panel/` holds `policy.db` (device policy + audit log) and `stats.db`
(traffic history, honest gap rows when the collector was down). Every policy
mutation snapshots the committed `policy.db` to a rotating
`policy.db.bak-<timestamp>` beside it (`PANEL_BACKUP_KEEP`, default 5);
`stats.db` is derived history with no automatic backups. Retention knobs
(`PANEL_STATS_*`) are documented in [configuration](configuration.md); the
runbook for backup / restore / reset / purge is in
[operations](operations.md).

What `stats.db` keeps (since v1.11):

| Data | Kept | Notes |
|---|---|---|
| Bytes per device and policy group, per minute | 48 h | A finer copy of the newest hours. |
| The same, per hour | 90 d | Written at every poll, so it is always complete. |
| The same, per local day | 730 d | Hours older than 90 d roll into days. |
| Bytes per device by exit node, rule type, category, destination country | 90 d of hours + 730 d of days | Recorded from v1.11 on. For that traffic each adds up to the device total; a window that reaches back before the upgrade (or into a time an older panel ran) holds device bytes the dimensions never saw. Country reads `unknown` while the running mihomo build does not report it; category stays empty (not yet attributed) until a category dictionary ships. |
| Bytes per device by hostname, sniffed name, destination ASN, destination port | 7 d, forced | Only with `PANEL_STATS_DOMAINS` on. No knob extends it. |
| Attribution coverage (which share carried a hostname, by rule) | 7 d, forced | A rule's payload is stored only for GeoSite, GeoIP, RuleSet, Match and SrcIPCIDR rules. Every other type (the Domain rules, which can name your subscription's own server) is stored blank. Rows written before v1.11 keep their payload until they age out or are purged. |

mihomo's own traffic (subscription pulls, health checks) is counted under the
device `gateway`. When the hard size cap (`PANEL_STATS_CAP_MB`) is reached,
the oldest data goes first, whichever table holds it. A seven-day row goes
first only when it is exactly as old as a long-term one.

**Running an older panel over a v1.11 store.** The panel can be downgraded
by hand, or by the updater's automatic rollback after a failed health check.
The older image opens the store and counts every byte once in its 7-day,
30-day and daily views: v1.11 keeps its minute rows in a table of its own
(`stats_minute_v5`), so nothing is counted twice. The older image's 48-hour
view reads only its own minute rows, so it starts empty and fills as it
collects. Whatever the older image collects is folded back in when v1.11
starts again. What the older image cannot do is look after the tables it
does not know:
- It never prunes or purges the v1.11 tables (the minute tier, the dimension
  tables, and the seven-day `stats_sniff`, `stats_asn` and `stats_port`).
  With `PANEL_STATS_DOMAINS` on, those seven-day rows outlive seven days
  until v1.11 returns. Its first maintenance pass, about a minute after
  start while the collector runs, prunes them.
- Its size cap trims only its own tables.
- The dimensions get no entries for the time it ran.

Before downgrading by hand, purge the seven-day tables with `POST
/v1/stats/purge` and `{"tables": ["stats_sniff", "stats_asn", "stats_port"]}`
(see [operations](operations.md)). An automatic rollback cannot do this for
you, so those rows stay until v1.11 is back.

## Security

- **Never expose the panel to the WAN** — do not point cloudflared (or any
  tunnel/port-forward) at `PANEL_IP`. The panel is designed for the LAN only:
  **reads are open on the LAN even when mutations are locked**, so WAN
  exposure leaks your device policy and traffic history no matter how strong
  `PANEL_SECRET` is, and the bearer check has no rate limiting — secret
  entropy is the only brute-force barrier for mutations.
- Mutations always require `Authorization: Bearer <PANEL_SECRET>`; an empty
  secret refuses every mutation (fail closed), it does not open them.
- Recorded follow-up (not in v1): an automated doctor check for accidental
  WAN exposure would need a Cloudflare API credential and scope of its own —
  cloudflared runs in token mode here, so its ingress mapping is invisible to
  any local file. Until that exists, this warning is the control.

## Collector health

`/health` (LAN-open, flat keys, numbers only, no error text) reports how the
stats collector is doing. `null` means "not measured yet", never zero.

| Key | Meaning |
|---|---|
| `collector` | `ok`, `stale` (no recent successful poll), `off` (`PANEL_STATS_POLL_S=0`) or `error` (stats store unavailable) |
| `collector_lag_s` | Seconds since the last successful poll |
| `collector_poll_ms` | Mean duration of the last 30 successful polls (fetch + store), ms |
| `collector_conns` | Connections in the last snapshot |
| `collector_failed_polls` | Polls that failed since the panel started |
| `collector_interval_s` | The poll interval the panel is actually using (`0` = collector off) |
| `stats_db_bytes` / `stats_cap_mb` | `stats.db` size, and the cap the panel is actually using (`0` = none) |
| `stats_db_growth_mb_day` | How fast `stats.db` grew over the last day, MB/day (null until an hour of samples; negative after a purge) |
| `mihomo_mem_mb` / `mihomo_version` | mihomo's in-use memory and running version, read once a minute |

`collector_interval_s` and `stats_cap_mb` go beyond the seven telemetry keys
the work order listed. They let the doctor and the release validator compare
numbers the panel reports, instead of re-reading `.env` knobs that the panel
may parse differently or that were edited without a redeploy.

`GET /v1/stats/self` serves the same gauges as a timeline, one row a minute
for seven days. Purge it like any other table (`stats_self`).

## When something is off

[Troubleshooting](troubleshooting.md) covers the concrete cases: policy
drift (`policy_parity` exit 3, the marker), 403 on every mutation, the
fail-static recovery path, the collector warnings, and why a full-direct
device can still show a foreign-DNS asymmetry.
