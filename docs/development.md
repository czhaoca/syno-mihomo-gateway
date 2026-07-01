# Development & Internals

[← README](../README.md) · [中文](zh/development.md)
Manual: [Architecture](architecture.md) · [Installation](installation.md) · [Release Zip](release-packaging.md) · [Configuration](configuration.md) · [Auto-Update](auto-update.md) · [Operations](operations.md) · [Troubleshooting](troubleshooting.md) · **Development**

---

For contributors and anyone extending the gateway.

## Repository layout

```
docker-compose.yml            # mihomo (macvlan, privileged) + metacubexd (bridge)
.env.example                  # documented config contract (copy to .env)
VERSION                       # release version (stamped into the package.sh artifact name)
bootstrap.sh                  # offline-install first-run helper (seeds .env, restores exec bits)
config/
  config.template.yaml        # mihomo config with {{PLACEHOLDERS}}
  subscription.txt.example    # subscription template (copy to subscription.txt)
scripts/
  setup_network.sh            # macvlan + TUN setup, optional ACR login/pull
  render_config.sh            # renders config.yaml from the template (entrypoint + CI both call it)
  auto_update.sh              # the DSM auto-update orchestrator (entry point)
  install_scheduler.sh        # prints DSM Task Scheduler / crontab settings
  package.sh                  # build-host: builds the offline release zip (docs/release-packaging.md)
  installer/
    preprocess.sh             # per-resource cleanup menus; the decision policy lives in lib/resolve.sh
  lib/
    common.sh                 # env load, logging+rotation, mkdir lock, exit codes
    registry.sh               # preflight (compose/arch/network/tun), ACR login, pull + change detect
    compose.sh                # compose up, health gate, rollback
    cloudflared.sh            # blue-green reprovision of the external cloudflared
    lifecycle.sh              # deployment inventory + verified scoped teardown
    resolve.sh                # UI-free config resolution: IP suggestion, image refs, subscription URL, cleanup-plan policy
    scheduler.sh              # safe DSM/BusyBox cron parsing and task commands
  ci/
    render_check.py           # CI: runs the real renderer + structural/rule assertions
    auto_update_check.sh      # fake-Docker TDD suite for scheduler/update/rollback paths
    cloudflared_check.sh      # fake-Docker TDD suite for blue-green behavior
    lifecycle_check.sh       # fake-Docker inventory/cleanup safety suite
    privacy_check.py         # tracked-content/history privacy gate
.woodpecker.yml               # CI: compose/yaml validate, render check, shellcheck
docs/                         # this manual (EN) + docs/zh (中文)
```

## Coding rules

- **POSIX `/bin/sh`, BusyBox-safe.** DSM ships BusyBox; no bashisms or associative arrays,
  including in `scripts/setup_network.sh` and the unattended task entry points.
- **No `set -e`/`set -u` in the orchestrator.** It checks return codes explicitly so one soft
  failure never tears down the gateway by surprise. `render_config.sh` *does* use `set -eu` (it's
  a short, fail-fast renderer).
- **No hardcoded DNS / network addresses** in committed files (project rule). Use
  `{{PLACEHOLDERS}}` + `.env`. CI enforces this (`render_check.py`).
- **Secrets only in gitignored `.env`** (`ACR_PASSWORD`, `CF_TUNNEL_TOKEN`, `CONTROLLER_SECRET`).
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
config → wait for Docker + preflight → pull/inspect/detect → local-only Compose apply
(+health-gate/rollback) → cloudflared blue-green → prune → notify**. Full detail in
[Auto-Update](auto-update.md#the-run-sequence). Key library functions:

| File | Functions |
|---|---|
| `lib/common.sh` | `load_env`, `log*`, `rotate_log`, `acquire_lock`/`release_lock` (guarded by `LOCK_HELD`), `EXIT_*` codes |
| `lib/registry.sh` | `validate_update_config`, `wait_for_docker_ready`, `check_arch_expectation`/`arch_ok`, `check_network`, `check_tun`, `acr_login`, `pull_image`, `deploy_needed` |
| `lib/compose.sh` | `compose_config_check`, `compose_up_local`, `health_gate` (+ `mihomo_controller_probe`), `rollback_compose` |
| `lib/cloudflared.sh` | `cloudflared_blue_green`, `cloudflared_wait_connected`, secure spec capture/replay, rollback, candidate/workdir cleanup |
| `lib/lifecycle.sh` | `lifecycle_inspect`, verified container/network removal, manual command rendering |
| `lib/resolve.sh` | `resolve_mihomo_ip`, `resolve_images`/`resolve_update_images`, `resolve_subscription_url`/`subscription_current`, `resolve_cleanup_plan` (UI-free; the wizards render its results) |
| `lib/scheduler.sh` | `cron_normalize`, `scheduler_update_command`, `scheduler_network_command`, `scheduler_reload_crond` |

Concurrency: only the lock holder releases the lock (`LOCK_HELD`); the EXIT trap won't reap a
cloudflared candidate when it may be the only connected tunnel (`CF_KEEP_CANDIDATE`).

## CI (`.woodpecker.yml`)

Runs on push/PR to `main` and `master`:

| Step | What |
|---|---|
| `validate-compose` | `docker-compose --env-file .env.example config --quiet` (blocking) |
| `validate-yaml` | `yaml.safe_load(docker-compose.yml)` |
| `render-config` | `python scripts/ci/render_check.py` — runs the **real** renderer against a fixture URL with a `Name=` prefix + `&` params and asserts the URL round-trips exactly; also enforces the no-hardcoded-DNS rule |
| `compose-policy` | `python scripts/ci/compose_policy_check.py` — asserts gateway images are **ACR-only**: no direct Docker Hub/ghcr fallback in `docker-compose.yml`, and `.env.example` image refs target a private registry |
| `package-check` | `python scripts/ci/package_check.py` — builds the release zip in a throwaway repo and proves **no secret can ship** (planted `.env`/subscription/`config.yaml` absent from both archives' names *and* bytes), checksums verify, the guards fire, and `bootstrap.sh` round-trips |
| `privacy-check` | Scans tracked files and reachable blobs for private operational identifiers, credentials, private keys, and accidentally tracked runtime files |
| `dsm-shell-tests` | Executes installer, lifecycle, scheduler/updater, and staged-cloudflared assertions under BusyBox `sh`, using fake Docker/Compose CLIs |
| `shellcheck` | `shellcheck -x` on the entry-point scripts (lib/*.sh followed in-context) |

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

## Local checks before pushing

```bash
# POSIX syntax
for f in scripts/*.sh scripts/lib/*.sh; do sh -n "$f" || echo "FAIL $f"; done

# renderer + rule check (needs pyyaml)
python3 -m venv /tmp/v && /tmp/v/bin/pip install -q pyyaml && /tmp/v/bin/python scripts/ci/render_check.py

# shellcheck (via Docker, same as CI)
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:stable \
  shellcheck -x scripts/auto_update.sh scripts/install_scheduler.sh scripts/setup_network.sh scripts/render_config.sh scripts/package.sh bootstrap.sh

# compose renders (needs a throwaway .env)
cp .env.example .env && docker compose config -q && rm -f .env

# release packaging safeguard (hermetic; builds in a temp repo, needs git)
python3 scripts/ci/package_check.py

# scheduler/updater/cloudflared TDD suites (fake Docker/Compose; no NAS mutation)
sh scripts/ci/auto_update_check.sh
sh scripts/ci/cloudflared_check.sh
sh scripts/ci/dsm_installer_check.sh
sh scripts/ci/lifecycle_check.sh
python3 scripts/ci/privacy_check.py
python3 scripts/ci/privacy_check_test.py

# ACR-only image policy (no direct Docker Hub/ghcr fallback)
python3 scripts/ci/compose_policy_check.py
```

## How to extend

- **Track another container for updates:** add its ACR ref to `UPDATE_IMAGES`. To make it
  *deploy* (not just cache), it must be a compose service referenced by one of the deploy image
  vars, or handled like cloudflared — otherwise it's pulled cache-only (logged as a `WARN`).
- **Add a config knob:** add a `{{TOKEN}}` to `config.template.yaml`, a `-e` line in the mihomo
  `environment:` block, a `sed -e` in `render_config.sh`, and a row in
  [Configuration](configuration.md) + `.env.example`. Add an assertion to `render_check.py`.
- **Change the health gate / blue-green:** edit `lib/compose.sh` / `lib/cloudflared.sh`; keep the
  pull-then-swap and prove-before-cutover invariants.

## Relationship to docker-china-sync

`../docker-china-sync` is the push side (GitHub Actions → Alibaba ACR). Keep its `images.txt`
and this repo's `UPDATE_IMAGES` in sync. See [Auto-Update › ACR setup](auto-update.md#acr-setup).
