# Brainstorm brief — Generic Linux deployment path (amd64 + arm64)

Date: 2026-07-17 · Mode: greenfield (`/brainstorm`) · Epic: `generic-linux-port`

## Idea

Promote the gateway from "Synology DSM + experimental Raspberry Pi" to **any
container-capable Linux host (amd64 and arm64)**: a first-class generic entry point,
per-platform packages and scripts from **one unified core codebase**, while the **NAS stays
the canonical, owner-validated target** with its dedicated test case untouched. The seed
asked for a feasibility evaluation first, then architecture, then implementation.

## Feasibility verdict (evaluated 2026-07-17)

**Yes — high feasibility, low effort.** The `raspberry-pi-port` epic already built the hard
part. Six dimension researchers converged on the same picture:

- `install-pi.sh` self-describes as "Raspberry Pi (generic Linux)"; `scripts/pi/detect.sh`
  explicitly treats amd64 boxes the same as arm64; the entry runs **unmodified and
  correctly** on a generic Debian/Ubuntu amd64 VM or arm64 cloud box today.
- The core (`scripts/lib/*`, `scripts/installer/*`, renderer, gateway/doctor/updater) is
  ~90% platform-neutral POSIX sh. The DSM remainder is one location probe (already escaped
  by `scripts/pi/preflight.sh`), scheduler mechanics (systemctl branch already landed), and
  **phrasing**.
- Arch is a **runtime concern, never a packaging concern**: `registry.sh:host_arch()` +
  `pi_lite_asset_arch()` map `uname -m`; images resolve by multi-arch manifest; the lite
  binary downloads per-arch on the target. Nothing arch-specific belongs in an archive.
- The `pi` bundle profile is already the de-facto arch-neutral generic-Linux bundle.

So the epic is a **reframe + thin additive layer**, not a port: a generic entry, a
macvlan-viability guard, a profile rename, a CI suite, docs, and phrasing.

## Dimensions

### Infra & deploy
Options: (A) rename `scripts/pi/` → generic namespace now; (B) additive `install-linux.sh`
entry sourcing the pi engine unchanged; (C) broaden `install-pi.sh` in place. **Chosen: B**
— mirrors the proven additive pattern the pi epic used over `install.sh`; zero churn to the
four live name-contracts (`pi_installer_check.sh`, i18n keys, `pi-compose`/`pi-lite` mode
markers, `--profile pi`); the namespace rename stays a possible later mechanical follow-up.
The single substantive infra gap is topology on macvlan-hostile hosts (cloud VPCs with MAC
filtering, Wi-Fi): **lite mode is the sanctioned v1 answer** there, fronted by a new
macvlan-viability preflight guard (virtualization/cloud-NIC detection generalizing the
wlan0 refusal); a compose-without-macvlan topology (host-net / bridge+DNAT) is deferred —
it would fight the single-compose-file constraint three CI checks hardcode.

### Core & config
No core logic rewrite. The generic path reuses the pi seams wholesale: `pi_check_location`
(any writable dir), the `systemctl cron|crond|cronie` reload branch, and
`pi_align_expected_arch` (auto-pin `EXPECTED_ARCH` to `host_arch`, removing the
amd64-default footgun on arm boxes). Registry: the generic wizard defaults the **user's**
`.env` to `REGISTRY_MODE=docker` (upstream multi-arch manifests — no China-mirror
prerequisite, no per-arch mirroring gap), with `acr` offered for China users plus the
arch notice; the **committed** `.env.example` stays `acr`, so `compose_policy_check.py`
and the DSM/Pi China-first story are untouched.

### Packaging & release
"arm64/amd64-specific packages" = **arch-neutral source bundles that self-resolve arch at
install time** — exactly what the code already does. Rejected: per-arch binary bundles
(bloat, staleness, duplicates the updater/lite downloader) and per-arch naming of identical
bytes (misleading). **The `pi` profile is renamed to `linux`** (ships both `install-pi.sh`
and `install-linux.sh`; artifact stem `syno-mihomo-gateway-linux`); asset count stays 8
(dsm 4 + linux 4) under keep-only-latest. Leak-gate posture carries over: the IDENTITY set
(enumerated at `scripts/package.sh` `leak_scan`, referenced by pointer — never copied)
stays forbidden in every gated profile; the FORGE set stays forbidden in enduser, allowed
in linux (the lite overlay ships functional upstream URLs).

### CI/CD & testing
CI stays **arch-neutral on the amd64 runner** — arm64/amd64 behavior is exercised via the
pi epic's env-injection pattern (`SMG_PI_ARCH`, `host_arch()` overrides, fixture files);
no qemu emulation in the blocking gate (slow, flaky, marginal value); no docker socket
(the deliberate homelab security posture stands). A **new
`scripts/ci/linux_installer_check.sh`** suite (assert.sh idiom — never the dsm hard-fail
idiom) covers the generic path; `dsm_installer_check.sh` and `cli_contract_check.py` stay
**byte-stable and passing unmodified** — the NAS-specific test case the seed requires.
Suite count grows 11→12 with the AGENTS.md + docs/development.md mirrors updated
same-change. Real arch/hardware validation stays a release-time step.

### Validation tiers
Support matrix of record: **DSM/NAS = required owner validation** (staged
`validate_release.sh` on the real NAS, tee'd log, tag only after real-world success —
unchanged); **Pi = experimental**; **generic Linux = experimental** (community/best-effort,
same tier as Pi). A `validate_release.sh` macvlan|bridge topology switch for an owner
amd64-VM run is a deferred follow-up, revisited if the generic tier is ever promoted.
The opt-in Woodpecker dind smoke was considered and declined (docker socket).

### Docs & positioning
The Pi guide set **generalizes in place**: `installation-pi.*` (4 files: en/zh md + txt
pair) becomes `installation-linux.*` ("Generic Linux & Raspberry Pi"; the Pi hardware
matrix becomes a section); the `INSTALL-LINUX.txt` pair ships in the linux bundle; a
one-line pointer stub replaces `installation-pi.md` for inbound links. README/README_ZH
and architecture.md reposition as **"born on Synology, runs on any Docker-capable Linux
host (amd64 + arm64)"** with a platform matrix; DSM remains the canonical deployment
subsection. All identifiers stay: repo name, the data-dir literal
(`scripts/lib/common.sh` `../syno-mihomo-gateway-data` — the one load-bearing occurrence),
release stems (except pi→linux, decided above). No repo rename, no neutral second name.

### Phrasing
Shared code carries DSM-worded remediation hints that lie off-DSM ("DSM Control Panel >
Network", "run: sudo sh ./install.sh (Redeploy)", "start Container Manager", "DSM Task
Scheduler"). **Bounded fix in-epic**: an entry-name/platform variable (e.g.
`$INSTALLER_ENTRY` + a platform label the entries set) makes the ~10 user-facing hint
lines platform-conditional. No logic change, no deep i18n refactor; the DSM branch keeps
byte-identical text so `dsm_installer_check.sh` passes unmodified.

## Decisions

Resolved interactively with the owner on 2026-07-17 (AskUserQuestion, one at a time):

| # | Decision | Answer |
|---|---|---|
| DEC-1 | Structure | **Additive `install-linux.sh`** + thin `scripts/linux/` overlay (i18n, guard); `scripts/pi/` engine sourced unchanged; namespace rename deferred |
| DEC-2 | Bundle SKU | **Rename `pi` profile → `linux`** (subsumes pi; both entries ship; stem `-linux`); assets stay 8 |
| DEC-3 | Macvlan-hostile topology | **Lite mode + macvlan-viability guard** in v1; compose-without-macvlan deferred |
| DEC-4 | Registry default | **Generic wizard writes `REGISTRY_MODE=docker` to the user's `.env`**; committed `.env.example` stays `acr`; CI policy untouched |
| DEC-5 | CI coverage | **New `linux_installer_check.sh` suite** (assert.sh idiom); pi suite keeps its Pi-hardware asserts |
| DEC-6 | Validation tier | **Generic ships experimental** (Pi tier); NAS gate unchanged; no dind, no owner-VM gate for now |
| DEC-7 | Docs shape | **Generalize the Pi guide in place** → `installation-linux.*`; ~0 net-new files; pointer stub for the old path |
| DEC-8 | DSM phrasing | **Bounded in-epic fix** via `$INSTALLER_ENTRY`/platform label; DSM output byte-stable |
| DEC-9 | Positioning | **Keep all identifiers; reframe prose** ("born on Synology, runs on any Docker-capable Linux host") |
| DEC-10 | Epic slug | **`generic-linux-port`** |

Pre-decided defaults carried from the research (not re-decidable in tickets):

- Mode-marker tokens stay `pi-compose`/`pi-lite` (internal dispatch contracts; rename rides
  the deferred namespace rename, cosmetic on generic hosts).
- Scheduler: the portable `/etc/crontab` writer + existing systemctl reload branch;
  systemd-timer registration deferred.
- 32-bit generic hosts inherit the Pi mode table (armv7 → lite-only; ARMv6 best-effort
  behind the explicit ack) — the dashboard image publishes amd64+arm64 only.
- `EXPECTED_ARCH` auto-pin in the generic preflight reuses `pi_align_expected_arch`.
- Guard posture: warn + steer to lite + **explicit ack to force macvlan anyway**
  (mirrors the ARMv6 ack pattern) — never a silent hard refusal.
- New generic-only files live in `scripts/linux/`; `scripts/pi/` stays the shared engine.
- Packages stay source-only; single `docker-compose.yml`; compose/config render
  byte-identical when generic knobs are unset.
- Data-dir literal untouched.

## Work breakdown

Six tickets, TDD-ordered (Sequence 10–60):

1. **feat(linux): install-linux.sh additive entry + scripts/linux overlay + seeded
   linux_installer_check** — the entry sources the same lib/installer modules as
   `install-pi.sh` plus the pi engine; `scripts/linux/i18n_linux.sh` overlay (generic
   phrasing, en+zh parity); mode wizard reusing the pi flow; seeded
   `scripts/ci/linux_installer_check.sh` (entry sourcing via `INSTALL_SOURCE_ONLY=1`,
   dispatch, i18n parity); `.woodpecker.yml` suite 11→12 + shellcheck targets + the
   docs/development.md and AGENTS.md mirrors, same-change.
2. **feat(linux): macvlan-viability guard + EXPECTED_ARCH auto-pin + docker-mode registry
   wizard** — `scripts/linux/preflight_linux.sh`: virtualization/cloud-NIC detection
   (mechanism decided in-ticket: `systemd-detect-virt` vs DMI vs probe — DEC-A), warn +
   steer-to-lite + explicit macvlan ack; `pi_align_expected_arch` reuse; wizard writes
   `REGISTRY_MODE=docker` to the user's `.env` with the acr option + arch notice; suite
   cases for guard firing rules, ack, auto-pin, and the runtime rewrite.
3. **feat(release): rename pi bundle profile to linux with carried leak-gate split** —
   `package.sh` profile rename (+ `pi` accepted as an alias arg), `LINUX_EXCLUDES` derived
   from `ENDUSER_EXCLUDES`, stem `syno-mihomo-gateway-linux`; `package_check.py` fixtures
   + split forbidden sets renamed, linux bundle must-include both entries +
   `scripts/linux/`; `release-packaging.md` + development.md updates.
4. **chore(shared): platform-conditional remediation phrasing behind INSTALLER_ENTRY** —
   the ~10 DSM-worded hint lines in `checks.sh`/`registry.sh`/`gateway.sh`/headers become
   platform-conditional; DSM branch byte-identical (`dsm_installer_check.sh` passes
   unmodified — hard constraint); linux suite asserts the generic phrasing.
5. **docs(linux): generalize Pi guide to installation-linux + cross-platform
   repositioning** — the 4-file rename/reframe + pointer stub; README/README_ZH
   reposition + platform/support matrix (canonical home of the validation tiers);
   architecture.md reframe; troubleshooting touch-points (macvlan-hostile hosts, registry
   modes); installation.md chooser update; en+zh throughout.
6. **chore(release): linux bundle release verification + risk-log closure** — unpack
   proofs (linux bundle ships both entries + `scripts/linux/` + INSTALL-LINUX txt pair,
   no `.md`; enduser excludes all of it), ash source-checks from the unpacked trees, full
   local 12-suite gate, risk outcomes recorded back into this brief.

## Risk log (verify early in the tickets)

- **R1** Guard reliability: virt detection false positives (Proxmox bridged VMs where
  macvlan *does* work) and negatives (bare-metal behind Wi-Fi bridges) — mitigated by the
  warn+ack posture, never hard refusal (Seq 20).
- **R2** `pi` asset-name disappearance breaks stale download links — accepted under
  keep-only-latest; release notes call it out (Seq 30/60).
- **R3** Registry runtime-rewrite must not touch committed files or trip
  `compose_policy_check.py`/`render_check.py` (Seq 20).
- **R4** Phrasing ticket colliding with `dsm_installer_check` output asserts — DSM branch
  keeps byte-identical text; run the suite before and after (Seq 40).
- **R5** Docs rename breaks inbound `installation-pi.md` links — pointer stub (Seq 50).
- **R6** No real-hardware validation for the generic tier — accepted (experimental tier,
  Pi-G3 pattern); revisit on promotion.

## Constraints carried into every ticket

- POSIX `/bin/sh` (BusyBox-compatible) only; no `set -e` in runtime scripts; explicit
  return-code checks; shellcheck + `sh -n` clean.
- The DSM path is frozen: `install.sh`, `gateway.sh` behavior, `doctor.sh`,
  `scripts/cli/spec.yaml`, `docker-compose.yml` see zero behavioral change;
  `dsm_installer_check.sh` and `cli_contract_check.py` pass unmodified.
- `scripts/pi/` engine modules unchanged except where a ticket explicitly says otherwise;
  `pi_installer_check.sh` stays green unmodified.
- Single `docker-compose.yml`; rendered compose-mode config byte-identical to pre-epic
  output when generic knobs are unset; committed `.env.example` stays `acr`.
- No hardcoded proxy rules / DNS / network addresses in committed files (CLAUDE.md);
  leak-gate identity list referenced by pointer only, never copied.
- Source-only bundles; 8 release assets; keep-only-latest.
- Verification gate per ticket: the full `.woodpecker.yml` step set locally, shell suites
  adjudicated in alpine docker (macOS bash-3.2 false-greens), per docs/development.md
  "Local checks before pushing".
