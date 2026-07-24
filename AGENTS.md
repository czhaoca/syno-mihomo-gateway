# Syno Mihomo Gateway — Agent Deployment Metadata

## Registry

- **Project name**: `syno-mihomo-gateway`
- **Repository**: `git@github.com:czhaoca/syno-mihomo-gateway.git`
- **Description**: Synology DSM transparent proxy gateway

## Services

| Service | Container Port | Protocol | Notes |
|---------|---------------|----------|-------|
| metacubexd | 80 | http | Web UI dashboard |
| mihomo | — | — | Network proxy (privileged, no exposed port) |
| panel | 8090 | http | Gateway panel (`mihomo-panel`): dynamic device policy + stats; FastAPI app on its own macvlan seat at `PANEL_IP` (LAN-only — never WAN-exposed) |

## Environments

- **prod**: Deployed on Synology NAS (not Proxmox-governed)

## Deploy

- **Entrypoint**: `docker-compose.yml` (mihomo + panel on macvlan, metacubexd on bridge).
- **Config**: rendered at container start by `scripts/render_config.sh` from the tracked
  `config/config.template.yaml` plus persistent sibling data in `../syno-mihomo-gateway-data`.
  The panel app (`app/`, FastAPI) is image-delivered — dev-excluded from bundles; its image is
  built by the sibling repo's `panel-build.yaml` (tag-driven multi-arch → ghcr + ACR mirror).
- **Note**: This runs on Synology DSM, not on Proxmox. Registered in Nimbus for CIDR tracking only.

## Auto-Update (China / Alibaba ACR)

- **Push side**: sibling repo `docker-china-sync` mirrors images to Alibaba ACR (GitHub Actions).
- **Pull side**: `scripts/auto_update.sh` (DSM Task Scheduler, root) pulls from ACR, detects
  digest changes, and applies serially, lowest blast radius first: enrolled **generic targets**
  (in-place recreate via `lib/container.sh` spec capture/replay, tiered health gate, saved-spec
  auto-restore, last-good persistence) → **blue-green** for the **external** `cloudflared`
  (managed by name, tunnel token preserved) → `docker compose up -d` for
  mihomo/metacubexd/panel (health-gate incl. the panel's `/health` db_ok + three-way
  auto-rollback) LAST. Reports via webhook/`synodsmnotify` + `logs/auto-update.log`
  with an `updated/unchanged/failed/rolled_back` counts header; `state/last-run.json` feeds
  `gateway.sh status`.
- **Generic enrollment**: managed list at `<data-dir>/state/update-targets`
  (`gateway.sh update --enable/--disable/--list-targets` or the installer flow); eligible =
  enrolled ∩ running ∩ ACR-ref, minus the trio/compose-managed/ambiguous/`UPDATE_DENY_CONTAINERS`;
  fail-closed parity guard refuses un-replayable settings. Acceptance: `scripts/state_diff.sh`
  snapshot/compare around an update is the required manual gate (see docs/auto-update.md).
- **Config**: `UPDATE_*`, `ACR_*`, `CF_*`, `EXPECTED_ARCH` in `.env` (see docs/configuration.md).

## CI/CD

- **Platform**: Woodpecker CI (on-premise)
- **Pipeline**: `.woodpecker.yml` — 12 blocking steps, in declaration order: `validate-compose`,
  `validate-yaml`, `render-config` (`scripts/ci/render_check.py`, also enforces the
  no-hardcoded-DNS rule), `cli-contract` (generated CLI docs must regenerate byte-identical),
  `compose-policy`, `package-check` (bundle + leak gate), `privacy-check`, `dsm-shell-tests`
  (twelve BusyBox-sh suites — `dsm_installer_check`, `lifecycle_check`, `auto_update_check`,
  `cloudflared_check`, `generic_update_check`, `gateway_cli_check`, `seed_provider_check`,
  `proxy_groups_check`, `full_proxy_check`, `mihomo_entrypoint_check`, `pi_installer_check`,
  `linux_installer_check` — plus `validate_release.sh --self-test`), `shellcheck`,
  `app-lint` (ruff over `app/`), `app-unit` (the panel's pytest suite + the contract gate:
  `app/openapi.json` and the generated `docs/panel-api.md` regenerate byte-identical), and
  `app-e2e` (the hermetic loopback e2e). Full step table: docs/development.md. Triggers on
  `main` and `master`.

## Documentation

- Operator + developer manual: `docs/` (English) and `docs/zh/` (中文); indexes at
  `README.md` / `docs/README_ZH.md`.

## Safety

- Network proxy configuration — changes affect all LAN traffic
- CIDR registered in Nimbus for collision prevention
