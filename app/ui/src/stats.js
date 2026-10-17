/* The stats query vocabulary (#80 DEC-A).

   RANGES is the ONE list shared by the view's selector and the
   `stats_default_range` setting (app/store/settings.py STATS_RANGES). Two
   lists that agree today drift, and a stored default naming a window the UI
   cannot draw would land the operator on a blank tab with nothing saying
   why. A range the panel does not know falls back to the shipped default
   rather than issuing a query for a tier that does not exist. */

export const RANGES = ["48h", "7d", "30d", "daily"];
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

export function statsPath(base, range, extra = {}) {
  const params = new URLSearchParams({ range: normalizeRange(range), ...extra });
  return `${base}?${params.toString()}`;
}

// Hours each preset looks back over - used ONLY for the coverage report,
// which has no `range` parameter (attribution lives in one hour-keyed
// table), so its `since` is still sent: truncated to the 13-char hour key
// that table writes, because bucket keys are compared as strings.
const COVERAGE_HOURS = { "48h": 48, "7d": 24 * 7, "30d": 24 * 30, daily: null };

export function coverageSince(range, now = new Date()) {
  const hours = COVERAGE_HOURS[normalizeRange(range)];
  if (hours === null) return "";
  return new Date(now.getTime() - hours * 3600 * 1000).toISOString().slice(0, 13);
}

/* `/v1/stats/coverage` takes since/until but NO tier - attribution lives in
   one 7-day table. The window still has to be sent: the report is capped at
   7 days by construction, so a 30-day request cannot widen it, but it is
   what makes the server answer `truncated: true`. Without it the panel would
   show a 7-day percentage beside a 30-day table and claim nothing was
   missing. */
export function coveragePath(range) {
  const since = coverageSince(range);
  return since ? `/v1/stats/coverage?since=${encodeURIComponent(since)}`
               : "/v1/stats/coverage";
}

/* Where a preset's window starts, for the chart's axis and for the gap read
   (#100). The SERVER still computes the window it reads; this is only how
   far back the chart's axis reaches, so the span before the data starts is
   drawn as such. `daily` is everything held: no start. */
const WINDOW_HOURS = { "48h": 48, "7d": 24 * 7, "30d": 24 * 30, daily: null };

export function windowStart(range, now = new Date()) {
  const hours = WINDOW_HOURS[normalizeRange(range)];
  return hours === null ? null : new Date(now.getTime() - hours * 3600 * 1000);
}

/* The gaps that overlap the window, from the start of its first HOUR - the
   first bucket an hour-resolution window draws, so a gap that ended inside
   that bucket but before the window's own minute is still listed - as many
   as the server lists (1000). The chart hatches each one, and a list cut at
   its limit is reported as such rather than read as complete. */
export const GAPS_LIMIT = 1000;

export function gapsPath(range, now = new Date()) {
  const start = windowStart(range, now);
  const params = new URLSearchParams({ limit: String(GAPS_LIMIT) });
  if (start) params.set("since", `${start.toISOString().slice(0, 13)}:00`);
  return `/v1/stats/gaps?${params.toString()}`;
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
