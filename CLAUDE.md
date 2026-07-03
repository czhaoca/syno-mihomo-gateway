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
- **Agent-assisted deploys over SSH need a temporary sudo grant**: the NAS account is a
  non-root admin, so ask the owner for temporary passwordless sudo when the first privileged
  step comes up, batch ALL privileged work (deploy, scheduler tasks, doctor verification)
  while it lasts, and **end the run by reminding the owner to remove the grant** — never
  leave it in place, and never commit its details (see docs/development.md)
