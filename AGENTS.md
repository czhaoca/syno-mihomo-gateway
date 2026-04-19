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

- **Entrypoint**: `docker-compose.yml`
- **Note**: This runs on Synology DSM, not on Proxmox. Registered in Nimbus for CIDR tracking only.

## CI/CD

- **Platform**: Woodpecker CI (on-premise)
- **Pipeline**: `.woodpecker.yml` (config validation only)

## Safety

- Network proxy configuration — changes affect all LAN traffic
- CIDR registered in Nimbus for collision prevention
