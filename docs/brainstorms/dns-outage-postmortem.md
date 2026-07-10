# Postmortem — 2026-07-10 gateway outage (host DNS + aborted upgrade + node-DNS deadlock)

Date: 2026-07-10 · Status: resolved (v1.3.7) · Severity: full gateway + NAS-services outage

Dev-only document (excluded from the enduser bundle). The per-symptom runbook
entries live in the four troubleshooting files; this is the causal story told
once, end to end.

## Impact

- The NAS could not reach any Synology service (QuickConnect, package center,
  account) — every name-based egress from the host failed.
- The cloudflared tunnel was down (remote access lost).
- The mihomo gateway was down after a reboot, then degraded after resurrection:
  LAN clients had no proxy egress; every airport node showed
  "dns resolve failed".

## Timeline (condensed, CST)

- **Jul 3–4** — a v1.3.4 upgrade was unpacked on the NAS but the deploy never
  completed: the release tree sat root-owned at VERSION 1.3.4 while the legacy
  flat install (`/volume1/docker/mihomo`) silently kept carrying the gateway.
- **Jul 10 ~22:25** — the NAS rebooted. The legacy mihomo container did not
  come back (macvlan-at-boot race); only the two bridge containers returned.
- **Jul 10 ~22:30 →** — with host DNS dead (see cause 1) the NAS lost Synology
  services and cloudflared could not resolve the tunnel edge. LAN clients had
  no gateway at all.
- **~02:00 (next cycle)** — the daily auto-update task's compose-apply
  resurrected the stack (~3.5 h after the reboot), but the TUN dataplane
  stayed broken until a force-recreate, and every node dead-ended on DNS
  (cause 3).
- **Jul 10–11 (recovery session)** — read-only SSH triage → owner-run recovery
  scripts → v1.3.7 patch built, NAS-validated, released.

## Root causes (three, stacked)

1. **Host DNS was `1.1.1.1`-only — dead from this network.** DSM's resolver
   list contained exactly one server, unreachable/unstable from mainland
   China. Every host-origin lookup failed, which took down Synology services
   directly, and — because bridge containers copy the host `resolv.conf` at
   container START — starved cloudflared too (raw TCP to the tunnel edge was
   provably open; only name resolution was dead).
2. **The Jul-4 upgrade was aborted mid-flight and nobody noticed.** The new
   layout was unpacked but never configured (`.env` absent in the data dir);
   the legacy flat install kept the LAN alive invisibly until the reboot
   removed it. There was no doctor signal for "unpacked but unconfigured", no
   guided path off a legacy flat install, and the boot task ensured only
   TUN + macvlan — it never brought the stack itself back.
3. **A latent node-DNS chicken-and-egg in the template.** With
   `fallback-filter: geoip: true`, an airport node hostname resolving to a
   non-CN IP has its domestic answer DISCARDED in favor of the fallback
   resolvers — which were dialed DIRECT and are blocked before any node is
   up. Result: every node dies with "dns resolve failed" on a cold start.
   Historically masked by node IPs cached in `cache.db`; the recovery's fresh
   start exposed it.

## What fixed it (v1.3.7, NAS-validated before tagging)

- China-safe DNS defaults (`223.5.5.5,119.29.29.29` + DoH/DoT fallback) in
  `.env.example`, wizards, and docs; DSM host DNS set domestic in the UI.
- `proxy-server-nameserver: [ {{DNS_NAMESERVER}} ]` in the template — node
  hostnames resolve via the domestic list, outside the fallback-filter (the
  cause-3 fix).
- `CF_DNS` knob — cloudflared gets explicit resolvers instead of inheriting
  the host's.
- `scripts/migrate_legacy.sh` + `legacy_install_detect()` + doctor hints for
  the unpacked-but-unconfigured state (the cause-2 tooling).
- Boot self-heal step [4/4]: `setup_network.sh` now also brings a deployed
  stack up from local images (exit 2 → DSM failure email).
- Doctor checks `host_dns` / `geodata` / `cloudflared`, human + `--json`.
- Geodata pre-seed via CDN mirrors, so a first start needs no cross-GFW fetch.

Two live bugs were caught ON the NAS before tagging (the LOCK_DIR
before-load_env lock failure and cause 3 itself) — CI could not have caught
either. That validated the **NAS-validate-before-tag** ship pattern, now
documented in development.md.

## Prevention beyond the patch (this cycle's follow-through)

- The LOCK_DIR bug generalized: all optional-tunable defaults now bind at
  source time in `scripts/lib/common.sh`, with an env-scrubbed (`env -i`)
  hermetic CI block so harness exports can never again mask an
  env-dependence bug (that is exactly how the LOCK_DIR bug survived CI).
- Template semantic invariants in `render_check.py` (fence pairing, rule
  targets, bidirectional token map, all-variant placeholder scans).
- `migrate_legacy_check.sh` — the importer was the last untested root-run
  entry point.
- The DNS **privacy** hardening this incident's inspection surfaced
  (split-horizon nameserver-policy) is staged as the `dns-privacy-hardening`
  epic — see [dns-privacy-hardening](dns-privacy-hardening.md).

## Lessons

1. **A default that is fine on one network is an outage on another.** Ship
   defaults for the deployment environment the project targets (mainland
   China), not the developer's.
2. **Inheritance chains are failure chains.** Host resolv.conf → bridge
   containers; harness env → scripts under test. Both bit in the same week;
   both fixes are "make the dependency explicit".
3. **Silent fallbacks hide half-finished state.** The legacy install carrying
   the gateway made the aborted upgrade invisible until a reboot. Detection
   (doctor hints, foreign-project guard) beats memory.
4. **Caches mask cold-start bugs.** cache.db hid the fallback-filter deadlock
   for months. Validation must include a cleared-cache cold start — now part
   of the staged NAS validation gate.
5. **Validate on the real box before tagging.** CI proves logic; only the
   production network proves the environment.
