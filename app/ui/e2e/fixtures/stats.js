/**
 * Shared browser-spec fixtures (#100): the readiness wait every spec opens
 * the panel with, and the GOLDEN stats series the chart specs draw - and
 * #101's Insights views will draw too, so both slices assert against one
 * known picture.
 *
 * The golden series is SYNTHESISED (TEST-NET addresses only; the privacy
 * gate scans the full history, so nothing here may ever be captured from a
 * real gateway). Twelve local days, 2026-10-01 .. 2026-10-12, read at day
 * resolution:
 *   - ten days hold traffic;
 *   - 2026-10-08 has no row and a collection gap inside it: a hatched band,
 *     never a zero (under its framing the gap falls in that day alone);
 *   - 2026-10-10 has no row and no gap: a real zero;
 *   - the day boundary moves on 2026-10-06 (UTC 00:00 -> Asia/Shanghai
 *     03:00): one seam;
 *   - the coverage report's dictionary partition carries an unattributed
 *     share, the permanent segment.
 *
 * `goldenOverview` serves the same picture as /v1/stats/overview answers it
 * (#101): per scope, with the sections a scope cannot answer `null` and the
 * reason under `unavailable` - the shapes app/store/stats/overview.py
 * writes. The lists add up to the timeline: 200 B up, 2000 B down.
 */
import { expect } from "@playwright/test";

/** Wait until the shell and the TAB say they are ready (#100 DEC-C): the
 *  shell has its dictionary and a first /health answer, the view's newest
 *  load for its current input has settled. The markers are hidden, so they
 *  are waited for as attached. */
export async function ready(page, tab = "stats") {
  await page.locator('[data-testid="app-ready"]')
    .waitFor({ state: "attached" });
  await page.locator(`[data-testid="${tab}-ready"]`)
    .waitFor({ state: "attached" });
}

const UTC = { bucket_tz: "UTC", day_boundary: "00:00" };
const SH = { bucket_tz: "Asia/Shanghai", day_boundary: "03:00" };

function day(n, up, down, frame) {
  return { bucket: `2026-10-${String(n).padStart(2, "0")}`, up, down, ...frame };
}

export const GOLDEN = {
  now: "2026-10-12T12:00:00Z",
  health: {
    db_ok: true, parity: "ok", last_apply: null, marker: false,
    collector: "ok", collector_last_ts: "2026-10-12T11:59:58Z",
    stats_db_bytes: 1048576, dashboard_port: 8080,
    collector_lag_s: 2, collector_poll_ms: 4, collector_conns: 12,
    collector_failed_polls: 0, collector_interval_s: 2, stats_cap_mb: 512,
    stats_db_growth_mb_day: 0.5, mihomo_mem_mb: 140, mihomo_version: "v1.19.32",
    day_tz: "Asia/Shanghai", day_cut: "03:00", day_framing: "ok",
  },
  timeline: {
    tier: "day", device: "",
    rows: [
      day(1, 10, 100, UTC), day(2, 20, 200, UTC), day(3, 15, 150, UTC),
      day(4, 30, 300, UTC), day(5, 25, 250, UTC),
      day(6, 12, 120, SH), day(7, 18, 180, SH),
      // 2026-10-08: no row, a gap inside it
      day(9, 22, 220, SH),
      // 2026-10-10: no row, no gap - a real zero
      day(11, 40, 400, SH), day(12, 8, 80, SH),
    ],
  },
  devices: {
    tier: "day",
    rows: [
      { device: "192.0.2.20", up: 120, down: 1200 },
      { device: "192.0.2.21", up: 60, down: 600 },
      { device: "198.51.100.7", up: 20, down: 200 },
    ],
    framings: [{ bucket_tz: "Asia/Shanghai", day_boundary: "03:00" },
               { bucket_tz: "UTC", day_boundary: "00:00" }],
  },
  gaps: {
    rows: [{ started: "2026-10-08T10:00:00Z", ended: "2026-10-08T12:00:00Z",
             reason: "no poll for 7200s" }],
  },
  coverage: {
    total: { up: 200, down: 2000 },
    classes: [{ klass: "hostname", up: 94, down: 934, share: 46.7 },
              { klass: "ip_only", up: 106, down: 1066, share: 53.3 }],
    rules: [],
    window: { requested_since: "", requested_until: "", oldest_bucket: "2026-10-05T00",
              retention_days: 7, truncated: false },
    dictionary: {
      version: "test", error: null, app_ids_kept: false, oldest_bucket: "2026-10-05T00",
      total: { up: 200, down: 2000 },
      classes: [{ klass: "app", up: 0, down: 0, share: 0 },
                { klass: "coarse", up: 94, down: 934, share: 46.7 },
                { klass: "unattributed", up: 106, down: 1066, share: 53.3 },
                { klass: "no_dictionary", up: 0, down: 0, share: 0 }],
    },
  },
};

export function json(route, body, status = 200) {
  return route.fulfill({ status, contentType: "application/json",
                         body: JSON.stringify(body) });
}

const EXITS = [{ value: "JP 01", up: 140, down: 1400 },
               { value: "US 01", up: 60, down: 600 }];
const COUNTRIES = [{ value: "JP", up: 140, down: 1400 },
                   { value: "US", up: 60, down: 600 }];
const CATEGORIES = [{ value: "unknown", class: "unattributed", up: 106, down: 1066 },
                    { value: "video", class: "coarse", up: 80, down: 800 },
                    { value: "", class: "no_dictionary", up: 14, down: 134 }];
const HOSTS = [{ value: "video.example.com", up: 60, down: 600 },
               { value: "cdn.example.org", up: 34, down: 334 }];
// the hostname class's floor at GOLDEN.now: seven days back, an hour key
const HOST_FLOOR = "2026-10-05T12";
const INDEPENDENT = (scope) => ("the dimensions are stored independently, so "
  + `this breakdown cannot be cut by ${scope}`);
const DOMAINS_OFF = ("the hostname class is off (PANEL_STATS_DOMAINS), so no "
  + "per-host traffic is kept");

function list(dim, rows, limit, extra = {}) {
  const sorted = rows.slice().sort((a, b) => (b.up + b.down) - (a.up + a.down));
  return {
    dim, tier: "day", sort: "total", limit, offset: 0,
    rows: sorted.slice(0, limit), total_rows: sorted.length,
    total: { up: sorted.reduce((s, r) => s + r.up, 0),
             down: sorted.reduce((s, r) => s + r.down, 0) },
    window: { oldest_bucket: "2026-10-01T00", truncated: false },
    ...extra,
  };
}

function scaled(rows, share) {
  return rows.map((r) => ({ ...r, up: Math.round(r.up * share),
                            down: Math.round(r.down * share) }));
}

/** The overview answer for URL (a /v1/stats/overview request) over the
 *  golden picture. OPTIONS: `timeline` replaces the series, `extraDevices`
 *  adds that many small TEST-NET devices (for "show more"), `domains`
 *  turns the hostname class on. */
export function goldenOverview(url, { timeline = GOLDEN.timeline, extraDevices = 0,
                                      domains = false } = {}) {
  const q = new URL(url).searchParams;
  const range = q.get("range") || "7d";
  const limit = Math.min(Math.max(Number(q.get("limit")) || 10, 1), 200);
  const device = q.get("device") || "";
  const category = q.has("category") ? q.get("category") : null;
  const host = q.get("host");
  const devices = [
    ...GOLDEN.devices.rows.map((r) => ({ value: r.device, up: r.up, down: r.down })),
    ...Array.from({ length: extraDevices }, (_v, i) => ({
      value: `203.0.113.${i + 1}`, up: 1, down: 2 })),
  ];
  const unavailable = {};
  const top = { device: null, exit: null, category: null, country: null, host: null };
  const hostList = domains
    ? list("host", HOSTS, limit, { enabled: true,
                                   window: { since: HOST_FLOOR, retention_days: 7,
                                             oldest_bucket: HOST_FLOOR,
                                             truncated: true } })
    : { dim: "host", tier: "hour", sort: "total", limit, offset: 0, enabled: false,
        rows: [], total_rows: 0, total: { up: 0, down: 0 },
        window: { retention_days: 7 } };
  let share = 1;
  let rows = timeline.rows;
  let totalsWindow = null;
  if (host !== null && !domains) {
    for (const key of ["totals", "timeline", "top.device", "top.exit",
                       "top.category", "top.country", "top.host"]) {
      unavailable[key] = DOMAINS_OFF;
    }
    rows = null;
  } else if (host !== null || category !== null) {
    const kind = host !== null ? "one host" : "one category";
    const value = host !== null ? HOSTS.find((h) => h.value === host)
      : CATEGORIES.find((c) => c.value === category);
    share = value ? (value.up + value.down) / 2200 : 0;
    if (host !== null) {
      rows = rows.filter((r) => r.bucket >= HOST_FLOOR.slice(0, 10));
      totalsWindow = { since: HOST_FLOOR, retention_days: 7,
                       oldest_bucket: HOST_FLOOR, truncated: true };
    } else {
      totalsWindow = { oldest_bucket: "2026-10-01T00", truncated: false };
    }
    if (device) unavailable["top.device"] = "scoped to one device";
    else top.device = list("device", scaled(devices, share), limit);
    for (const dim of ["exit", "country"]) unavailable[`top.${dim}`] = INDEPENDENT(kind);
    if (host !== null) {
      unavailable["top.category"] = INDEPENDENT(kind);
      unavailable["top.host"] = "scoped to one host";
    } else {
      unavailable["top.category"] = "scoped to one category";
      unavailable["top.host"] = INDEPENDENT(kind);
    }
  } else {
    if (device) {
      const own = devices.find((d) => d.value === device);
      share = own ? (own.up + own.down) / 2200 : 0;
      unavailable["top.device"] = "scoped to one device";
    } else {
      top.device = list("device", devices, limit);
    }
    top.exit = list("exit", scaled(EXITS, share), limit,
                    { unrecorded: { up: 0, down: 0 } });
    top.category = list("category", scaled(CATEGORIES, share), limit);
    top.country = list("country", scaled(COUNTRIES, share), limit);
    top.host = hostList;
  }
  if (rows) rows = scaled(rows, share);
  const tier = timeline.tier;
  const body = {
    range,
    scope: { device, category, host },
    totals: rows ? { tier, up: rows.reduce((s, r) => s + r.up, 0),
                     down: rows.reduce((s, r) => s + r.down, 0),
                     ...(totalsWindow ? { window: totalsWindow } : {}) } : null,
    timeline: rows ? { tier, rows } : null,
    top, unavailable,
    gaps: GOLDEN.gaps.rows, gaps_truncated: false,
    coverage: null,
    invisible_traffic_hint: { code: "gateway_only", text: "Only traffic that "
      + "passes through the gateway is counted." },
  };
  if (tier === "day") body.framings = GOLDEN.devices.framings;
  if (device || category !== null || host !== null) {
    unavailable.coverage = "coverage is measured for the whole gateway only, not per scope";
  } else {
    body.coverage = GOLDEN.coverage;
  }
  return body;
}

/** A minimal overview answer: DEVICES [{value, up, down}] as the device list
 *  and nothing else - for the specs that only care whose rows are shown. */
export function plainOverview(range, devices) {
  const up = devices.reduce((s, r) => s + r.up, 0);
  const down = devices.reduce((s, r) => s + r.down, 0);
  return {
    range, scope: { device: "", category: null, host: null },
    totals: { tier: "day", up, down },
    timeline: { tier: "day", rows: [] },
    top: { device: list("device", devices, 10), exit: null, category: null,
           country: null, host: null },
    unavailable: {}, gaps: [], gaps_truncated: false, coverage: null,
    invisible_traffic_hint: { code: "gateway_only", text: "" },
  };
}

/** Serve the golden series for every stats read and /health. OVERRIDES maps
 *  a path fragment ("overview", "health", ...) to a route handler, for the
 *  specs that break one read on purpose; OPTIONS go to goldenOverview. */
export async function routeGolden(page, overrides = {}, options = {}) {
  const serve = (name, body) => async (route) => (overrides[name]
    ? overrides[name](route) : json(route, body));
  await page.route("**/health", serve("health", GOLDEN.health));
  await page.route("**/v1/stats/overview**", async (route) => (overrides.overview
    ? overrides.overview(route)
    : json(route, goldenOverview(route.request().url(), options))));
  await page.route("**/v1/stats/timeline**", serve("timeline", GOLDEN.timeline));
  await page.route("**/v1/stats/devices**", serve("devices", GOLDEN.devices));
  await page.route("**/v1/stats/gaps**", serve("gaps", GOLDEN.gaps));
  await page.route("**/v1/stats/coverage**", serve("coverage", GOLDEN.coverage));
  await page.route("**/v1/stats/domains**",
                   serve("domains", { enabled: false, rows: [] }));
}

/** Open the panel's stats tab on RANGE and wait until that load settled. */
export async function openStats(page, range = "daily") {
  await page.goto("/ui/");
  await ready(page, "stats");
  await page.locator('[data-testid="stats-range"]').selectOption(range);
  await page.locator(`[data-testid="stats-ready"][data-range="${range}"]`)
    .waitFor({ state: "attached" });
  await expect(page.locator('[data-testid="stats-range"]')).toHaveValue(range);
}
