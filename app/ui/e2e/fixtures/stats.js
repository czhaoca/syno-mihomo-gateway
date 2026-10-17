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

function json(route, body, status = 200) {
  return route.fulfill({ status, contentType: "application/json",
                         body: JSON.stringify(body) });
}

/** Serve the golden series for every stats read and /health. OVERRIDES maps
 *  a path fragment ("timeline", "health", ...) to a route handler, for the
 *  specs that break one read on purpose. */
export async function routeGolden(page, overrides = {}) {
  const serve = (name, body) => async (route) => (overrides[name]
    ? overrides[name](route) : json(route, body));
  await page.route("**/health", serve("health", GOLDEN.health));
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
