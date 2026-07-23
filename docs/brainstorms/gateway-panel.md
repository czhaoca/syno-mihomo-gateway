# Brainstorm brief — Gateway Panel: dynamic device policy + persistent stats

Date: 2026-07-23 · Mode: greenfield (`/brainstorm`) · Epic: `gateway-panel`
Relates to: `per-device-full-proxy.md` (the static `FULL_PROXY_SOURCES` band this epic
subsumes as a fallback — see DEC-4) and `gateway-cli-api.md` (the spec-first contract
pattern this epic clones for its HTTP API).

## Idea

The v1.7.0 per-device story is a static `.env` band plus a router-console fixed-IP
flip: coarse (band membership only), full-proxy only (no per-device "never proxy"
concept), and history-free (MetaCubexD is a stateless browser client — every stat
dies with the page or the container). Build a **companion service — the Gateway
Panel** (`mihomo-panel`): a SQLite-backed FastAPI backend + no-build web UI that
(1) flips any LAN source IP between **default rule-mode / full-tunnel / full-direct**
live — no `.env` edit, no restart, honoring the standing "never a NAS-side gesture
per change" rule via mihomo's hot-reload API — and (2) continuously persists
per-device/per-chain traffic history in SQLite so stats survive reboots.

**Mechanism (all dimensions converged):** two file-based rule providers
(`dyn-full-direct`, `dyn-full-tunnel`; `type: file`, `behavior: classical`,
`format: text`) in the persistent config volume, referenced by two `RULE-SET` rules
spliced directly under `GEOIP,LAN,DIRECT` (above the static band). The panel owns
SQLite → atomic tmp+rename provider write → `PUT /providers/rules/:name` →
read-back verify. Policy survives mihomo restarts (files persist) and panel downtime
(fail-static). `PUT /configs` full-push (merge-ownership conflict with the renderer,
whole-config blast radius) and `PATCH /rules` (ephemeral, index-addressed) were
rejected.

## Dimensions (options weighed → chosen)

- **backend** — Go static binary vs Python stdlib vs **Python 3.12 + FastAPI
  (chosen, DEC-1)** vs sh+httpd (stats unimplementable). File-provider mechanism
  unanimous; contract stored per DEC below.
- **frontend** — **no-build vanilla JS served same-origin by the backend (chosen)**
  vs built SPA (node toolchain tax) vs MetaCubexD fork (owning upstream's codebase).
  Browser never sees `CONTROLLER_SECRET` — an improvement over MetaCubexD.
- **coding paradigm** — module boundaries store/ mihomo-client/ reconciler/
  collector/ http; typed models (pydantic via FastAPI); fail-closed typed error
  classes cloned from the `render_config.sh` knob-validation walk.
- **engineering practices** — new top-level `app/` (scripts/ stays pure POSIX-sh +
  shellcheck); **panel naming family (DEC-10)**; ruff joins CI; conventional
  commits to master.
- **TDD/testing** — unit + hermetic fake-controller integration + e2e; layer split
  decided by DEC-3; fixtures use TEST-NET / placeholder addressing only.
- **CI/CD** — hermetic new steps (Woodpecker steps stay daemonless);
  `docs/development.md` local mirror grows in the same change; leak-gate/privacy/
  package checks extended for the new surface.
- **data & storage** — **split `policy.db` + `stats.db` (chosen)** vs one file vs
  raw event log vs JSONL; delta-accounted collector with persisted per-connection
  baselines (no double-count on restart; downtime = honest gaps, never backfill).
- **infra & deploy** — **own macvlan IP (chosen, DEC-2)** vs bridge→child
  (presumed broken: host→child isolation) vs netns-share (TUN self-hijack risk) vs
  dual-homed; image sourcing decided by DEC-1/DEC-11.
- **security & authz** — **separate bearer token, header-only, fail-closed writes
  (DEC-6)**; no CORS (same-origin by construction); input validation ports the
  fail-closed knob classes; audit append-only at the API layer.
- **observability** — **panel-owned `/health` verdict + thin doctor probes
  (chosen)** vs sh-side three-way diff (same-engine principle violation) vs
  health-only vs Prometheus stack (over-scope).
- **docs** — **one new guide + spec-first-style generated API contract (chosen)**;
  brief-as-architecture-record continues (no ADR dir).

## Decisions (owner-resolved 2026-07-23)

- **DEC-1 — Runtime: Python 3.12 + FastAPI, custom image.** Best DX + native
  OpenAPI, accepting the repo's **first image build+publish pipeline** (built in the
  `docker-china-sync` sibling repo's Actions, not this repo's Woodpecker). `app/`
  is image-delivered (dev-excluded from bundles); contract becomes code-first
  (committed `openapi.json` regenerated from the app, byte-identity CI gate).
  Overrode the fan-out's Python-stdlib-on-stock-image recommendation.
- **DEC-2 — Network seat: own macvlan IP.** `mihomo-panel` joins `tproxy_network`
  with `${PANEL_IP}` (Nimbus-registered). LAN→child is proven on this OVS NAS;
  sibling→sibling verified by one curl at execution. No DSM host-port publish;
  doctor probes via docker-exec (host→child is blocked by design).
- **DEC-3 — e2e depth: hermetic CI + real e2e at NAS validation.** CI runs the
  REAL app in-step against a scripted fake controller (UI action → SQLite →
  provider file → refresh call → read-back). Real mihomo semantics + routing
  assertions (distinct-src-IP client containers through the mixed port) live in the
  local compose driver + `validate_release.sh` NAS probes, **required before
  tagging**. Playwright deferred.
- **DEC-4 — Authority: UI wins, band badged.** Dynamic RULE-SETs splice ABOVE the
  static band; the UI badges band-member IPs as router-pinned and asks confirmation
  before overriding (a deliberate, documented inversion of the v1.7.0 "never
  silently un-proxied" promise — mitigated by badge + audit). Band coexists as the
  panel-independent fallback; deprecation revisited only after staged validation.
- **DEC-5 — Rollout: enduser from day one.** Panel is a standard third service in
  the base compose (fail-closed `${PANEL_IMAGE:?}` etc.), installer prompts for it,
  `.env` auto-migration on upgrade (ux-automation precedent), full doc treatment
  including the `PANEL.txt`/`PANEL.zh.txt` bundle pair. Overrode the
  experimental-opt-in recommendation.
- **DEC-6 — Auth: separate `PANEL_SECRET` bearer, header-only, fail-closed
  writes.** Installer generates a token by default; empty knob ⇒ reads LAN-open,
  ALL mutations 403. No cookies, no CORS headers. Separate knob keeps a leaked UI
  token from granting raw controller power.
- **DEC-7 — DB failure: fail-static + loud.** `policy.db` missing/corrupt ⇒
  provider files untouched (mihomo keeps last-applied routing), mutations refused,
  webhook fired, UI banner + doctor ERROR until restore (per-flip `VACUUM INTO`
  backups) or explicit reset. Routing changes only ever by owner action.
- **DEC-8 — Stats: rollup tiers + opt-in domain table.** Per-device + per-chain
  tiers (minute 48h → hourly 90d → daily 2y, hard 512 MB `stats.db` cap,
  oldest-tier-first pruning, thresholds as knobs) **plus** the per-domain table
  shipped now behind an off-by-default knob with forced 7-day retention. Counterweight:
  a stats purge endpoint (domains included); the policy audit stays API-immutable.
  Overrode the no-domains-in-v1 recommendation.
- **DEC-9 — CLI parity in v1.** `gateway.sh policy list/set` as thin proxies over
  the panel API (single write path), token-authed, **exempt from the root+`--yes`
  guardrail** (they mutate no host state); spec-first via `scripts/cli/spec.yaml`
  with regenerated artifacts in the same change. Doubles as the e2e/validation
  driver.
- **DEC-10 — Naming: panel family.** Service `panel`, container `mihomo-panel`,
  knobs `PANEL_*`, guide `docs/panel.md`, UI title "Gateway Panel".
- **DEC-11 — Image publish: GHCR upstream + ACR mirror, multi-arch.**
  `docker-china-sync` builds from this repo's tagged release → pushes
  `ghcr.io/<owner>/mihomo-panel` (the public upstream for `REGISTRY_MODE=docker`)
  → mirrors to ACR (the default). amd64 + arm64 so the linux/Pi compose tier
  inherits.
- **DEC-12 — MetaCubexD: keep both, split roles.** Panel = device policy +
  persistent stats (daily surface); MetaCubexD = node/group ops + live connections
  (power surface). Panel deep-links across; its scope stays small forever.

### Deferred decision points (decided at execution)

- **DEC-A — Empty-provider seed format**: whether the pinned mihomo accepts a
  zero-line classical text provider file at `mihomo -t` (vs needing a stub payload).
  Proven by the template issue before anything builds on it.
- **DEC-B — Sibling reachability proof**: one curl from a `tproxy_network` sibling
  to `${MIHOMO_IP}:${CONTROLLER_PORT}` during staged validation before the panel's
  refresh path is trusted.
- **DEC-C — Collector constants**: `/connections` poll cadence + connection-id
  stability verified against the pinned mihomo before the baseline schema freezes.
- **DEC-D — Image build trigger** in `docker-china-sync` (tag-driven vs manual) —
  decided when wiring the sibling repo.
- **DEC-E — WAN-exposure policing**: v1 ships a docs warning (never expose the
  panel via cloudflared); a doctor check is a follow-up if warranted.

### Pre-decided constraints

- Dynamic layer renders **unconditionally**: providers + RULE-SET splice always in
  the rendered config; the entrypoint seeds empty provider files before `mihomo -t`
  (seed_provider.sh precedent); empty files = zero behavior change. The
  `Full-Tunnel Devices` group **un-fences** (renders always — it is now a RULE-SET
  target even with `FULL_PROXY_SOURCES` unset).
- Rule order: `GEOIP,LAN,DIRECT` → `RULE-SET,dyn-full-direct,DIRECT` →
  `RULE-SET,dyn-full-tunnel,Full-Tunnel Devices` → static `{{FULL_PROXY_RULES}}`
  band → airport pin → domain rules. One mode per IP enforced in the DB;
  full-direct means internet-DIRECT (LAN rule already covers LAN).
- Reconciliation is self-verifying: write → refresh → `GET /providers/rules`
  count-parity check; startup re-sync; apply-failure ⇒ webhook + persistent marker
  (`config_rejected` pattern) + doctor ERROR until reconciled.
- Validation ports the `FULL_PROXY_SOURCES` fail-closed classes: IPv4 /32-or-CIDR
  only, reject IPv6 (with the `ipv6_bypass` pointer), octet/prefix/leading-zero
  checks, dedupe, full-tunnel/full-direct overlap rejection, reject `MIHOMO_IP` and
  `PANEL_IP` as policy entries; provider files are emitted from the validated
  canonical form only (no raw input interpolation).
- The band's UDP-fallthrough caveat applies to dynamic full-tunnel too: the
  doctor's `full_proxy` runtime check extends to dynamic full-tunnel sources.
  Split-horizon DNS remains global (a full-direct device's foreign lookups still
  resolve via the tunneled list — documented asymmetry, per-source DNS is
  impossible in mihomo).
- Storage: `policy.db` + `stats.db` under `GATEWAY_DATA_DIR/state/`; WAL +
  `synchronous=NORMAL` + busy_timeout; single-writer service; `PRAGMA user_version`
  migrations at startup; umask 077; refuse WAL on a network FS; `conn_baseline`
  flushed transactionally with rollups; audit records ALL mutations (flips,
  renames, add/remove) with requester IP + optional note, append-only at the API.
- Secrets (`PANEL_SECRET`, `CONTROLLER_SECRET`, webhook URL) reach the panel as
  env from `.env` only — never DB, never logs, never argv; `privacy_check.py` +
  the `package.sh` leak-gate grow the panel runtime paths and `*.db`/`*.sqlite*`
  globs.
- CI: new blocking steps — app lint (ruff) + unit, hermetic app-e2e (real app +
  fake controller), panel contract byte-identity gate — each mirrored in
  `docs/development.md` in the same change; e2e fixtures use TEST-NET-2 /
  placeholder addresses only.
- Compose/deploy: base-compose third service (`ipv4_address ${PANEL_IP}`,
  `${PANEL_IMAGE:?}`, `restart: always`, mem limit, json-file log caps); installer
  prompts, generates `PANEL_SECRET`, migrates existing `.env` on upgrade; Nimbus IP
  registration is an explicit owner step; `auto_update.sh` trio→quartet (panel
  updates with the compose set, LAST, under the existing health gate + rollback).
- Observability: panel `/health` returns structured verdicts (db_ok, parity,
  collector_last_ts, db_bytes, last_apply); doctor gains `companion_health`
  (container down = **warn** — routing unaffected) and `policy_parity`
  (DB↔file↔live drift = **ERROR**, exit 3) parsing that one endpoint via
  docker-exec; webhook notifies on failures only.
- UI: saved → applying → confirmed/drift badges must be honest (read back from
  mihomo, never assumed); band badge per DEC-4; `data-testid` discipline; EN/zh
  JSON dictionary, auto-detect + persisted toggle; plain page v1 (PWA later);
  lite (bare-metal) mode is documented as no-panel — compose tiers inherit via the
  multi-arch image.
- No real addresses/identities anywhere tracked: placeholder `192.168.1.x` and
  TEST-NET only (CLAUDE.md rule; privacy gate scans full history).

## Verification gate

The full local gate (docs/development.md "Local checks before pushing", alpine-
adjudicated sh suites) plus this epic's additions as they land: the new app steps
(ruff/pytest/app-e2e), the panel contract gate, extended
render/compose-policy/package/privacy checks, and the panel probes joining
`validate_release.sh` (NAS pass required before tagging). Verbatim commands live in
each issue.

## Work breakdown

Seven issues, one chain (`Epic: gateway-panel`, Sequence 10–70):

1. `feat(template): dynamic policy rule-provider layer` — providers + RULE-SET
   splice + Full-Tunnel un-fence + entrypoint seeding (proves DEC-A); render_check
   + entrypoint suite coverage.
2. `feat(panel): service core` — `app/` FastAPI skeleton, policy store +
   migrations + backups, reconciler (write→refresh→verify, fail-static), typed
   validation, token auth, audit; hermetic fake-controller tests; contract gate +
   `openapi.json`; Dockerfile; new CI steps.
3. `feat(panel): stats collector` — delta accounting + baselines, rollup tiers,
   retention/cap pruning, opt-in domain table (7d forced), purge endpoint,
   `/health` verdicts.
4. `feat(panel): web UI` — devices/stats/audit views, 3-state toggle, honest
   apply/drift badges, band badge, EN/zh, data-testid.
5. `feat(cli): policy verbs + doctor checks` — spec.yaml `policy list/set` (+
   regenerated artifacts), `companion_health`/`policy_parity` doctor checks,
   `full_proxy` dynamic extension, webhook wiring.
6. `feat(deploy): compose + installer + auto-update` — base-compose service,
   `.env.example` knobs, installer prompt + migration + secret generation,
   quartet auto-update, compose-policy/package/privacy check updates.
7. `feat(release): image pipeline + validation + docs` — docker-china-sync wiring
   (GHCR+ACR, multi-arch) + digest pinning, validate_release panel probes, local
   compose e2e driver, all docs (panel.md+zh, generated panel-api.md, PANEL.txt
   pair, architecture/configuration/installation/operations/troubleshooting/README/
   development/AGENTS.md), release notes.
