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

## Environments

- **prod**: Deployed on Synology NAS (not Proxmox-governed)

## Deploy

- **Entrypoint**: `docker-compose.yml` (mihomo on macvlan + metacubexd on bridge).
- **Config**: rendered at container start by `scripts/render_config.sh` from the tracked
  `config/config.template.yaml` plus persistent sibling data in `../syno-mihomo-gateway-data`.
- **Note**: This runs on Synology DSM, not on Proxmox. Registered in Nimbus for CIDR tracking only.

## Auto-Update (China / Alibaba ACR)

- **Push side**: sibling repo `docker-china-sync` mirrors images to Alibaba ACR (GitHub Actions).
- **Pull side**: `scripts/auto_update.sh` (DSM Task Scheduler, root) pulls from ACR, detects
  digest changes, and redeploys safely: `docker compose up -d` for mihomo/metacubexd with a
  health-gate + auto-rollback; **blue-green** for an **external** `cloudflared` (managed by name,
  tunnel token preserved). Reports via `synodsmnotify` + `logs/auto-update.log`.
- **Config**: `UPDATE_*`, `ACR_*`, `CF_*`, `EXPECTED_ARCH` in `.env` (see docs/configuration.md).

## CI/CD

- **Platform**: Woodpecker CI (on-premise)
- **Pipeline**: `.woodpecker.yml` — compose/YAML validation, config render check
  (`scripts/ci/render_check.py`, also enforces the no-hardcoded-DNS rule), and `shellcheck`.
  Triggers on `main` and `master`.

## Documentation

- Operator + developer manual: `docs/` (English) and `docs/zh/` (中文); indexes at
  `README.md` / `docs/README_ZH.md`.

## Safety

- Network proxy configuration — changes affect all LAN traffic
- CIDR registered in Nimbus for collision prevention
