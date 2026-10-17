/* The stats query vocabulary (#80 DEC-A).

   RANGES is the ONE list shared by the view's selector and the
   `stats_default_range` setting (app/store/settings.py STATS_RANGES). Two
   lists that agree today drift, and a stored default naming a window the UI
   cannot draw would land the operator on a blank tab with nothing saying
   why. A range the panel does not know falls back to the shipped default
   rather than issuing a query for a tier that does not exist. */

export const RANGES = ["24h", "48h", "7d", "30d", "daily"];
export const DEFAULT_RANGE = "7d";

/* The SERVER owns the window (#91). A `range=` read is computed from the
   panel's own clock and covers every tier the window spans - the
   resolution's tier plus the finer ones holding the newest rows not yet
   rolled up. The browser used to send `tier` + a `since` it computed itself,
   and that read ONE tier table: rollup moves rows between tiers, so the 7d
   and 30d views lost the newest 48 hours and "daily" lost the last 90 days.
   Naming the preset is all the client does now. */
export function normalizeRange(value) {
  return RANGES.includes(value) ? value : DEFAULT_RANGE;
}

/* The resolution each preset reads at (app/store/stats/window.py
   RANGE_SPECS). A scoped read may answer at a coarser one - the dimensions
   keep no minute tier - and the answer's own `timeline.tier` then wins. */
const RESOLUTION = { "24h": "minute", "48h": "minute", "7d": "hour",
                     "30d": "hour", daily: "day" };

export function resolutionOf(range) {
  return RESOLUTION[normalizeRange(range)];
}

// How often a view of each resolution is re-read (#101 DEC-H): a bucket
// finer than the cadence would change between reads unseen; one coarser
// would be re-read for nothing.
export const CADENCE_MS = { minute: 10_000, hour: 60_000, day: 300_000 };

/* Whether a read ELAPSED ms after the last one is due at CADENCE ms. The
   shell's tick fires 10 s after the previous one PLUS that tick's /health
   round trip, so ticks drift by a few ms either way: compared exactly, a
   tick a hair early would skip a due minute read and leave a 20 s hole.
   Half a tick of slack makes "due" mean "this tick or later". */
const TICK_SLACK_MS = 5_000;

export function isDue(elapsed, cadence) {
  return elapsed + TICK_SLACK_MS >= cadence;
}

// Hours each preset looks back over; null is "everything held".
const WINDOW_HOURS = { "24h": 24, "48h": 48, "7d": 24 * 7, "30d": 24 * 30,
                       daily: null };

/* The window's start for the chart's axis - the SERVER computes the window
   it reads (#91); this only says where the axis begins. */
export function windowStart(range, now = new Date()) {
  const hours = WINDOW_HOURS[normalizeRange(range)];
  return hours === null ? null : new Date(now.getTime() - hours * 3600 * 1000);
}

/* The hostname class (hostnames, app-level ids, the attribution split) is
   kept for this many days, whatever the window (app/store/stats/breakdown.py
   DOMAIN_RETENTION_DAYS). The server says so in its answers; this is only
   the fallback when an answer does not. */
export const CLASS_RETENTION_DAYS = 7;
// the ranges whose window reaches past that cap (#101 DEC-G)
export const BEYOND_CLASS = ["30d", "daily"];

// Top lists show this many values at first, and "show more" adds as many,
// up to the server's clamp (#101 DEC-B).
export const PAGE = 10;
export const LIMIT_MAX = 200;

// The category counted without a dictionary is "", which has no path form;
// routes carry this reserved token instead (useHashRoute).
export const NO_DICTIONARY = "no_dictionary";

/* The scoped overview read: the range PRESET (never a client-computed
   window), at most one device and at most one of a category or a hostname.
   An empty category is SENT (`category=`) - it is a real value. */
export function overviewPath(range, scope, limit) {
  const params = new URLSearchParams({ range: normalizeRange(range) });
  if (limit) params.set("limit", String(limit));
  if (scope.client) params.set("device", scope.client);
  if (scope.app !== null && scope.app !== undefined) params.set("category", scope.app);
  else if (scope.host) params.set("host", scope.host);
  return `/v1/stats/overview?${params.toString()}`;
}

export function fmtBytes(n) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = Number(n) || 0;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) { value /= 1024; i += 1; }
  return `${value.toFixed(value >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
}

/* Aliases onto traffic rows.

   `GET /v1/identity` is the join source, and its `ip` is ALREADY BARE -
   `list_aliases` strips the `/32` (app/store/identity.py). The stats tables
   key on the bare `metadata.sourceIP` too, so the two forms match directly.

   The `/32`-keyed sources (`/v1/devices[].cidr`, `identity.resolve()`) do
   NOT: joining against them matches zero rows for every real host and
   raises nothing, which is the silent miss the identity module was written
   to make visible. `/v1/identity` is also the only COMPLETE source, because
   an alias may exist for a host that carries no policy at all - and those
   never appear in `/v1/devices`. */
export function aliasMap(identities) {
  const out = new Map();
  for (const row of identities || []) {
    if (row.ip && row.alias) out.set(row.ip, row.alias);
  }
  return out;
}

// `unknown` is the literal the collector substitutes when mihomo reports no
// source IP. It can never carry an alias (host_key refuses it), so it simply
// never matches - and an IPv6 source cannot either, the gateway being
// IPv4-only. Both degrade to the raw address rather than erroring.
export function labelFor(device, aliases) {
  const alias = aliases.get(device);
  return alias ? `${alias} (${device})` : device;
}
