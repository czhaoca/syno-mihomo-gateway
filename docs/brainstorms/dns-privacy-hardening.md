# Brainstorm brief — DNS privacy hardening + post-incident debt/test/docs cleanup

Date: 2026-07-10 · Mode: greenfield (`/brainstorm`) · Epic: `dns-privacy-hardening`

## Idea

Three threads seeded by the 2026-07-10 incident cycle:

1. **DNS privacy inspection** — AliDNS (Alibaba) and DNSPod (Tencent) are the primary
   resolvers since v1.3.7's China-safe defaults; as domestic companies they can log the
   full query history tied to the subscriber IP, and plain UDP:53 exposes the same
   history to the ISP/GFW wire. Pure-foreign DNS (1.1.1.1 direct) is not viable — it is
   unstable/blocked in China (that instability *caused* the incident). Find a design
   that minimizes what domestic observers see without recreating the cold-start
   chicken-and-egg the incident taught us about.
2. **Tech-debt review** of the Synology shell codebase; enact one refactor now.
3. **Test + docs strengthening** targeted at the debug-cycle's demonstrated bug classes.

## Dimensions

### security-dns — the leak surface and the fix

**Verified against the mihomo wiki (wiki.metacubex.one):** with rules
`GEOSITE,CN,DIRECT` → `GEOIP,CN,DIRECT` → `MATCH,PROXY`, the GEOIP rule forces local
upstream resolution of **every** domain a client connects to (foreign included) unless
`no-resolve` is set — so today AliDNS/DNSPod receive the complete browsing history by
name, in plaintext, and `nameserver`+`fallback` are queried concurrently so the fallback
vendors (Cloudflare/Google) receive a copy of long-tail queries too. Also verified:
`nameserver-policy` matches bypass nameserver/fallback/fallback-filter entirely; a
`#GroupName` URL fragment routes that resolver's traffic through a proxy group; DoH
directly on an IP (`https://223.5.5.5/dns-query`) needs no bootstrap (the wiki's own
example); `default-nameserver` hosts must be IPs; `proxy-server-nameserver` resolves
node hostnames outside the fallback-filter (the v1.3.7 incident fix relies on this);
DNSPod's DoH-on-IP endpoint is `https://120.53.53.53/dns-query` — **119.29.29.29 does
not serve DoH**.

Options weighed: **O1** DoH-on-IP to the same domestic resolvers (wire encrypted, Ali
still sees everything); **O2** split-horizon `nameserver-policy` — `geosite:cn` →
domestic DoH-on-IP direct, `geosite:geolocation-!cn` → foreign DoH tunneled via
`#PROXY`, fallback tunneled too (fixes 1.1.1.1 instability as a side effect: it is no
longer dialed direct); **O3** = O2 + `no-resolve` on `GEOIP,CN,DIRECT` (zeroes the
long-tail leak; costs long-tail CN domains routing via the airport). **Chosen: O2 with
O1 folded in, plus the O3 flag shipped as a default-off knob.** Cold-start invariants
preserved by construction: bootstrap, node-hostname, and subscription resolution stay
domestic + unproxied; the template's fenced policy block renders byte-identical to
v1.3.7 output when the new knobs are unset.

Who sees what after: CN domains → Ali/Tencent encrypted (expected, needed for CDN
locality); geosite-listed foreign → tunnel only, zero domestic exposure; long-tail
unlisted → Ali encrypted (ISP/GFW blind), flippable to zero via the knob. Residuals
that survive every DNS option: subscription-fetch TLS SNI on the wire; the airport
operator sees proxied domains (inherent).

### refactor-debt — ranked

1. **Source-time defaults hoist** (enact now): generalize the incident's LOCK_DIR fix —
   move all ~21 optional-tunable defaults in `scripts/lib/common.sh` from `load_env` to
   source time. Fixes a **live latent bug** found during review: `gateway.sh doctor
   --json` loads env via `dotenv_load` (not `load_env`), so a lean `.env` without the
   optional `CONTROLLER_PORT` probes `http://127.0.0.1:/version` → false "controller
   broken" while human `doctor.sh` says ok. Deletes the hand-copied `EXPECTED_ARCH`
   default at `gateway.sh:486` and the now-dead in-`load_env` LOCK_DIR copy. `:=` fills
   unset only, so caller-env-wins / .env-wins ordering is byte-identical.
2. **Wizard-default single-source** (staged): the same default literals live in ~5
   shipping sites (wizards.sh ×3, pi/flow_lite.sh, .env.example) — this cycle's DNS
   edit touched all of them. Fix: wizards read defaults from `.env.example` at runtime
   (already guaranteed present; zero new literals, cleanest CLAUDE.md compliance).
3. **Doctor check engine** (staged, blocked on parity coverage): ~17 checks are
   hand-mirrored between `doctor.sh` (human) and `gateway.sh gateway_doctor` (--json);
   CI parity-asserts only 3. Unify into one check table + two renderers only after the
   parity cases cover all checks — otherwise the refactor is unprovable.
4. Shared in-container HTTP probe helper (3 drifted copies) and health-gate ladder
   consolidation — recorded, deliberately deferred (the health-gate twins' divergence
   is intentional and the 2am-unattended path; lowest urgency).

### testing-ci — demonstrated bug classes

Class A "harness env-bleed" (the LOCK_DIR incident mechanism: fixture env masks
env-dependence): kill dynamically with an **`env -i` hermetic smoke block** running the
real entry points with zero harness exports — include `deploy --yes`, because dry-run
skips `acquire_lock` and would have missed the actual incident; plus generalize the
existing source-time-default assertion to the whole common.sh family. Class B "template
semantic invariants" (the fallback-filter chicken-and-egg; the historic
`MATCH,my-airport` crash-loop): **render_check.py semantic pack** — every rule target ∈
groups ∪ builtins and never a provider, fence-pair integrity (a lost `{{TUN_END}}`
currently deletes to EOF *silently* on the TUN-off render), bidirectional
placeholder↔sed-mapping equality, unresolved-`{{}}` scan on **all** variants, and a
3-line minimal-env fix (render_check itself spreads `**os.environ` — the checker has
the same env-bleed disease it should be catching). Plus **`migrate_legacy_check.sh`**:
migrate_legacy.sh is the only fully-dark root-run entry point (rc contract 0/2/3/6/7,
never-clobber import — all untested). Staged: installer i18n full en/zh set-equality +
used-key sweep (the Pi overlay already does this; the 10×-bigger main catalog checks a
hardcoded 21-key list), doctor `--json` check-name contract gate (names appear only in
spec.yaml prose today — renames drift silently).

### docs — silent drift + missing threat model

Bilingual parity is clean (23/23 troubleshooting entries in all four files). Four
drifts: boot self-heal step [4/4] documented nowhere (installation.md/architecture.md/
AUTO-UPDATE.txt still describe 3 steps); operations.md elides the three new doctor
checks behind "…"; the NAS-validate-before-tag release ritual lives only in session
memory; zero DNS threat-model coverage anywhere and `proxy-server-nameserver` — the
incident fix itself — is documented nowhere. Postmortems: no convention exists; reuse
`docs/brainstorms/` (dev-only, auto-excluded from the enduser bundle by the
`:(exclude)docs/*.md` pathspec whose `*` crosses `/` — empirically verified) rather
than minting a directory for one file; revisit at postmortem #2.

## Decisions

- **DEC-1 (owner): split-horizon, default-on.** Fenced `nameserver-policy` block +
  tunneled fallback; new installs get it via `.env.example`; existing v1.3.7 `.env`
  files render byte-identical (fence auto-removed when knobs unset; exactly-one-set
  fails loud). NAS cold-start validation required before any release tag.
- **DEC-2 (owner): `DNS_GEOIP_NO_RESOLVE` knob ships, default `false`.** Long-tail CN
  stays DIRECT; privacy-max users flip one .env line.
- **DEC-3 (owner): enact the source-time defaults hoist** this session; wizard-DRY and
  doctor-engine staged.
- **DEC-4 (owner): enact the debug-cycle test/docs items now** (env -i block, render
  semantic pack, migrate_legacy_check, 4 doc catch-ups, postmortem); stage the DNS
  chain and the larger refactors.
- **DEC-5 (owner): epic slug `dns-privacy-hardening`.**
- Agent-resolved (recorded, not re-asked): foreign resolver vendors stay
  Cloudflare+Google (same trust set as today's fallback — no new party); DSM host
  resolv.conf and CF_DNS stay domestic-direct (boot-safety, incident-proven; the
  gateway-as-host-DNS alternative is documented as an option, not default); enduser
  docs name the operators factually ("AliDNS (Alibaba)") — clearer and leak-gate-clean;
  release ritual lands in development.md; postmortem reuses docs/brainstorms/; i18n
  dead-key sweep is warn-first; geox-url blocked-host CI assertion is a CI-side test,
  not a config address — compliant with the no-hardcode rule.
- Deferred with reason: provider `proxy:` field for subscription-refresh SNI hiding
  (small win, first-run caveat — DEC-X in the feature issue); `respect-rules: true`
  rejected (blunt global instrument; per-server `#PROXY` is surgical); setup_network.sh
  SOURCE_ONLY seam (logic lives in already-tested libs; shellcheck-only acceptable).

## v2 addendum — foreign-by-default (recorded 2026-07-12, ships in v1.3.10)

Owner re-opened DEC-2's accepted residual after a dnsleaktest.com extended test still showed
AliDNS: the long-tail leak (GEOIP-forced lookups + the `nameserver`/`fallback` dual-query)
is **no longer acceptable**, and netflix.com was additionally not usable via the proxy
(single-group design: `auto` picks by latency, rarely a streaming-unlock node). Both fixed
in one release; production `.env` was also still on the pre-1.3.8 legacy profile because
release validations end `--revert` (upgrades never migrate by design).

- **DEC-A (owner, supersedes the DEC-2 stance): split-horizon v2, foreign-by-default.**
  With the split pair set, `DNS_FOREIGN_NAMESERVER` renders as the DEFAULT `nameserver` and
  the `fallback`/`fallback-filter` dual-query is removed — domestic resolvers see only
  CN-listed domains + bootstrap pins; a dead tunnel fails closed (source-verified:
  nameserver-policy replaces the server list; `default-nameserver` is never a general
  retry). Legacy render byte-identity preserved via a second fence pair
  (`DNSSPLIT`/`DNSLEGACY`). `DNS_GEOIP_NO_RESOLVE` stays default-`false` — under v2 the
  GEOIP lookup rides the tunnel, so the knob's privacy rationale is gone and unlisted-CN
  keeps DIRECT.
- **DEC-B (owner): STREAMING group + geosite rules.** `GEOSITE,NETFLIX,STREAMING` (new
  select group, first member PROXY = day-one no-op) + `GEOSITE,GEOLOCATION-!CN,PROXY`
  ahead of the GEOIP fallthrough, from the already-shipped geosite.dat. Rule-providers
  (runtime-fetched community lists) deliberately deferred — same cold-start fetch class as
  the 2026-07-10/12 outages.
- Agent-verified + resolved in review: DNS detour fragments switched `#PROXY` → **`#auto`**
  (survives a dashboard `PROXY=DIRECT` pin; DNS wants "any live tunnel", which url-test is
  by construction); `www.gstatic.com` joins the always-on domestic policy pins (delay
  probes + the COMPATIBLE placeholder dial it DIRECT) but NOT fake-ip-filter; the
  `geosite:geolocation-!cn` policy line stays (redundant under the flip, smallest diff);
  legacy `.env` migration = interactive default-No offer in the redeploy/pi wizards
  (`offer_dns_privacy_upgrade`, values via `example_default()`, custom `://` values never
  clobbered); doctor gains `dns_privacy` (v2|v1|legacy|unknown, 17→18 checks); validation
  gains the fails-closed `/dns/query` pair + STREAMING/rule probes + a dnsleaktest/netflix
  owner spot-check block. Known residual (documented, deferred): clients with hardcoded
  DNS bypass fake-ip and miss the STREAMING rule — `sniffer:` is the structural fix.
- **Post-release incident addendum (same day):** owner's LAN devices turned out to bypass
  the gateway's DNS entirely (DHCP hands the router out as resolver — same-subnet traffic
  the `any:53` hijack can't see — plus a WARP app and browser DoH), which reproduced the
  AliDNS leak and broke facebook/netflix via poisoned raw-IP dials while the gateway's own
  v2 chain measured healthy end-to-end. The "deferred" sniffer shipped immediately as
  `SNIFFER_ENABLE` (default on for new installs, `parse-pure-ip` + `override-destination`;
  unset renders byte-identical), the rule chain gained `GEOIP,LAN,DIRECT,no-resolve` first
  (Windows Delivery Optimization peers at foreign RFC1918 addresses were riding the tunnel),
  and installation §7 now mandates DHCP announcing the gateway as gateway AND sole DNS —
  the gateway-only wording was the root doc bug. Follow-ups recorded: node UDP support
  (QUIC silently falls to DIRECT when the selected node lacks UDP), opt-in DoT/DoH-blocking
  rule tiers, a doctor client-adoption check.

## Work breakdown

**Enacted this session (no issues; committed directly):**

- E1 `refactor(lib)`: source-time defaults hoist in common.sh + delete gateway.sh:486
  hand-copy + hermetic regressions in gateway_cli_check.sh (source-time sweep + probe
  regression a fixture .env cannot mask).
- E2 `test(ci)`: env -i hermetic smoke block in gateway_cli_check.sh (help / status /
  status --json / doctor --json / deploy --yes / migrate_legacy --dry-run).
- E3 `test(ci)`: render_check.py semantic pack (rule targets, fence integrity,
  bidirectional placeholders, all-variant unresolved scan) + minimal-env fix.
- E4 `test(ci)`: new scripts/ci/migrate_legacy_check.sh + .woodpecker.yml wiring +
  package_check must-include note (CI files are dev-tree only).
- E5 `docs`: boot self-heal [4/4] catch-up (installation.md + zh, architecture.md + zh,
  AUTO-UPDATE.txt + .zh.txt); operations.md doctor-check list refresh (+ zh); release
  ritual in development.md; postmortem `docs/brainstorms/dns-outage-postmortem.md`.

**Staged as the `dns-privacy-hardening` work-order chain:**

1. `feat(dns)`: split-horizon nameserver-policy + tunneled fallback + no-resolve knob
   (template fence, renderer knobs + validation, .env.example defaults, render_check
   cases incl. v1.3.7 byte-identity, geox-url reachability assertion, wizard seeding
   DEC-X, provider-proxy DEC-X).
2. `docs(dns)`: threat-model + knob guidance, en+zh, enduser .txt + dev .md, incl.
   proxy-server-nameserver semantics (knob names final after #1).
3. `chore(release)`: NAS cold-start validation (provider cache cleared, fallback
   black-holed — converts the MED-HIGH provider-fetch claim to verified fact) + ship
   v1.3.8 per the release flow.
4. `refactor(installer)`: wizard defaults single-sourced from .env.example + CI
   value-parity assertion (Pi override seam DEC-X).
5. `test(ci)`: installer i18n full en/zh set-equality + used-key sweep + dead-key
   warnings (replaces the 21-key list).
6. `test(ci)`: doctor --json check-name contract gate + extend doctor parity cases
   3→all (prose-assert vs spec restructure DEC-X).
7. `refactor(doctor)`: unified check table + two renderers (human/JSON) — after #6.
