# Development & Internals

[← README](../README.md) · [中文](zh/development.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · [Operations](operations.md) · [CLI](cli.md) · [Troubleshooting](troubleshooting.md) · **Development**

---

For contributors and anyone extending the gateway.

## Repository layout

```
docker-compose.yml            # mihomo (macvlan, privileged) + metacubexd (bridge)
.env.example                  # documented config contract (live .env: ../syno-mihomo-gateway-data/.env)
VERSION                       # release version (stamped into the package.sh artifact name)
bootstrap.sh                  # offline-install first-run helper (seeds .env, restores exec bits)
install.sh                    # interactive installer (menu: Deploy/Redeploy/Cron/Modify/Status)
config/
  config.template.yaml        # mihomo config with {{PLACEHOLDERS}}
  subscription.txt.example    # subscription template (live copy: ../syno-mihomo-gateway-data/config/)
scripts/
  gateway.sh                  # non-interactive CLI: deploy/redeploy/modify/cron/status/doctor/update
  setup_network.sh            # headless boot self-heal: /dev/net/tun + tproxy_network macvlan
  render_config.sh            # renders config.yaml from the template (entrypoint + CI both call it)
  auto_update.sh              # the DSM auto-update orchestrator (entry point)
  doctor.sh                   # read-only diagnostics (also backs `gateway.sh doctor`)
  state_diff.sh               # snapshot/compare a container's replayable spec around an update
  install_scheduler.sh        # prints DSM Task Scheduler / crontab settings
  package.sh                  # build-host: builds the offline release zips (docs/release-packaging.md)
  cli/
    spec.yaml                 # CLI contract source of truth (see "The CLI contract" below)
  installer/                  # TTY modules sourced by install.sh
    ui.sh / i18n.sh           # prompt + menu primitives; EN/中文 strings (INSTALLER_LANG)
    preflight.sh / netscan.sh # docker-share location gate; interface scan + IP suggestion
    wizards.sh / envedit.sh   # per-key prompts; dotenv-safe .env editing
    preprocess.sh             # per-resource cleanup menus; the decision policy lives in lib/resolve.sh
    flow_*.sh                 # menu-item flows: deploy, redeploy, modify, cron, targets
  lib/
    common.sh                 # env load, logging+rotation, mkdir lock, exit codes
    registry.sh               # preflight (compose/arch/network/tun), ACR login, pull + change detect, TUN redirect probe
    compose.sh                # compose up, health gate, rollback
    container.sh              # generic container spec capture/replay engine + parity guard
    targets.sh                # generic-target enrollment + DEC-1 eligibility (state/update-targets)
    cloudflared.sh            # blue-green reprovision of the external cloudflared
    lifecycle.sh              # deployment inventory + verified scoped teardown
    network.sh                # macvlan/IP planning: interface detect/scan, IP-in-use probe, OVS warning
    notify.sh                 # notifications: webhook + best-effort Synology DSM push
    resolve.sh                # UI-free config resolution: IP suggestion, image refs, subscription URL, cleanup-plan policy
    scheduler.sh              # safe DSM/BusyBox cron parsing and task commands
    help.sh                   # GENERATED from cli/spec.yaml - never hand-edit
  ci/
    render_check.py           # CI: runs the real renderer + structural/rule assertions
    cli_contract_check.py     # CI: spec.yaml vs committed artifacts byte-diff (--write regenerates)
    compose_policy_check.py   # CI: fail-closed image refs + REGISTRY_MODE=acr default
    package_check.py          # CI: builds both bundles in throwaway repos, proves no secret ships
    privacy_check.py          # tracked-content/history privacy gate (+ privacy_check_test.py)
    auto_update_check.sh      # fake-Docker TDD suite for scheduler/update/rollback paths
    cloudflared_check.sh      # fake-Docker TDD suite for blue-green behavior
    generic_update_check.sh   # fake-Docker suite for the generic capture/replay engine
    gateway_cli_check.sh      # PATH-stub suite for the gateway.sh CLI contract
    dsm_installer_check.sh    # fake-Docker suite for the installer flows
    lifecycle_check.sh        # fake-Docker inventory/cleanup safety suite
    lib/assert.sh             # shared assertions for the sh suites
.woodpecker.yml               # CI: 9 blocking steps (see the CI table below)
docs/                         # manual (EN) + docs/zh mirrors (中文) + docs/*.txt enduser guides
```

`install.sh` is the interactive TTY front-end (and the enduser-bundle entry point,
`sh ./install.sh`); `scripts/gateway.sh` is the non-interactive verb surface documented in
[CLI](cli.md). Both drive the same `scripts/lib/` functions.

## Coding rules

- **POSIX `/bin/sh`, BusyBox-safe.** DSM ships BusyBox; no bashisms or associative arrays,
  including in `scripts/setup_network.sh` and the unattended task entry points.
- **No `set -e`/`set -u` in the orchestrator.** It checks return codes explicitly so one soft
  failure never tears down the gateway by surprise. `render_config.sh` *does* use `set -eu` (it's
  a short, fail-fast renderer).
- **No hardcoded DNS / network addresses** in committed files (project rule). Use
  `{{PLACEHOLDERS}}` + `.env`. CI enforces this (`render_check.py`).
- **Secrets only in gitignored `.env`** (`ACR_PASSWORD`, `CF_TUNNEL_TOKEN`, `CONTROLLER_SECRET`).
- **Image refs are fail-closed, never hardcoded.** Every compose `image:` must be exactly
  `${VAR}` / `${VAR:?msg}` — no `:-`/`:=` defaults, no literal refs. The source is selected by
  `REGISTRY_MODE` (`acr` default, `docker` upstream as an explicit opt-in); CI's `compose-policy`
  step enforces both.
- **Private operations data is rejected.** `privacy_check.py` scans tracked content and reachable
  blobs while allowing public project links and Shenzhen ACR examples.
- **ASCII only in shell scripts** — non-ASCII (e.g. em-dashes) breaks shellcheck's output
  encoding in the CI image.

## The renderer (`render_config.sh`)

Single source of truth for turning the template into `config.yaml`, called by **both** the mihomo
entrypoint (`sh /scripts/render_config.sh && exec /mihomo`, via the `./scripts:/scripts:ro` mount)
and CI. Honors `MIHOMO_CONFIG_DIR` (default `/root/.config/mihomo`) so tests can point it at a
temp dir. Key correctness points:

- **Subscription parse:** strips an optional leading `label=` and trailing whitespace,
  *preserving* `=` inside the URL — `sed -e 's/^[A-Za-z0-9_.-]*=//' -e 's/[[:space:]]*$//'`.
  (A bare URL has no `name=` prefix because `https` is followed by `:`, not `=`.)
- **`sed` escaping:** an `esc()` helper escapes `&`, `|`, `\` in every substituted value before
  injection (otherwise `&` in a URL would mean "the matched text" and corrupt the output).
- **Fail-loud:** empty subscription URL or any empty `DNS_*` ⇒ non-zero exit, no output file.

## The orchestrator run sequence

`auto_update.sh` sources the libs and runs: **lock → validate kill-switch → kill-switch → validate
config → wait for Docker + preflight → pull/inspect/detect (compose pair, cloudflared, enrolled
generic targets) → dry-run short-circuit → TUN auto-redirect probe (real runs only; can veto the
compose apply) → apply strictly serially, lowest blast radius first (DEC-5): generic targets →
cloudflared blue-green → the compose gateway pair LAST (+health-gate/rollback at each stage) →
prune → notify**. Every terminal path writes `state/last-run.json` via the EXIT trap
(`ts`/`exit_code`/`dry_run`/counters + `*_names` lists); INT/TERM terminate cleanly (exit
130/143). A dry run stays read-only — it only *notes* that the probe would gate the real apply.
Full detail in [Auto-Update](auto-update.md#the-run-sequence). Key library functions:

| File | Functions |
|---|---|
| `lib/common.sh` | `load_env`, `log*`, `rotate_log`, `acquire_lock`/`release_lock` (guarded by `LOCK_HELD`), `EXIT_*` codes |
| `lib/registry.sh` | `validate_update_switch`/`validate_update_config`, `wait_for_docker_ready`, `check_arch_expectation`/`arch_ok`, `check_network`, `check_tun`, `acr_login`, `pull_image`, `deploy_needed`, `mihomo_auto_redirect_probe` |
| `lib/compose.sh` | `compose_config_check`, `compose_up_local`, `health_gate` (+ `mihomo_controller_probe`), `rollback_compose` |
| `lib/container.sh` | `container_capture_spec`, `container_run_saved`, `container_restore_old`, `container_parity_guard` (fail-closed on unreplayable settings), workdir management |
| `lib/targets.sh` | `targets_validate`, `target_enroll`/`target_remove` (serialized via their own lock), `targets_discover` (the DEC-1 eligibility filter), `targets_image_databaselike` |
| `lib/cloudflared.sh` | `cloudflared_blue_green`, `cloudflared_wait_connected`, secure spec capture/replay, rollback, candidate/workdir cleanup |
| `lib/lifecycle.sh` | `lifecycle_inspect`, verified container/network removal, manual command rendering |
| `lib/network.sh` | `ensure_tun_device`, `detect_parent_interface`/`scan_interfaces`, `ip_in_use`, `validate_network_plan`, `recreate_macvlan`, `iface_is_ovs`/`warn_if_ovs_parent` (shared by `setup_network.sh` and the installer) |
| `lib/notify.sh` | `notify` — independent channels: opt-in webhook (config via curl stdin, never argv) + best-effort `synodsmnotify` |
| `lib/resolve.sh` | `resolve_mihomo_ip`, `resolve_images`/`resolve_update_images`, `resolve_subscription_url`/`subscription_current`, `resolve_cleanup_plan` (UI-free; the wizards render its results) |
| `lib/scheduler.sh` | `cron_normalize`, `scheduler_update_command`, `scheduler_network_command`, `scheduler_reload_crond` |

Concurrency: only the lock holder releases the lock (`LOCK_HELD`); a stale lock is reclaimed only
after `kill -0` proves the recorded pid dead (a pid-less lock gets a 2-second grace); the EXIT
trap won't reap a cloudflared candidate when it may be the only connected tunnel
(`CF_KEEP_CANDIDATE`).

## CI (`.woodpecker.yml`)

Runs on push/PR to `main` and `master`:

| Step | What |
|---|---|
| `validate-compose` | Compose **v2** (`apk add docker-cli-compose`, then `docker compose --env-file .env.example config --quiet`) — the frozen v1 `docker/compose` image cannot parse the fail-closed `${VAR:?}` image refs |
| `validate-yaml` | `yaml.safe_load(docker-compose.yml)` |
| `render-config` | `python scripts/ci/render_check.py` — runs the **real** renderer against a fixture URL with a `Name=` prefix + `&` params and asserts the URL round-trips exactly; also enforces the no-hardcoded-DNS rule |
| `cli-contract` | `python scripts/ci/cli_contract_check.py` — byte-diffs the committed `help.sh`/`cli.md` (en+zh)/`CLI.txt` (en+zh) against a fresh regeneration from `scripts/cli/spec.yaml`, and asserts the spec's exit codes match `common.sh`, its verb set matches `gateway.sh`'s dispatch, and `gateway.sh --help` serves the spec text verbatim |
| `compose-policy` | `python scripts/ci/compose_policy_check.py` — asserts **fail-closed** image refs: every compose `image:` is exactly `${VAR}`/`${VAR:?msg}` (no defaults, no hardcoded refs) and `.env.example` defines the image vars and ships `REGISTRY_MODE=acr` (ACR default; `docker` upstream is an explicit opt-in, not forbidden) |
| `package-check` | `python scripts/ci/package_check.py` — builds **both** the dev and enduser bundles in throwaway repos and proves **no secret can ship** (planted `.env`/subscription/`config.yaml` absent from both archives' names *and* bytes), checksums verify, the enduser bundle prunes developer/`.md`/CI files, ships the installer + `.txt` guides, contains no identity string, and its leak-gate fails closed on an injected leak |
| `privacy-check` | Scans tracked files and reachable blobs for private operational identifiers, credentials, private keys, and accidentally tracked runtime files (+ the gate's self-test) |
| `dsm-shell-tests` | Seven BusyBox `sh` suites with fake Docker/Compose/service CLIs: `dsm_installer_check`, `lifecycle_check`, `auto_update_check`, `cloudflared_check`, `generic_update_check`, `gateway_cli_check`, `pi_installer_check` (the Raspberry Pi port's shared seams) |
| `shellcheck` | `sh -n` parse-checks **every** `*.sh` in the repo, then `shellcheck -x` on 15 targets: `install.sh`, `install-pi.sh`, `gateway.sh`, `auto_update.sh`, `pi/auto_update_lite.sh`, `pi/lite_ctl.sh`, `install_scheduler.sh`, `setup_network.sh`, `render_config.sh`, `package.sh`, `doctor.sh`, `state_diff.sh`, `bootstrap.sh`, `lib/container.sh`, `lib/targets.sh` (sourced libs followed in-context) |

## The CLI contract (generated files)

`scripts/cli/spec.yaml` is the **single source of truth** for `gateway.sh`'s command surface
(verbs, options, guardrails, exit codes, outputs — English and Chinese). Five committed artifacts
are GENERATED from it and must **never be hand-edited**:

- `scripts/lib/help.sh` — the runtime `--help` heredocs `gateway.sh` sources
- `docs/cli.md` / `docs/zh/cli.md` — the CLI reference (EN / 中文)
- `docs/CLI.txt` / `docs/CLI.zh.txt` — the plain-text guides shipped in the enduser bundle

Regenerate with `python3 scripts/ci/cli_contract_check.py --write` — the only sanctioned way to
change them. The artifacts are committed rather than CI-built because the release is a
`git archive` of tracked files: the NAS only ever sees the pre-generated `help.sh`/`CLI.txt`.
CI's bare `cli-contract` step (table above) fails on any drift.

## Cutting a release

Maintainers produce the offline bundle consumed in [Release Zip](release-packaging.md):

```bash
sh scripts/package.sh                         # curated DSM end-user bundle (default)
sh scripts/package.sh --profile dev           # full internal/developer bundle
sh scripts/package.sh --version 1.2.12         # override the VERSION file
```

- Built with `git archive`, so **only tracked files** ship — `.env`, `config/subscription.txt`,
  `config/config.yaml`, `logs/`, and `.git/` can never leak in. `.env.example` and
  `config/subscription.txt.example` ship as templates.
- Version comes from the `VERSION` file (then `git describe`); output lands in the gitignored
  `dist/`. Run from a **clean checkout** — it refuses a dirty tree unless `--allow-dirty`.
- Source-only: container images are not bundled. They reach the NAS via the `docker-china-sync`
  ACR mirror (see [Relationship to docker-china-sync](#relationship-to-docker-china-sync)).
- Safeguards: `package.sh` refuses to build if a secret path is tracked, and CI's `package-check`
  (`scripts/ci/package_check.py`) proves the archive ships no secret on every push.
- The default (enduser) profile prunes developer/CI files via the `ENDUSER_EXCLUDES` pathspec in
  `package.sh` (README.md, AGENTS.md, `docs/*.md`, `docs/zh`, `scripts/ci`, `scripts/cli`, …) and
  ships the `.txt` guides + `install.sh`; a `leak_scan` identity gate greps the staged tree for
  forbidden strings and **fails closed**. When adding tracked files, check both lists in
  `scripts/package.sh`.

## Agent-assisted deploys need a temporary sudo grant

The NAS deployment is a bundle install owned by a **non-root admin account**; the privileged
steps of a deploy or acceptance run (docker commands, swapping the release tree, creating DSM
Task Scheduler entries, `doctor.sh`) all need root. When an automation agent performs those
steps over SSH:

1. **Grant temporary passwordless sudo** for the deploying account — a drop-in under
   `/etc/sudoers.d/` on the NAS (DSM: Control Panel access or a root shell). The agent should
   stop and ask for this grant when it hits the first privileged step, not assume it.
2. Let the agent **batch every privileged step while the grant lasts** — deploy, scheduler
   tasks, acceptance checks, `doctor` verification — so the grant window stays short.
3. **Remove the sudoers drop-in immediately after** verification passes. The agent must remind
   the owner to revoke it at the end of the run; treat a lingering grant as a defect.

The grant is an operational secret-equivalent: never commit its filename, account name, or host
details to the repo (see the leak gate above).

## Local checks before pushing

These mirror `.woodpecker.yml` step for step — when you add a CI step, add its local equivalent
here in the same change.

```bash
# POSIX syntax (CI parse-checks EVERY .sh in the repo, incl. install.sh, installer/, ci/)
for f in $(find . -path ./.git -prune -o -name "*.sh" -print); do sh -n "$f" || echo "FAIL $f"; done

# renderer + rule check, then the CLI contract (both need pyyaml)
python3 -m venv /tmp/v && /tmp/v/bin/pip install -q pyyaml
/tmp/v/bin/python scripts/ci/render_check.py
/tmp/v/bin/python scripts/ci/cli_contract_check.py   # --write regenerates the artifacts

# shellcheck (via Docker, same 15 targets as CI)
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable \
  shellcheck -x install.sh install-pi.sh scripts/gateway.sh scripts/auto_update.sh \
  scripts/pi/auto_update_lite.sh scripts/pi/lite_ctl.sh \
  scripts/install_scheduler.sh scripts/setup_network.sh scripts/render_config.sh \
  scripts/package.sh scripts/doctor.sh scripts/state_diff.sh bootstrap.sh \
  scripts/lib/container.sh scripts/lib/targets.sh

# compose renders (non-destructive, same as CI - never touches your real .env)
docker compose --env-file .env.example config --quiet

# release packaging safeguard (hermetic; builds both bundles in temp repos, needs git)
python3 scripts/ci/package_check.py

# the seven fake-Docker/PATH-stub TDD suites CI runs (no NAS mutation)
sh scripts/ci/dsm_installer_check.sh
sh scripts/ci/lifecycle_check.sh
sh scripts/ci/auto_update_check.sh
sh scripts/ci/cloudflared_check.sh
sh scripts/ci/generic_update_check.sh
sh scripts/ci/gateway_cli_check.sh
sh scripts/ci/pi_installer_check.sh

# privacy gate + its self-test
python3 scripts/ci/privacy_check.py
python3 scripts/ci/privacy_check_test.py

# image-ref policy (fail-closed ${VAR:?} refs + REGISTRY_MODE=acr default)
python3 scripts/ci/compose_policy_check.py
```

## How to extend

- **Auto-update another standalone container:** enroll it as a **generic target** —
  `sudo sh scripts/gateway.sh update --enable NAME --yes` (or the installer's targets menu).
  Enrolled targets are pulled, arch-checked, and recreated in place via `lib/container.sh` with a
  tiered health gate (running → stable `RestartCount` → native healthcheck → optional probe) and
  saved-spec auto-restore; proven-good records persist under
  `../syno-mihomo-gateway-data/state/last-good/<name>`. Eligibility (DEC-1, `lib/targets.sh`)
  requires the container to *already* run an image under the configured ACR
  registry/namespace — no upstream→ACR name guessing, and no generic targets under
  `REGISTRY_MODE=docker`. An optional `exec:<cmd>`/`log:<regex>` probe goes in the target's
  `name|strategy|probe` record in `../syno-mihomo-gateway-data/state/update-targets`. Bare
  `UPDATE_IMAGES` refs that map to no deploy target are still pulled **cache-only** (logged as a
  `WARN` naming `MIHOMO_IMAGE`/`METACUBEXD_IMAGE`/`CF_IMAGE`). See
  [Auto-Update › Generic targets](auto-update.md#generic-targets-any-enrolled-container). Extend
  the engine in `lib/targets.sh` (eligibility) / `lib/container.sh` (capture/replay + parity
  guard, fail-closed on unreplayable settings), cover it in `scripts/ci/generic_update_check.sh`,
  and prove retention with `scripts/state_diff.sh`.
- **Add a config knob:** add a `{{TOKEN}}` to `config.template.yaml`, a `- VAR=${VAR}` entry in
  the mihomo `environment:` block, a `sed -e` in `render_config.sh`, and a row in
  [Configuration](configuration.md) + `.env.example`. Add an assertion to `render_check.py`.
- **Add or change a `gateway.sh` verb/option:** edit `scripts/cli/spec.yaml`, run
  `python3 scripts/ci/cli_contract_check.py --write`, and commit the regenerated artifacts with
  the `gateway.sh` change — never hand-edit them (see
  [The CLI contract](#the-cli-contract-generated-files)).
- **Change the health gate / blue-green:** edit `lib/compose.sh` / `lib/cloudflared.sh`; keep the
  pull-then-swap and prove-before-cutover invariants.

## Docs: mirrors and enduser guides

- `docs/zh/*.md` are Chinese mirrors of `docs/*.md` — apply every English doc change to its
  mirror **in the same change**.
- `docs/*.txt` (+ `.zh.txt`) are the plain-text enduser guides shipped by `package.sh`'s enduser
  profile: `CLI.txt`/`CLI.zh.txt` are generated from `spec.yaml` (above); the rest are
  hand-maintained and must track their `.md` counterparts.

## Relationship to docker-china-sync

`../docker-china-sync` is the push side (GitHub Actions → Alibaba ACR). Keep its `images.txt`
and this repo's `UPDATE_IMAGES` in sync. `REGISTRY_MODE=acr` (the default) pulls through this
mirror; `REGISTRY_MODE=docker` is an explicit opt-in that pulls upstream directly and bypasses
it (and makes generic targets ineligible). See
[Auto-Update › ACR setup](auto-update.md#acr-setup).
