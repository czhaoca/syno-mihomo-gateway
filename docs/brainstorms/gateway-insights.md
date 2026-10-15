# Brainstorm brief — Gateway Insights: the panel's stats surface → a UniFi-class analytics platform

Date: 2026-10-15 · Mode: greenfield (`/brainstorm`) · Epic: `gateway-insights`
Relates to: `gateway-panel.md` (the v1.8.0 epic whose DEC-8 stats tiers and DEC-12 scope
line this brief extends and — for DEC-12 — **formally revises**), `panel-ui-v2.md` (the
v1.9/v1.10 epic whose item 12 "category dictionary + per-app charts" never shipped and
whose deferred DEC-A/B/D are carried here), `dns-privacy-hardening.md` (the retention
promise for hostname-derived data).

## Idea

The owner asked for three things: a review of the "status tracking interface", an
official name for it, and the critical questions that decide how it grows into an
analytics platform comparable to UniFi Network's Traffic/Insights stats — justified by
the fact that every LAN flow transits the mihomo transparent proxy, so the gateway can
observe what a router-side DPI engine observes.

**The interface, named.** The status tracking interface is the **Gateway Panel**'s
Stats tab (`mihomo-panel`, compose service `panel`: FastAPI + SQLite, React 19 / MUI 6
SPA served same-origin at `/ui/`). Its analytics subsystem is from now on officially
**Gateway Insights** (DEC-1): the name of the tab, the guide, and the epic. The container,
service, and `PANEL_*` knob family keep the names gateway-panel DEC-10 fixed — Insights
is a surface *inside* the panel, not a fourth container.

**What the platform must become.** Per-client traffic history, per-category and per-app
breakdown (UniFi's DPI equivalent, derived from hostnames mihomo already sees), top
destinations, exit-node and destination-country breakdown, connection counts and peak
rates, time-series with a range picker and drilldowns, a live-throughput tile, node delay
history and subscription quota — all under the panel's existing honesty rules (gaps are
holes, stale is labelled, unattributed is a permanent segment) and its privacy promise
(hostname-derived rows are zero by default and capped at seven days when opted in).

## What was already built (and what the review found)

- **Stack (verified, v1.10.2).** Collector: `GET /connections` snapshot every 10 s via
  urllib (runtime deps are fastapi + uvicorn only, by constraint). It reads
  id/up/down/sourceIP/host/sniffHost/rule/rulePayload/`chains[-1]` and discards dst
  IP/port, network, inbound type, start, dnsMode, and the geo fields newer mihomo builds
  carry. **`chains[-1]` is the outermost policy group ("Routing Mode"), not the exit node
  (`chains[0]`)** — the shipped "chain" dimension is nearly constant. The flush issues one
  SELECT per connection plus a full baseline scan per poll (`app/store/stats.py:214-266`).
- **Store.** `stats.db` user_version 3: minute/hour/day tiers keyed (bucket, device,
  chain) at 48 h / 90 d / 730 d under a 512 MB cap; `stats_domain` opt-in with a forced
  7-day horizon; `stats_coverage` (7 d); gaps; baselines. Bytes only — no counts, no
  rates. One shared SQLite connection and one RLock cover both collector writes and API
  reads (`app/main.py:64-98`).
- **API.** `/v1/stats/{devices,chains,timeline,domains,coverage,gaps}` + `purge`; `/v1`
  additive-only behind a byte-identity OpenAPI gate that admits only `/health` and
  `/v1/*` paths (`scripts/ci/panel_contract_check.py:113-119`); reads LAN-open; `/health`
  flat-keyed because the doctor's sed extractor cannot read nesting.
- **UI.** No chart library — one hand-drawn SVG polyline (`app/ui/src/controls.jsx`),
  six GETs per 10 s tick, no router or URL state, light-only theme, zero-external-request
  gate enforced at four layers, **no bundle-size budget** (dist ≈ 389 KB). Playwright
  (27 specs) is a required gate that runs collector-off and stubs stats with
  `page.route`; its `open()` waits on `networkidle`. `/v1/stats/chains` and the domain
  rows are never rendered.
- **Platform.** Panel `mem_limit 256m`, uid 10001, mounts only the providers directory
  and `state/panel`, own macvlan seat. The mihomo image is `:latest` from the ACR mirror,
  so its API surface drifts nightly: field presence must be feature-detected, never
  assumed. The template carries no REJECT rule, so "blocked traffic" is structurally zero
  until the dyn-block splice (panel-ui-v2 DEC-D) exists.
- **Unshipped prior scope.** panel-ui-v2 item 12 (category dictionary + per-app charts)
  was gated by its DEC-6 on the real coverage number and never built; `/v1/stats/coverage`
  ships, the dictionary does not. The A6b stats validation leg promised in that brief was
  never added to `validate_release.sh`.

### Bugs found while scoping (fixed regardless of the epic)

- **Tier-continuity bug.** Rollup moves minute rows older than 48 h into hours *and
  deletes them* (`app/store/stats.py:289-367`); every read is single-tier
  (`read_grouped` / `read_timeline`, `stats.py:442-517`); the UI maps 7d/30d to
  `tier=hour` (`app/ui/src/stats.js:17-25`). So the **7d and 30d views omit the newest
  48 hours** and **"daily" only holds data older than 90 days**. No test asserts that a
  window total equals the union of tiers. Ships first as v1.10.3 (DEC-6).
- **Airport-hostname leak.** `{{AIRPORT_DIRECT_RULE}}` renders a
  `DOMAIN,<airport-host>,DIRECT` rule whose payload lands in `stats_coverage.rule_payload`
  and is served openly by `/v1/stats/coverage` (DEC-4 closes it).
- **Doc drift.** `docs/development.md`'s local-check list lacks the npm ci / lint /
  build-check / Playwright commands the CI steps run; `AGENTS.md` says 15 blocking steps
  (it is 16 — `ci-pins` is missing); panel-ui-v2's verification block cites a
  `scripts/ci/run_all.sh` that does not exist.

## Dimensions (options weighed → chosen)

- **backend / collection** — HTTP poll at a faster cadence vs hand-rolled RFC 6455 ws
  client vs `websockets` dep vs `/logs` stream. **Chosen: HTTP polling, flush made O(1)
  first, then 2–5 s (DEC-3).** Decisive fact: mihomo's `/connections` WebSocket pushes
  the *same full snapshot* per interval — it is not an event feed — so a ws client buys
  ~1 ms of round-trip at the cost of the supply-chain constraint. API: one additive
  `breakdown?dim=` route (dim as a parameter keeps the OpenAPI diff small), one `overview`
  aggregate (one lock acquisition), server-side `range=` presets, SSE via
  `StreamingResponse` for live (no new dependency).
- **frontend** — hand-rolled SVG chart kit vs `uplot` vs `@mui/x-charts` vs
  recharts/chart.js/echarts/visx. **Chosen: hand-rolled kit + a dist-size gate (DEC-7).**
  Every honesty primitive this panel needs (hatched gaps, framing seams, a permanent
  "unattributed" segment, stale/unavailable frames, DOM-assertable marks) is an overlay
  no library ships; a library would save the easy 40 % and leave the hard 60 %. IA: keep
  the four tabs; one `AnalyticsView` parametrised by scope {overview, client, app, host};
  a ~40-line hash router (the hash never reaches FastAPI, so the A6 raw-HTML grep is
  safe); one scoped fetch per tick with in-flight skip and hidden-tab pause.
- **coding paradigm / engineering practices** — split `app/store/stats.py` (650+ lines)
  into a `stats/` package with re-exports; per-request read-only (`mode=ro`) connections
  so the RLock becomes writer-only; migrations stay linear and additive (no DROP) so an
  image rollback over a newer database is safe; a soft ~400-line module norm in
  AGENTS.md (no gate); ruff gains SIM/RUF/PERF.
- **TDD / testing** — seeded-random vs hypothesis vs golden-only. **Chosen: hypothesis as
  a pinned dev dep** for three named invariants (I-1 any window total equals the union of
  tiers; I-2 rollup is lossless for any `now`; I-3 the cap never prunes a newer tier while
  an older one has rows), golden JSONL frames (synthesised, TEST-NET + `example.com` only
  — a capture can never be committed because the privacy gate scans full history), a
  perf-guard pytest with 10× headroom plus a local-only bench script, migration tests on
  a populated v3 store (`test_day_tier.py` idiom). Playwright stays collector-off and
  stubs with the *same* golden series the pytest suite reads; marks carry
  `data-bucket/up/down/gap/seam` so specs assert counts and text, never pixels.
- **CI/CD** — a per-asset dist-size ceiling joins `ui_build_check.py` with a negative
  control; the tier-continuity invariant lives in `app-unit`; no Woodpecker benchmark
  step (shared agent, wall-clock noise). Release phasing per DEC-8.
- **data & storage** — one cube vs star vs DuckDB/embedded TSDB. **Chosen: star model in
  SQLite (DEC-4)**: one fact table per dimension keyed (bucket, device, value) on the
  shared hour/day tiers, nothing new in the minute tier (5× storage). Sizing for a ~50
  device home: ≈ 40 MB per dimension for 90 d of hours plus ≈ 45 MB per dimension for
  730 d of days → four long-term dimensions ≈ 170 MB inside the 512 MB cap. DuckDB's
  ~40 MB wheel breaks the dependency constraint to solve a problem that does not exist
  below ~1 M rows per table. Continuity fix: materialise hour at ingest and synthesise the
  un-rolled day window from hour rows under the current frame (DEC-6).
- **infra & deploy** — no new container, no new mount, no new port. Resource envelope:
  a 1000-connection snapshot is ~400 KB of JSON, ~20 ms to parse and ~30 ms to flush once
  the baseline lookup is batched — ~3 % of a core at a 2 s cadence, inside 256 MB.
- **security & authz / privacy** — category long-term vs everything hostname-derived at
  7 d vs token-gated reads. **Chosen (DEC-4/5/12):** coarse categories and country are
  long-term; hostname, sniffHost, ASN (names an app almost as well as a hostname), dst
  port, and app-level category ids stay in the 7-day opt-in class; `rule_payload` is
  persisted only for category-bearing rule types; reads stay LAN-open this epic (the
  doctor's docker-exec probe needs `/health` open); `/metrics` is default-off and never
  carries the hostname class; the "never WAN-expose" warning is reaffirmed.
- **observability** — flat `/health` self-metrics the doctor can assert on, a 7-day
  `/v1/stats/self` gauge timeline, `companion_health` warnings for stale collector,
  ≥ 90 % of the cap, a poll slower than half its interval, and mihomo memory over a knob;
  `mihomo_version` recorded so `:latest` drift is visible. Prometheus exposition per
  DEC-11/12. Node delay *history* is analytics and lives in the panel; node *operations*
  stay on MetaCubexD.
- **docs** — brief-as-ADR continues (no ADR dir); this brief carries the numbered
  storage/collector invariants tests cite in docstrings; `panel-api.md` regenerates with
  every route change; a new `docs/insights.md` family (en, zh, `INSIGHTS.txt` pair) is
  born in the UI slice; `docs/panel.md` keeps policy/identity/security and links across.

## Decisions (owner-resolved 2026-10-15, one at a time)

- **DEC-1 — Name: "Gateway Insights".** The analytics subsystem inside the Gateway
  Panel; epic and brief slug `gateway-insights`; the Stats tab is renamed Insights in the
  UI slice; `docs/insights.md` is its guide. Container, service and `PANEL_*` knobs are
  unchanged (gateway-panel DEC-10 stands).
- **DEC-2 — Scope: gateway-panel DEC-12 is revised.** Old line: "panel = device policy +
  persistent stats, scope stays small forever; MetaCubexD = node/group ops + live
  connections". New line: **operations (node switching, per-connection live) stay on
  MetaCubexD; history and analytics live in Gateway Insights**, plus exactly one
  gateway-wide live-throughput tile (bytes/s + 60 s sparkline) relayed same-origin from
  mihomo `/traffic`, opt-in and default-off, labelled "not stored", showing "stale Ns" on
  stream loss rather than a frozen number. The browser never contacts mihomo.
- **DEC-3 — Transport: HTTP polling stays; O(1) flush first, then 2–5 s.** No WebSocket
  client and no `/logs` consumer in this epic. The flush batches the baseline lookup into
  one SELECT plus an in-memory dict before the default cadence drops (exact default =
  DEC-X-4); `samples` per bucket records how many polls fed it so the UI can show real
  coverage.
- **DEC-4 — Retention classes.** Long-term (hour 90 d + day 730 d): exit node
  (`chains[0]`), policy group (today's `chain`), rule type, coarse category, destination
  country. Seven-day forced opt-in class (the existing `PANEL_STATS_DOMAINS` gate,
  unchanged): hostname, sniffHost, ASN, destination port. Nothing new enters the minute
  tier. `rule_payload` is persisted only when the rule *type* carries a category
  identifier (GeoSite, GeoIP, RuleSet, Match, SrcIPCIDR) and blanked for Domain,
  DomainSuffix and DomainKeyword types — closing the airport-hostname leak without the
  panel knowing the hostname (it cannot: `subscription.txt` is deliberately not mounted).
- **DEC-5 — Dictionary: two levels, geosite-keyed.** The COARSE level (~20 ids: video,
  social, gaming, cdn, cloud, messaging, ads, system, …) is stored long-term by default;
  the APP level (`geosite:netflix`, `geosite:bilibili`, …) rides the 7-day opt-in class
  with hostname, because an app identity per device over two years is behaviourally as
  sensitive as a hostname. Category ids stay mihomo's own geosite vocabulary so the
  identifier that labels a byte can render a blocking rule unchanged (panel-ui-v2).
- **DEC-6 — Continuity fix ships as a v1.10.3 bug fix.** Server-side
  `range=48h|7d|30d|daily` presets join the existing stats reads; `tier` becomes
  *resolution* and finer tiers fill the uncovered tail; day keys for the un-rolled window
  are synthesised via `dayframe.day_key` under the current frame. Same response shape,
  more rows. **Owner acknowledgement recorded here:** a strict reading of
  `development.md`'s additive policy could call "more rows for the same query" a semantics
  change; the owner accepts it as a correction of a wrong answer, to be stated in the
  release notes.
- **DEC-7 — Charts: hand-rolled SVG kit + a dist-size gate.** `app/ui/src/charts/` with
  zero new dependencies; `ui_build_check.py` gains a total dist-JS ceiling of 450 KB raw
  with a reason-bearing bump constant (mirroring the URL allowlist). Written escalation
  trigger: adopt `uplot` (0 transitive deps, ~50 KB, canvas) only if brush/zoom or more
  than ~5k points per chart are ever required.
- **DEC-8 — Phasing: five release slices.** (a) v1.10.3 continuity hotfix; (b) v1.11
  collector v2 + v4 star schema + telemetry + A6c; (c) v1.12 dictionary + top-N API +
  exports; (d) v1.13 Insights UI; (e) v1.14 live tile + node delay + quota. Every
  `app/`-touching slice follows tag → Panel Build image → NAS validation → publish; a
  UI rewrite never shares a validation cycle with new data semantics (panel-ui-v2 DEC-9
  precedent).
- **DEC-9 — Measurement first.** Issue 1 is a read-only measurement of the production
  NAS: attribution coverage share (the number panel-ui-v2 DEC-6 was waiting on),
  `stats_db_bytes`, typical `/connections` length, the running mihomo version, and
  whether the geo fields are present. Its numbers are pasted into "Measured baseline"
  below; the dictionary scope and the cadence default cite them.
- **DEC-10 — Identity stays IP-keyed.** `POST /v1/identities/import` gains an optional
  `mac` field (additive) so the host-side alias sync can carry it for display and a
  future history merge; the DHCP-churn caveat (a device that changes address shows as
  two clients unless the router pins it) is documented.
- **DEC-11 — Export: CSV AND a Prometheus exposition.** The owner overrode the fan-out's
  CSV-only recommendation. `?format=csv` on breakdown and timeline (additive, in `/v1`)
  plus a Prometheus text exposition shaped by DEC-12.
- **DEC-12 — Metrics shape.** Root `/metrics` (the Prometheus convention; the contract
  check learns one more allowed root path, with a reason); new knob `PANEL_METRICS=false`
  by default; LAN-open like every other read; labels limited to the long-term class
  (device, exit node, group, rule type, coarse category, country) plus panel
  self-metrics — never hostname, sniffHost, ASN or app-level ids. Grafana per-destination
  panels are impossible by design.
- **DEC-13 — Dark mode inside the UI slice.** Light and dark tokens land with the chart
  kit; `prefers-color-scheme` auto-detect with a persisted toggle beside the language
  toggle; Playwright asserts both schemes render without overflow.
- **DEC-14 — One epic, `gateway-insights`.** Sequence numbers follow release-slice
  order so `/issue-resolver` drains the chain in the order the releases ship.

### Pre-decided constraints (not re-decidable during execution)

- Runtime dependencies stay fastapi + uvicorn; `hypothesis` joins the pinned dev deps
  only. No WebSocket library, no chart library, no DuckDB.
- `/v1` stays additive-only; `app/openapi.json` and `docs/panel-api.md` regenerate via
  `python3 scripts/ci/panel_contract_check.py --write` in the same commit as any route
  change; `/health` stays flat-keyed and LAN-open; `/metrics` is the only new root path
  and the contract check admits it with a stated reason.
- Migrations are linear and additive (no DROP, no column rewrite) so an image rollback
  over a newer database is safe; a test asserts every `stats_%` table is listed in both
  `PURGE_TABLES` and the cap-tier order; the cap drains by data age across all tables.
- Honest data everywhere: gaps are holes (hatched bands, never zero, never interpolated);
  rates are labelled interval averages, never "current"; "unattributed" is a permanent
  segment; "unavailable" is never rendered as "no traffic"; day-framing seams stay visible.
- The hostname class (7 d, opt-in) never reaches the long-term tiers, `/metrics`, or a
  CSV window longer than seven days; `subscriptionInfo` persists only its four quota
  numbers and `updatedAt`, never the provider URL; the panel never holds a vendor
  credential (DEC-7 of panel-ui-v2 stands).
- Feature-detect mihomo fields (`dstGeoIP`, `dstIPASN`, `/rules` counters); a missing
  field degrades to "unknown", never to an error; record `mihomo_version` in `/health`.
- UI: zero external requests (four-layer gate), system fonts only, `data-testid` on every
  interactive element asserted in JSX and in the rendered DOM, EN + zh dictionaries change
  together, the A6 marker `data-i18n="app_title"` stays verbatim in the Vite shell,
  native controls, 44 px targets, `alert()` banned, the 390 px no-overflow sweep covers
  every new scope. The hash router keeps every route client-side.
- Fixtures use TEST-NET and `example.com` addressing only; golden frames are synthesised,
  never captured from a real gateway.
- Shell stays POSIX `/bin/sh` on BusyBox; validation legs are grep-able with
  `--self-test` controls (`validate_release.sh` idiom).
- Pi lite mode has no panel: Gateway Insights is a compose-tier feature and the docs say so.
- No real addresses, identities, tokens or database files anywhere tracked (CLAUDE.md
  rule; `privacy_check.py` scans full history).

### Deferred decision points (decided at execution)

- **DEC-X-1 — Geo fields.** Whether the running mihomo exposes `dstGeoIP`/`dstIPASN`
  (issue 1 measures it); the country dimension stores "unknown" when absent.
- **DEC-X-2 — Shared-CDN labelling** (panel-ui-v2 DEC-B carried): when an edge cannot
  separate two apps (alicdn, gtimg/qpic, ByteDance edge), the label is vendor-level; the
  dictionary never guesses.
- **DEC-X-3 — The coarse category list** (~20 ids) and the geosite→coarse mapping source,
  frozen in issue 8 with a validation test.
- **DEC-X-4 — Poll cadence default** (2 s vs 5 s) from the measured `collector_poll_ms`
  after the O(1) flush lands.
- **DEC-X-5 — SSE delivery details** (heartbeat interval, reconnect, behaviour behind a
  buffering proxy) for `/v1/stats/live`.
- **DEC-X-6 — The A6c assertion set**: telemetry-based (`/health` collector keys, db
  growth, mihomo version present), never live LAN probes.

## Critical roadmap questions

Resolved by the decisions above: the name, the scope line vs MetaCubexD, the collection
transport, which dimensions are long-term and which are hostname-class, dictionary
granularity, how the continuity bug ships, the charting approach and bundle budget,
release phasing, identity keying, export paths and metrics shape, dark mode, the epic.

Still open — recorded so they are not silently assumed:

1. **The production numbers.** Attribution coverage share, `stats_db_bytes`, connection
   count, mihomo version → issue 1 (DEC-9). The dictionary's worth and the cadence default
   both hang on them.
2. **"All traffic" is not all traffic.** IPv6 clients and clients using router-side DNS on
   the same subnet never transit the gateway (doctor `ipv6_bypass`;
   `dns-privacy-hardening.md`). Insights must state what it cannot see — an "invisible
   traffic" note on the overview, and a docs section — rather than imply completeness.
3. **Per-app blocking is out of this epic.** panel-ui-v2 DEC-D needs a
   `RULE-SET,dyn-block,REJECT` splice *above* the dyn pair in `config.template.yaml`; it
   deserves its own brainstorm once categories exist, because blocking on bad attribution
   takes out the wrong app on a gateway carrying all LAN traffic.
4. **Reads stay LAN-open while the history gets richer.** A token-gated-reads knob and the
   DEC-E WAN-exposure doctor check (gateway-panel) remain follow-ups; slice (c) reaffirms
   the "never expose the panel to the WAN" warning in the docs.
5. **mihomo `:latest` drift.** The analytics depend on `/connections` field presence that
   changes under the ACR nightly mirror; the panel feature-detects and records the
   version so a regression is attributable (the pinned-version question is a separate
   release-policy decision, not taken here).
6. **Per-connection fidelity.** Flows shorter than one poll interval and REJECT counts
   need the `/logs` stream; that belongs to the blocking epic, not this one.
7. **Compare-to-previous-period** is deliberately absent: with gaps and framing seams
   differing between periods it is an honesty hazard; custom date ranges are deferred
   with it.

## Measured baseline (filled by issue 1)

_Pending the read-only measurement of the production NAS. Record: coverage share
(hostname vs ip_only, window), `stats_db_bytes`, `/connections` length at a quiet and a
busy moment, mihomo `/version`, presence of `dstGeoIP`/`dstIPASN`, `PANEL_STATS_DOMAINS`
state, and `collector_poll_ms` once slice (b) exposes it._

## Verification gate

Per slice, the repo's existing gate plus what the slice adds:

```sh
ruff check app && python -m pytest app/tests -q
python3 scripts/ci/panel_contract_check.py        # byte-identity (--write to regenerate)
python3 scripts/ci/panel_e2e_check.py             # real uvicorn + FakeController
npm --prefix app/ui ci && npm --prefix app/ui run lint
python3 scripts/ci/ui_build_check.py --build && (cd scripts/ci && python3 ui_build_check_test.py)
(cd app/ui && npx playwright test)                # UI slices
docker build -f app/Dockerfile app/               # image smoke
python3 scripts/ci/cli_contract_check.py          # only if scripts/cli/spec.yaml changes
```

Then Woodpecker green plus the GitHub `panel-image` check green; for every
`app/`-touching slice: tag → Panel Build image → owner-run `validate_release.sh` on the
NAS (A6 required; A6c joins from slice b) → publish. The hotfix additionally hand-checks
on the live panel that a 7-day window equals the sum of its 48 h of minute rows plus its
hour rows.

## Work breakdown

Fourteen issues, one chain (`Epic: gateway-insights`, Sequence 10–140, issues #90–#103, head #90), in release order.

**Slice (a) — v1.10.3 hotfix**
1. `chore(insights): measure the real NAS baseline` — read-only LAN reads of `/health`
   and `/v1/stats/coverage`; during a sudo window, `docker exec` reads of mihomo
   `/version`, `/connections` length and geo-field presence; results land in "Measured
   baseline" above (DEC-9, DEC-X-1).
2. `fix(panel): tier-complete stats reads with server-side range presets` — DEC-6;
   `range=` on devices/chains/timeline; `tier` as resolution; day keys via
   `dayframe.day_key`; invariants I-1 and I-2 as hypothesis tests; `stats.js` sends
   `range`; contract regen; release notes state the owner-acknowledged more-rows change.
3. `docs(ci): sync the local check list and the CI step count` — `development.md` gains
   the npm ci / lint / build-check / Playwright commands; `AGENTS.md` says 16 steps
   including `ci-pins`; the dead `run_all.sh` reference is corrected.

**Slice (b) — v1.11 collector v2**
4. `refactor(panel): split stats.py into a stats package with read-only reader
   connections` — `app/store/stats/{schema,ingest,maintain,read,coverage}.py` with
   re-exports so existing imports and monkeypatches keep working; per-request `mode=ro`
   readers; the RLock becomes writer-only; ruff SIM/RUF/PERF; the soft module-size norm
   in AGENTS.md. No behaviour change.
5. `perf(panel): O(1) flush per poll, samples/conns/peak facts, faster default cadence` —
   batched baseline SELECT + dict; `samples`, `conns` (first sightings), `peak_up`/
   `peak_down` per bucket with the interval recorded in `stats_meta`; perf-guard pytest
   (10× headroom) + local-only `scripts/ci/panel_bench.py`; default `PANEL_STATS_POLL_S`
   per DEC-X-4.
6. `feat(panel): v4 star schema — exit, group, rule type, category, country + the 7-day
   class tables` — DEC-4; one fact table per dimension on hour + day; hostname/sniffHost/
   ASN/port tables behind the existing opt-in gate at 7 d; `rule_payload` blanking;
   feature-detected geo (DEC-X-1); additive v4 migration with a one-shot hour backfill
   from the 48 h of minute rows; cap drains by data age across tables; invariant I-3;
   purge body gains per-device / per-table / before-timestamp; `(device, bucket)` indexes.
7. `feat(panel): collector telemetry, doctor warnings, A6c validation leg` — flat
   `/health` keys `collector_lag_s`, `collector_poll_ms`, `collector_conns`,
   `collector_failed_polls`, `stats_db_growth_mb_day`, `mihomo_mem_mb`, `mihomo_version`;
   `/v1/stats/self` 7-day gauges; `companion_health` warns on stale collector, ≥ 90 % of
   the cap, poll slower than half its interval, mihomo memory over a knob;
   `validate_release.sh` A6c per DEC-X-6.

**Slice (c) — v1.12 dictionary + API**
8. `feat(panel): two-level category dictionary keyed to geosite` — DEC-5, DEC-X-2/3;
   classification at ingest from hostname only (panel-ui-v2 DEC-C: never weaker signals);
   coarse long-term, app-level 7 d opt-in; the coverage report gains per-class shares;
   the dictionary is an in-repo data file with a validation test.
9. `feat(panel): breakdown + overview top-N endpoints and CSV export` —
   `/v1/stats/breakdown?dim=exit|group|rule|category|country|host&range|tier&since&until&device&sort&limit&offset`,
   `/v1/stats/overview?range&device&category&host` (one lock acquisition), window-scoped
   gaps, `?format=csv`; contract regen; `docs/panel.md` + zh reaffirm the WAN warning.
10. `feat(panel): Prometheus /metrics behind PANEL_METRICS` — DEC-11/12; contract-check
    root-path allowance with a reason; labels = long-term class + self-metrics; knob
    documented in `configuration.md` and `.env.example`; LAN-only security note.

**Slice (d) — v1.13 Insights UI**
11. `feat(panel-ui): SVG chart kit, dist-size gate, light/dark tokens` — DEC-7/13;
    `src/charts/` (stacked area and bars with gap bands, top-N horizontal bars, share bar,
    axis, DOM tooltip, legend, ResizeObserver width); `ChartFrame` states {fresh,
    stale-since, unavailable(reason), empty} each with a testid; marks carry
    `data-bucket/up/down/gap/seam`; the 450 KB gate with a negative control in
    `ui_build_check_test.py`; theme toggle; `open()` waits on a readiness testid instead
    of `networkidle`; shared `e2e/fixtures/stats.js` golden series.
12. `feat(panel-ui): Gateway Insights — scoped AnalyticsView, hash routes, drilldowns` —
    scopes overview / client / app / host with KPI row, scoped timeline and next-level
    top-N tables; `useHashRoute` (`#/insights/client/<ip>?range=7d`); `useScopedStats`
    (in-flight skip, hidden-tab pause, tier-aware cadence 10/60/300 s); `RANGES` gains
    `24h`; domains-off messaging with an opt-in nudge; the region beyond the 7-day
    attribution cap is shaded on 30d; an "invisible traffic" note; Stats tab → Insights
    (en + zh); `docs/insights.md` + `docs/zh/insights.md` + the `INSIGHTS.txt` /
    `INSIGHTS.zh.txt` pair added to the package ship lists; ≤ 8 new Playwright specs with
    a `globalTimeout`.

**Slice (e) — v1.14 live + node delay**
13. `feat(panel): SSE live relay, selected-node delay history, subscription quota` —
    `/v1/stats/live` via `StreamingResponse` with a documented event schema (DEC-X-5);
    the selected node per group sampled every 300 s into a 7–30 d delay history;
    `subscriptionInfo` hourly (four numbers + `updatedAt`); `/memory` every 60 s.
14. `feat(panel-ui): live throughput tile (opt-in), node delay and quota widgets` —
    DEC-2; default-off toggle persisted per browser; "stale Ns" on loss; labelled "not
    stored"; Playwright stubs the stream; the per-connection deep link to MetaCubexD stays.
