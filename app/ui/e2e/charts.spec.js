import { expect, test } from "@playwright/test";

import { GOLDEN, openStats, ready, routeGolden } from "./fixtures/stats.js";

/**
 * The chart kit (#100), against the GOLDEN series (fixtures/stats.js) on the
 * real stats view. Marks are counted and read through their data-attributes
 * - never by pixel - and every honesty rule is a separate assertion: a gap
 * is a band without a value, a missing bucket with no gap is a zero, a
 * moved day boundary is one seam, and the unattributed share is always
 * drawn.
 */

const SERIES = '[data-testid="stats-sparkline"]';

function json(route, body, status = 200) {
  return route.fulfill({ status, contentType: "application/json",
                         body: JSON.stringify(body) });
}

test.describe("the chart kit draws the golden series honestly", () => {
  // the golden "now": the axis ends where the series does, whatever day
  // the suite runs on, and the panel's refresh tick is driven by the spec
  test.beforeEach(async ({ page }) => {
    await page.clock.install({ time: new Date(GOLDEN.now) });
  });

  test("every bucket, the gap, the zero, the seam and the shares", async ({
    page,
  }) => {
    let series = GOLDEN.timeline;
    await routeGolden(page, { timeline: (route) => json(route, series) });
    await openStats(page, "daily");
    await expect(page.locator('[data-testid="stats-chart-frame-fresh"]'))
      .toBeAttached();

    const marks = page.locator(`${SERIES} [data-mark]`);
    await expect(marks).toHaveCount(12);
    // the gap: one value-less band, on the day the gap fell in
    const gap = page.locator(`${SERIES} [data-gap="full"]`);
    await expect(gap).toHaveCount(1);
    await expect(gap).toHaveAttribute("data-bucket", "2026-10-08");
    expect(await gap.getAttribute("data-up"),
           "a gap carries no value - it is not a zero").toBeNull();
    await expect(page.locator(`${SERIES} [data-gap="partial"]`)).toHaveCount(0);
    // the missing day without a gap: a real zero
    const zero = page.locator(`${SERIES} [data-bucket="2026-10-10"][data-mark]`);
    await expect(zero).toHaveAttribute("data-up", "0");
    await expect(zero).toHaveAttribute("data-gap", "");
    // the day boundary moved once
    await expect(page.locator(`${SERIES} [data-seam="true"]`)).toHaveCount(1);
    await expect(page.locator(`${SERIES} [data-seam="true"]`))
      .toHaveAttribute("data-bucket", "2026-10-06");
    await expect(page.locator('[data-testid="stats-sparkline-legend-gap"]'))
      .toBeVisible();
    await expect(page.locator('[data-testid="stats-sparkline-legend-seam"]'))
      .toBeVisible();

    // the keyboard reaches every mark, and the tooltip names it
    await page.locator('[data-testid="stats-sparkline-focus"]').focus();
    await page.keyboard.press("End");
    await expect(page.locator('[data-testid="stats-sparkline-tooltip"]'))
      .toContainText("2026-10-12");
    await page.keyboard.press("Home");
    await page.keyboard.press("ArrowRight");
    await expect(page.locator('[data-testid="stats-sparkline-tooltip"]'))
      .toContainText("2026-10-02");

    // the unattributed share is drawn and labelled; a zero class is still
    // only shown when it is permanent
    const share = page.locator('[data-testid="stats-share-label-unattributed"]');
    await expect(share).toContainText("53.3%");
    await expect(page.locator('[data-testid="stats-share-unattributed"]'))
      .toHaveAttribute("data-share", "53.3");
    await expect(page.locator('[data-testid="stats-share-app"]')).toHaveCount(0);

    // the top devices, largest first
    const top = page.locator('[data-testid="stats-top-row"]');
    await expect(top).toHaveCount(GOLDEN.devices.rows.length);
    await expect(top.first()).toHaveAttribute("data-key", "192.0.2.20");

    // the populated charts fit a phone in BOTH schemes, and the scheme
    // reaches the chart's own tokens, not just the page
    await page.setViewportSize({ width: 390, height: 844 });
    const surfaces = [];
    for (const scheme of ["light", "dark"]) {
      await page.emulateMedia({ colorScheme: scheme });
      await openStats(page, "daily");
      await page.locator('[data-testid="stats-sparkline-focus"]').focus();
      await page.keyboard.press("End");
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth
          - document.documentElement.clientWidth);
      expect(overflow, `the golden charts (${scheme}) overflow by ${overflow}px`)
        .toBeLessThanOrEqual(1);
      surfaces.push(await page.locator(SERIES).evaluate(
        (el) => getComputedStyle(el).backgroundColor));
    }
    expect(surfaces[0], "the dark scheme must repaint the chart itself")
      .not.toEqual(surfaces[1]);

    // a periodic refresh that returns FEWER buckets while one is selected
    // keeps that same bucket selected - never another one, and never an
    // index past the end (which took the whole panel down)
    await expect(page.locator('[data-testid="stats-sparkline-tooltip"]'))
      .toContainText("2026-10-12");
    series = { ...GOLDEN.timeline, rows: GOLDEN.timeline.rows.slice(5) };
    await page.clock.runFor(10_000);
    await expect(marks).toHaveCount(7);
    await expect(page.locator('[data-testid="app-shell"]')).toBeAttached();
    await expect(page.locator('[data-testid="stats-sparkline-tooltip"]'))
      .toContainText("2026-10-12");
  });

  test("the frame says when a chart cannot be trusted", async ({ page }) => {
    // no answer at all: nothing is drawn, and it is not "no traffic"
    await routeGolden(page, {
      timeline: (route) => route.fulfill({
        status: 503, contentType: "application/json",
        body: '{"detail":"stats store unavailable"}' }),
    });
    await openStats(page, "daily");
    await expect(page.locator('[data-testid="stats-chart-frame-unavailable"]'))
      .toBeVisible();
    await expect(page.locator(SERIES)).toHaveCount(0);
    await page.unrouteAll({ behavior: "ignoreErrors" });

    // an answer with nothing in it: empty, said so
    await routeGolden(page, {
      timeline: (route) => route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify({ tier: "day", device: "", rows: [] }) }),
    });
    await openStats(page, "daily");
    await expect(page.locator('[data-testid="stats-chart-frame-empty"]'))
      .toBeVisible();
    await page.unrouteAll({ behavior: "ignoreErrors" });

    // a good answer, then a refresh that fails: the picture stays, marked
    // stale, never retracted into "unavailable"
    const before = GOLDEN.health.collector_last_ts;
    let fail = false;
    let polled = before;
    let told;
    const toldNewer = new Promise((resolve) => { told = resolve; });
    await routeGolden(page, {
      health: async (route) => {
        await json(route, { ...GOLDEN.health, collector_last_ts: polled });
        if (polled !== before) told();
      },
      timeline: async (route) => {
        if (!fail) return json(route, GOLDEN.timeline);
        // the failure lands only once the newer poll has been reported
        if (polled !== before) await toldNewer;
        return json(route, { detail: "down" }, 503);
      },
    });
    // on the LANDING range, read once only: its load must already know the
    // poll its data includes
    await page.goto("/ui/");
    await ready(page, "stats");
    await expect(page.locator('[data-testid="stats-chart-frame-fresh"]'))
      .toBeAttached();
    fail = true;
    await page.locator('[data-testid="stats-refresh"]').click();
    await expect(page.locator('[data-testid="stats-chart-frame-stale"]'))
      .toContainText(before);
    await expect(page.locator(`${SERIES} [data-mark]`)).toHaveCount(12);

    // two days on, the collector still polling and the reads still failing:
    // nothing after the last good read is filled in - not one zero - the
    // span is the stale band, and "since" stays the poll that read saw
    polled = "2026-10-14T11:59:58Z";
    await page.clock.fastForward("48:00:00");
    await expect(page.locator('[data-testid="stats-sparkline-stale-band"]'))
      .toBeAttached();
    await expect(page.locator(`${SERIES} [data-mark]`)).toHaveCount(12);
    await expect(page.locator('[data-testid="stats-chart-frame-stale"]'))
      .toContainText(before);
    await expect(page.locator('[data-testid="stats-chart-frame-stale"]'))
      .not.toContainText(polled);
    await page.unrouteAll({ behavior: "ignoreErrors" });

    // the collector itself stopped: the last answer is shown, stale since
    // its last poll
    await routeGolden(page, {
      health: (route) => route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify({ ...GOLDEN.health, collector: "stale" }) }),
    });
    await openStats(page, "daily");
    await expect(page.locator('[data-testid="stats-chart-frame-stale"]'))
      .toContainText(GOLDEN.health.collector_last_ts);
  });
});
