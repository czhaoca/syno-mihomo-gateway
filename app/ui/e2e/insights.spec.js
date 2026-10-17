import { expect, test } from "@playwright/test";

import { CADENCE_MS, isDue } from "../src/stats.js";
import { GOLDEN, goldenOverview, json, ready, routeGolden } from "./fixtures/stats.js";

/**
 * Gateway Insights (#101): the scoped views, their routes and their honesty
 * notes, against the GOLDEN picture served the way /v1/stats/overview
 * answers it (fixtures/stats.js `goldenOverview`, whose scoped answers carry
 * the same `null` sections and reasons app/store/stats/overview.py writes).
 *
 * Four specs, the rest of the epic's eight (#100 used three).
 */

const READY = (scope) => `[data-testid="stats-ready"][data-scope="${scope}"]`;

/** A full page load of HASH - never a same-document hash change, so the
 *  readiness marker waited on is the new page's. */
async function land(page, hash = "", scope = null) {
  await page.goto("about:blank");
  await page.goto(`/ui/${hash}`);
  await ready(page, "stats");
  if (scope) await page.locator(READY(scope)).waitFor({ state: "attached" });
}

function statsReads(page) {
  const asked = [];
  page.on("request", (r) => {
    if (r.url().includes("/v1/stats/")) asked.push(r.url());
  });
  return asked;
}

test.describe("Gateway Insights", () => {
  test("a drill keeps its trail, survives a reload, and every list says what it left out",
    async ({ page }) => {
      await routeGolden(page, {}, { domains: true, extraDevices: 12 });
      const asked = statsReads(page);
      await land(page, "", "overview");

      // ten values first; the rest is said (how many), and "show more"
      // asks the one overview read for more (#101 DEC-B)
      const devices = page.locator('[data-testid="stats-top-device-row"]');
      await expect(devices).toHaveCount(10);
      await expect(page.locator('[data-testid="stats-top-device-rest"]'))
        .toHaveAttribute("data-rest", "5");
      await page.locator('[data-testid="stats-more-device"]').click();
      await expect(devices).toHaveCount(15);
      await expect(page.locator('[data-testid="stats-more-device"]')).toHaveCount(0);
      await expect(page.locator('[data-testid="stats-top-device-rest"]')).toHaveCount(0);
      expect(asked.some((url) => /[?&]limit=20(&|$)/.test(url)),
             "show more must raise the overview's own limit").toBe(true);

      // overview -> a client: the route says so, the trail leads back
      await page.locator('[data-testid="stats-top-device-link"][data-key="192.0.2.20"]')
        .click();
      await page.locator(READY("client")).waitFor({ state: "attached" });
      await expect(page).toHaveURL(/#\/insights\/client\/192\.0\.2\.20\?range=7d$/);
      await expect(page.locator('[data-testid="stats-crumb-overview"]'))
        .toHaveAttribute("href", /#\/insights\?range=7d$/);
      await expect(page.locator('[data-testid="stats-crumb-client"]'))
        .toHaveAttribute("aria-current", "page");
      await expect(page.locator('[data-testid="stats-unavailable-top-device"]'))
        .toBeVisible();

      // client -> one of its categories (named "Category", routed `app`):
      // what the stored tables cannot cut by a category is said, not drawn
      await page.locator('[data-testid="stats-top-category-link"][data-key="video"]')
        .click();
      await page.locator(READY("app")).waitFor({ state: "attached" });
      await expect(page).toHaveURL(/\/client\/192\.0\.2\.20\/app\/video\?range=7d$/);
      await expect(page.locator('[data-testid="stats-crumb-app"]'))
        .toContainText("Category video");
      await expect(page.locator('[data-testid="stats-unavailable-top-host"]'))
        .toContainText("separately");
      await expect(page.locator('[data-testid="stats-top-host"]')).toHaveCount(0);

      // back to the client, then on to one of its hostnames
      await page.goBack();
      await page.locator(READY("client")).waitFor({ state: "attached" });
      await page.locator('[data-testid="stats-top-host-link"][data-key="video.example.com"]')
        .click();
      await page.locator(READY("host")).waitFor({ state: "attached" });
      await expect(page).toHaveURL(
        /\/client\/192\.0\.2\.20\/host\/video\.example\.com\?range=7d$/);

      // a reload keeps the scope: it is the URL
      await page.reload();
      await ready(page, "stats");
      await expect(page.locator(READY("host"))).toBeAttached();
      await expect(page.locator('[data-testid="stats-crumb-host"]'))
        .toContainText("video.example.com");
      expect(asked.some((url) => url.includes("device=192.0.2.20")
        && url.includes("host=video.example.com"))).toBe(true);

      // the value counted without a dictionary has a route of its own, and
      // is SENT as an explicit empty category
      await land(page, "#/insights/app/no_dictionary", "app");
      expect(asked.some((url) => /[?&]category=(&|$)/.test(url))).toBe(true);
      await expect(page.locator('[data-testid="stats-crumb-app"]'))
        .toContainText("Before the dictionary");

      // a link this grammar cannot read lands on the overview, never blank -
      // an object's own key names included
      await land(page, "#/insights/app/video/host/x", "overview");
      await land(page, "#/insights/app/video/constructor/q/host/video.example.com",
                 "overview");

      // a host's history in Devices links to its client scope (DEC-C)
      await page.route("**/v1/devices**", (route) => json(route, {
        devices: [{ id: 1, cidr: "192.0.2.20/32", mode: "full-tunnel", name: "",
                    note: "", band_member: false, alias: "" }],
        band: [] }));
      await page.locator('[data-testid="tab-devices"]').click();
      await ready(page, "devices");
      await expect(page).toHaveURL(/#\/devices$/);
      await page.locator('[data-testid="device-history"]').click();
      const link = page.locator('[data-testid="device-insights-192.0.2.20/32"]');
      await expect(link).toHaveAttribute("href", "#/insights/client/192.0.2.20");
      await link.click();
      await page.locator(READY("client")).waitFor({ state: "attached" });
      await expect(page.locator('[data-testid="tab-stats"]'))
        .toHaveAttribute("aria-selected", "true");
    });

  test("the notes say what the numbers cannot", async ({ page }) => {
    await routeGolden(page);
    await land(page, "", "overview");
    // what the gateway cannot see, and why there are no hostnames
    await expect(page.locator('[data-testid="invisible-note"]')).toContainText("IPv6");
    await expect(page.locator('[data-testid="domains-note"]'))
      .toContainText("PANEL_STATS_DOMAINS");
    await expect(page.locator('[data-testid="stats-list-host"]')).toHaveCount(0);
    // a 7-day window starts at the hostname window: nothing to shade
    const shade = page.locator('[data-testid="stats-sparkline-shade"]');
    await expect(shade).toHaveCount(0);

    // 30 days: the span older than the hostname window is a region of its
    // own, labelled - and the bars inside it are still drawn (DEC-G)
    await page.locator('[data-testid="stats-range"]').selectOption("30d");
    await page.locator('[data-testid="stats-ready"][data-range="30d"]')
      .waitFor({ state: "attached" });
    await expect(shade).toHaveAttribute("data-until", "2026-10-05");
    await expect(page.locator('[data-testid="stats-sparkline-legend-shade"]'))
      .toContainText("(7d)");
    await expect(page.locator('[data-testid="stats-sparkline"] [data-mark]'))
      .toHaveCount(12);

    // a category is kept long-term: nothing in it ages out at seven days
    await land(page, "#/insights/app/video?range=30d", "app");
    await expect(shade).toHaveCount(0);

    // a hostname with the class off: no chart, no zero - every section
    // says why it is missing
    await land(page, "#/insights/host/video.example.com", "host");
    await expect(page.locator('[data-testid="stats-chart-frame"]')).toHaveCount(0);
    await expect(page.locator('[data-testid="stats-kpi"]')).toHaveCount(0);
    await expect(page.locator('[data-testid="stats-unavailable-totals"]'))
      .toContainText("PANEL_STATS_DOMAINS");
    await expect(page.locator('[data-testid="domains-note"]')).toBeVisible();

    // with the class on, a hostname's own shade says ITS traffic is not
    // kept there - an empty span is no data, not no traffic
    await page.unrouteAll({ behavior: "ignoreErrors" });
    await routeGolden(page, {}, { domains: true });
    await land(page, "#/insights/host/video.example.com?range=30d", "host");
    await expect(page.locator('[data-testid="stats-sparkline-legend-shade"]'))
      .toContainText("this hostname's traffic is not kept");
    await expect(page.locator('[data-testid="stats-sparkline-before"]')).toHaveCount(0);
  });

  test("one scoped read per tick: paced by resolution, paused while hidden, never piled on",
    async ({ page }) => {
      await page.clock.install({ time: new Date(GOLDEN.now) });
      const reads = [];
      let hold = null;
      let fail = false;
      await routeGolden(page, {
        overview: async (route) => {
          reads.push(route.request().url());
          if (hold) await hold;
          if (fail) return json(route, { detail: "down" }, 503);
          return json(route, goldenOverview(route.request().url()));
        },
      });
      const others = [];
      page.on("request", (r) => {
        if (r.url().includes("/v1/stats/") && !r.url().includes("/v1/stats/overview")) {
          others.push(r.url());
        }
      });
      const quiet = () => page.waitForTimeout(300);
      // the golden answer is day-resolution: re-read every 300 s
      await land(page, "#/insights?range=7d", "overview");
      const base = reads.length;

      await page.clock.runFor(60_000);
      await quiet();
      expect(reads.length, "six shell ticks, none of them due").toBe(base);
      await page.clock.runFor(250_000);
      await expect.poll(() => reads.length).toBe(base + 1);

      // hidden: nothing, however long
      await page.evaluate(() => {
        Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
        document.dispatchEvent(new Event("visibilitychange"));
      });
      await page.clock.runFor(900_000);
      await quiet();
      expect(reads.length, "a hidden page reads nothing").toBe(base + 1);
      // visible again and long due: at once
      await page.evaluate(() => {
        Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
        document.dispatchEvent(new Event("visibilitychange"));
      });
      await expect.poll(() => reads.length).toBe(base + 2);

      // a read that hangs is never piled on, however many ticks fall due
      let release;
      hold = new Promise((resolve) => { release = resolve; });
      await page.clock.runFor(310_000);
      await expect.poll(() => reads.length).toBe(base + 3);
      await page.clock.runFor(1_800_000);
      await quiet();
      expect(reads.length, "thirty minutes of due ticks behind one slow read")
        .toBe(base + 3);
      // ... and the picture says so: a read unanswered that long is stale
      await expect(page.locator('[data-testid="stats-chart-frame-stale"]')).toBeVisible();
      release();
      hold = null;
      await expect(page.locator(READY("overview"))).toBeAttached();
      // ... and once it answers, the stall it described is over
      await expect(page.locator('[data-testid="stats-chart-frame-fresh"]')).toBeAttached();
      expect(others, "Insights reads nothing but the scoped overview").toEqual([]);

      // the real tick drifts by its /health round trip: a minute view's
      // next tick a hair early is still due - every tick reads - while an
      // hour view waits for its sixth
      expect(isDue(9_990, CADENCE_MS.minute)).toBe(true);
      expect(isDue(10_000, CADENCE_MS.hour)).toBe(false);
      expect(isDue(59_960, CADENCE_MS.hour)).toBe(true);
      expect(isDue(49_990, CADENCE_MS.hour)).toBe(false);

      // a view with no answer yet retries at the minute cadence, whatever
      // its resolution: a failed first read of "long term" is retried in
      // ten seconds, not five minutes
      fail = true;
      await land(page, "#/insights/client/192.0.2.20?range=daily", "client");
      await expect(page.locator('[data-testid="stats-chart-frame-unavailable"]'))
        .toBeVisible();
      const failed = reads.length;
      fail = false;
      await page.clock.runFor(10_000);
      await expect.poll(() => reads.length).toBe(failed + 1);
      await expect(page.locator('[data-testid="stats-chart-frame-fresh"]')).toBeAttached();
    });

  test("every scope fits a phone, in both schemes", async ({ page }) => {
    await routeGolden(page, {}, { domains: true, extraDevices: 12 });
    await page.setViewportSize({ width: 390, height: 844 });
    const scopes = [
      ["", "overview"],
      ["#/insights/client/192.0.2.20", "client"],
      ["#/insights/app/video", "app"],
      ["#/insights/host/video.example.com", "host"],
      ["#/insights/client/192.0.2.20/app/video", "app"],
      ["#/insights/client/192.0.2.20/host/video.example.com", "host"],
    ];
    for (const scheme of ["light", "dark"]) {
      await page.emulateMedia({ colorScheme: scheme });
      for (const [hash, scope] of scopes) {
        await land(page, hash, scope);
        const overflow = await page.evaluate(
          () => document.documentElement.scrollWidth
            - document.documentElement.clientWidth);
        expect(overflow, `${hash || "#/insights"} (${scheme}) overflows by ${overflow}px`)
          .toBeLessThanOrEqual(1);
      }
    }
  });
});
