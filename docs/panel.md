# Gateway Panel

The **gateway panel** (`mihomo-panel`, the compose `panel` service) is the third
container of the stack: a small FastAPI app that owns **dynamic per-device
policy** (flip a device between *full-tunnel*, *full-direct*, and the default
routing without touching `.env` or restarting anything) and **persistent
traffic statistics**. It writes SRC-IP rule files into mihomo's config volume
and hot-reloads them over the controller API — mihomo itself is never
restarted for a policy change.

- Web UI: `http://<PANEL_IP>:<PANEL_PORT>/ui/` (default port 8090), bilingual,
  same-origin only.
- CLI: `gateway.sh policy --list` / `--set <ip> --mode full-tunnel|full-direct|default`
  ([CLI reference](cli.md)).
- HTTP API: [generated reference](panel-api.md) — additive-only `/v1` contract.
- Doctor: `companion_health` (panel down/degraded ⇒ warn) and `policy_parity`
  (panel state vs mihomo rules drift ⇒ **error, exit 3**).

## How a policy change flows

1. A mutation reaches the panel (UI, CLI, or API) and is validated fail-closed
   (canonical `/32` for bare IPs, overlap and self-address refusal).
2. The desired state is written to SQLite (`policy.db`), then rendered into
   `providers/dyn-full-direct.txt` / `dyn-full-tunnel.txt` (tmp + rename).
3. The panel PUTs the matching rule providers on the mihomo controller and
   re-reads the rule counts (**count parity**). The response's honest
   `applied` / `parity` fields say whether the change is LIVE, not just saved.
4. On apply failure the panel goes **fail-static**: the marker
   `panel-apply-failed` is set, the webhook (if configured) fires, and the
   doctor's `policy_parity` reports drift until an apply converges.

The rule files sit **above** the general routing (directly under the LAN
exemption `GEOIP,LAN,DIRECT`), so a device policy beats GEOSITE/GEOIP routing,
while LAN destinations always stay direct — a full-tunnel device still
reaches the NAS.

## Precedence and the band

The static `.env` band (`FULL_PROXY_SOURCES`) still renders at deploy time;
the **dynamic entries outrank it**. The UI shows band membership on each
device row and asks for confirmation before overriding a band address
(the panel, not `.env`, is the operational authority for day-to-day flips —
the band remains the declarative baseline that survives a panel reset).

## Deployment

The panel deploys with the stack — `install.sh` (fresh) prompts for
`PANEL_IP` (a spare LAN address on the gateway's subnet, conflict-checked)
and **generates `PANEL_SECRET`** (32 hex chars); an upgrade migrates a
pre-panel `.env` the same way and folds `PANEL_IMAGE` into `UPDATE_IMAGES`.
Compose fails loudly (`${PANEL_IMAGE:?}` / `${PANEL_IP:?}`) until the knobs
exist. The image comes from your ACR in `acr` mode (mirrored by the image
pipeline) or from an operator-supplied `PANEL_UPSTREAM` in `docker` mode —
see [configuration](configuration.md) for every `PANEL_*` knob.

Least privilege: the container runs as uid 10001 and mounts ONLY the
provider write surface and its own `state/panel` subdirectory — never the
data-dir root and never `state/` itself (the auto-updater's metadata lives
there). The installer hands both mounts to that uid before `compose up`.

## Data, retention, backups

`state/panel/` holds `policy.db` (device policy + audit log) and `stats.db`
(traffic history: minute→hour→day rollups with a hard size cap, oldest tier
trimmed first, honest gap rows when the collector was down). Every policy
mutation snapshots the committed `policy.db` to a rotating
`policy.db.bak-<timestamp>` beside it (`PANEL_BACKUP_KEEP`, default 5);
`stats.db` is derived history with no automatic backups. Retention knobs
(`PANEL_STATS_*`) are documented in [configuration](configuration.md); the
runbook for backup / restore / reset / purge is in
[operations](operations.md).

## Security

- **Never expose the panel to the WAN** — do not point cloudflared (or any
  tunnel/port-forward) at `PANEL_IP`. The panel is designed for the LAN only:
  **reads are open on the LAN even when mutations are locked**, so WAN
  exposure leaks your device policy and traffic history no matter how strong
  `PANEL_SECRET` is, and the bearer check has no rate limiting — secret
  entropy is the only brute-force barrier for mutations.
- Mutations always require `Authorization: Bearer <PANEL_SECRET>`; an empty
  secret refuses every mutation (fail closed), it does not open them.
- Recorded follow-up (not in v1): an automated doctor check for accidental
  WAN exposure would need a Cloudflare API credential and scope of its own —
  cloudflared runs in token mode here, so its ingress mapping is invisible to
  any local file. Until that exists, this warning is the control.

## When something is off

[Troubleshooting](troubleshooting.md) covers the concrete cases: policy
drift (`policy_parity` exit 3, the marker), 403 on every mutation, the
fail-static recovery path, and why a full-direct device can still show a
foreign-DNS asymmetry.
