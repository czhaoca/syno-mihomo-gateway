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

## Device names (aliases)

A name and a routing policy are separate things: the shipped `devices` table
requires a mode on every row, so naming a host there would force a routing
decision onto it. Aliases therefore live in their own sidecar, keyed on the
host address, and a device can be named whether or not it carries a policy.
Naming applies no policy and triggers no reconcile — there is nothing for
the gateway to *do* about a label.

Every alias records **where it came from**, and that provenance decides who
may overwrite it:

- **An alias you typed outranks every importer.** A sync leaves those rows
  untouched and reports each one as `skipped`.
- **The consequence is deliberate, and worth knowing before you use it:**
  once you name a host in the panel, it stops following later renames on the
  vendor side. To hand that host back to the sync, clear its alias — or
  re-run the sync with `--adopt`, attended.
- An importer may always update a row **it** wrote, and may claim a row whose
  provenance is unknown (only raw SQL that omitted the column can produce
  one, so it carries no authority).

Import a batch from the host with `gateway.sh alias --sync --from <source>`
(`--list` prints what is stored). Two sources ship: `unifi` reads a
controller through `UNIFI_*` in `.env`, and `file` reads an
`{"entries":[{"ip":…,"alias":…}]}` document from
`<data-dir>/identity/aliases.json` — the same path a Nimbus export or a
hand-written list uses. The output is a **per-row ledger**:
`applied` / `unchanged` / `skipped` / `rejected`, and a row that met an
existing alias also reports the alias and provenance already stored, so a
skip names who owns the name it declined to overwrite. (A `rejected` row
never reached the store, so it carries only the address and the reason.) A
skip is a designed refusal, not a failure — the run still exits 0 — and a
bare total would hide exactly the rows the rule exists to protect.

The panel itself stays vendor-agnostic and **never holds a vendor
credential**. `POST /v1/identities/import` knows only `{ip, alias, source}`;
no vendor code ships inside the panel image. The adapter runs on the host in
a **one-shot container** built from the panel image and used purely as a
python runtime, and the credential reaches it on **stdin** — never on the
command line (`ps` shows argv on both sides) and never in the container's
environment. `alias --sync` requires root whichever source it uses: it reads
its input out of the root-owned data dir (`unifi` the credential in `.env`,
`file` the document beside it) and starts a container — more than the
`policy` verbs' "only the panel's own authenticated API" exemption covers,
with `unifi` the sharpest case since the credential then also leaves the
host. `--adopt` requires `--yes` as well, because it is the one mode that
can overwrite a name a human typed.

TLS certificates are **verified by default**. A UniFi console ships a
self-signed certificate, so the first sync against one fails on purpose;
`UNIFI_INSECURE=true` in `.env` is the explicit opt-out, rather than a
silent downgrade on a credential-bearing call.

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
