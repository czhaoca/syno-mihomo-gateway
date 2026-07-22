# Brainstorm brief — Advisory closeout (post-ux-hardening tail)

Date: 2026-07-22 · Mode: greenfield (`/brainstorm`) · Epic: `advisory-closeout`

## Idea

Close out the three advisories recorded in the `post-ux-hardening` close evidence
(#59/#60/#61): user-facing docs the code changes falsified, a latent shell-semantics
hazard that needed a disposition rather than a fix, and one weak test assert.

## Dimensions

### Hazard disposition (from #59)
With `env_set`'s now-honest rc, a genuinely failing write inside a `$(fn)` capture
under `set -eu` truncates rc-ignoring caller functions mid-flight. Grounding: no
production entrypoint (`install.sh`, `install-pi.sh`, `install-linux.sh`) ever sets
`-e`; the CI suites' live capture shapes are stub-neutralized (the only real
env-writer under `$(pi_flow_lite)` captures is the `|| :`-guarded backfill); ~23 bare
`env_set` calls sit transitively under 8 dsm-suite capture sites. Options: brief-only
record | **document the contract at the source (chosen)** | sweep the capture-reachable
sites with `|| :` guards (rejected: exactly the ~60-site sweep #59 scoped out, and it
re-masks the failures the honest rc exposes).

### Docs refresh (from #60 + #61)
The "Upgrading a pre-v1.3.8 install" troubleshooting section (EN :252-263, ZH
:224-233) has three gaps: the "both lists missing" eligibility sentence is now wrong
(#61 relaxed it to missing-OR-still-example-default per field); the lite-flow
self-heal (#60) is unmentioned; the lite doctor's remediation hint is unmentioned —
DSM Redeploy is presented as the only fix. Options: minimal one-sentence correction |
**full section refresh EN+ZH (chosen)** — one section carries all three gaps, and the
file already has platform-specific callout precedent (the "Pi lite:" sections).
Heading text/anchors stay unchanged.

### Test strength (from #60)
`pi_installer_check.sh:923` matches any `backfill_wrote` token; the dsm suite asserts
each key separately (`:1331-1332`). The stubbed output is exactly two lines (one per
`ui_ok`), so the per-key split is mechanical. **Chosen:** mirror the dsm shape,
mutation-proven (temporarily drop one emit, watch it fail, restore).

## Decisions

Resolved interactively with the owner on 2026-07-22 (AskUserQuestion, one at a time):

| # | Decision | Answer |
|---|---|---|
| DEC-A | set-e hazard disposition | **Document the contract**: 3-4 lines in `env_set`'s header — honest rc under active `set -e` stops a caller on a failed write; guard with `\|\| :` only where masking is intended. No guard sweep, zero behavior change |
| DEC-B | Docs refresh scope | **Full section refresh** EN+ZH: correct the eligibility sentence, add the lite self-heal path (re-run the lite deploy; the day-2 doctor names it) alongside DSM Redeploy; headings/anchors unchanged |
| DEC-C | Ticket shape | **Single ticket** carrying all three items (each is minutes of work; per-ticket resolver overhead dominates) |
| DEC-D | Epic | **`advisory-closeout`**, 1 ticket, Sequence 10 |

Pre-decided defaults carried from grounding (not re-decidable in the ticket):

- No behavior change anywhere in this ticket — docs, one comment block, test asserts
  only.
- Docs may name the lite entrypoints explicitly (`install-pi.sh` / `install-linux.sh`);
  the entrypoint-neutrality rule from #60 binds shared *output* strings, not docs.
- en+zh parity; red-first (mutation-proof) for the assert change; alpine:3.22
  adjudication.

## Work breakdown

One ticket (Sequence 10):

1. **chore(followup): close out the post-ux-hardening advisories** — per-key
   `backfill_wrote` asserts in the pi suite (dsm shape, mutation-proven); full
   pre-v1.3.8 troubleshooting section refresh EN+ZH; `env_set` header gains the
   set-e caller contract.

## Handoff

Staged as the `advisory-closeout` work-order chain via `/stage-work-order`; drained by
`/issue-resolver` (or `/resume-gap 62`). No NAS access needed; rides the next release
round's staged validation like any docs/test change.
