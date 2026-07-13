# Brainstorm brief — HK-exclusion default + per-country auto groups

Date: 2026-07-13 · Mode: greenfield (`/brainstorm`) · Epic: `country-groups`

## Idea

Many sites block Hong Kong egress IPs even though major services (YouTube etc.)
serve the location fine, and the airport is HK-heavy (26 of ~30 sampled nodes
are 香港NN), so the latency-optimal `auto` group almost always lands on an HK
node. Two asks:

1. Exclude Hong Kong from the *automatic* selection path by default.
2. Let the dashboard auto-select by country — or by a *group* of countries —
   as one-click selector entries.

Both are realized purely as mihomo **group topology** rendered from `.env`;
MetaCubeXD needs zero changes (it passively lists whatever groups exist).
There is verifiably no runtime API to mutate group filters (PATCH /configs
schema covers no group fields), so pre-provisioned alternative groups inside
the `PROXY` selector are the only — and the correct — runtime switch.

## Dimensions (fan-out findings that shaped the design)

### mihomo capabilities (verified against wiki.metacubex.one + Meta-branch source)

- `filter` / `exclude-filter` regex engine is **dlclark/regexp2 (.NET flavor)**,
  not Go RE2: case-sensitive by default, inline `(?i)` works, multiple patterns
  are **backtick-separated** (a literal backtick can never appear in a
  pattern), matching is unanchored substring (`香港` matches `香港01`). An
  invalid pattern **panics mihomo at startup** → render-time validation is
  load-bearing.
- `filter` applies only to `use:`-provider nodes; `exclude-filter` runs last
  over the assembled list (also removes inline `proxies:` members).
- **No probe amplification**: a url-test group with `use:` and *no own `url:`*
  inherits the provider's health check and registers nothing extra — N country
  groups cost zero additional probe traffic. Keep the single provider
  health-check (gstatic 204, interval 600, lazy).
- **Empty-group failure is a silent leak**: a filter matching zero nodes loads
  fine and degrades to the `COMPATIBLE` placeholder, which is a
  **Direct-typed adapter** — traffic exits the CN uplink unproxied. Newer Meta
  builds support `empty-fallback: <proxy>` (e.g. `REJECT`) to fail closed;
  detectable at runtime via `GET /group/{name}` showing only COMPATIBLE.
- `smart` group type is **not** in upstream MetaCubeX/mihomo (vernesong fork
  only) — not an option for this stack.
- CJK/emoji literals match fine (UTF-8 runes); avoid `\b` next to CJK; anchor
  short Latin codes (`JP\d`, `^JP`) to avoid substring collisions.

### renderer / installer (repo mechanics)

- `scripts/render_config.sh` is pure two-pass token/fence substitution — **no
  loop capability**. The scalar exclude knob is a 1:1 SNIFFER-clone
  (fence + token, empty ⇒ fence stripped ⇒ byte-identical legacy render).
  Per-country groups require the renderer's **first generation loop**: a
  POSIX-sh parser over a spec var emitting url-test blocks + selector-member
  lines into dedicated token sites.
- `esc()` already handles `|` (the sed delimiter) in values; a `|`-bearing
  regex round-trips. New CI fixture must prove it.
- Registration surfaces for a new knob: `docker-compose.yml` env allowlist
  (`:-` default pattern), `.env.example`, `render_config.sh`,
  `config.template.yaml`, docs (`configuration.md` + zh + CONFIGURE.txt×2),
  `validate_release.sh` self-test key lists, Pi path `pi/flow_lite.sh` knob
  threading.
- CI couplings: `render_check.py` `check_token_mapping` (bidirectional
  token↔sed-mapping equality), `check_fences` (pairing), byte-identical
  legacy-render assertions (new fences join the strip chain), and — the
  blocker — **`render_check.py:461` asserts the group inventory equals
  `["auto","PROXY","STREAMING"]` exactly**; must become spec-derived.
- Installer: wizard prompts only the 3 required DNS vars; SNIFFER precedent =
  seed-only via `.env.example` copy; `offer_dns_privacy_upgrade` is the
  pattern if a redeploy-wizard offer is wanted later.

### doctor / validation

- No check counts provider or group nodes today. The zero-match condition is
  only knowable at runtime → new `chk_*` in `scripts/lib/checks.sh` querying
  the controller via the established docker-exec-wget pattern
  (`seed_provider.sh` `real_nodes()`: `all[]` minus COMPATIBLE), registered in
  `checks_run` + `scripts/cli/spec.yaml` (en+zh) with `gateway_cli_check.sh`
  parity.
- `validate_release.sh` probes only the `PROXY`/`auto`/`STREAMING` literals —
  new groups are NOT covered automatically; a loop over
  controller-discovered url-test groups closes that gap pre-release.
- Hermetic test template: `scripts/ci/seed_provider_check.sh` (PATH-stub
  `docker` answering canned controller JSON).

## Decisions (all resolved with the owner, 2026-07-13)

- **DEC-1 — Where the exclusion lives: sibling group.** A new url-test group
  (working name `auto-x`, final name deferred to execution) carries the
  exclude-filter and becomes `PROXY`'s **first member** (= routing default).
  `auto` is untouched: full pool, still the split-horizon DNS `#auto` detour.
  Rationale: the provider is HK-heavy; filtering `auto` itself would couple
  LAN-wide DNS to a handful of non-HK nodes (empty ⇒ SERVFAIL). Fallback to
  full-auto stays one dashboard click. Provider-level exclusion rejected (kills
  manual HK picks).
- **DEC-2 — Country groups via `.env` spec + generation loop.**
  `COUNTRY_GROUPS="JP=日本|JP;US=美国|US;…"` (entry = `NAME=regex`, `;`
  separated); the renderer's new loop emits one url-test group per entry (no
  own `url:` ⇒ no extra probes) and splices the names into the selectors. A
  multi-country group is simply an entry whose regex spans several countries
  (e.g. `ASIA=日本|台湾|新加坡`) — this is the countries-as-a-group answer.
  Group name = spec key verbatim (operator controls dashboard labels). Unset ⇒
  byte-identical legacy render. Fixed fenced groups rejected (frozen country
  set, awkward selector splicing).
- **DEC-3 — Empty filtered group fails closed + doctor coverage.**
  `empty-fallback: REJECT` rendered on every filtered group (subject to the
  deployed-image verification below) AND a doctor check: **warn** on an empty
  country group, **error** when the default routing group (`auto-x`) is empty.
  Deliberate: matches the project's fail-closed DNS posture; COMPATIBLE→DIRECT
  is exactly the silent-bypass class this gateway treats as a bug.
- **DEC-4 — Rollout is seed-only (SNIFFER precedent).** Defaults documented in
  `.env.example` (HK exclude ON, starter country spec) so new installs get the
  feature; existing `.env` files render byte-identically until hand-edited. No
  wizard prompt in v1; a redeploy-wizard upgrade offer is a separable
  follow-up, out of scope here.
- **DEC-5 — Country groups appear in both `PROXY` and `STREAMING`.** One-click
  "best node in country X" for streaming pinning; zero probe cost. Accepted:
  longer STREAMING list; within-country url-test rotation possible (tolerance
  dampens; per-node pinning remains available).

### Deferred to execution (DEC-X in the tickets)

- Final dashboard name of the exclusion group (`auto-x` proposed: the knob is
  generic — `AUTO_EXCLUDE_FILTER` can exclude anything — so a `-no-hk` name
  would over-promise).
- `empty-fallback` availability in the deployed `metacubex/mihomo` image
  (`MIHOMO_TAG=latest`): verify before relying on it; if unsupported/strictly
  rejected, render without it and lean on the doctor check.
- Exact starter `COUNTRY_GROUPS` default (candidate countries from the node
  sample: TW/JP/US/菲律宾; anchor Latin codes, prefer Chinese names).
- Doctor cold-start grace (avoid false-warn during the provider seed window).

## Work breakdown (→ epic `country-groups`, staged via /stage-work-order)

1. **feat(renderer): AUTO_EXCLUDE_FILTER knob + default-exclusion sibling
   group** — SNIFFER-clone fence/token; `auto-x` group (exclude-filter,
   `empty-fallback: REJECT`, no own url:) first in `PROXY`; compose allowlist,
   `.env.example` (default = HK regex ON), docs; render_check sections incl.
   `|`-escaping fixture and byte-identical off-render; verify empty-fallback
   against the deployed image.
2. **feat(renderer): COUNTRY_GROUPS generation loop** — spec parser + group
   emission + PROXY/STREAMING member splicing; render_check.py:461 inventory
   assertion becomes spec-derived; spec-syntax validation (reject backticks,
   empty regexes, malformed entries) failing the render loudly; docs + example
   defaults.
3. **feat(doctor): zero-node guard for filtered groups** — new `chk_*`
   enumerating url-test groups via the controller, warn/error per DEC-3;
   spec.yaml en+zh + CLI parity; hermetic docker-stub test suite.
4. **test(validate): staging coverage for filtered groups** —
   `validate_release.sh` loop over controller-discovered url-test groups
   (empty ⇒ fail before release); self-test fixtures for the new helpers;
   `.env.example` key-list updates.

## Verification gate

Repo suite as enforced by CI (`.woodpecker.yml`): `python
scripts/ci/render_check.py`, each `sh scripts/ci/*_check.sh` (adjudicate in
alpine:3.22 — macOS bash-3.2 false-greens `set -u` suites), shellcheck/`sh -n`,
`scripts/validate_release.sh --self-test`, compose policy gate. Real-world
validation follows the release ship flow (owner-run staged NAS validation).
