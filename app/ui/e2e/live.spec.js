import { expect, test } from "@playwright/test";

import { GOLDEN, GOLDEN_QUOTA, goldenNodeDelay, json, ready,
         routeGolden } from "./fixtures/stats.js";

/**
 * The gateway view's widgets (#103): the live throughput tile, the node
 * delay history and the subscription quota - against stubs only. The live
 * stream is a `text/event-stream` fulfilled by `page.route` (DEC-A..C):
 * its frames are the relay's own shape, and its `retry:` long enough that
 * the browser never reconnects on its own inside a test - except where a
 * spec asks for one reconnect, and then holds it until it is ready. Each
 * stream ends with a `: ping`, which EventSource never surfaces: the tile
 * must go stale after it all the same. A wrapper around the page's
 * EventSource counts the streams still open, so "hidden closes it" is
 * asserted on the stream itself rather than on a request log.
 */

// stamped to the whole second as the relay stamps them: two share a second
// and one skips one, the jitter of a 1 s cadence - never a hole
const FRAMES = [
  { ts: "2026-10-12T11:59:57Z", up_bps: 600, down_bps: 48000 },
  { ts: "2026-10-12T11:59:58Z", up_bps: 1200, down_bps: 56000 },
  { ts: "2026-10-12T11:59:58Z", up_bps: 2400, down_bps: 64000 },
  { ts: "2026-10-12T12:00:00Z", up_bps: 3600, down_bps: 72000 },
];
// what a reconnect brings, seven seconds on
const RECOVERED = [{ ts: "2026-10-12T12:00:07Z", up_bps: 4800, down_bps: 80000 }];
const stream = (frames, retry = 600_000) => `retry: ${retry}\n\n${frames
  .map((f) => `data: ${JSON.stringify(f)}\n\n`).join("")}: ping\n\n`;
const FULL = "retry: 600000\nevent: full\ndata: {}\n\n";

/** Serve /v1/stats/live by MODE.now ("stream", "full", "down"). With
 *  MODE.firstRetry the first stream asks the browser to reconnect that
 *  soon, and with MODE.hold that reconnect waits for the promise, then
 *  brings RECOVERED. */
async function routeLive(page, mode) {
  const asked = [];
  await page.route("**/v1/stats/live**", async (route) => {
    asked.push(route.request().url());
    const n = asked.length;
    if (mode.now === "down") return route.fulfill({ status: 503, body: "" });
    let body = mode.now === "full" ? FULL : stream(FRAMES);
    if (mode.now === "stream" && n === 1 && mode.firstRetry) {
      body = stream(FRAMES, mode.firstRetry);
    } else if (mode.now === "stream" && n === 2 && mode.hold) {
      await mode.hold;
      body = stream(RECOVERED);
    }
    return route.fulfill({
      status: 200, headers: { "content-type": "text/event-stream",
                              "cache-control": "no-store" }, body });
  });
  return asked;
}

/** Count the page's EventSources that are still open (not closed). */
async function watchStreams(page) {
  await page.addInitScript(() => {
    const Native = window.EventSource;
    const open = new Set();
    window.openStreams = () => open.size;
    window.EventSource = class extends Native {
      constructor(...args) {
        super(...args);
        open.add(this);
      }

      close() {
        open.delete(this);
        super.close();
      }
    };
  });
}

async function land(page, hash = "") {
  await page.goto("about:blank");
  await page.goto(`/ui/${hash}`);
  await ready(page, "stats");
}

async function setHidden(page, hidden) {
  await page.evaluate((value) => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => value });
    document.dispatchEvent(new Event("visibilitychange"));
  }, hidden);
}

const openStreams = (page) => page.evaluate(() => window.openStreams());
const overflowOf = (page) => page.evaluate(
  () => document.documentElement.scrollWidth - document.documentElement.clientWidth);

test.describe("the gateway widgets", () => {
  test("the live tile is off until this browser opts in, then streams, says when it is stale, and remembers",
    async ({ page }) => {
      await page.clock.install({ time: new Date(GOLDEN.now) });
      await watchStreams(page);
      await routeGolden(page);
      let release;
      const mode = { now: "stream", firstRetry: 1_000,
                     hold: new Promise((resolve) => { release = resolve; }) };
      const asked = await routeLive(page, mode);
      await land(page);

      // off by default: no stream at all, and the tile says nothing it
      // shows is stored whatever its state
      const toggle = page.locator('[data-testid="live-toggle"]');
      const sparkMarks = page.locator('[data-testid="live-sparkline"] [data-mark="1"][data-gap=""]');
      const sparkHoles = page.locator('[data-testid="live-sparkline"] [data-gap="full"]');
      await expect(toggle).not.toBeChecked();
      await expect(page.locator('[data-testid="live-not-stored"]')).toBeVisible();
      await page.waitForTimeout(300);
      expect(asked, "no stream opens until the browser opts in").toEqual([]);
      expect(await openStreams(page)).toBe(0);

      // on: one stream, the newest figures, the minute's sparkline
      await toggle.check();
      await expect(page.locator('[data-testid="live-rate-up"]'))
        .toHaveAttribute("data-bps", "3600");
      await expect(page.locator('[data-testid="live-rate-down"]'))
        .toHaveAttribute("data-bps", "72000");
      await expect(sparkMarks).toHaveCount(FRAMES.length);
      await expect(sparkHoles).toHaveCount(0);
      // every mark is reachable, the two sharing a second included, and
      // each names its own rates, per second
      await page.locator('[data-testid="live-sparkline-focus"]').focus();
      await page.keyboard.press("ArrowRight");
      await page.keyboard.press("ArrowRight");
      await expect(page.locator('[data-testid="live-sparkline-tooltip"]'))
        .toContainText("Up: 2.3 KB/s");
      await page.keyboard.press("Escape");
      expect(new URL(asked[0]).search, "the stream takes no query").toBe("");
      expect(await openStreams(page)).toBe(1);

      // the stream goes quiet (its last word a ping): how long, counting
      // up - never the old rates or the old minute as if current
      await page.clock.runFor(4_000);
      const stale = page.locator('[data-testid="live-stale"]');
      await expect(stale).toBeVisible();
      await expect(stale).toContainText("No new figures for");
      const first = Number(await stale.getAttribute("data-seconds"));
      expect(first).toBeGreaterThanOrEqual(3);
      await expect(page.locator('[data-testid="live-rates"]')).toHaveCount(0);
      await expect(page.locator('[data-testid="live-sparkline"]')).toHaveCount(0);
      await page.clock.runFor(2_000);
      await expect.poll(async () => Number(await stale.getAttribute("data-seconds")))
        .toBeGreaterThanOrEqual(first + 2);

      // the browser reconnects; the new figures replace the stale note, and
      // the sparkline places them by time - the quiet seconds are a hole,
      // the kit's hatched value-less mark, never a blank that reads as zero
      await expect.poll(() => asked.length).toBe(2);
      release();
      await expect(page.locator('[data-testid="live-rate-up"]'))
        .toHaveAttribute("data-bps", "4800");
      await expect(stale).toHaveCount(0);
      await expect(sparkMarks).toHaveCount(FRAMES.length + RECOVERED.length);
      const xs = await sparkMarks.evaluateAll((els) => els.map((e) => Number(e.getAttribute("x"))));
      for (let i = 1; i < FRAMES.length; i += 1) {
        expect(xs[i] - xs[i - 1], `frame ${i} sits beside the one before it`).toBeCloseTo(1, 1);
      }
      expect(xs[FRAMES.length] - xs[FRAMES.length - 1], "seven quiet seconds leave a hole")
        .toBeCloseTo(7, 1);
      await expect(sparkHoles).toHaveCount(1);
      await expect(sparkHoles).toHaveAttribute("width", "6");
      // the hole is named by the silence it spans
      await page.locator('[data-testid="live-sparkline-focus"]').focus();
      await page.keyboard.press("End");
      await page.keyboard.press("ArrowLeft");
      await expect(page.locator('[data-testid="live-sparkline-tooltip"]'))
        .toContainText(`${FRAMES[FRAMES.length - 1].ts} - ${RECOVERED[0].ts}`);
      await expect(page.locator('[data-testid="live-sparkline-tooltip"]'))
        .toContainText("the stream was quiet, not zero");
      await page.keyboard.press("Escape");

      // hidden closes the stream; visible opens a new one
      await setHidden(page, true);
      await expect.poll(() => openStreams(page)).toBe(0);
      // a paused tile keeps no figure to show as current on return
      await expect(page.locator('[data-testid="live-rates"]')).toHaveCount(0);
      await expect(page.locator('[data-testid="live-sparkline"]')).toHaveCount(0);
      await setHidden(page, false);
      await expect.poll(() => asked.length).toBe(3);
      await expect.poll(() => openStreams(page)).toBe(1);
      // ... starting a new minute: no frame from before the pause is kept
      await expect(sparkMarks).toHaveCount(FRAMES.length);
      await expect(page.locator('[data-testid="live-rate-up"]'))
        .toHaveAttribute("data-bps", "3600");

      // the choice is this browser's: a reload opens the stream unasked
      await page.reload();
      await ready(page, "stats");
      await expect(toggle).toBeChecked();
      await expect.poll(() => asked.length).toBe(4);
      await expect.poll(() => openStreams(page)).toBe(1);

      // leaving the gateway view in-app closes the stream; coming back
      // opens one, the choice kept - and re-reads no widget before it is due
      const widgetReads = [];
      page.on("request", (r) => {
        if (/\/v1\/stats\/(node-delay|quota)/.test(r.url())) widgetReads.push(r.url());
      });
      await page.locator('[data-testid="quota-ready"]').waitFor({ state: "attached" });
      await page.waitForTimeout(300);
      const beforeTrip = widgetReads.length;
      await page.locator('[data-testid="stats-top-device-link"][data-key="192.0.2.20"]').click();
      await page.locator('[data-testid="stats-ready"][data-scope="client"]')
        .waitFor({ state: "attached" });
      await expect.poll(() => openStreams(page)).toBe(0);
      await page.waitForTimeout(300);
      expect(asked, "a client's view opens no stream").toHaveLength(4);
      await page.goBack();
      await page.locator('[data-testid="stats-ready"][data-scope="overview"]')
        .waitFor({ state: "attached" });
      await expect.poll(() => asked.length).toBe(5);
      await expect.poll(() => openStreams(page)).toBe(1);
      await page.waitForTimeout(300);
      expect(widgetReads, "a scope round trip is not a due read").toHaveLength(beforeTrip);

      // too many viewers: the panel says so and the stream stays closed
      mode.now = "full";
      await toggle.uncheck();
      await expect.poll(() => openStreams(page)).toBe(0);
      await toggle.check();
      await expect(page.locator('[data-testid="live-closed"]'))
        .toContainText("too many live viewers");
      await expect.poll(() => openStreams(page)).toBe(0);
      await expect(page.locator('[data-testid="live-sparkline"]')).toHaveCount(0);

      // a stream the browser gives up on (a 503) says so too
      mode.now = "down";
      await toggle.uncheck();
      await toggle.check();
      await expect(page.locator('[data-testid="live-closed"]'))
        .toContainText("The live feed closed");

      // off is remembered as well, and opens nothing on the next visit
      await toggle.uncheck();
      expect(await page.evaluate(() => localStorage.getItem("panel_live"))).toBe("0");
      const before = asked.length;
      await page.reload();
      await ready(page, "stats");
      await expect(toggle).not.toBeChecked();
      await page.waitForTimeout(300);
      expect(asked).toHaveLength(before);
      expect(await openStreams(page)).toBe(0);
    });

  test("node delay draws what mihomo tested - a failed test is no answer, never 0 ms - and the quota what it reported",
    async ({ page }) => {
      await page.clock.install({ time: new Date(GOLDEN.now) });
      await routeGolden(page);
      await land(page, "#/insights?range=48h");
      await page.locator('[data-testid="node-delay-ready"][data-range="48h"]')
        .waitFor({ state: "attached" });
      const golden = goldenNodeDelay("http://x/v1/stats/node-delay?range=48h");
      const at = (name) => golden.groups.findIndex((g) => g.group === name);
      const marks = (name) => page.locator(`[data-testid="node-delay-${at(name)}"] [data-mark="1"]`);

      await expect(page.locator('[data-testid="node-delay-frame-fresh"]')).toBeAttached();
      await expect(page.locator('[data-testid^="node-delay-row-"]'))
        .toHaveCount(golden.groups.length);
      expect(golden.groups.length, "the sweep needs eight groups or more")
        .toBeGreaterThanOrEqual(8);
      await expect(page.locator('[data-testid="node-delay-truncated"]')).toHaveCount(0);
      // a delay chart is ONE series: no traffic mark anywhere in it
      await expect(page.locator('[data-testid="node-delay"] [data-up]')).toHaveCount(0);

      // "Proxy" at test resolution: one mark per test - a slot with no test
      // has none (never a zero-filled bar)...
      await expect(marks("Proxy")).toHaveCount(7);
      // ... a failed test is a value-less mark ...
      const failed = marks("Proxy").and(page.locator('[data-gap="full"]'));
      await expect(failed).toHaveCount(1);
      await expect(failed).toHaveAttribute("data-bucket", "2026-10-12T10:05:00Z");
      expect(await failed.getAttribute("data-ms")).toBeNull();
      // ... and a switch inside one slot splits it, each half naming its node
      const jp = marks("Proxy").and(page.locator('[data-bucket="2026-10-12T10:20:00Z"]'));
      const us = marks("Proxy").and(page.locator('[data-bucket="2026-10-12T10:21:00Z"]'));
      await expect(jp).toHaveAttribute("data-node", "JP 01");
      await expect(us).toHaveAttribute("data-node", "US 01");
      const [jx, ux] = [Number(await jp.getAttribute("x")), Number(await us.getAttribute("x"))];
      expect(Math.floor(jx), "both tests share one slot").toBe(Math.floor(ux));
      expect(ux - jx).toBeCloseTo(0.5, 1);

      // the newest test failed: "no answer", no number, and when
      const fallback = page.locator(`[data-testid="node-delay-${at("Fallback")}-latest"]`);
      await expect(fallback).toContainText("no answer");
      expect(await fallback.getAttribute("data-ms")).toBeNull();
      await expect(fallback).toContainText("as of 2026-10-12T11:10:00Z");
      // and its tooltip says the same of the failed test it points at
      await page.locator(`[data-testid="node-delay-${at("Fallback")}-focus"]`).focus();
      await page.keyboard.press("End");
      await expect(page.locator(`[data-testid="node-delay-${at("Fallback")}-tooltip"]`))
        .toContainText("no answer");
      // a group tested only before the window: its latest, dated, no strip
      await expect(page.locator(`[data-testid="node-delay-${at("Games")}-none"]`)).toBeVisible();
      await expect(page.locator(`[data-testid="node-delay-${at("Games")}-latest"]`))
        .toContainText("as of 2026-09-30T08:00:00Z");

      // 7d reads hour aggregates: the hour JP 01 partly failed keeps its
      // mean under a partial mark beside US 01; an hour of nothing but
      // failures is value-less. A new range is a new question: read at
      // once, never at the next due tick
      const delayReads = [];
      page.on("request", (r) => {
        if (r.url().includes("/v1/stats/node-delay")) delayReads.push(r.url());
      });
      await page.locator('[data-testid="stats-range"]').selectOption("7d");
      await expect.poll(() => delayReads.some((u) => u.endsWith("?range=7d")),
                        { timeout: 2_000 }).toBe(true);
      await page.locator('[data-testid="node-delay-ready"][data-range="7d"]')
        .waitFor({ state: "attached" });
      await expect(marks("Proxy")).toHaveCount(3);
      const partial = marks("Proxy").and(page.locator('[data-node="JP 01"]'));
      await expect(partial).toHaveAttribute("data-gap", "partial");
      await expect(partial).toHaveAttribute("data-ms", "125");
      await expect(marks("Proxy").and(page.locator('[data-bucket="2026-10-12T10"][data-node="US 01"]')))
        .toHaveAttribute("data-ms", "208");
      await expect(marks("Telegram")).toHaveCount(1);
      await expect(marks("Telegram")).toHaveAttribute("data-gap", "full");
      expect(await marks("Telegram").getAttribute("data-ms")).toBeNull();

      // 30d reaches past the 14 days kept: the window says where it starts
      await page.locator('[data-testid="stats-range"]').selectOption("30d");
      await page.locator('[data-testid="node-delay-ready"][data-range="30d"]')
        .waitFor({ state: "attached" });
      await expect(page.locator('[data-testid="node-delay-truncated"]'))
        .toContainText("14d");
      await expect(page.locator('[data-testid="node-delay-truncated"]'))
        .toContainText("2026-09-28T12:00:00Z");
      await expect(page.locator(`[data-testid="node-delay-${at("Games")}"]`)).toBeVisible();

      // the quota: a bar against a reported limit; none without one; an
      // overrun reads as one (the bar stops at full); a past expiry says so
      await page.locator('[data-testid="quota-ready"]').waitFor({ state: "attached" });
      await expect(page.locator('[data-testid="quota-frame-fresh"]')).toBeAttached();
      await expect(page.locator('[data-testid="quota-bar-0"]')).toHaveAttribute("data-share", "10.0");
      await expect(page.locator('[data-testid="quota-used-0"]')).toContainText("(10.0%)");
      await expect(page.locator('[data-testid="quota-expire-0"]')).toContainText("Expires 2027-01-01");
      await expect(page.locator('[data-testid="quota-expire-0"]')).toHaveAttribute("data-expired", "false");
      await expect(page.locator('[data-testid="quota-bar-1"]')).toHaveCount(0);
      await expect(page.locator('[data-testid="quota-no-limit-1"]')).toContainText("no limit reported");
      await expect(page.locator('[data-testid="quota-expire-1"]')).toContainText("no expiry reported");
      await expect(page.locator('[data-testid="quota-expire-1"]')).toContainText("report time unknown");
      await expect(page.locator('[data-testid="quota-bar-2"]')).toHaveAttribute("data-share", "150.0");
      await expect(page.locator('[data-testid="quota-used-2"]')).toContainText("(150.0%)");
      await expect(page.locator('[data-testid="quota-expire-2"]')).toContainText("Expired 2026-01-01");
      await expect(page.locator('[data-testid="quota-expire-2"]')).toHaveAttribute("data-expired", "true");
      // a half of the use not reported: no share from a null, and the limit
      // that WAS reported is said
      await expect(page.locator('[data-testid="quota-bar-3"]')).toHaveCount(0);
      await expect(page.locator('[data-testid="quota-no-used-3"]'))
        .toContainText("Limit 100 GB - used not reported");

      // the widgets are the gateway's: a client's view has none of them
      await land(page, "#/insights/client/192.0.2.20?range=48h");
      await expect(page.locator('[data-testid="node-delay"]')).toHaveCount(0);
      await expect(page.locator('[data-testid="quota"]')).toHaveCount(0);
      await expect(page.locator('[data-testid="live-tile"]')).toHaveCount(0);
    });

  test("each widget says when its picture cannot be trusted - in its own words, never traffic's",
    async ({ page }) => {
      // `hold`, when set, keeps the widget reads unanswered until it resolves
      const answers = { delay: null, quota: GOLDEN_QUOTA, health: GOLDEN.health, hold: null };
      await routeGolden(page, {
        health: (route) => json(route, answers.health),
        nodeDelay: async (route) => {
          if (answers.hold) await answers.hold;
          return answers.delay === "down"
            ? json(route, { detail: "down" }, 503)
            : json(route, answers.delay || goldenNodeDelay(route.request().url()));
        },
        quota: async (route) => {
          if (answers.hold) await answers.hold;
          return answers.quota === "down"
            ? json(route, { detail: "down" }, 503) : json(route, answers.quota);
        },
      });
      // a page that opens hidden (the flag survives navigations)
      await page.addInitScript(() => {
        let hidden = false;
        try {
          hidden = localStorage.getItem("e2e_hidden") === "1";
        } catch {
          // about:blank has no storage
        }
        if (hidden) {
          Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
        }
      });
      const widgetReads = [];
      page.on("request", (r) => {
        if (/\/v1\/stats\/(node-delay|quota)/.test(r.url())) widgetReads.push(r.url());
      });
      const settle = async () => {
        await land(page);
        await page.locator('[data-testid="node-delay-ready"]').waitFor({ state: "attached" });
        await page.locator('[data-testid="quota-ready"]').waitFor({ state: "attached" });
      };

      // opened in a hidden tab: no widget reads at all until it is shown,
      // then one each
      await settle();
      await page.evaluate(() => localStorage.setItem("e2e_hidden", "1"));
      const opened = widgetReads.length;
      await land(page);
      await page.waitForTimeout(500);
      expect(widgetReads, "a hidden page reads no widget, not even on open")
        .toHaveLength(opened);
      await page.evaluate(() => localStorage.removeItem("e2e_hidden"));
      await setHidden(page, false);
      const ofKind = (kind) => widgetReads.slice(opened).filter((u) => u.includes(kind)).length;
      await expect.poll(() => [ofKind("/node-delay"), ofKind("/quota")]).toEqual([1, 1]);
      await page.locator('[data-testid="node-delay-ready"]').waitFor({ state: "attached" });
      await page.waitForTimeout(300);
      expect([ofKind("/node-delay"), ofKind("/quota")], "and no more").toEqual([1, 1]);

      // nothing stored yet: empty, in delay and quota words
      answers.delay = { ...goldenNodeDelay("http://x/?range=7d"), groups: [] };
      answers.quota = { state: "none", sampled_at: "2026-10-12T11:00:00Z", providers: [] };
      await settle();
      await expect(page.locator('[data-testid="node-delay-frame-empty"]'))
        .toContainText("No delay test is stored yet");
      await expect(page.locator('[data-testid="node-delay-frame-empty"]'))
        .not.toContainText("traffic");
      await expect(page.locator('[data-testid="quota-frame-empty"]'))
        .toContainText("No provider reports a quota");
      // ... and a refresh that fails over it is stale, the last answer's
      // "nothing stored" kept under the label - never a current-looking one
      answers.delay = "down";
      answers.quota = "down";
      await page.locator('[data-testid="stats-refresh"]').click();
      await expect(page.locator('[data-testid="node-delay-frame-stale"]')).toContainText("Not updated since");
      await expect(page.locator('[data-testid="node-delay-none-stored"]'))
        .toContainText("No delay test is stored yet");
      await expect(page.locator('[data-testid="quota-frame-stale"]')).toContainText("Not updated since");
      await expect(page.locator('[data-testid="quota-none-stored"]'))
        .toContainText("No provider reports a quota");

      // a purge deletes both widgets' sources (#102): they re-read at once
      // and never draw the deleted figures as fresh
      answers.delay = null;
      answers.quota = GOLDEN_QUOTA;
      await settle();
      await expect(page.locator('[data-testid="node-delay-frame-fresh"]')).toBeAttached();
      await expect(page.locator('[data-testid="quota-frame-fresh"]')).toBeAttached();
      await page.route("**/v1/stats/purge", (route) => json(route, { purged: true }));
      page.once("dialog", (dialog) => dialog.accept());
      answers.delay = { ...goldenNodeDelay("http://x/?range=7d"), groups: [] };
      answers.quota = { state: "pending", sampled_at: null, providers: [] };
      await page.locator('[data-testid="stats-purge"]').click();
      await expect(page.locator('[data-testid="node-delay-frame-empty"]')).toBeVisible();
      await expect(page.locator('[data-testid="quota-pending"]')).toBeVisible();
      await expect(page.locator('[data-testid^="quota-row-"]')).toHaveCount(0);
      // ... from any view: purged inside a client's view, the overview reads
      // both afresh on the way back instead of drawing the deleted figures
      answers.delay = null;
      answers.quota = GOLDEN_QUOTA;
      await settle();
      await expect(page.locator('[data-testid="quota-frame-fresh"]')).toBeAttached();
      await page.locator('[data-testid="stats-top-device-link"][data-key="192.0.2.20"]').click();
      await page.locator('[data-testid="stats-ready"][data-scope="client"]')
        .waitFor({ state: "attached" });
      answers.delay = { ...goldenNodeDelay("http://x/?range=7d"), groups: [] };
      answers.quota = { state: "pending", sampled_at: null, providers: [] };
      const inClient = widgetReads.length;
      page.once("dialog", (dialog) => dialog.accept());
      await page.locator('[data-testid="stats-purge"]').click();
      await page.waitForTimeout(300);
      expect(widgetReads, "a client's view reads no widget, purge or not").toHaveLength(inClient);
      // back on the overview, while its re-reads are unanswered, nothing the
      // purge deleted is drawn - not even for a round trip
      let releaseReads;
      answers.hold = new Promise((resolve) => { releaseReads = resolve; });
      await page.goBack();
      await page.locator('[data-testid="stats-ready"][data-scope="overview"]')
        .waitFor({ state: "attached" });
      await expect.poll(() => widgetReads.length).toBe(inClient + 2);
      await expect(page.locator('[data-testid^="quota-row-"]')).toHaveCount(0);
      await expect(page.locator('[data-testid^="node-delay-row-"]')).toHaveCount(0);
      await expect(page.locator('[data-testid="quota-frame"]')).toHaveAttribute("data-state", "none");
      answers.hold = null;
      releaseReads();
      await expect(page.locator('[data-testid="node-delay-frame-empty"]')).toBeVisible();
      await expect(page.locator('[data-testid="quota-pending"]')).toBeVisible();
      await expect(page.locator('[data-testid^="quota-row-"]')).toHaveCount(0);

      // a plain Refresh away from the gateway view deletes nothing: the
      // overview re-reads on return, and a read that fails then keeps the
      // last good picture, stale - never "could not be read"
      answers.delay = null;
      answers.quota = GOLDEN_QUOTA;
      await settle();
      const toClient = async () => {
        await page.locator('[data-testid="stats-top-device-link"][data-key="192.0.2.20"]').click();
        await page.locator('[data-testid="stats-ready"][data-scope="client"]')
          .waitFor({ state: "attached" });
      };
      const toOverview = async () => {
        await page.goBack();
        await page.locator('[data-testid="stats-ready"][data-scope="overview"]')
          .waitFor({ state: "attached" });
      };
      await toClient();
      await page.locator('[data-testid="stats-refresh"]').click();
      answers.delay = "down";
      answers.quota = "down";
      await toOverview();
      await expect(page.locator('[data-testid="node-delay-frame-stale"]')).toBeVisible();
      await expect(page.locator('[data-testid="quota-frame-stale"]')).toBeVisible();

      // a purge acts on the view shown when its POST answers, not the one
      // its button was pressed in: drilled away mid-POST, no widget is read
      // in the client's view, and the overview reads both afresh after
      answers.delay = null;
      answers.quota = GOLDEN_QUOTA;
      await settle();
      let releasePurge;
      const purgeHeld = new Promise((resolve) => { releasePurge = resolve; });
      await page.unroute("**/v1/stats/purge");
      await page.route("**/v1/stats/purge", async (route) => {
        await purgeHeld;
        return json(route, { purged: true });
      });
      page.once("dialog", (dialog) => dialog.accept());
      await page.locator('[data-testid="stats-purge"]').click();
      await toClient();
      answers.delay = { ...goldenNodeDelay("http://x/?range=7d"), groups: [] };
      answers.quota = { state: "pending", sampled_at: null, providers: [] };
      const midPost = widgetReads.length;
      releasePurge();
      await page.waitForTimeout(500);
      expect(widgetReads, "a purge answered in a client's view reads no widget there")
        .toHaveLength(midPost);
      await toOverview();
      await expect(page.locator('[data-testid="node-delay-frame-empty"]')).toBeVisible();
      await expect(page.locator('[data-testid="quota-pending"]')).toBeVisible();

      // the quota not sampled yet: a note, and no state drawn
      answers.quota = { state: "pending", sampled_at: null, providers: [] };
      await settle();
      await expect(page.locator('[data-testid="quota-pending"]')).toBeVisible();
      await expect(page.locator('[data-testid="quota-frame"]')).toHaveAttribute("data-state", "none");
      // ... but figures stored before a restart are drawn, stale since
      // their provider's newest report
      answers.quota = { ...GOLDEN_QUOTA, state: "pending", sampled_at: null };
      await settle();
      await expect(page.locator('[data-testid="quota-pending"]')).toBeVisible();
      await expect(page.locator('[data-testid="quota-frame-stale"]'))
        .toContainText("The last good figures, from 2026-10-12T10:58:00Z");

      // mihomo did not answer the last sample: the last good list, labelled
      answers.quota = { ...GOLDEN_QUOTA, state: "error" };
      await settle();
      await expect(page.locator('[data-testid="quota-frame-stale"]'))
        .toContainText("The last good figures, from 2026-10-12T11:00:00Z");
      await expect(page.locator('[data-testid="quota-error"]'))
        .toContainText("mihomo did not answer");
      await expect(page.locator('[data-testid="quota-bar-0"]')).toBeVisible();

      // unreadable: unavailable, nothing drawn
      answers.delay = "down";
      answers.quota = "down";
      await settle();
      await expect(page.locator('[data-testid="node-delay-frame-unavailable"]'))
        .toContainText("node delay could not be read");
      await expect(page.locator('[data-testid="quota-frame-unavailable"]'))
        .toContainText("quota could not be read");
      await expect(page.locator('[data-testid^="node-delay-row-"]')).toHaveCount(0);

      // the collector stopped: both kept, both stale - the delay since its
      // newest stored test, not since the read that carried it
      answers.delay = null;
      answers.quota = GOLDEN_QUOTA;
      answers.health = { ...GOLDEN.health, collector: "stopped" };
      await settle();
      await expect(page.locator('[data-testid="node-delay-frame-stale"]'))
        .toContainText("Not updated since 2026-10-12T11:55:00Z");
      await expect(page.locator('[data-testid="quota-frame-stale"]')).toBeVisible();
      await expect(page.locator('[data-testid="quota-error"]')).toHaveCount(0);
      // ... and with nothing stored, still empty: a stale label over
      // nothing would claim figures that were never kept
      answers.delay = { ...goldenNodeDelay("http://x/?range=7d"), groups: [] };
      answers.quota = { state: "none", sampled_at: "2026-10-12T11:00:00Z", providers: [] };
      await settle();
      await expect(page.locator('[data-testid="node-delay-frame-empty"]')).toBeVisible();
      await expect(page.locator('[data-testid="node-delay-frame-stale"]')).toHaveCount(0);
      await expect(page.locator('[data-testid="quota-frame-empty"]')).toBeVisible();
      await expect(page.locator('[data-testid="quota-frame-stale"]')).toHaveCount(0);
    });

  test("the widgets fit a phone, in both schemes, whatever the tile says", async ({ page }) => {
    await page.clock.install({ time: new Date(GOLDEN.now) });
    await routeGolden(page);
    const mode = { now: "stream" };
    await routeLive(page, mode);
    await page.addInitScript(() => {
      try {
        localStorage.setItem("panel_live", "1");
      } catch {
        // about:blank has no storage
      }
    });
    await page.setViewportSize({ width: 390, height: 844 });
    for (const scheme of ["light", "dark"]) {
      await page.emulateMedia({ colorScheme: scheme });
      for (const range of ["48h", "30d"]) {
        mode.now = "stream";
        await land(page, `#/insights?range=${range}`);
        await page.locator(`[data-testid="node-delay-ready"][data-range="${range}"]`)
          .waitFor({ state: "attached" });
        await page.locator('[data-testid="quota-ready"]').waitFor({ state: "attached" });
        await expect(page.locator('[data-testid="live-rates"]')).toBeVisible();
        const where = `#/insights?range=${range} (${scheme})`;
        expect(await overflowOf(page), `${where}, live`).toBeLessThanOrEqual(1);
        await page.clock.runFor(4_000);
        await expect(page.locator('[data-testid="live-stale"]')).toBeVisible();
        expect(await overflowOf(page), `${where}, stale`).toBeLessThanOrEqual(1);
        mode.now = "full";
        const toggle = page.locator('[data-testid="live-toggle"]');
        await toggle.uncheck();
        await toggle.check();
        await expect(page.locator('[data-testid="live-closed"]')).toBeVisible();
        expect(await overflowOf(page), `${where}, closed`).toBeLessThanOrEqual(1);
      }
    }
  });
});
