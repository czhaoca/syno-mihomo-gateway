# Brainstorm brief — Panel UI v2: stats-first, settings, local-time rollups, app attribution

Date: 2026-07-29 · Mode: greenfield (`/brainstorm`) · Epic: `panel-ui-v2`
Relates to: `gateway-panel.md` (the v1.8.0 epic this extends — its DEC-4 band
fallback, DEC-8 domain-stats retention, and its no-build UI choice, which **DEC-1
below deliberately reverses**).

## Idea

v1.8.0 shipped the panel: per-device policy plus persistent stats behind a ~25KB
no-build vanilla UI. Living with it exposed five gaps — the landing tab is Devices
rather than Stats, there is no settings surface at all, every bucket boundary is
UTC on a UTC+8 network, traffic has no app-level attribution, and the audit view is
unreadable on a desktop. This epic addresses all five, and deliberately splits them
across three releases so a framework migration never rides in the same NAS
validation as new data semantics.

**The reported bug, diagnosed:** `style.css:42` caps `main` at `max-width: 640px`
for **every** viewport and the file contains **zero `@media` queries**, so the
5-column audit log (`Time|Action|Target|Requester|Note`) renders in ~614px on a
2560px desktop. `style.css:82-83` then applies `word-break: break-all` to every
`td`, shattering `2026-07-26T14:03:11Z` into `2026-07-2 / 6T14:03:1 / 1Z`. The UI
calls `/v1/audit` with no params (`app.js:302`), so the server default `limit=200`
dumps 200 rows with no paging — though the server has supported `offset` since
v1.8.0 (`routes.py:296-299`). It is not "desktop-cramped": at 390px those same five
columns get ~75px each. One table layout, hostile at every width.

## What was already built (corrects three of the five seed assumptions)

- **"Add a device table with alias"** — `devices` already exists *with* a `name`
  column (`db.py:57-65`). The real defect is that `mode` is `NOT NULL CHECK IN
  ('full-direct','full-tunnel')`, so **a device cannot be named without also being
  given a routing policy**. The work is splitting identity from policy.
- **"Aggregate hourly into daily"** — `stats_minute`/`stats_hour`/`stats_day`
  already exist and roll up every 60s. The gap is purely that
  `collector/core.py:24` stamps `datetime.now(UTC)`, so every boundary is UTC.
- **"Per-app categories"** — `stats_domain` already captures per-domain bytes, and
  the collector already fetches `rule`/`rulePayload`/`sniffHost` and **discards
  them** (`stats.py:117-123` reads only 6 fields). Attribution needs no new mihomo
  call, mount, or dependency.

## Dimensions (options weighed → chosen)

- **frontend** — vanilla + design-system vs vendored Preact+htm vs **React + MUI
  with a build step (chosen, DEC-1)** vs vendored CSS framework. Chosen against the
  dimension's own recommendation; see DEC-1 for the costs accepted.
- **data & storage** — identity/policy split via an **IP-keyed `device_identity`
  sidecar** leaving the shipped `devices` table untouched; **k/v settings table**
  with defaults in code; **UTC minute/hour + local-keyed day tier** (DEC-4);
  classification stored at ingest into a bounded category cascade.
- **app classification** — curated table vs **geosite-derived dictionary** vs rule-
  engine tagging vs ASN. Chosen: geosite-keyed hybrid, **gated behind a measurement
  spike** (DEC-6) — keying category ids to geosite names means the same identifier
  that labels a byte today renders the blocking rule tomorrow.
- **backend & API** — **additive overlay**: new tables + new routers, no semantics
  change to any shipped endpoint, so `/v1` stays genuinely additive and the
  byte-identity contract gate needs only a regenerate.
- **testing** — **Playwright as a required gate** (DEC-8). Today *zero lines* of
  `app.js` execute in CI; the UI leg of `panel_e2e_check.py:299-316` asserts only
  that the served HTML contains the string `data-testid`.
- **security** — settings are a **read-time projection** over immutable UTC buckets
  wherever possible, so the settings the owner most wants mutate zero rows; the
  UniFi credential never enters the panel (DEC-7).
- **docs & upgrade** — fold into the existing panel doc family; stamp existing
  installs `bucket_tz=UTC` so shipped v1.8.0 history keeps its meaning.

## The three gates that actually bind the UI

Two are commonly mis-stated; recorded here so the rewrite does not trip them.

1. **`app/tests/test_static_ui.py:79-96`** forbids *any* `https?://` string under
   `app/static` (two inert SVG/XHTML exceptions). This — not the enduser leak-gate —
   is what makes vendoring a third-party dist hard: React and MUI embed doc URLs.
2. **`validate_release.sh:548`** greps `data-i18n="app_title"` out of a **raw
   `wget`** of `/ui/` during A6, a REQUIRED release gate. **No JavaScript runs.** A
   client-rendered `<div id="root">` shell fails the release unless the marker is
   kept in the shell verbatim.
3. **`privacy_check.py:145-160`** scans tracked files **plus full reachable
   history**, so a committed vendor blob can never be removed without a history
   rewrite.

**Correction to a widely-assumed constraint:** `package.sh:52` sets
`ENDUSER_EXCLUDES=". :(exclude)app …"`, so the entire `app/` tree — UI included —
is **excluded from both shipped bundles**. The UI reaches the NAS inside the panel
image (`app/Dockerfile:16`). A build step therefore does **not** touch the enduser
install story at all.

## Decisions (owner-resolved 2026-07-29)

- **DEC-1 — UI stack: React + MUI with a build step.** Chosen over the frontend
  dimension's recommendation (stay vanilla + design system). Costs knowingly
  accepted: the zero-external-URL gate relaxes to a dist allowlist, the testid gate
  is repointed from `index.html` to JSX source, the A6 marker must be hand-kept in
  the Vite shell, and a node supply chain enters a GFW-adjacent repo. Bought: a
  component library and design system for a surface about to grow settings,
  per-app charts, and a responsive audit view.
- **DEC-2 — The build runs in CI and is baked into the image; nothing is
  committed.** No `dist/`, no `node_modules`, no vendor blob in git — which also
  keeps `privacy_check`'s full-history scan clean forever.
- **DEC-3 — The node build lives in a `app/Dockerfile` builder stage.** Resolves
  DEC-2 against the real pipeline: Panel Build is `runs-on: self-hosted` and builds
  from a **fresh checkout of the release tag** (`panel-build.yaml:72-77`), so it
  cannot consume a Woodpecker artifact. With the build in the Dockerfile, Panel
  Build needs **zero changes** and a local `docker build` reproduces the shipped
  image. Woodpecker's role: lint + test + a build smoke on the UI source.
- **DEC-4 — Timezone model: UTC minute/hour, LOCAL-keyed day tier.** `stats_day`
  is keyed by the local day with `tz` and `cut` stamped **per row**. Changing the
  timezone later leaves historical rows on their original stamp — a visible, honest
  seam rather than silently relabelled numbers. Existing installs are stamped
  `bucket_tz=UTC`, `day_boundary=00:00` so shipped v1.8.0 history keeps its meaning.
- **DEC-5 — Default timezone inherits the container's `TZ`; settings override.**
  Rejects hardcoding `Asia/Taipei` in the panel: the stack already ships
  `TZ=Asia/Shanghai` (`.env.example:322`) into every container, and a panel that
  disagrees with mihomo and the updater about what "today" means is a bug
  generator. Both zones are UTC+8 with no DST, so the arithmetic is identical —
  this is about a single source of truth, not the numbers.
- **DEC-6 — Measure attribution coverage before building the dictionary.** v1.9
  keeps `rule`/`rulePayload`/`sniffHost` and reports what fraction of bytes are
  attributable at all; v1.10 scopes the dictionary against that real number.
  Rationale: this feature exists to enable **blocking**, and blocking on bad
  attribution takes out the wrong app on a gateway carrying all LAN traffic.
- **DEC-7 — Alias sync: a generic import endpoint; vendor adapters live outside.**
  `POST /v1/identities/import` takes `{ip, alias, source}`; a host-side
  `gateway.sh alias sync` speaks UniFi and pushes. The panel already holds
  `CONTROLLER_SECRET` and can write routing rules — a UniFi credential does not
  join that blast radius, and non-UniFi users get no dead vendor code.
- **DEC-8 — Playwright is a required CI gate, browsers pre-baked into the image.**
  The only layer that can assert the three things this epic rests on: zero requests
  leave the origin at *runtime*, badges render from the API's `applied`/`parity`
  answer, and the audit layout is readable at 1280px *and* 390px. jsdom cannot see
  layout — i.e. cannot see the bug that started this epic. Pre-baked browsers avoid
  a 110MB CDN pull from behind the GFW on every run.
- **DEC-9 — Three releases: CSS relief → backend → React rewrite.** Each is
  independently NAS-validatable. v1.8.0 needed five rc runs on a far smaller
  surface with no framework change; a framework migration and new data semantics
  will not share one validation cycle.

### Pre-decided constraints (not re-decidable during execution)

- The Vite shell **must** contain `data-i18n="app_title"` verbatim in served HTML.
- `/v1` stays **additive-only**; no shipped endpoint changes semantics. The
  byte-identity contract gate is regenerated, never overridden.
- Bilingual EN + zh change together; every interactive element keeps a stable
  `data-testid` (asserted against the **rendered** DOM once Playwright lands).
- Storage stays UTC for minute/hour tiers. Only the day tier is local-keyed.
- The panel never holds a vendor (UniFi) credential.
- Category ids are keyed to mihomo's own geosite vocabulary so the identifier that
  labels a byte can render the blocking rule unchanged.

### Deferred decision points (decided at execution)

- **DEC-A** — per-category retention: inherit `stats_domain`'s forced 7 days, or
  longer? Seed req 3 wants 30-day views, so categories likely need their own cap.
- **DEC-B** — app-level vs vendor-level labels where a CDN is shared (alicdn,
  gtimg/qpic, ByteDance edge genuinely cannot separate WeChat from QQ, or Douyin
  from TikTok). This is the one place the feature could actively lie.
- **DEC-C** — does the attribution floor require a hostname, or may weaker signals
  count? Sets whether "unclassified" stays honest or quietly absorbs guesses.
- **DEC-D** — may a future per-app block modify `config.template.yaml`? Blocking
  needs `RULE-SET,dyn-block,REJECT` spliced **above** the dyn-full pair, or a
  full-direct device's blocked traffic matches DIRECT first and is never rejected.

## Bugs found while scoping (fix regardless of the epic)

- **Honest-state violation:** `app.js:176` warns about apply drift via `alert()`.
  A browser's "prevent this page from creating additional dialogs" checkbox makes
  `alert()` a **no-op**, silently swallowing the warning. The band `confirm()` at
  least fails closed (returns false = abort); `alert()` does not.
- **Ungated i18n keys:** `test_static_ui.py:35`'s usage regex `t\("([^"]+)"\)`
  cannot see template-literal keys, and `app.js:309-310` builds ``t(`action_${e.action}`)`` —
  so every `action_*` key is currently unverified in both languages.
- **Touch targets:** `.mode-btn` is ~28px tall (`style.css:70-73`), below the 44px
  minimum, with five wrapping in one row.
- **No dark mode:** `style.css:2-5` defines light-only tokens, no
  `prefers-color-scheme`.
- **Audit is excluded from the 10s refresh** (`app.js:382-386`) — the tab is
  silently stale until re-clicked.

## Verification gate

Per release, the repo's existing gate plus what this epic adds:

```sh
sh scripts/ci/run_all.sh          # existing shell suites
ruff check app && python -m pytest app/tests -q
python scripts/ci/panel_contract_check.py   # byte-identity OpenAPI
python scripts/ci/panel_e2e_check.py        # real uvicorn + fake controller
# v1.10 adds:
npm --prefix app/ui ci && npm --prefix app/ui run build   # build smoke
npx playwright test                                        # required UI gate
```

On-device: `validate_release.sh` A6 stays required, extended with a settings/stats
surface leg (A6b) once those ship.

## Work breakdown

**v1.8.1 — CSS relief (no framework):**
1. Kill the global 640px cap; add desktop breakpoints; per-view shell widths.
2. Fix audit readability: scoped `word-break`, column priority, sticky head,
   density, and wire the server's existing `offset` into paging.
3. Fix the `alert()` honest-state bug and the `action_*` i18n gate.

**v1.9 — backend epic (no UI risk):**
4. `device_identity` sidecar (IP-keyed) + alias CRUD, shipped `devices` untouched.
5. `POST /v1/identities/import` (generic; no vendor code) + host-side
   `gateway.sh alias sync --from unifi`.
6. Settings: k/v table, `GET/PUT /v1/settings`, defaults in code, tz inherited
   from the container.
7. Local-keyed day tier with per-row `tz`/`cut` stamps + the UTC stamp migration
   for existing installs.
8. Collector keeps `rule`/`rulePayload`/`sniffHost`; ship the coverage report.

**v1.10 — React + MUI rewrite:**
9. Vite + React + MUI scaffold; node builder stage in `app/Dockerfile`; gate rework
   (zero-URL allowlist, testid gate repointed to JSX, A6 marker preserved).
10. Playwright required gate with pre-baked browsers.
11. Stats-first IA: Stats landing tab, range selector (7d/30d/daily), settings page,
    responsive audit view.
12. Category dictionary + per-app charts, scoped to what the v1.9 measurement showed.
