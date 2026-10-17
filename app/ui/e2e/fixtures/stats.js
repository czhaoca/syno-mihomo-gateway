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
 *
 * The gateway widgets (#103) read their own synthesised answers:
 * `goldenNodeDelay` serves /v1/stats/node-delay from one list of raw tests
 * (DELAY_TESTS) the way app/store/stats/node_delay.py reads them - the
 * tests themselves at a minute preset, hour aggregates at a longer one -
 * and GOLDEN_QUOTA is a /v1/stats/quota answer. Group and node names are
 * placeholders, long and CJK/emoji on purpose (the 390 px sweep).
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

// The delay history (#103): every test mihomo "ran", oldest first, as
// [group, node, tested_at, delay_ms] - null is a failed test. Chosen so the
// picture holds each rule the widget must keep:
//   - "Proxy": a failed test (10:05), a slot with no test (10:15), a switch
//     inside one 5-minute slot (10:20 JP 01, 10:21 US 01) and so, at hour
//     resolution, an hour where JP 01 partly failed beside US 01;
//   - "Fallback": its newest test failed - "no answer", never 0 ms;
//   - "Games": tested once, 12 days ago - outside 48h and 7d, inside 30d;
//   - "Telegram": every test failed - a null-delay hour.
export const DELAY_RETENTION_DAYS = 14;
const LONG_CJK = "节点选择（这是一个用于测试换行的非常非常长的策略组名称）";
const LONG_EMOJI = "🚀 Emoji 🚀 group with a very long name that has to wrap on a phone";
export const DELAY_TESTS = [
  ["Games", "SG 03", "2026-09-30T08:00:00Z", 60],
  ["Proxy", "JP 01", "2026-10-12T10:00:00Z", 120],
  ["Proxy", "JP 01", "2026-10-12T10:05:00Z", null],
  ["Proxy", "JP 01", "2026-10-12T10:10:00Z", 130],
  ["Proxy", "JP 01", "2026-10-12T10:20:00Z", 125],
  ["Proxy", "US 01", "2026-10-12T10:21:00Z", 210],
  ["Proxy", "US 01", "2026-10-12T10:25:00Z", 206],
  ["AI", "JP 01", "2026-10-12T11:00:00Z", 150],
  ["Fallback", "HK 02", "2026-10-12T11:00:00Z", 90],
  ["AI", "JP 01", "2026-10-12T11:05:00Z", 160],
  ["Fallback", "HK 02", "2026-10-12T11:05:00Z", null],
  ["AI", "US 01", "2026-10-12T11:10:00Z", 180],
  ["Fallback", "HK 02", "2026-10-12T11:10:00Z", null],
  ["AI", "US 01", "2026-10-12T11:15:00Z", 175],
  [LONG_EMOJI, "🇯🇵 JP 01", "2026-10-12T11:20:00Z", 140],
  ["Telegram", "SG 03", "2026-10-12T11:30:00Z", null],
  ["Telegram", "SG 03", "2026-10-12T11:35:00Z", null],
  ["♻️ 自动选择", "HK 02", "2026-10-12T11:40:00Z", 80],
  [LONG_CJK, "日本 东京 01 - 一个很长的节点名称用于测试换行", "2026-10-12T11:45:00Z", 95],
  ["Proxy", "US 01", "2026-10-12T11:50:00Z", 200],
  ["Streaming", "JP 01", "2026-10-12T11:55:00Z", 300],
];
const RANGE_HOURS = { "24h": 24, "48h": 48, "7d": 168, "30d": 720, daily: null };
const stamp = (ms) => `${new Date(ms).toISOString().slice(0, 19)}Z`;

/** The node delay answer for URL (a /v1/stats/node-delay request): the
 *  window starts at the later of the preset's start and the retention
 *  horizon, `truncated` when the preset reached past it; a minute preset
 *  lists the tests, a longer one aggregates them per hour and node (a
 *  failed test counted, never averaged in). Groups sort by name and every
 *  group's `latest` is its newest test, wherever it falls. */
export function goldenNodeDelay(url, { tests = DELAY_TESTS,
                                       retentionDays = DELAY_RETENTION_DAYS } = {}) {
  const range = new URL(url).searchParams.get("range") || "7d";
  const hours = RANGE_HOURS[range] === undefined ? 168 : RANGE_HOURS[range];
  const now = Date.parse(GOLDEN.now);
  const floor = now - retentionDays * 86_400_000;
  const start = hours === null ? floor : Math.max(now - hours * 3_600_000, floor);
  const since = stamp(start);
  const raw = range === "24h" || range === "48h";
  const groups = new Map();
  const group = (name) => {
    if (!groups.has(name)) groups.set(name, { group: name, latest: null, points: [] });
    return groups.get(name);
  };
  for (const [grp, node, at, ms] of tests) {
    group(grp).latest = { node, tested_at: at, delay_ms: ms };
  }
  const inside = tests.filter(([, , at]) => at >= since);
  if (raw) {
    const ordered = inside.slice().sort((a, b) => (a[2] < b[2] ? -1 : a[2] > b[2] ? 1
      : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
    for (const [grp, node, at, ms] of ordered) {
      group(grp).points.push({ at, node, delay_ms: ms });
    }
  } else {
    const hoursOf = new Map();
    for (const [grp, node, at, ms] of inside) {
      const key = `${grp}\u0000${at.slice(0, 13)}\u0000${node}`;
      if (!hoursOf.has(key)) hoursOf.set(key, { grp, node, hour: at.slice(0, 13), ok: [], failed: 0 });
      const slot = hoursOf.get(key);
      if (ms === null) slot.failed += 1;
      else slot.ok.push(ms);
    }
    const keys = [...hoursOf.keys()].sort();
    for (const key of keys) {
      const { grp, node, hour, ok, failed } = hoursOf.get(key);
      group(grp).points.push({
        at: hour, node,
        delay_ms: ok.length ? Math.round(ok.reduce((s, v) => s + v, 0) / ok.length) : null,
        min_ms: ok.length ? Math.min(...ok) : null,
        max_ms: ok.length ? Math.max(...ok) : null,
        tests: ok.length, failed,
      });
    }
  }
  const byName = (a, b) => {
    const x = [...a.group].map((c) => c.codePointAt(0));
    const y = [...b.group].map((c) => c.codePointAt(0));
    for (let i = 0; i < Math.min(x.length, y.length); i += 1) {
      if (x[i] !== y[i]) return x[i] - y[i];
    }
    return x.length - y.length;
  };
  return { range, resolution: raw ? "test" : "hour", retention_days: retentionDays,
           since, truncated: hours === null || now - hours * 3_600_000 < floor,
           sampled_every_s: 300, groups: [...groups.values()].sort(byName) };
}

/** A /v1/stats/quota answer: one provider with a limit and an expiry, one
 *  that reports neither (mihomo's zero-fill, served as null), one past both
 *  its total and its expiry, and one with half its use unreported. */
export const GOLDEN_QUOTA = {
  state: "ok", sampled_at: "2026-10-12T11:00:00Z",
  providers: [
    { provider: "provider-a", upload: 1_073_741_824, download: 9_663_676_416,
      total: 107_374_182_400, expire: 1_798_761_600, updatedAt: "2026-10-12T10:58:00Z" },
    { provider: "provider-b 一个很长的提供者名称", upload: 0, download: 5_368_709_120,
      total: null, expire: null, updatedAt: null },
    { provider: "provider-c", upload: 0, download: 161_061_273_600,
      total: 107_374_182_400, expire: 1_767_225_600, updatedAt: "2026-10-12T10:30:00Z" },
    { provider: "provider-d", upload: null, download: 1_073_741_824,
      total: 107_374_182_400, expire: null, updatedAt: null },
  ],
};

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
 *  a path fragment ("overview", "health", "nodeDelay", "quota", ...) to a
 *  route handler, for the specs that break one read on purpose; OPTIONS go
 *  to goldenOverview. The live stream is never stubbed here: a spec that
 *  opens it routes it itself, and an unrouted one fails loudly. */
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
  await page.route("**/v1/stats/node-delay**", async (route) => (overrides.nodeDelay
    ? overrides.nodeDelay(route)
    : json(route, goldenNodeDelay(route.request().url()))));
  await page.route("**/v1/stats/quota**", serve("quota", GOLDEN_QUOTA));
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
