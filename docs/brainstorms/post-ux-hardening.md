# Brainstorm brief — Post-UX hardening (the advisory tail of gateway-ux-automation)

Date: 2026-07-22 · Mode: greenfield (`/brainstorm`) · Epic: `post-ux-hardening`

## Idea

Close out the advisories the `gateway-ux-automation` gap panels recorded on #54–#57:
one real cross-cutting bug (`env_set` reports success on a failed rename), one
platform gap (the pi bare-metal *lite* flow never runs the pre-v2 `.env` backfill),
and a batch of small robustness/coverage items. All were adjudicated non-blocking in
their tickets and deferred here.

## Dimensions

### envedit write integrity
`env_set` (`scripts/installer/envedit.sh:48-56`) tests only awk's status; the
`mv && chmod` compound on line 54 is discarded by an unconditional `return 0`, and a
failed `mv` also orphans the temp file (cleanup only runs on the awk-failure path).
Call-site survey: 6 sites already check the rc (`gateway.sh` config verbs,
`linux/preflight_linux.sh:150-151`, `pi/preflight.sh:96`, `derive_images`) and become
genuinely fail-closed with an honest rc; ~60 sites ignore the rc either way; the two
#55-era functions (`_pc_backfill_pair`, `_wi_apply_dns_variant`) sidestep the bug with
local read-back and stay as belt-and-braces. `validate_release.sh` has its own honest
`env_set` — unaffected. Options: honest rc only | **self-verifying env_set (chosen)**:
honest rc PLUS an internal read-back compare of the decoded value after the rename,
temp cleanup on every failure path — the strongest guarantee at the single source,
making the write primitive itself prove the line landed.

### pi-lite platform gap
`pi_flow_lite` (`scripts/pi/flow_lite.sh:101-169`) never calls precheck: a pre-v2
`.env` passes straight to `pi_lite_render_config` (:122), which reads the pair as
empty (:86-87) and dead-ends at render. Full `precheck_env` is WRONG there (it
validates macvlan fields — `ROUTER_IP`/`SUBNET_CIDR`/`MIHOMO_IP` — that lite never
sets, `wizards.sh:543-564`). All of `_pc_backfill_pair`'s dependencies are already
sourced by `install-pi.sh` (envedit :54-55, network :48-49, ui :34-35, i18n :36-37, wizards :62-63).
The day-2 doctor (`lite_ctl.sh` `_lc_render_check` :74-97) is read-only by design; it
correctly detects the dead-end (BROKEN) but names no remediation. **Chosen:** call
`_pc_backfill_pair || return 1` + re-`load_env` in `pi_flow_lite` between the wizard
and the render (mirrors the compose precheck placement), and give the BROKEN verdict
a remediation hint (output-only — the read-only doctor contract holds).

### Robustness/coverage batch
(a) `_wi_auto_scan`'s "mixed" branch (`wizards.sh:286-291` — unfiltered verdict +
registry unreachable → menu, yet the DNS-variant swap still runs at :298) has no test;
(b) no end-to-end test drives `precheck_deploy → precheck_env → wizard_images →
_wi_auto_scan` on a blank-image `.env` (`wizards.sh:571-576` never exercised through
the precheck entry point); (c) `scan_registry_reachable`'s `SMG_SCAN_FORCE` case
(`lib/network.sh:164`) lacks the `unknown` arm its sibling handles; (d) the kept
`.pre-v2.bak`'s chmod 600 (`wizards.sh:509-510`) is never mode-asserted, and the
`_bf_both` snapshot (`wizards.sh:511-512,533`) permanently loses one-time
variant-upgrade eligibility when a true pre-v2 repair faults on the SECOND field and
is retried; (e) B3's streaming region-block heuristic is blind to SPA-rendered block
pages (`validate_release.sh:1240-1251`) — WARN-only by design. **Chosen:** fix a–d
(the retry corner via example-default-counts-as-eligible), leave (e) as-is with the
limitation named in its WARN text.

## Decisions

Resolved interactively with the owner on 2026-07-22 (AskUserQuestion, one at a time):

| # | Decision | Answer |
|---|---|---|
| DEC-A | env_set fix semantics | **Self-verifying env_set**: honest mv/chmod rc + internal read-back compare (decoded value) + temp cleanup on every failure path; the 6 rc-checking call sites become genuinely fail-closed; the ~60 rc-ignoring sites keep today's behavior; the local read-back patterns in `_pc_backfill_pair`/`_wi_apply_dns_variant` STAY (belt-and-braces, tested contracts) |
| DEC-B | pi-lite bypass | **Backfill + doctor hint**: `_pc_backfill_pair \|\| return 1` + `load_env` in `pi_flow_lite` before render; `lite_ctl.sh` BROKEN verdict gains a remediation hint naming the lite re-run (hint = output only) |
| DEC-C | Coverage scope | **All four + retry fix**: tests for the mixed branch, the precheck→scan chain, the kept-backup mode bit; the `SMG_SCAN_FORCE=unknown` arm added; retry-eligibility fixed by counting a field that already equals the example default toward `_bf_both`; B3 heuristic unchanged, limitation named in the WARN message |
| DEC-D | Epic | **`post-ux-hardening`**, 3 tickets, Sequence 10–30 |

Pre-decided defaults carried from research (not re-decidable in tickets):

- `env_set`'s read-back compares the DECODED round-trip (env_get semantics) against
  the original value — symmetry proven by the existing special-character round-trip
  test at the top of `dsm_installer_check.sh`.
- No new prompts anywhere (the parent epic's contract): the pi-lite fix is repair, not
  a wizard question.
- `pi_lite_render_config` gets no extra pre-guard (the render already fails naming the
  variable; the upstream backfill is the fix) — recorded as considered-and-skipped.
- POSIX/BusyBox sh; alpine:3.22 adjudication; red-first tests; no DNS/address literals
  in scripts (example-derived values only).

## Work breakdown

Three tickets, TDD-ordered (Sequence 10–30):

1. **fix(envedit): make env_set self-verifying** — honest rc, internal read-back,
   temp cleanup; red-first cases for lying-mv, chmod-fail, cleanup, and the unchanged
   success round-trip; existing suites prove the 6 fail-closed call sites.
2. **fix(pi): backfill the split-horizon pair in the lite flow** — `pi_flow_lite`
   insertion + `lite_ctl` BROKEN remediation hint; pi_installer_check cases (pre-v2
   fixture → lite deploy backfills; doctor hint text).
3. **test(hardening): close the recorded coverage gaps** — mixed-branch case,
   precheck→scan e2e on blank refs, `SMG_SCAN_FORCE=unknown` arm + case, kept-backup
   mode assert, `_bf_both` retry-eligibility fix + case, B3 WARN-text limitation note.

## Handoff

Staged as the `post-ux-hardening` work-order chain via `/stage-work-order`; drained by
`/issue-resolver` (or single tickets via `/resume-gap`). No NAS access needed until
these ride the next release round's staged validation.
