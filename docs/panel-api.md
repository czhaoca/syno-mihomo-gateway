# Panel HTTP API (generated)

<!-- GENERATED from app/openapi.json - never hand-edit. Regenerate: python3 scripts/ci/panel_contract_check.py --write -->

Version 1.0.0. Dynamic device policy for the Syno Mihomo Gateway. The /v1 surface is additive-only: fields and endpoints may be added, but a breaking change (removal, rename, semantics change) requires a NEW version prefix and explicit owner acknowledgment. Reads are LAN-open; every mutation requires the PANEL_SECRET bearer token.

Reads are open on the LAN; every mutation (POST/PATCH/DELETE) requires
`Authorization: Bearer <PANEL_SECRET>` and is refused when the secret is
unset - fail closed. Responses are JSON unless an endpoint says
otherwise: the CSV exports (`format=csv`), the `/metrics` text
exposition and the `/v1/stats/live` event stream. The base URL is
`http://<PANEL_IP>:<PANEL_PORT>` (default port 8090); prefer
`gateway.sh policy` over raw calls for the policy surface.

## `GET /health`

Health

## `GET /metrics`

Metrics

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

## `POST /v1/identities/import`

Post Identities Import

## `GET /v1/identity`

Get Identity

## `DELETE /v1/identity/{ip}`

Delete Identity

Parameters: `ip`

## `PUT /v1/identity/{ip}`

Put Identity

Parameters: `ip`

## `GET /v1/settings`

Get Settings

## `PUT /v1/settings`

Put Settings

## `GET /v1/stats/breakdown`

Stats Breakdown

Parameters: `dim`, `tier`, `since`, `until`, `device`, `sort`, `limit`, `offset`, `range`, `format`

## `GET /v1/stats/chains`

Stats Chains

Parameters: `tier`, `since`, `until`, `range`

## `GET /v1/stats/coverage`

Stats Coverage

Parameters: `since`, `until`

## `GET /v1/stats/devices`

Stats Devices

Parameters: `tier`, `since`, `until`, `range`

## `GET /v1/stats/domains`

Stats Domains

Parameters: `since`, `until`

## `GET /v1/stats/gaps`

Stats Gaps

Parameters: `limit`, `since`, `until`

## `GET /v1/stats/live`

Stats Live

Gateway-wide throughput, live, as Server-Sent Events. Nothing from
this stream is stored.

The stream opens with `retry: 5000` (reconnect after 5 s), then sends
one event per mihomo /traffic frame (about one a second):

    data: {"ts": "2026-10-16T12:00:00Z", "up_bps": 1200, "down_bps": 56000}

`up_bps` / `down_bps` are BYTES per second, as mihomo reports them, and
`ts` is the panel's clock when the frame was relayed. `/health`
`live_viewers` says how many viewers are connected right now. When no frame has
arrived for 15 s - mihomo restarting, the stream reconnecting - a
`: ping` comment keeps the connection open; a viewer shows how long it
has been since the last `data` event, never a frozen number. One relay
serves every viewer and reads mihomo only while at least one is
connected; past 16 concurrent viewers the answer is 503 - or, when the
16th slot went in the instant between that check and the stream
starting, a stream of `retry: 60000`, one `event: full` and its end.
The panel shutting down ends every stream.

## `GET /v1/stats/node-delay`

Stats Node Delay

Parameters: `range`

## `GET /v1/stats/overview`

Stats Overview

Parameters: `range`, `device`, `category`, `host`, `limit`

## `POST /v1/stats/purge`

Stats Purge

## `GET /v1/stats/quota`

Stats Quota

## `GET /v1/stats/self`

Stats Self

Parameters: `since`, `until`

## `GET /v1/stats/timeline`

Stats Timeline

Parameters: `tier`, `device`, `since`, `until`, `range`, `format`
