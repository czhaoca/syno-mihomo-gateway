# Panel HTTP API (generated)

<!-- GENERATED from app/openapi.json - never hand-edit. Regenerate: python3 scripts/ci/panel_contract_check.py --write -->

Version 1.0.0. Dynamic device policy for the Syno Mihomo Gateway. The /v1 surface is additive-only: fields and endpoints may be added, but a breaking change (removal, rename, semantics change) requires a NEW version prefix and explicit owner acknowledgment. Reads are LAN-open; every mutation requires the PANEL_SECRET bearer token.

Reads are open on the LAN; every mutation (POST/PATCH/DELETE) requires
`Authorization: Bearer <PANEL_SECRET>` and is refused when the secret is
unset - fail closed. All responses are JSON. The base URL is
`http://<PANEL_IP>:<PANEL_PORT>` (default port 8090); prefer
`gateway.sh policy` over raw calls for the policy surface.

## `GET /health`

Health

## `POST /v1/apply`

Post Apply

## `GET /v1/audit`

Get Audit

Parameters: `limit`, `offset`

## `GET /v1/devices`

Get Devices

## `POST /v1/devices`

Post Device

## `PATCH /v1/devices/{device_id}`

Patch Device

Parameters: `device_id`

## `DELETE /v1/devices/{device_id}`

Delete Device

Parameters: `device_id`, `note`

## `GET /v1/identity`

Get Identity

## `DELETE /v1/identity/{ip}`

Delete Identity

Parameters: `ip`

## `PUT /v1/identity/{ip}`

Put Identity

Parameters: `ip`

## `GET /v1/stats/chains`

Stats Chains

Parameters: `tier`, `since`, `until`

## `GET /v1/stats/devices`

Stats Devices

Parameters: `tier`, `since`, `until`

## `GET /v1/stats/domains`

Stats Domains

Parameters: `since`, `until`

## `GET /v1/stats/gaps`

Stats Gaps

Parameters: `limit`

## `POST /v1/stats/purge`

Stats Purge

## `GET /v1/stats/timeline`

Stats Timeline

Parameters: `tier`, `device`, `since`, `until`
