# Brainstorm brief — Raspberry Pi deployment path

Date: 2026-07-09 · Mode: greenfield (`/brainstorm`) · Epic: `raspberry-pi-port`

## Idea

Give people **without Synology equipment** a first-class way to run the gateway on
**Raspberry Pi devices (ARM CPU, low RAM)**, and document the two questions the seed asked
explicitly: the **minimum RAM required** and **whether early Raspberry Pi models are OK**.
The port must not disturb the DSM path: the existing installer, CLI contract, compose safety
model, and CI stay behaviorally untouched.

## What already exists (verified 2026-07-09)

The port is far cheaper than a fork — the machinery is already portable POSIX sh (CI runs the
suites under BusyBox ash; a repo-wide bashism scan found zero hits):

| Asset | Where | Reuse |
|---|---|---|
| Config template + renderer (TUN fence, dns, controller) | `config/config.template.yaml`, `scripts/render_config.sh` | Unmodified on Pi (both modes); gains one optional `external-ui` fence |
| Docker-root gate escape hatch | `scripts/installer/preflight.sh:38-49` (`DOCKER_ROOT` override) | Pi preflight replaces the DSM volume probe |
| Parent-iface detection + macvlan creation | `scripts/lib/network.sh:100-109,307-349` (`ip route`-based) | Works as-is on wired `eth0`; wlan0 documented unsupported |
| Portable crontab writer (6-field `/etc/crontab`) | `scripts/installer/flow_cron.sh:11-43`, `scripts/gateway.sh:565-595` | Debian format identical; reused for both Pi modes |
| Scheduler detection fallback | `scripts/lib/scheduler.sh:83-117` (falls back to `/etc/crontab` + `crontab -l`) | Works on Pi today; only the crond reload is DSM-bound |
| Arch guard | `scripts/lib/registry.sh:129-146,239-252` (`host_arch` maps `aarch64`→arm64, `armv7l`→arm) | Enforced at deploy + update, already generic |
| Health/retry primitives | `scripts/lib/registry.sh:59-84` | Reused by the lite updater's gate |
| Update orchestrator (lock, kill-switch, dry-run, exit codes, log rotation) | `scripts/auto_update.sh`, `scripts/lib/common.sh` | Compose mode unchanged; lite updater mirrors the semantics |
| Notifications degrade off-DSM | `scripts/lib/notify.sh:44-49` (`command -v synodsmnotify` gate) | Webhook path works on Pi as-is |
| Installer menu/wizard/i18n system | `scripts/installer/*.sh` | Sourced by the new entry; bilingual overlay adds Pi strings |
| Release bundle + leak gate | `scripts/package.sh:47,90-100` (`git archive`, OS-agnostic) | Pi ships in the same enduser zip; no new profile *(superseded — see Re-scope 2026-07-12)* |

DSM-specific remainder (the entire porting surface): the volume-probe location gate, the
DSM-only crond reload (`scheduler_reload_crond()`, `scripts/lib/scheduler.sh:119-139`), DSM
phrasing in i18n, and the amd64-only default of the ACR mirror pipeline.

## Dimensions

### Platform & hardware floor
Evidence gathered 2026-07-09 (mihomo v1.19.28): upstream ships `linux-armv6/armv7/arm64`
binaries, but the `metacubex/mihomo` Docker image publishes **`linux/arm64` + `linux/arm/v7`
only — no `arm/v6`**. mihomo steady-state is ~60–100 MB RSS with TUN + fake-ip
(`geodata-loader: memconservative` is the default; `.mrs` rule-sets are the biggest low-RAM
lever). Raspberry Pi OS Lite idles ~100 MB (32-bit) / ~125 MB (64-bit); dockerd+containerd
idle ≈140–180 MB. Throughput (WireGuard as an optimistic proxy — a transparent gateway does
~2× crypto): ARMv6 ~30–40 Mbps; quad-A53 (Pi 3/Zero 2 W) ~270 Mbps class; Pi 4B ~760 Mbps.

| Tier | Models | Verdict |
|---|---|---|
| Rejected for whole-home duty | Pi 1 A/B/B+ (ARMv6, 256–512 MB) | No arm/v6 image; can't fill 100 Mbps; no/USB2 NIC |
| Best-effort, lite only | Pi Zero/Zero W (ARMv6); Zero 2 W (512 MB ARMv8, WiFi-only); Pi 2B (1 GB, 100 M) | Native binary + external-ui |
| Officially supported | Pi 3B/3B+ (1 GB arm64) | Compose works tuned (.mrs, zram); lite maximizes headroom |
| Recommended | Pi 4B ≥2 GB (true GbE) | Current compose+TUN+macvlan topology unchanged |
| Overkill | Pi 5 | Effortless |

**Chosen: minimum RAM = ≈256 MB tuned / 512 MB comfortable (lite mode); ≥1 GB minimum /
≥2 GB comfortable (compose mode). Early ARMv6 Pis are NOT OK for whole-home gateway duty**
and stay best-effort behind an explicit acknowledgment. This sizing guidance is net-new
(no RAM/CPU minimum existed anywhere in the docs); its canonical home is the
"Hardware & mode matrix" section of `docs/installation-pi.md`.

### Deployment model
Options weighed: (A) compose-parity only (≥1 GB floor, least work); (B) bare-metal lite only
(lowest floor, forfeits the compose safety machinery); (C) both, lite phased later; (D) both
fully in v1. **Chosen: D — both paths fully in v1** (owner call). Compose mode is the
preferred path wherever hardware allows because the mature digest/health-gate/rollback
updater lives there; lite mode exists for the 512 MB tier and ARMv6, not as an alternative
for capable hardware. The installer recommends by detected hardware: ≥2 GB → compose;
1 GB → compose + low-RAM tuning (lite offered); 512 MB → lite; ARMv6 → lite + ack.

### Installer placement
Options weighed: platform layer inside `install.sh`; additive `install-pi.sh` entry; separate
repo. **Chosen: additive `install-pi.sh` + a new `scripts/pi/` namespace** — the DSM flow and
its CI suite stay byte-stable; the Pi entry sources the same `scripts/lib` + `scripts/installer`
modules and swaps only preflight, the cron menu, and i18n strings. A separate repo was
rejected: ~90% of the machinery is shared and every fix would land twice.

### Registry & artifact sourcing
Compose images: **`REGISTRY_MODE=acr` stays the default on Pi** (China-first parity with DSM;
owner call, taken knowingly). Consequence: the sibling mirror pipeline
([docker-china-sync](https://github.com/czhaoca/docker-china-sync)) is amd64-only today, so
Pi compose in acr mode has an **external prerequisite — the user's ACR namespace must mirror
arm64 (and armv7 if kept) images**; the installer prints an actionable arch notice *before*
any pull, and `docker` upstream mode (true multi-arch manifests) remains the documented
out-of-box alternative. Lite artifacts (binary, MetaCubexD zip, geodata): every GitHub URL
passes through a **mirror-prefix env (`GH_MIRROR`, empty = direct)**; the zh-locale wizard
suggests a public gh-proxy mirror; fully-offline sideload is documented, mirroring the
release-zip pattern.

### Scheduler & auto-update
Compose mode reuses `scripts/auto_update.sh` unchanged, scheduled through the existing
crontab writer; the only seam is `scheduler_reload_crond()` gaining a
`systemctl restart cron|crond|cronie` branch (rc=1 stays benign — Debian cron re-reads
`/etc/crontab` by mtime). Lite mode gets a **new binary updater**
(`scripts/pi/auto_update_lite.sh`): resolve tag (or pinned `MIHOMO_VERSION`) → download via
`GH_MIRROR` → verify ladder (sha256 → `gzip -t` → exec smoke → version match) → keep
`mihomo.prev` → atomic swap → `systemctl restart` → health gate (unit active + restart-count
stability + controller HTTP probe + TUN link when enabled) → rollback to `.prev` on failure —
mirroring `auto_update.sh` semantics (lock, `UPDATE_ENABLED` kill-switch, `--dry-run`,
last-run JSON, exit codes, notify).

### Dashboard
Compose mode keeps the MetaCubexD container (parity). Lite mode uses mihomo's own
`external-ui` (serving the MetaCubexD static build from `$GATEWAY_DATA_DIR/ui/metacubexd` at
`http://<pi>:CONTROLLER_PORT/ui`) — this removes an entire container and is the free low-RAM
lever. Implemented as a `{{EXTUI_BEGIN}}/{{EXTUI_END}}` template fence emitted only when
`EXTERNAL_UI_DIR` is set, so the compose render stays byte-identical.

### Testing
New CI suite `scripts/ci/pi_installer_check.sh` in the `dsm_installer_check.sh` style
(BusyBox ash, mktemp sandbox, PATH-injected fake `systemctl`/`curl`/docker): mode
recommendation table incl. the ARMv6 ack, ACR arch notice firing rules, `pi_gh_url`
prefixing, download-verify ladder failure closure, swap/rollback with `.prev`, idempotent
crontab writing honoring `CRONTAB_FILE`, the systemctl crond-reload branch, external-ui fence
byte-identity, unit/mode-marker idempotence, and `INSTALL_SOURCE_ONLY=1` sourcing. Shellcheck
targets grow 12→15 (`install-pi.sh`, `scripts/pi/auto_update_lite.sh`,
`scripts/pi/lite_ctl.sh`) in `.woodpecker.yml` + the `docs/development.md`(+zh) mirrors.
`cli_contract_check` proves `spec.yaml`/`gateway.sh` stay untouched.

### Docs
Tri-mirror set: `docs/installation-pi.md` + `docs/zh/installation-pi.md` +
`docs/INSTALL-PI.txt` + `docs/INSTALL-PI.zh.txt` (auto-ship in the enduser bundle), plus
touch-points in README/README_ZH doc tables, `architecture.md`, `troubleshooting.md`
(ACR-not-mirrored, lite rollback, wlan0 macvlan, port-53 conflicts), `auto-update.md`
(lite updater), `installation.md` (path chooser). Low-RAM ops guidance (log2ram, zram,
journald `Storage=volatile`, `.mrs` rule-sets) is documentation, not installer automation.

## Decisions

Resolved interactively with the owner on 2026-07-09 (AskUserQuestion, one at a time):

| # | Decision | Answer |
|---|---|---|
| DEC-1 | Deploy model | **Both paths fully in v1**: compose parity (Pi 3/4/5) + bare-metal lite (512 MB tier) |
| DEC-2 | Placement | **Additive `install-pi.sh`** + `scripts/pi/`; DSM flow behaviorally untouched |
| DEC-3 | Pi registry default | **`acr` stays default** (China-first parity); early arch notice; external dep: docker-china-sync arm64 mirroring |
| DEC-4 | Lite artifact source | **`GH_MIRROR` prefix env** (empty = direct GitHub) + zh wizard suggestion + offline sideload docs |
| DEC-5 | ARMv6 stance | **Best-effort behind explicit warning ack** (≤30–40 Mbps, lab/single-device); compose = arm64/armv7 only |
| DEC-6 | Epic slug | **`raspberry-pi-port`** |

Owner clarification recorded during DEC-4: Pi 3B+ **can and should run Docker** — compose
mode with the existing updater is the recommended path there; bare-metal is never required
above the 512 MB tier.

Pre-decided defaults carried from the research (not re-decidable in tickets):
`docker-compose.yml` is reused unchanged (no second compose file — `compose_policy_check.py`
hardcodes the single path); dashboard = container (compose) / external-ui (lite); lite
updater ships in v1 with full health-gate + rollback parity; the Pi rides the same enduser
bundle (no new package profile) *(superseded by Re-scope 2026-07-12: dedicated
`--profile pi`)*; wired eth0 required for compose macvlan.

## Work breakdown

Seven tickets, TDD-ordered so each lands with its tests (Sequence 10–70):

1. **chore(shared): pi seams — crond systemctl branch + external-ui render fence** — every
   shared-file seam behind no-op defaults (`scheduler_reload_crond` systemctl branch;
   template/renderer EXTUI fence; `render_check.py` case; `.env.example` comments;
   `pi_installer_check.sh` seeded; CI wiring). Compose render proven byte-identical.
2. **feat(pi): install-pi.sh entry + hardware detect + compose-parity mode** —
   `scripts/pi/{detect,preflight,i18n_pi,flow_compose}.sh`; mode wizard by detected
   model/mem/arch; ACR arch notice (DEC-3); wlan0 refusal; ARMv6 ack (DEC-5); delegates
   deployment to the existing `flow_deploy` pipeline; writes the mode marker.
3. **feat(pi): lite runtime — download/verify, external-ui, systemd unit, render** —
   `scripts/pi/{lite,flow_lite}.sh`; `pi_gh_url` (DEC-4); fetch/verify ladder;
   `mihomo-gateway.service` render (minimal v1, `ExecStartPre` re-render); external-ui
   unpack; host-bind topology (no macvlan; the Pi's IP is the client gateway/DNS).
4. **feat(pi): lite binary auto-updater with rollback + cron wiring** —
   `scripts/pi/auto_update_lite.sh`; health-gated swap/rollback via `.prev`; last-run JSON;
   lock/kill-switch/dry-run parity; `pi_flow_cron` + lite crontab writer.
5. **feat(pi): lite_ctl status/doctor + scheduler coverage** — `scripts/pi/lite_ctl.sh`
   (`status|doctor|start|stop|update`); doctor exit semantics mirror `doctor.sh`;
   `scheduler_task_deployed` lite path covered; proves the CLI contract untouched.
6. **docs(pi): installation-pi tri-mirror + sizing matrix + touch-points** — the 4 new doc
   files + README/README_ZH rows + architecture/troubleshooting/auto-update/installation
   touch-points (en+zh); canonical hardware matrix lands here.
7. **chore(release): pi release verification + risk log closure** — enduser bundle proof
   (zip ships `install-pi.sh` + `scripts/pi/` + INSTALL-PI.txt pair, no `.md`); full local
   CI set green; hardware-risk evidence recorded back into this brief. *(superseded —
   re-scoped 2026-07-12: exclusion-proof + pi-bundle proof; see the Re-scope section.)*

## Risk log (verify early in the tickets)

- **G1** metacubexd image armv7 availability for compose on Pi 2/3 32-bit (probe in Seq 20;
  fallback: compose = arm64-only, armv7 → lite; matrix updated).
- **G2** mihomo release checksum asset presence per tag (Seq 30; verify ladder degrades
  gracefully by design).
- **G3** real mihomo RSS on 512 MB under load with `.mrs` tuning — not CI-able; hardware
  validation note (Seq 60/70).
- **G4** systemd hardening options on older ARM images — unit stays minimal in v1.
- **G5** `releases/latest` tag resolution through gh mirrors (Seq 40; fallback: pinned
  `MIHOMO_VERSION`).
- **G6** MetaCubexD gh-pages zip vs `compressed-dist.tgz` layout stability (Seq 30).
- **G7** port-53 conflicts with resolvers on Pi OS variants (lite doctor check + docs,
  Seq 50/60).

## Constraints carried into every ticket

- POSIX `/bin/sh` (BusyBox-compatible) only; no `set -e` in runtime scripts; explicit
  return-code checks; shellcheck + `sh -n` clean.
- No hardcoded proxy rules / DNS / network addresses in committed files (CLAUDE.md); the
  committed gh-proxy suggestion stays a generic placeholder pattern, mirror choice lives
  in `.env`.
- The DSM path is frozen: `install.sh`, `gateway.sh`, `doctor.sh`, `scripts/cli/spec.yaml`,
  and `docker-compose.yml` see zero behavioral change; `dsm_installer_check.sh` and
  `cli_contract_check.py` must pass unmodified.
- With `EXTERNAL_UI_DIR` unset, the rendered compose-mode config is byte-identical to
  pre-epic output.
- Verification gate per ticket: the relevant `scripts/ci/*_check` subset + shellcheck +
  render/compose/package/privacy checks — the full `.woodpecker.yml` step set locally
  before commit (docs/development.md "Local checks before pushing").

## Re-scope 2026-07-12 — dedicated pi bundle profile (`/brainstorm --issue 23`)

Trigger: `/issue-resolver` hard-stopped #23 (2026-07-11) on issue-vs-repo drift — commit
`d12eb7d` (v1.3.7 series) deliberately prunes the Pi port from the enduser bundle because
`scripts/pi/` carries functional GitHub URLs the identity leak gate forbids, while #23's
body (and this brief's "Pi ships in the same enduser zip" rows, now marked superseded)
demanded inclusion. `package_check.py` pins the exclusion in `ENDUSER_MUST_EXCLUDE`, so
the old acceptance criterion had become CI-contradictory.

Grounding facts that shaped the decisions:

- `GH_MIRROR` cannot make pi files gate-clean: `pi_gh_url` (`scripts/pi/lite.sh:22-24`)
  *prefixes* a still-literal `https://github.com/...` URL, so the `github` substring
  survives any mirror choice.
- `docs/INSTALL-PI.txt` + `docs/INSTALL-PI.zh.txt` are leak-clean (zero forbidden
  strings) — their enduser exclusion is policy, not necessity.
- `scripts/pi/i18n_pi.sh:32` mentions `docker-china-sync` — a genuine identity string
  that must not ship in ANY bundle.
- The AGENTS.md suite-count drift flagged in the hard-stop comment was already fixed
  (f8315d5, "nine BusyBox-sh suites") — no action needed.

Decisions (owner, one at a time, 2026-07-12):

| # | Decision | Answer |
|---|---|---|
| DEC-R1 | Pi bundle strategy | **Exclusion-proof #23 + a new dedicated `--profile pi` ticket** — matches package.sh's declared design; #23 stays a pure verification chore |
| DEC-R2 | Chain position | **Sequence 65, same epic, before #23** (`Next -> #23`) — the tail then verifies BOTH artifacts |
| DEC-R3 | Leak-gate posture | **Identity/forge split**: the identity set (the personal/infra identifiers `leak_scan` already enumerates at `scripts/package.sh:95-99` — kept pointed-at rather than copied here, and the deliberately concatenation-obfuscated private-site token stays obfuscated wherever the list moves — plus the email regex) stays forbidden in every gated profile; the forge set (github, gitlab, bitbucket, gitea, git@) stays forbidden in enduser but is allowed in pi; `i18n_pi.sh` hint reworded |
| DEC-R4 | Pi bundle content | **Superset of enduser**: `PI_EXCLUDES = ENDUSER_EXCLUDES` minus the four pi entries; no other divergence |
| DEC-R5 | INSTALL-PI txt pair | **Pi-bundle-only** — the DSM enduser zip stays a coherent DSM-only artifact |
| DEC-R6 | VERSION bump in #23 | **Dropped** — VERSION moves in the owner-driven `chore(release)` commit at ship time (v1.3.8 pattern, commit 33b1183) |
| DEC-R7 | Cross-flavor crontab residue (carried #20 -> #21 -> #22) | **Fixed in the Sequence-65 ticket** — the cron flow removes the other flavor's managed entry on an install-mode switch; the #18 `pi_sudo_rerun_hint` cosmetic nit rides along |

Defaults applied without a dedicated ask: #23's verification list re-synced to the
current 12-step local gate (it was missing `migrate_legacy_check`,
`seed_provider_check`, `validate_release.sh --self-test`, the `sh -n` loop, shellcheck,
and compose-config); risk outcomes to be recorded by #23 as G1/G2/G5/G6/G7
closed-with-evidence (#18/#19/#21 close comments), G4 "retired by design" (minimal v1
unit, no CI guard — the hardening deferral stays deliberate), G3 "open — needs hardware
validation"; txt-pair naming corrected to `docs/INSTALL-PI.zh.txt`.

Work breakdown delta (staged 2026-07-12):

- **#31 (Sequence 65, Next -> #23)** — `feat(release): dedicated pi bundle profile with
  split leak gate`: package.sh `pi` profile + `PI_EXCLUDES` + split `leak_scan`;
  package_check.py pi fixture + split FORBIDDEN sets + gate-fires/gate-passes proofs;
  `i18n_pi.sh` reword; DEC-R7 crontab cleanup + `pi_installer_check` case;
  `release-packaging.md` (en+zh) pi section.
- **#23 (Sequence 70, tail; re-scoped)** — release verification: both bundles proven by
  unpacking (enduser excludes / pi includes), ash source-checks from the unpacked trees,
  G1-G7 outcomes recorded back into this brief, full 12-step gate. The body edit was
  classifier-blocked, so the authoritative re-scoped body lives in the 2026-07-12 issue
  comment (comments override body per `/issue-resolver` precedence).

Risk-log note: outcomes are deliberately NOT recorded in this section — stamping G1-G7
with evidence is #23's job at drain time.
