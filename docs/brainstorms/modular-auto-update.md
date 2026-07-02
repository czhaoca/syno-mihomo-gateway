# Brainstorm brief — Modular auto-update for all active containers

Date: 2026-07-02 · Mode: greenfield (`/brainstorm`) · Epic: `modular-auto-update`

## Idea

Generalize the ACR auto-refetch pipeline so **every enrolled active container** whose
image has a new digest in Alibaba ACR is updated in place and restarted — not just the
hardcoded mihomo / metacubexd / cloudflared trio — with a hard requirement that updates
**never break running services**: all existing container configuration and state must be
retained, every swap must be health-gated and rollback-able, and the whole thing must be
tested. Alongside: smoother user interaction (CLI + installer wizard) and DSM Task
Scheduler integration.

## What already exists (verified 2026-07-02)

The seed underestimates the current system. Verified building blocks:

| Asset | Where | Reuse |
|---|---|---|
| Generic capture→replay recreate engine | `scripts/lib/cloudflared.sh:109-242` (`_cloudflared_capture_spec` / `_run_saved` / `_restore_old`) | Extract into `lib/container.sh`; cloudflared becomes a thin specialization |
| Compose-vs-standalone classifier | `scripts/lib/lifecycle.sh:24-42` (`managed` / `ambiguous` / `absent` via compose labels) | Generalize into target classification; guardrail against hand-recreating compose members |
| Generic per-container change detection | `scripts/lib/registry.sh:259-267` (`deploy_needed` = running image ID vs pulled local ID) | Works for any container as-is |
| Restart-stability health logic | `scripts/lib/compose.sh:106-129` | Becomes the generic health-gate floor |
| Fake-docker test harness + orchestrator seam | `scripts/ci/auto_update_check.sh` (PATH-shim mock, `AUTO_UPDATE_SOURCE_ONLY=1`), `scripts/ci/cloudflared_check.sh` | Template for `generic_update_check.sh`; assert helpers to extract |
| Failure isolation / lock / kill-switch / arch guard / prune-on-success / exit codes | `scripts/auto_update.sh:95-205`, `lib/common.sh` | Unchanged infrastructure |
| Persistent state home | `GATEWAY_DATA_DIR` (`lib/common.sh:24`, chmod 700, survives releases) | Home for enrollment list + last-good records |

The thing to replace: the hardcoded `case "$img"` trio dispatch at
`scripts/auto_update.sh:98-133` and the two hardcoded apply branches at `:158-200`.

## Dimensions

### Updater architecture
Options weighed: (A) driver abstraction dispatched by container class; (B) declarative
targets table; (C) keep trio + one generic post-pass. **Chosen: A + B-lite** — two
drivers only: the existing compose driver (mihomo+metacubexd, byte-for-byte unchanged
behavior: single `compose up -d --pull never` + full health gate + re-tag rollback) and
a new generic recreate driver extracted from cloudflared. A small per-target record
(name|strategy|probe) selects driver options. The trio's bespoke safety paths are never
weakened; new risk is confined to opted-in standalone containers.

### Registry / mirroring
**No upstream→ACR name translation, ever.** The docker-china-sync flattening rule
(org prefix dropped) is ambiguous — guessing pulls wrong images. Only containers already
running a `$DOCKER_REGISTRY/$ACR_NAMESPACE/*` ref are candidates. A pull failure for an
enrolled ref is classified and reported as actionable: "add `<upstream>` to
docker-china-sync/images.txt". Keep pull-always + content-ID compare (no experimental
`docker manifest inspect` on DSM docker). ACR intra-region pulls are effectively free at
this scale. Credential hardening: document a dedicated pull-only ACR robot/sub-account
for the NAS, distinct from the sync push account (current `--password-stdin` handling is
already safe).

### Safety / state retention
The capture engine must be audited to full `docker inspect` surface before generic use.
Fields already captured: Env, Cmd, Entrypoint, Binds, named+anonymous volumes by
`.Name`, PortBindings, Networks + static IPs, Dns, ExtraHosts, CapAdd/Drop, SecurityOpt,
Devices, Tmpfs, RestartPolicy, User, WorkingDir, ReadonlyRootfs, Privileged.
**Must add**: Labels (re-stamped so DSM/classifier state survives), Sysctls, LogConfig,
StopSignal/StopTimeout, network Aliases, resource limits (Memory/NanoCpus/Ulimits/
ShmSize), Hostname/MacAddress, Ipc/Pid/UTS modes, Healthcheck overrides.
Anonymous-volume data is retained **only** by replaying `.Name` — a naive rm+run loses
it; this is the core state-retention mechanic. Hard refusals stay: `container:*`
netmode, `AutoRemove`. DSM Container Manager "stuck Project" cosmetic drift:
document-and-accept (matches existing guidance).

### UX / DSM Task Scheduler
DSM task creation stays **print-instructions** (`install_scheduler.sh`): programmatic
esynoscheduler-DB manipulation is unsupported and fragile across DSM 7.x. One scheduled
update task (the updater loops all targets internally) + the existing boot network task.
CLI surface grows via `scripts/cli/spec.yaml` only (CI-frozen contract, en+zh):
`update --list-targets / --enable <name> / --disable <name> / --last`; a last-run JSON
state file under `GATEWAY_DATA_DIR` is surfaced by `gateway.sh status` / `status
--json`. Installer gains a wizard step that scans running ACR-ref containers and toggles
per-container enrollment. Notification summary gains sections + counts
(updated / unchanged / failed / rolled-back).

### Testing
Three tiers, plain POSIX sh (no bats/shellspec — repo convention is a hand-rolled
assert vocabulary that runs under the same BusyBox it targets):
1. **Fake-docker unit + orchestrator tier (CI-blocking)** — new
   `scripts/ci/generic_update_check.sh` reusing the PATH-shim mock, extended with
   `docker ps` enumeration replay and per-container inspect fixtures; shared assert
   helpers extracted to `scripts/ci/lib/assert.sh`. TDD floor: written first, red-green.
2. **Real-docker integration tier (deferred decision)** — requires granting the
   Woodpecker runner a socket/dind (homelab security call, DEC-T1 in the test issue).
   Until granted, tier 3 covers real-daemon fidelity.
3. **On-NAS acceptance** — `--dry-run` smoke + canary update of one non-critical
   container, gated by a before/after `docker inspect` field-set diff script (equality
   on everything except `Image` and `RestartCount`). The diff field set = the capture
   contract, making "state retained" a mechanical assertion.

## Decisions

All auto-resolved to the researched recommendation on 2026-07-02 (owner AFK during the
clarify phase — each is override-able via `/brainstorm --issue N` before its ticket
starts):

- **DEC-1 Enrollment**: managed list file `GATEWAY_DATA_DIR/state/update-targets`
  (records `name|strategy|probe`), edited via CLI/wizard; a container must **also**
  already run an ACR ref. Rejected: pure label opt-in (labels can't be added to an
  existing container without recreating it), auto-all-ACR (sweeps unintended stateful
  containers), .env list (loosens the exact-3 contract in `registry.sh`).
- **DEC-2 Generic health gate**: ladder — (1) running, (2) stable `RestartCount`
  (reuse `compose.sh:106-129`), (3) native `State.Health` must reach `healthy` when the
  image defines a healthcheck, (4) optional per-target probe (`docker exec` cmd or
  log-regex marker) from the target record; floor-only targets log a WARN. Probes must
  run in-netns (`docker exec`) — macvlan self-reach makes host-side probes impossible.
- **DEC-3 Strategy**: in-place stop→recreate with saved-spec + saved-old-image-ID
  auto-restore on gate failure (cloudflared `_restore_old` model). True blue-green stays
  cloudflared-only (generic containers owning host ports / static IPs can't run a
  colliding candidate).
- **DEC-4 Spec parity**: **fail-closed** — if an enrolled container has a non-default
  `HostConfig`/`Config` field the capture engine doesn't carry, refuse to update it and
  report which field; never silently degrade a container's config.
- **DEC-5 Ordering**: strictly serial; generic targets → cloudflared → gateway compose
  pair **last**. Verify during implementation that NAS egress does not route via
  `MIHOMO_IP` (if it does, ordering is load-bearing for the updater's own pulls).
- **DEC-6 CI real-docker tier**: deferred (DEC-T1 in the testing ticket) — owner call
  on Woodpecker runner privilege.
- **DEC-7 CLI shape**: sub-flags on the existing `update` verb + `status` surfacing;
  no new top-level verb; all via `spec.yaml` + `cli_contract_check.py --write`.
- **DEC-8 Denylist**: hard refusals regardless of enrollment — `container:*` netmode,
  `AutoRemove`, `ambiguous` compose classification, Container Manager's own infra;
  databases warn loudly at enroll time (no generic quiesce exists).
- **DEC-9 Epic slug**: `modular-auto-update`.

## Work breakdown

Seven tickets, TDD-ordered so each lands with its tests (Sequence 10–70):

1. **refactor(ci): extract shared sh assert lib** — `scripts/ci/lib/assert.sh` from the
   inline helpers in `auto_update_check.sh`; existing suites source it. Pure enabler.
2. **feat(lib): generic container spec capture/replay engine** — `lib/container.sh`
   extracted from `cloudflared.sh`, expanded inspect surface (DEC-4 field audit),
   fail-closed guard, `cloudflared.sh` re-based on it as a thin specialization.
3. **feat(lib): target enrollment + discovery** — `lib/targets.sh`: managed list file,
   ACR-ref gate, classifier generalization (from `lifecycle.sh`), denylist refusals
   (DEC-1, DEC-8).
4. **feat(update): generic driver dispatch in auto_update.sh** — trio `case` becomes
   discover→classify→bucket loop; apply becomes serial dispatch (generic → cloudflared
   → compose last, DEC-5); tiered health gate (DEC-2); in-place recreate + saved-spec
   rollback (DEC-3); last-good persistence in `GATEWAY_DATA_DIR/state/last-good/`;
   sectioned notification summary.
5. **feat(cli): update target-management + last-run surface** — `spec.yaml` additions
   (`--list-targets/--enable/--disable/--last`), last-run JSON state file, `status`
   integration, contract regeneration (DEC-7).
6. **feat(installer): enrollment wizard step** — scan running ACR-ref containers,
   per-container opt-in toggle writing the managed list; `flow_cron.sh` integration;
   en+zh i18n.
7. **test+docs(acceptance): on-NAS acceptance runbook + state-diff script** —
   before/after inspect field-set diff tool, dry-run smoke, canary procedure; DEC-T1
   (Woodpecker docker socket) resolved here; docs updates (`auto-update.md` en+zh,
   `configuration.md`, `.env.example`).

## Constraints carried into every ticket

- POSIX `/bin/sh` (DSM BusyBox) only; no `set -e`; explicit return-code checks.
- No hardcoded proxy rules / DNS / network addresses in committed files (CLAUDE.md).
- mihomo + metacubexd compose path behavior is frozen — regressions there take the LAN down.
- Never hand-recreate a compose-managed or ambiguous container.
- Verification gate: `sh scripts/ci/*_check.sh` suites + shellcheck + compose/render
  checks (the `.woodpecker.yml` step set), locally before commit.
