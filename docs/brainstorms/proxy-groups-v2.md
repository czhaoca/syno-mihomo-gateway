# Brainstorm brief — proxy groups v2: stable-region default, friendly names, audio streaming

Date: 2026-07-14 · Mode: greenfield (`/brainstorm`) · Epic: `proxy-groups-v2`
Predecessor: `country-groups-hk-exclusion.md` (epic `country-groups`, shipped in v1.3.12).

## Idea

The v1 country-groups feature made the routing default (`auto-x`) a url-test over
*all* non-HK nodes. Latency-driven switching therefore hops the egress **country**
— login-sensitive sites see a user whose location shifts constantly and start
blocking/challenging. Four asks:

1. The priority policy must be scopeable to a **single country/region**, not
   just "everything except HK".
2. Rename the groups to human labels: `auto` → **All Nodes**, `auto-x` →
   **Priority Nodes**, and the country groups to English **"<Country> Auto"**.
3. STREAMING should also capture **audio** streaming (Spotify et al.).
4. Every nation group must be selectable in the STREAMING selector alongside
   All Nodes / Priority Nodes (Netflix content differs per country).

## Dimensions (fan-out findings that shaped the design)

### mihomo semantics (verified against Alpha source + wiki + meta-rules-dat)

- **`filter` + `exclude-filter` coexist on one group**: `filter` applies while
  appending provider nodes, `exclude-filter` subtracts from the accumulated
  list, `exclude-type` last (`adapter/outboundgroup/groupbase.go`). So a
  region-scoped Priority Nodes is include-filter + the existing exclude-filter
  on the same url-test group. Nuance: `filter` only applies to `use:`-provider
  nodes (Compatible/static members bypass it); `exclude-filter` covers the full
  accumulated list.
- **Group names: spaces + CJK safe end-to-end**, including the DNS detour —
  `parseNameServer` splits `u.Fragment` on `&` and uses the name **verbatim, no
  unescaping** (so never percent-encode; forbidden chars in a name used as a
  detour: `#`, `&`, `=`). `'tls://1.1.1.1#Priority Nodes'` works single-quoted.
- **No display-name/alias field exists** — the group `name` IS the dashboard
  label (`icon:` decorates, `hidden:` hides; neither relabels). Renaming the
  YAML name is the only way to change the label.
- **cache.db selections are keyed by group name** (`cachefile` bucket
  "selected": `Put(group, selected)`); cache.db lives on the persistent volume
  (`$GATEWAY_DATA_DIR/config`). A rename silently resets that group's
  dashboard pin to its first member — one-time, accepted and documented.
- **url-test has no cross-restart persistence**; `tolerance` is hysteresis
  (challenger must beat incumbent by > tolerance ms), not stickiness.
  `default-selected` exists for select groups since v1.19.28.
- **`empty-fallback`**: upstream since v1.19.27; since v1.19.28 it may name
  only a **proxy**, never a group. Current template's `empty-fallback: REJECT`
  stays valid.
- **Audio geosite categories that exist**: `spotify`, `apple-music`, `tidal`,
  `deezer`, `soundcloud` (verified `.list` present). `youtube-music` does NOT
  exist — YouTube Music rides `geosite:youtube` (`+.youtube.com`).
  `category-entertainment` is an over-broad umbrella; rejected.

### rename blast radius (repo)

- **The `#auto` detour is operator DATA, not template**: `.env` /
  `.env.example` embed `...#auto` in `DNS_FALLBACK` and
  `DNS_FOREIGN_NAMESERVER`. CI enforces detour↔group consistency
  (`render_check.py:403-427 check_dns_detour_targets`). This coupling is the
  highest-risk edge: renaming the group without handling existing `.env` files
  silently kills tunneled DNS resolution.
- Assertion surfaces to update in lockstep: `render_check.py` (group inventory
  :289, PROXY member order :861/:998, STREAMING first-member :871, .env.example
  default render :894, detour targets :403, DNS fixtures), fixtures in
  `proxy_groups_check.sh` / `gateway_cli_check.sh` / `dsm_installer_check.sh`
  (incl. a %-URL-encoding ordering assumption between the two names),
  `validate_release.sh` (self-test fixtures :280, live probes
  `/group/auto/delay` :452, `/proxies/PROXY|auto` :458, STREAMING+rule greps
  :495), doctor `checks.sh` (:328 skip-set, :333-336 cases, detail/hint
  strings), `installer/i18n.sh` + `cli/spec.yaml` (EN+ZH), reserved-name
  collision guards (`render_config.sh:147`, `checks.sh:328`,
  `validate_release.sh:142`), docs EN+ZH incl. troubleshooting anchor slugs.
- Unaffected (verified): `scripts/pi/*`, `privacy_check*`. (The original
  claim wrongly listed `migrate_legacy.sh` and `seed_provider*` here —
  `seed_provider.sh` probes `/proxies/auto` by name and its CI suite stubs
  that endpoint; corrected in the Revision below, which also removes
  `migrate_legacy.sh` entirely.)

### streaming rules + upgrade machinery (repo)

- **Rules are static template lines**, exact-equality asserted via
  `render_check.py RULES_BASE` (:136) in ~6 render variants, plus a literal
  grep in `validate_release.sh:499`. Adding rules = template lines +
  RULES_BASE + validate greps in lockstep; no new renderer machinery.
- Rule ordering constraint: service rules must precede
  `GEOSITE,GEOLOCATION-!CN` (services are subsets of it).
- Back-compat precedents: seed-only knobs via `.env.example` (SNIFFER,
  COUNTRY_GROUPS); in-renderer one-time adoption (provider-cache md5
  adoption, `render_config.sh:353-366`) — the model for the `#auto` rewrite;
  redeploy-wizard upgrade offers (`wizards.sh offer_dns_privacy_upgrade`) —
  available later, not used in v1 of this epic.
- `validate_release.sh` parks/restores cache.db and asserts the
  dashboard-selected node survives — that assertion must learn that a rename
  release legitimately resets pins.
- `state_diff.sh` does not cover group topology (container facets only) — no
  safety net there; staging validation carries the weight.

## Decisions (all resolved with the owner, 2026-07-14)

- **DEC-1 — Rename path: renderer auto-migrates `#auto`.** Both groups are
  renamed in the template; at render time the renderer rewrites `#auto` /
  `#auto-x` detour fragments inside the DNS_* values to the new names, so
  every existing `.env` keeps working untouched (provider-cache-adoption
  precedent). Dashboard pins on renamed groups reset once — documented in
  release notes. Rejected: hidden alias group (permanent config clutter),
  rename-auto-x-only (half the ask), breaking rename (silent DNS death).
- **DEC-2 — Region scoping: include-filter knob with a scoped shipped
  default.** New `filter:` on Priority Nodes driven by an env knob; include
  applies first, the exclude-filter still subtracts (verified order). Runtime
  region switching stays "pick a country group in PROXY". Rejected:
  select-over-country-groups (type change, COUNTRY_GROUPS dependency, loses
  fail-closed clarity); unset-default (ships the flapping bug onward).
- **DEC-3 — Default region: Japan.** `.env.example` ships
  `PRIORITY_INCLUDE_FILTER=日本|JP\d|^JP`. Caveat accepted: HK-heavy pool ⇒
  few JP nodes; empty ⇒ fail-closed REJECT + doctor error (existing v1
  machinery).
- **DEC-4 — Audio rules: Spotify + Tidal + Deezer + SoundCloud.** Four
  explicit `GEOSITE,<svc>,STREAMING` rules, inserted before
  `GEOSITE,GEOLOCATION-!CN`. apple-music deliberately excluded (CN storefront
  risk); YouTube Music implicitly rides `geosite:youtube` → PROXY (unchanged);
  `category-entertainment` rejected as over-capture.
- **DEC-5 — STREAMING members: PROXY, Priority Nodes, All Nodes, <country
  groups>, DIRECT.** PROXY stays first (day-one default, CI-asserted);
  Priority Nodes added so streaming can follow the stable-region route
  explicitly; country groups give one-click Netflix-country pinning.
- **DEC-6 — Names: "All Nodes" / "Priority Nodes"; country groups "<Country>
  Auto"** (US Auto, Singapore Auto, Japan Auto, Taiwan Auto, Philippines
  Auto — English, "Auto" suffix = auto-picks best node in that country).
  `.env.example` COUNTRY_GROUPS default switches to the English names;
  existing `.env` files keep their spec until hand-edited (seed-only
  precedent — the owner updates the NAS `.env` during release validation).
  The COUNTRY_GROUPS parser must accept spaces in group names.
- **DEC-7 — Knobs: canonical pair `PRIORITY_INCLUDE_FILTER` /
  `PRIORITY_EXCLUDE_FILTER`.** Renderer honors legacy `AUTO_EXCLUDE_FILTER`
  as fallback when `PRIORITY_EXCLUDE_FILTER` is unset; `.env.example`
  documents only the new names; compose allowlists both.

### Deferred to execution (DEC-X in the tickets)

- Whether the reserved-name collision list keeps the OLD names (`auto`,
  `auto-x`) reserved alongside the new ones (recommended: yes, prevents
  confusing shadowing while `#auto` rewriting exists).
- Exact JP regex hardening (anchoring, airport naming drift) once tested
  against the live provider list.
- Whether `validate_release.sh` gains a one-release "pins reset expected"
  acknowledgement or a permanent rename-aware check.
- Whether template token/fence names (AUTOX*, COUNTRY_*) are renamed with the
  groups or kept (recommended: keep — CI only asserts template⇄renderer
  parity; keeping shrinks the diff).

## Work breakdown (→ epic `proxy-groups-v2`, staged via /stage-work-order)

1. **feat(renderer): rename groups to All Nodes / Priority Nodes / "<X> Auto"
   with `#auto` detour auto-migration** — template renames + member lists;
   renderer detour-fragment rewrite (`#auto`→`#All Nodes`,
   `#auto-x`→`#Priority Nodes`) in DNS values; COUNTRY_GROUPS parser accepts
   spaces; reserved-name guards updated; `.env.example` detours + English
   COUNTRY_GROUPS default; render_check + shell-suite fixtures.
2. **feat(renderer): PRIORITY_INCLUDE_FILTER / PRIORITY_EXCLUDE_FILTER knobs
   with JP-scoped default** — `filter:` rendering on Priority Nodes;
   AUTO_EXCLUDE_FILTER legacy fallback; compose allowlist; `.env.example`
   defaults + docs; render_check sections incl. include+exclude combined
   render and legacy-fallback fixture.
3. **feat(routing): STREAMING gains Priority Nodes + audio-streaming rules** —
   member splice order per DEC-5; four GEOSITE audio rules before
   GEOLOCATION-!CN; RULES_BASE + validate_release rule greps.
4. **chore(ux+docs): doctor/i18n/spec/docs/validate sweep for the new
   topology** — doctor case labels + detail/hint strings; spec.yaml +
   i18n.sh EN+ZH; docs EN+ZH + anchor slugs + CONFIGURE/CLI txt mirrors;
   validate_release self-test fixtures + live probes + cache.db pin-reset
   handling; release-note draft (pins reset once; owner .env hand-edit for
   English country names).

## Revision — 2026-07-14 (owner decisions during /issue-resolver, recorded on #39)

Execution of #39 stopped on a scope drift (the "seed_provider* unaffected"
claim above was false), and the owner resolved it — plus the ticket's open
DECs — interactively, then widened the epic into a no-back-compat direction:

- **DEC-1 SUPERSEDED — no migration machinery at all.** The renderer does
  NOT rewrite `#auto`/`#auto-x` detour fragments. This is a single-NAS
  deployment: the owner hand-edits the NAS `.env` once when moving to the
  new code (the Sequence-40 release note carries the exact checklist).
- **DEC-7 SUPERSEDED — no legacy knob fallback.** `AUTO_EXCLUDE_FILTER`
  renames outright to `PRIORITY_EXCLUDE_FILTER` in Sequence 20; whether a
  stale value trips a loud renderer error or is simply dropped is Sequence
  20's DEC-B (recommendation: tripwire).
- **#39 DEC-A — reserve only the new names.** The COUNTRY_GROUPS collision
  guard lists `All Nodes`/`Priority Nodes` + the builtins; `auto`/`auto-x`
  become legal user group names (safe: no rewrite exists to collide with).
- **#39 DEC-B — internal fence/token names rename too.** `AUTOX*` →
  `PRIORITY*`, `AUTOXMEMBER*` → `PRIORITYMEMBER*` (Sequence 10);
  `{{AUTO_EXCLUDE_FILTER}}` → `{{PRIORITY_EXCLUDE_FILTER}}` (Sequence 20).
- **Purge of all migration/back-compat machinery**, staged as two new
  tickets ahead of the rename:
  - **Sequence 5 (#44)**: delete `migrate_legacy.sh` + its CI suite +
    `legacy_install_detect` + the doctor import hint + bundle-manifest
    entries + doc sections; delete the renderer's provider-cache md5
    adoption and `seed_provider.sh`'s dual-name cache write.
  - **Sequence 7 (#43)**: split-horizon v2 becomes the ONLY DNS profile —
    the DNSLEGACY core, `DNS_FALLBACK`, and `offer_dns_privacy_upgrade`
    are removed everywhere (template/renderer/compose/.env.example/DSM +
    Pi installers/CI fixtures/validate_release/docs); the
    DNSPOLICY/DNSSPLIT fences are inlined; the split-horizon pair becomes
    REQUIRED (fail loud, named errors).
  - Deliberately KEPT: the `UPDATE_IMAGES` normalization in `common.sh`
    (mislabeled compat — it expands the literal default the current
    `.env.example` ships) and `chk_dns_privacy`'s v2|v1|legacy|unknown
    DETECTION vocabulary (it reads the on-disk rendered config; during the
    owner's own upgrade it is the stale-render signal — only its
    wizard-pointing hint text is reworded).
- **seed_provider fix folded into #39** (probes rename to the %XX-encoded
  new group names; its suite fixtures updated).

Chain after the restructure: **#44 (Seq 5) → #43 (Seq 7) → #39 (Seq 10) →
#40 (Seq 20) → #41 (Seq 30) → #42 (Seq 40)**.

## Verification gate

Repo suite as enforced by CI (`.woodpecker.yml`): `python
scripts/ci/render_check.py`, each `sh scripts/ci/*_check.sh` (adjudicate in
alpine:3.22 — macOS bash-3.2 false-greens `set -u` suites), shellcheck/`sh -n`,
`scripts/validate_release.sh --self-test`, compose policy gate. Real-world
validation follows the release ship flow (owner-run staged NAS validation);
verify the deployed mihomo image is ≥ v1.19.27 (`empty-fallback` floor)
during the deploy window.
