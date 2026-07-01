# Brainstorm brief — gateway-cli-api

Date: 2026-07-01 · Mode: greenfield (`/brainstorm`) · Epic: `gateway-cli-api`

## Idea

The interactive installer works, but its technical logic is only reachable
through TTY menus. Restructure it into an **API-style, modular command
surface** (`gateway.sh <verb>`) callable non-interactively by other
procedures (DSM Task Scheduler, scripts, future CI), with the interactive
installer becoming a thin UX layer over the same functions. On top of that:
make the interactive CLI a proper **closing loop** (every flow ends in a
known, visible state), document `--help` as maintained markdown, ship an
**OpenAPI-style machine-readable CLI contract** for maintainers, align the
auto-update story with current DSM documentation, and settle the packaging
question (DSM Container Manager Project vs. building our own image).

## Dimensions

- **backend / CLI surface** — `scripts/lib/*.sh` is already a UI-free,
  exit-code-driven API layer; `auto_update.sh` is the working headless
  prototype. Coupling is localized: `wizards.sh` fuses prompt+compute+persist,
  `preprocess.sh` uses menus as its only control flow, `flow_redeploy/modify`
  dispatch on menu index. Options weighed: (A) `gateway.sh` dispatcher over
  the libs, (B) NON_INTERACTIVE shim inside `ui.sh`, (C) parallel
  `scripts/api/` tree. **Chosen: A** — most reuse, honors the repo's
  "no TTY code in headless paths" invariant; B violates it, C doubles files
  for marginal gain.
- **cli-ux / closing loop** — audit found two broken loops: (1) deploy
  failure *after* pre-deployment cleanup silently leaves the user with no
  gateway (`flow_deploy.sh` teardown-then-fail); (2) `flow_cron` prints
  success when "Done" is chosen with no scheduler installed
  (`UPDATE_ENABLED=true`, nothing scheduled). Plus: no state visibility from
  the menu, `doctor.sh` unreachable from the loop, ~20–25 prompts on first
  deploy, rollback strings bypass i18n, empty `CONTROLLER_SECRET` accepted
  silently. Packages P1 (fixes only) / P2 (+state banner, Status item) /
  P3 (+express deploy, verification table, secret guard). **Chosen: P3.**
- **docs / CLI contract** — options: spec-first YAML manifest, help-first
  scraping, third-party spec formats. **Chosen: spec-first** — mirrors the
  repo's render_check.py template pattern; POSIX runtime can't consume a
  spec, so generation happens at dev time and artifacts are committed
  (the end-user zip is `git archive` of tracked files).
- **infra & deploy / DSM** — Container Manager (DSM 7.2+) Projects cannot
  create macvlan networks, can't manage privileged capabilities from the UI,
  bundle an older/stricter compose, and their update flow (stop → Build,
  `:latest`-only badges) has no health-gate or rollback; CLI-created stacks
  don't appear as Projects. `synodsmnotify` requires package-registered i18n
  strings on DSM 7 (effectively broken for plain scripts). **Chosen:
  SSH-installer-first**, with explicit docs telling users not to manage the
  stack from the Project tab.
- **ci-cd / packaging** — building our own image would double the
  China-mirror supply chain (upstream → build → ACR), make us the CVE-rebase
  bottleneck, and the hard parts (privileged, TUN, macvlan, sysctls) live in
  compose regardless. The compose entrypoint + CI-tested renderer + NAS
  health-gate/rollback already deliver the own-image benefits. **Chosen:
  status quo hardened — no own image, no sidecar.**
- **testing** — keep behavioral verb tests in the bespoke POSIX-sh idiom
  under the alpine CI step (true BusyBox fidelity; PATH-prepended stub dir
  since function overrides don't cross the subprocess boundary; `DOCKER_BIN`
  still honored); the contract layer (help==spec, exit codes, `--json`
  schema) lives in the Python check. No bats (bash-not-ash, new dep).
- **security & observability** — no secret ever transits argv today
  (`--password-stdin`, tokens via workdir env files); preserve that.
  Generalize `auto_update.sh`'s primitives (lock, dry-run, kill-switch,
  fail-closed arg parsing) per verb; fix stdout contamination (`log()` tees
  to stdout) before any `--json`.

## Decisions

| # | Decision | Answer |
|---|----------|--------|
| DEC-1 | Packaging | Status quo hardened: keep consuming upstream images via ACR mirror; no own image, no sidecar image |
| DEC-2 | DSM positioning | SSH-installer-first; document "containers visible in Container Manager, but never manage/Build via the Project tab"; DSM 7.2+ documented minimum, 7.3.1+ recommended |
| DEC-3 | CLI architecture | New `scripts/gateway.sh <verb>` dispatcher sourcing `scripts/lib/*.sh` only (never `ui.sh`); extract compute-only halves of `wizards.sh`/`preprocess.sh` (e.g. `resolve_mihomo_ip`, `resolve_images`, cleanup-mode flag) shared by wizard and CLI; `install.sh` interactive path preserved |
| DEC-4 | Verbs | `deploy`, `redeploy`, `cron`, `modify` (`--network/--images/--subscription`), read-only `status`, `doctor`; `update` verb simply execs `auto_update.sh` |
| DEC-5 | Exit codes | Reuse existing table (0 ok, 2 partial, 3 config, 4 locked, 5 login) verbatim; extend 6=needs-root, 7=needs-confirmation; never repurpose |
| DEC-6 | --json | Read-only verbs (`status`, `doctor`) first; single JSON object on stdout, all logs to file/stderr, never interleaved |
| DEC-7 | Guardrails & logging | Full audit package: `--yes` required for mutating verbs when non-TTY; `--dry-run` supported on every mutating verb; secrets hard-rejected on argv (must come from `.env`); per-verb root gate (read-only verbs unprivileged); unified `logs/gateway.log` with `verb=`/run-id fields (old log names symlinked one release); `notify()` on every non-zero mutating exit |
| DEC-8 | CLI contract | `scripts/cli/spec.yaml` (verbs, flags, env vars, exit codes, outputs, `{en, zh}` strings) → single dual-mode `scripts/ci/cli_contract_check.py --write` regenerates committed artifacts: runtime `scripts/lib/help.sh`, `docs/cli.md`, `docs/zh/cli.md`, `docs/CLI.txt`, `docs/CLI.zh.txt`; bare mode = CI freshness gate; `package_check.py` extended to assert CLI.txt ships and help.sh survives pruning |
| DEC-9 | Help language | Runtime `--help` English-only; Chinese via generated `docs/zh/cli.md` + `CLI.zh.txt` |
| DEC-10 | UX scope | P3: both loop fixes + i18n rollback strings + Ctrl-C notice + state banner above menu + Status/Diagnose menu item (wraps `stack_state`/`health_gate`/`doctor.sh`) + express deploy (one confirmation screen of detected/saved values) + post-deploy verification table |
| DEC-11 | CONTROLLER_SECRET | Auto-generate a random secret when left empty (stored in `.env`, shown in post-deploy summary), explicit opt-out to stay unauthenticated |
| DEC-12 | Notifications | DSM Task Scheduler "send run details by email" (driven by non-zero exits) becomes the documented default; webhook stays the opt-in rich channel; `synodsmnotify` demoted to best-effort (broken for plain scripts on DSM 7) |
| DEC-13 | auto_update.sh | Untouched — it stays the standalone scheduled entry point; no rebase onto gateway.sh |
| DEC-14 | Update trigger extras | No `repository_dispatch` future-proofing in docker-china-sync, no diun-style notifier, keep `:latest` float (the health-gate is the pin) |

Pre-decided defaults (recorded without a full ask — conventional, low
stakes): YAML over JSON for the spec; only `CLI.txt` regenerates from the
spec (prose guides stay hand-written); one `gateway_cli_check.sh` with
per-verb sections, split past ~400 lines; hand-rolled `--json` structural
validation (no jsonschema dep); teardown-then-fail handled message-only now
(auto-restore deferred); no CI re-test against Container Manager's bundled
compose version.

## Work breakdown

| Seq | Item | Summary |
|-----|------|---------|
| 10 | `refactor(installer): extract compute-only config resolution` | Split prompt/compute fusion in `wizards.sh` + `preprocess.sh` into UI-free functions; installer behavior unchanged |
| 20 | `feat(cli): gateway.sh verb dispatcher with guardrails + unified log` | DEC-3/4/5/6/7/13; behavioral sh test harness included |
| 30 | `feat(contract): machine-readable CLI spec + generated help/docs + CI gate` | DEC-8/9; freshness gate + package_check extension |
| 40 | `fix(ux): close the broken installer loops` | Teardown-then-fail notice, cron false-success warning, i18n rollback strings, Ctrl-C notice |
| 50 | `feat(ux): state banner + Status/Diagnose menu item` | Menu shows stack state/IP/dashboard URL; new menu item wraps status/doctor |
| 60 | `feat(ux): express deploy + post-deploy verification + secret guard` | One-screen confirm of detected values; verification table; DEC-11 |
| 70 | `fix(notify): DSM-7-correct notification path` | DEC-12; docs updated |
| 80 | `docs(dsm): DSM positioning, Container Manager caution, min version` | DEC-2; auto-update docs refreshed against current DSM docs |
