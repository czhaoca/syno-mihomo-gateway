# CLAUDE.md — Syno Mihomo Gateway

## Project Identity

**Syno Mihomo Gateway** — transparent proxy gateway for Synology DSM.
- **Mihomo**: Network proxy engine (privileged container)
- **MetaCubexD**: Web dashboard for proxy management

## Critical Rules

- **NEVER hardcode** proxy rules, DNS servers, or network addresses in committed files
- Configuration templates use placeholders; real values in `.env` (gitignored)
- CIDR ranges registered in Nimbus for collision prevention
- Changes to proxy config affect all LAN traffic — test carefully

## Deploy

- Runs on **Synology NAS**, not Proxmox
- `docker compose up -d` on the NAS
- Registered in Nimbus registry for CIDR tracking only
