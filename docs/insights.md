# Gateway Insights

Gateway Insights is the panel's analytics view, and the tab the panel opens
on (`http://<PANEL_IP>:8090/ui/`). It answers "what is the network doing" from
the traffic history the panel collects: totals, a timeline, and the top
devices, categories, exit nodes, countries and hostnames. You can drill from
the whole gateway into one device, then into one of its categories or
hostnames.

Every view is one read of `GET /v1/stats/overview` (see
[Panel API](panel-api.md)). All of its sections come from the same database
moment, so the totals, the chart and the lists always agree. Gateway
Insights is part of the compose deployment's panel; the Raspberry Pi lite
mode has no panel and so no Insights.

## Ranges

| Range | Resolution | Window |
|---|---|---|
| Last 24h | minutes | the last 24 hours |
| Last 48h | minutes | the last 48 hours |
| Last 7 days | hours | the last 7 days |
| Last 30 days | hours | the last 30 days |
| Long term | local days | everything held |

The view opens on the `stats_default_range` setting (Settings tab), not on a
value built into the panel. The server computes each window from its own
clock and reads every tier it spans, so the newest hours are never missing
from a long window.

## Scopes and drilling

| Scope | Route | What it shows |
|---|---|---|
| Overview | `#/insights` | the whole gateway: every top list, the attribution share and coverage note, and what the gateway cannot see |
| Client | `#/insights/client/<ip>` | one device: its categories, hostnames, exit nodes and countries |
| Category | `#/insights/app/<category>` | one category value: its devices |
| Host | `#/insights/host/<hostname>` | one hostname: its devices |

A row in a list drills into the next scope, and the trail above the view
leads back.
- From the overview, a device opens its client scope, a category its
  category scope, and a hostname its host scope.
- From a client, a category or a hostname drills further **while keeping
  the device**: `#/insights/client/<ip>/app/<category>` or
  `#/insights/client/<ip>/host/<hostname>`.
- From a category or a hostname, a device drills to that category or
  hostname on that device.

Every route takes `?range=` (for example
`#/insights/client/192.0.2.20?range=30d`). The route is the address, so the
back button, a reload and a bookmark all return to the same view. A link the
panel cannot read opens the overview, never an empty page. The Devices tab
links each host's history to its client scope.

**Why "Category" and not "App".** The category scope is routed as `app` but
named Category on screen. It is one value of the category dimension: a
coarse category such as `video`, `unknown` (unattributed), or the bytes
counted before the dictionary existed (routed as `no_dictionary`). There is
no scope for a single app-level id such as `netflix`, because the panel keeps
those only in the seven-day class.

**What a scope cannot show.** The panel stores each dimension in its own
tables, and no table joins a category to its exit nodes, countries or
hostnames. So a category scope cannot list hostnames, and you cannot drill
from a category to a hostname. Walk it as client → category, back to the
client, then client → hostname. Whenever a scope cannot answer a list, the
view names the list and says why. It never shows the list as empty or as
zero.

## Top lists

Each list shows ten values, largest first. What it does not show is said:
how many values are left and how many bytes they carry. **Show more** adds
ten more, up to 200. Past 200 the list says how many it could not list.

Show more raises the size of the one overview read. It does not page a
second endpoint, because the breakdown endpoint cannot list a device's
traffic within a category or a hostname. Pages read at different moments
could also list a value twice, or skip one, as the ranks shift between
them. Raising the size keeps every list from the same moment. The cost is a
larger answer: every list in that read grows, and the view shows each list
at its own size. Changing the range or the scope starts every list at ten
again.

A long-term list also says what it has **no record of** (device bytes from
before the panel kept that dimension, or from a time an older panel ran)
and where its data starts.

## Reading the chart

- A **hatched band** is a collection gap: the collector was not polling. It
  is a hole, never a zero, and never filled in. A bar under a hatched cap
  kept its value; only part of that bucket is missing.
- A missing bar **with no gap** is a real zero: the collector ran and saw no
  traffic.
- A **marker line** is a seam: the local day's boundary or time zone
  changed there, and a day under two framings is drawn as two bars.
- The flat span **before the data starts** and the span **after the last
  good poll** are regions, not zeros.
- On 30 days and long term, the span older than the **hostname window**
  (seven days) is shaded. A category scope is never shaded: everything in
  it is kept long-term. Its bars are real: bytes, exit nodes, countries
  and categories are kept long-term. What the shade marks is that
  hostnames, app-level ids and the attribution split are not kept there.
  In a host scope the shade is where that hostname's data is not kept, so
  no bar there means no data, not no traffic, and its legend says so.
- **Stale since …**: the picture on screen is the last good answer. Either
  the collector stopped, the newest read failed, or the newest read has
  gone unanswered for two refresh periods. Nothing after the poll
  that answer included is drawn.
- **Unavailable** means the stats store did not answer. **No traffic**
  means it answered with nothing. The two are never confused.

Click or tap a bar, or focus the chart and use the arrow keys, to read a
bucket.

## Notes the view keeps

- **Hostnames are off** (the default): no hostname lists, and a host scope
  says so. To keep hostnames and app-level ids for seven days, set
  `PANEL_STATS_DOMAINS=true` in `.env` and redeploy. The panel never turns
  this on by itself.
- **What the gateway cannot see**: only traffic that passes through the
  gateway is counted. A device that bypasses it (for example over an IPv6
  route the router hands out) or a DNS server outside the gateway is not
  seen. `sudo sh scripts/doctor.sh` checks for the IPv6 bypass, and
  [Troubleshooting](troubleshooting.md) explains the fix.
- **Attribution** (the overview): the share of traffic whose hostname is
  known, measured over the seven days the class keeps.

## Refresh

The view re-reads on the panel's 10 s tick, but only when the answer's own
resolution can have changed: every 10 s at minute resolution, every 60 s at
hours, every 300 s at days; until a view has its first answer it retries
every 10 s. It does not read while the tab is hidden, and the refresh never
starts a read while another is in flight: a read still unanswered after two
refresh periods marks the picture stale instead. Refresh and a new range or
scope read at once, and the older read's answer is dropped when it arrives;
Show more waits for a read in flight.

The colour scheme (System, Light or Dark) is the picker beside the language
toggle. On System it follows the device.

## Downgrading

An older panel that reads a stored `24h` default lands on its own default
range. Reads never re-validate a stored setting, and an older view ignores
a range it does not know.

## Security

Like every panel read, Insights needs no password and shows per-device
traffic. Keep the panel LAN-only and never expose it to the WAN (see
[Gateway Panel](panel.md)).
