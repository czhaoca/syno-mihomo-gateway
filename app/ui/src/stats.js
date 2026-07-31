/* The stats query vocabulary (#80 DEC-A).

   RANGES is the ONE list shared by the view's selector and the
   `stats_default_range` setting (app/store/settings.py STATS_RANGES). Two
   lists that agree today drift, and a stored default naming a window the UI
   cannot draw would land the operator on a blank tab with nothing saying
   why. A range the panel does not know falls back to the shipped default
   rather than issuing a query for a tier that does not exist. */

export const RANGES = ["48h", "7d", "30d", "daily"];
export const DEFAULT_RANGE = "7d";

// Bucket keys are compared as STRINGS server-side (stats.py read_grouped),
// so `since` has to be truncated to exactly the width the tier writes:
// 13 chars for an hour bucket (`YYYY-MM-DDTHH`), 16 for a minute one.
const SPEC = {
  "48h": { tier: "minute", hours: 48, width: 16 },
  "7d": { tier: "hour", hours: 24 * 7, width: 13 },
  "30d": { tier: "hour", hours: 24 * 30, width: 13 },
  // The day tier keys on a LOCAL calendar date whose boundary the operator
  // sets, so a rolling `since` computed in the browser would disagree with
  // the rows. It asks for the whole tier and lets the server's own framing
  // report say what the window means.
  daily: { tier: "day", hours: null, width: 0 },
};

export function normalizeRange(value) {
  return RANGES.includes(value) ? value : DEFAULT_RANGE;
}

export function rangeQuery(range, now = new Date()) {
  const spec = SPEC[normalizeRange(range)];
  if (spec.hours === null) return { tier: spec.tier, since: "" };
  const from = new Date(now.getTime() - spec.hours * 3600 * 1000);
  return { tier: spec.tier, since: from.toISOString().slice(0, spec.width) };
}

export function statsPath(base, range, extra = {}) {
  const { tier, since } = rangeQuery(range);
  const params = new URLSearchParams({ tier, ...extra });
  if (since) params.set("since", since);
  return `${base}?${params.toString()}`;
}

/* `/v1/stats/coverage` takes since/until but NO tier - attribution lives in
   one 7-day table. The window still has to be sent: the report is capped at
   7 days by construction, so a 30-day request cannot widen it, but it is
   what makes the server answer `truncated: true`. Without it the panel would
   show a 7-day percentage beside a 30-day table and claim nothing was
   missing. */
export function coveragePath(range) {
  const { since } = rangeQuery(range);
  return since ? `/v1/stats/coverage?since=${encodeURIComponent(since)}`
               : "/v1/stats/coverage";
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
