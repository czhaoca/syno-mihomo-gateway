# Brainstorm brief — group model streamline: Country Pick, Proxy Mode, Streaming Sites

Date: 2026-07-16 · Mode: greenfield (`/brainstorm`) · Epic: `group-model-streamline`
Predecessor: `proxy-groups-v2.md` (epic `proxy-groups-v2`, shipped in v1.4.0). This brief
**reverses** part of that design (Priority Nodes is removed) and supersedes
`country-groups-hk-exclusion.md` DEC-5's member layout for the PROXY-side splice.

## Idea

The v1.4.0 group model is still confusing, and the full-pool `All Nodes` url-test
shuffles the exit node — across countries — which trips site bot-protection when
traffic hops exit IPs. Five asks (owner-stated):

1. **"Auto" suffix = country auto-pick** — keep the `<Country> Auto` url-test groups.
2. **Remove Priority Nodes as a category** — the country autos cover the
   stable-region need; a second filtered-pool concept is redundant.
3. **`STREAMING` → `Streaming Sites`** — the name must say it is a *site* rule group.
4. **`PROXY` → `Proxy Mode`** — a group that represents a *mode* gets a ` Mode` suffix.
5. **Replace `All Nodes` as the traffic default with a country-level selector**
   (`Country Pick`, select over the country autos): picking `US Auto` routes all
   proxy traffic through the one node US Auto currently holds — a stable exit
   country, no cross-country hopping.

## Dimensions (fan-out findings that shaped the design)

### mihomo semantics (verified against wiki + source)

- **Nested groups are supported**: a `select` group's `proxies:` may reference other
  groups, so `Country Pick` (select) over `<Country> Auto` (url-test) is legal and
  yields one exit IP at any moment. Scope honesty: url-test still re-picks *within*
  the selected country at provider-health-check cadence (600 s) under `tolerance: 50`
  — this epic eliminates cross-country hops; within-country hops remain (raw-node
  pinning is the escape hatch, see DEC-3).
- **`hidden: true` is supported** on proxy groups and shipped MetaCubexD filters
  `!proxy.hidden` — a group can stay alive (routable, DNS-detourable) yet invisible.
- **DNS detour safety**: the `'#All Nodes'` fragment rides `DNS_FOREIGN_NAMESERVER`
  in every deployed `.env` (operator DATA, not template). Detouring DNS via the
  dashboard-pickable chain (`#Country Pick` / `#Proxy Mode`) re-couples LAN-wide
  resolution to dashboard picks — an empty picked country (fail-closed REJECT) or a
  DIRECT pin becomes a total foreign-DNS outage. The decoupled full-pool anchor is
  the verified-safe design and is kept (DEC-1).
- **Country autos already fail closed** — every generated group renders
  `empty-fallback: REJECT` (render_config.sh:282); no gap to fix. (`empty-fallback`
  may name only a proxy, never a group — REJECT qualifies; see proxy-groups-v2 brief.)
- **cache.db selections are keyed by group name**; a stored pick whose group is
  renamed silently falls back to first member. One-time reset, accepted (constraints).

### rename blast radius (repo inventory)

- ~615 literal references across 22-28 files per name; the largest single surface is
  `scripts/ci/render_check.py` (spec-as-test — pins the `#All Nodes` detour list, the
  exact PROXY member order, the group inventory, and ~190 lines of Priority-only
  assertions at :785-972). CI's exact-equality checks make a **partial rename
  unlandable** — the change must be one atomic commit.
- Load-bearing runtime probes by literal name: doctor.sh:64 (`/proxies/PROXY/delay`,
  **unencoded** — `Proxy Mode` needs %20), seed_provider.sh:123-125
  (`/proxies/All%20Nodes` fallback), validate_release.sh (probes all four names,
  BLACKHOLE fixture `#All Nodes` at :57, one-level egress indirection at :473-476
  that must become a loop for Proxy Mode → Country Pick → `<Country> Auto` → node),
  lib/checks.sh:308-370 (skip-list, special-cases, operator hints),
  installer i18n.sh EN+zh strings, cli/spec.yaml help text.
- **CI gap found**: no check renders `.env.example`'s *actual* `DNS_FOREIGN_NAMESERVER`
  (render_check.py uses its own fixtures) — a stale `#fragment` in `.env.example`
  would pass CI and dead-end live DNS. Closed by a new render-time validation
  (constraints below).
- Knob-retire precedent: the AUTO_EXCLUDE_FILTER tripwire (render_config.sh:70-78,
  owner DEC-B on #40) — compose keeps passing the old name **only** so a stale `.env`
  fails loud, no fallback semantics.

### UX / naming (MetaCubexD)

- Dashboard shows groups in **config order**; today the two selectors users actually
  touch sit behind ~7 machinery cards. Definition order is functionally free →
  selectors-first layout costs nothing.
- Bilingual invariant: zh docs keep English group names verbatim — English canonical
  names stay. All candidates fit MetaCubexD's one-line title clamp.
- ` Pick` completes the owner's kind-suffix system (Auto = auto-pick, Mode = mode,
  Sites = site rules, Pick = manual choice) — documented once as a legend.

### testing / CI

- Verification gate = docs/development.md:235-284 local mirror of `.woodpecker.yml`
  (parity rule: CI step ⇔ local equivalent in the same change). The ten BusyBox-sh
  suites + `validate_release.sh --self-test` must be adjudicated inside
  `alpine:3.22` docker (macOS bash-3.2 false-greens `set -u` errors).
- `proxy_groups_check.sh` re-fixtures wholesale (encodings, group JSON,
  default-empty semantics repointed from Priority Nodes to Country Pick's selection).
- `mihomo_entrypoint_check.sh` poison fixture (`PRIORITY_EXCLUDE_FILTER='bad`tick'`)
  moves to a `COUNTRY_GROUPS` backtick (equally fail-closed).

### docs / migration

- ~14 doc files (EN + zh mirrors required in the same change per
  development.md:316-320, plus the hand-maintained bundle `.txt` tier and
  spec.yaml→CLI regen). Cross-doc anchors from configuration.md:77-78 into
  troubleshooting.md's Priority section break — re-anchor.
- Release reality: only the latest GitHub release is kept; bundle installs, no git on
  the NAS → staging/aliasing across two releases is pointless. Atomic breaking
  release modeled on `docs/release-notes/v1.4.0.md` (REQUIRED checklist +
  "Expect once" pin-reset section).

## Decisions

- **DEC-1 — All Nodes survives, hidden, name unchanged.** The full-pool url-test
  group gains `hidden: true` and exists solely as the DNS detour anchor. Every
  deployed `.env`'s `#All Nodes` fragments keep working (zero migration for the
  worst hazard); the dashboard shows only the new graph; LAN DNS stays decoupled
  from dashboard picks. Documented as "exists for DNS, not shown".
- **DEC-2 — the selector is `Country Pick`** (select; members = the country autos
  only, no DIRECT/REJECT). ` Pick` is blessed as the fourth kind-suffix.
- **DEC-3 — raw nodes stay pinnable in both selectors** (`use: my-airport` kept on
  Proxy Mode and Streaming Sites): pinning one exact node is the only complete
  answer to within-country IP hops, and two documented troubleshooting flows depend
  on visible raw nodes.
- **DEC-4 — Japan Auto ships first in `COUNTRY_GROUPS`** — Country Pick defaults to
  its first member, preserving v1.4.0's Japan default egress. Upgraders keep their
  own knob order (release-note line).
- **DEC-5 — PRIORITY_* knobs retire via loud tripwire**: render refuses when
  `PRIORITY_INCLUDE_FILTER`/`PRIORITY_EXCLUDE_FILTER` are set, naming the
  country-auto replacement (AUTO_EXCLUDE_FILTER precedent; compose passthrough kept
  only to trip; entrypoint gate keeps the LAN on last-good meanwhile).

### Target group graph

```yaml
proxy-groups:                # dashboard order = config order
  - name: Proxy Mode         # select: Country Pick | DIRECT | REJECT (+ raw nodes) — the rule target
  - name: Streaming Sites    # select: Proxy Mode | <country autos> | DIRECT (+ raw nodes)
  - name: Country Pick       # select: <country autos> only
  - name: <Country> Auto ... # url-test per COUNTRY_GROUPS entry (Japan first)
  - name: All Nodes          # url-test full pool, hidden: true — DNS detour anchor ONLY
# Priority Nodes: REMOVED
```

### Pre-decided constraints (not re-decidable at execution)

- `COUNTRY_GROUPS` becomes **mandatory**: empty/unset → loud render error naming the
  `.env.example` default (Country Pick needs members). The empty-knob byte-identity
  assertions in render_check.py flip to fail-closed cases.
- New render-time validation in `render_config.sh`: every `#group` fragment in
  `DNS_FOREIGN_NAMESERVER` must name a rendered group (ports CI's
  check_dns_detour_targets to the renderer; closes the `.env.example` CI gap and
  permanently protects future renames).
- Reserved-name lists (render_config.sh:174 + validate_release.sh:143 +
  lib/checks.sh:325): **add** `Country Pick` / `Proxy Mode` / `Streaming Sites` /
  `Full Proxy` (reserved ahead for the `per-device-full-proxy` epic), **keep** the
  old names reserved.
- Rules rename only their targets: `MATCH,PROXY` → `MATCH,Proxy Mode`,
  `GEOSITE,*,STREAMING` → `...,Streaming Sites`; rule order unchanged.
- cache.db pin reset on rename: accepted; release-note "Expect once" line.
- Release notes: from-v1.4.0 only, + one line pointing older installs at the bundled
  v1.4.0 notes first.
- Ships as its own release, NAS-validated before the `per-device-full-proxy` epic.

## Verification gate

The full local mirror of CI per docs/development.md:235-284 (parity rule applies): `sh -n`
loop, render_check.py + cli_contract_check.py, compose config check, the ten dsm-shell
suites + `validate_release.sh --self-test` adjudicated inside `alpine:3.22` docker,
shellcheck, package/privacy/compose-policy checks. Verbatim commands live in issue #45.

## Work breakdown

One atomic issue (CI's exact-equality assertions make partial renames unlandable):

1. `feat(groups): streamline group model — Country Pick / Proxy Mode / Streaming
   Sites, remove Priority Nodes` — template + renderer + render_check + doctor
   chain + suites + validate_release + i18n/spec + docs (EN/zh/.txt) + release notes,
   one commit. Epic `group-model-streamline`, Sequence 10, no Next.

Related: the `per-device-full-proxy` epic (see `per-device-full-proxy.md`) builds on
this graph and drains after this epic's release is validated.
