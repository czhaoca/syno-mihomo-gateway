# Brainstorm brief — Install auto-selection, hands-free validation, dashboard naming

Date: 2026-07-21 · Mode: greenfield (`/brainstorm`) · Epic: `gateway-ux-automation`

## Idea

Three UX/automation gaps surfaced during the v1.6.0 release rounds, fixed as one epic:

1. **DNS strategy should choose itself.** The release validator still asks a
   split-horizon y/N, the installer asks a GFW question that only picks the image
   registry, and a pre-v2 `.env` (missing the now-required DNS pair) passes precheck but
   hard-fails at render. Replace the asks with a network scan that auto-selects the DNS
   variant and registry, and auto-migrate old `.env` files.
2. **Validation should never wait for a human.** `validate_release.sh` pauses three
   times for manual spot-checks where Enter gates nothing. Replace them with automated
   probes from an ephemeral LAN-client container that sends a normal macOS Chrome
   User-Agent (so destinations that block curl/wget default UAs still answer).
3. **Dashboard cards should explain themselves.** The MetaCubexD Proxies-page group
   names (`Proxy Mode`, `Country Pick`, …) don't say what they do; rename the template
   selectors to function names.

## Split-horizon, explained (the seed's first ask)

Split-horizon is per-domain DNS routing in the rendered mihomo config. China-listed
domains (`geosite:cn`) resolve on domestic DoH (`DNS_CN_NAMESERVER`) and dial DIRECT;
foreign-listed domains **and every unmatched long-tail domain** resolve on overseas DoH
(`DNS_FOREIGN_NAMESERVER`) with the query tunneled through the proxy (the `#All Nodes`
suffix). Domestic resolver operators therefore only ever see Chinese names — never the
browsing long tail — and foreign domains get un-poisoned answers. There is deliberately
no fallback resolver: a dead tunnel fails **closed** (SERVFAIL) instead of leaking.
Bootstrap pins (geodata mirror, gstatic, the panel host) resolve domestically so cold
start works before any tunnel exists.

**Premise corrections found in research:** since `proxy-groups-v2` (v1.4.0) this is the
**only** DNS profile — the on/off toggle was purged and the pair is REQUIRED
(`scripts/render_config.sh:259-263` refuses to render without it). No installer asks a
split-horizon y/n; the y/N the owner keeps meeting is `scripts/validate_release.sh:995`
(the validator's keep-or-restore choice). The only real degree of freedom is the pair's
*values*: the **filtered** variant (domestic CN DoH + tunneled foreign, the
`.env.example` default) vs the **unfiltered** variant (plain foreign DoH both sides, no
`#All Nodes` detour). The filtered variant works on any network; the unfiltered variant
breaks behind the GFW — which makes filtered the safe automatic default.

## Dimensions

### Installer & DNS strategy
Options: (A) silent network scan with fallback ask; (B) wire the existing
`ask_unfiltered` answer (`scripts/installer/wizards.sh:229`, today registry-only) to
also drive DNS; (C) validator-only fix. **Chosen: A** — a short-timeout DIRECT reach
test of a known-CN-blocked endpoint (+ docker.io reachability for the registry
default), conservative filtered default, falling back to the existing question only
when inconclusive; the question survives as the manual override. Migration rides the
same variant choice: `precheck_env` (`wizards.sh:406-407`) learns the pair and
backfills a pre-v2 `.env` in place via `env_set` (`scripts/installer/envedit.sh:36`),
printing exactly what it wrote after backing up `.env`.

### Validation & testing
The three pauses (`validate_release.sh:860-873` A5 band spot-check, `:941-951` B3
dnsleak+Netflix, `:972-985` C LAN spot-check) record no verdict — A5 unconditionally
`ok`s, B3/C record nothing. Probe architecture facts that shaped the design: the NAS
cannot reach its own macvlan child (host-side curls measure nothing, `:41-43`);
gstatic-204 is CN-reachable DIRECT so it can never prove egress (`:59-61`); the A5
`--probe-ip` path (`:828-855`) already spins an ephemeral mihomo-image container on
`tproxy_network` routed through the gateway and asserts via `/connections` — the
correct LAN-client vantage point. **Chosen:** generalize that pattern into a
`lan_probe` helper carrying a macOS Chrome UA; C becomes two hard gates (CN URL DIRECT,
foreign URL via a real node — `www.google.com/generate_204` is CN-blocked so success is
genuine egress proof); B3's Netflix check becomes a warn-only region-block assertion
via the normal rules; B3's dnsleak instruction is dropped (the automated fail-closed
DNS proof at `:915-923` already covers the leak class); A5 auto-derives a free probe IP
when none is given, WARN-skipping if underivable. The repo has **zero** User-Agent
strings today; the UA and every destination become documented `.env` knobs (extending
the existing-but-undocumented `EGRESS_TEST_URL`/`EGRESS_TEST_GROUP`/
`EGRESS_TEST_TIMEOUT_MS`/`SMG_DNS_PROBE_DOMAIN` family), with neutral-endpoint literal
defaults per the gstatic precedent.

### Dashboard naming
Premise corrections: `GLOBAL` is a mihomo **built-in** (not in the template, not
renameable, inert because the gateway always runs `mode: rule`,
`config/config.template.yaml:15`) and does not mean "direct" — the bypass behavior is
pinning `Proxy Mode → DIRECT`. The `<Country> Auto` cards are fastest-node-in-country
url-tests (members of `Country Pick`), not "modes". Options: function-name renames;
renames + `icon:` fields; docs-legend only. **Chosen: function-name renames** of the
four template selectors, no icons. Constraints honored: ASCII+space names (non-ASCII
would break `scripts/doctor.sh:65`'s hardcoded `Proxy%20Mode` and
`flow_deploy.sh:72`'s space-only sed); CI exact-equality assertions force one atomic
commit; cache.db pins are keyed by name → one-time dashboard pin reset (v1.5.0
release-note precedent); hidden `All Nodes` stays (renaming it would break every
deployed `.env`'s `#All Nodes` fragment); zh docs keep English group names verbatim.

## Decisions

Resolved interactively with the owner on 2026-07-21 (AskUserQuestion, one at a time):

| # | Decision | Answer |
|---|---|---|
| DEC-A | DNS strategy driver | **Silent scan** sets DNS variant + `REGISTRY_MODE`; filtered fail-safe default; inconclusive → existing `ask_unfiltered` (kept as override) |
| DEC-B | Pre-v2 `.env` migration | **Auto-backfill on redeploy** via `env_set`, printed, `.env` backed up first |
| DEC-C | Validator keep-prompt (`:995`) | **Automatic**: original pair valid → `restore_env`; missing → keep example values (= migration); `--keep`/`--revert` still win |
| DEC-D | Gate policy for converted checks | **Hard-gate infra** (CN-direct, foreign-via-real-node, band rides Full Proxy); **warn external** (Netflix); no-probe-IP → WARN, never silent |
| DEC-E | Probe set + sourcing | CN `www.baidu.com` + foreign `www.google.com/generate_204` (hard), Netflix title (warn), dnsleak dropped (covered by `:915-923`); all URLs + Chrome UA = documented `.env` knobs |
| DEC-F | Names | `Proxy Mode`→**`Routing Mode`**, `Streaming Sites`→**`Streaming Unlock`**, `Country Pick`→**`Exit Country`**, `Full Proxy`→**`Full-Tunnel Devices`**; country autos, `All Nodes`, built-ins unchanged; no icons |
| DEC-G | Stale split-horizon docs | Fix in-epic: `docs/architecture.md:202-204` + zh (removed dual-mode fence), `docs/configuration.md:130` + zh ("left unset" is now render-fatal) |
| DEC-H | Epic | Single epic **`gateway-ux-automation`**, 5 tickets, Sequence 10–50 |

Pre-decided defaults carried from research (not re-decidable in tickets):

- Filtered variant is the fail-safe everywhere; unfiltered only on a conclusive scan.
- Probe endpoints follow the neutral-literal + env-override precedent — never
  hardcoded proxy rules/DNS servers/private addresses in committed files.
- Retired group names join the collision guard (`render_config.sh:149` pattern);
  `EGRESS_TEST_GROUP` default follows the rename.
- Historical files (brainstorm briefs, shipped release notes) keep the old names.
- busybox-wget TLS capability in the mihomo image is a ticket-time DEC (verify on
  device; degrade to http URLs + redirect-tolerant assertions).
- CI has no CAP_MKNOD / real egress: new probe code tests via stubs + probe-and-SKIP.

## Work breakdown

Five tickets, TDD-ordered (Sequence 10–50):

1. **feat(installer): network scan auto-selects DNS variant + registry** — probe helper
   beside `resolv_conf_probe` (`scripts/lib/network.sh`); wire into `wizard_images` +
   fresh-install seeding; DEC-G docs fixes ride along.
2. **feat(installer): pre-v2 `.env` pair backfill on redeploy** — `precheck_env` learns
   the pair; backfill via `env_set`; counter-case to `render_check.py:808-820`.
3. **feat(validate): auto-decide the keep-split-horizon prompt** — DEC-C rule replaces
   the `:995` read.
4. **feat(validate): Chrome-UA LAN-client probe engine + convert the three pauses** —
   `lan_probe` helper from the A5 pattern; C/B3/A5 conversions per DEC-D/E; knob family
   documented in `.env.example`.
5. **feat(config): atomic group renames** — DEC-F sweep across template, renderer
   guards, scripts, CI fixtures, living docs en/zh/txt; pin-reset release note.

## Handoff

Staged as the `gateway-ux-automation` work-order chain via `/stage-work-order`;
drained by `/issue-resolver` (or single tickets via `/resume-gap`). NAS re-validation
happens at the next release cut — after ticket 4 the staged validator runs with zero
`/dev/tty` reads end to end.

## Release-note snippet (draft for the next release — ticket 5 acceptance)

> **Renamed: the dashboard cards now say what they do.** `Proxy Mode` →
> **`Routing Mode`**, `Streaming Sites` → **`Streaming Unlock`**, `Country Pick` →
> **`Exit Country`**, `Full Proxy` → **`Full-Tunnel Devices`**. The `<Country> Auto`
> cards and the hidden `All Nodes` DNS anchor are unchanged. **One-time effect after
> upgrading:** mihomo keys its saved dashboard selections by group name, so each
> renamed card resets to its default member once — re-pin your streaming exit,
> country choice, or Full-Tunnel Devices selection in MetaCubeXD if you had one (same behavior as the v1.5.0 group
> streamline). The old names are retired and can no longer be used as
> `COUNTRY_GROUPS` labels.
