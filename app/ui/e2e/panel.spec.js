import { expect, test } from "@playwright/test";

/**
 * The browser gate (#79, DEC-8).
 *
 * Until this existed, not one line of the panel's JavaScript ran in CI:
 * the whole UI leg was three HTTP GETs asserting that some strings appeared
 * in the served HTML. Everything below therefore asserts against the
 * RENDERED page - which is the only layer that can see layout, and layout
 * is the defect that started this epic.
 *
 * The subject is the classic panel at /ui/. The React tree is still a
 * scaffold at /ui/next/; the rewrite item is what moves these specs onto it.
 */

const PANEL = "/ui/";

test.describe("the panel makes no external request", () => {
  test("nothing leaves the origin, at runtime rather than by grep", async ({
    page,
  }) => {
    // The zero-external-request promise has had NO runtime enforcement -
    // only a source grep, which cannot see a URL built at runtime from
    // string fragments. Route interception can.
    // Resolve the origin from the page itself rather than a private
    // Playwright field: an undefined baseURL there would silently compare
    // against the wrong host and make this assert nothing.
    await page.goto(PANEL, { waitUntil: "networkidle" });
    const origin = new URL(page.url()).host;
    expect(origin, "the page must have a real origin to compare against")
      .toMatch(/^127\.0\.0\.1:\d+$/);

    const offOrigin = [];
    await page.route("**/*", (route) => {
      const host = new URL(route.request().url()).host;
      if (host !== origin) offOrigin.push(route.request().url());
      return route.continue();
    });

    await page.reload({ waitUntil: "networkidle" });
    // exercise the tabs so their fetches happen too, not just first paint
    for (const id of ["tab-stats", "tab-audit", "tab-devices"]) {
      const tab = page.locator(`[data-testid="${id}"]`);
      if (await tab.count()) {
        await tab.first().click();
        await page.waitForLoadState("networkidle");
      }
    }
    expect(offOrigin, `off-origin requests: ${offOrigin.join(", ")}`)
      .toEqual([]);
  });
});

test.describe("testids exist in the rendered DOM", () => {
  test("every interactive element carries one after render", async ({
    page,
  }) => {
    // The source-side gate reads the HTML file. This reads what the browser
    // actually built, which is the only version a Playwright selector - or
    // a human - can use.
    await page.goto(PANEL, { waitUntil: "networkidle" });
    const missing = await page.evaluate(() => {
      const out = [];
      for (const el of document.querySelectorAll(
        "button, input, select, textarea, a[href]",
      )) {
        if (el.offsetParent === null && el.tagName !== "A") continue;
        if (!el.hasAttribute("data-testid")) {
          out.push(`${el.tagName.toLowerCase()}#${el.id || "?"}`);
        }
      }
      return out;
    });
    expect(missing, `rendered elements without data-testid: ${missing}`)
      .toEqual([]);
    const count = await page.locator("[data-testid]").count();
    expect(count, "the rendered page must carry stable testids").toBeGreaterThan(9);
  });
});

test.describe("the health surfaces are honest", () => {
  // The panel's core promise is that a badge never claims a change reached
  // mihomo when it did not. Both directions are asserted, because a banner
  // that is ALWAYS shown is exactly as useless as one that never is - and
  // a happy-path-only test cannot tell the two apart.

  const health = (parity) => ({
    db_ok: true, parity, last_apply: null, marker: parity === "failed",
    collector: "off", collector_last_ts: null, stats_db_bytes: 0,
    dashboard_port: 8080, day_tz: "UTC", day_cut: "00:00",
    day_framing: "unknown",
  });

  test("a failed parity raises the banner", async ({ page }) => {
    await page.route("**/health", (route) => route.fulfill({
      status: 200, contentType: "application/json",
      body: JSON.stringify(health("failed")),
    }));
    await page.goto(PANEL, { waitUntil: "networkidle" });
    await expect(page.locator('[data-testid="parity-banner"]'))
      .toBeVisible();
    await expect(page.locator('[data-testid="health-dot"]'))
      .toHaveAttribute("title", /parity=failed/);
  });

  test("an ok parity leaves it down", async ({ page }) => {
    await page.route("**/health", (route) => route.fulfill({
      status: 200, contentType: "application/json",
      body: JSON.stringify(health("ok")),
    }));
    await page.goto(PANEL, { waitUntil: "networkidle" });
    await expect(page.locator('[data-testid="parity-banner"]'))
      .toBeHidden();
  });
});

test.describe("the audit view is readable at both ends", () => {
  for (const [label, width, height] of [
    ["desktop", 1280, 900],
    ["phone", 390, 844],
  ]) {
    test(`no horizontal overflow at ${label} (${width}px)`, async ({
      page,
    }) => {
      // The defect that started this epic was layout, and layout is exactly
      // what no amount of string-matching could see. A page wider than its
      // own viewport is the machine-checkable form of "unreadable".
      await page.setViewportSize({ width, height });
      await page.goto(PANEL, { waitUntil: "networkidle" });
      const audit = page.locator('[data-testid="tab-audit"]');
      if (await audit.count()) {
        await audit.first().click();
        await page.waitForLoadState("networkidle");
      }
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth
          - document.documentElement.clientWidth,
      );
      expect(overflow, `page overflows its viewport by ${overflow}px`)
        .toBeLessThanOrEqual(1);
    });
  }
});

test.describe("the band confirm guards both mutation paths", () => {
  // This replaces a textual gate that string-split `app.js` function bodies
  // to assert the guard existed. Splitting on `async function addDevice`
  // proves the SOURCE contains a call; it cannot prove the dialog actually
  // fires, and it breaks on a rename that changes nothing real. The browser
  // can just ask.

  const devices = (band) => ({
    devices: [{ id: 1, cidr: "192.0.2.70/32", mode: "full-tunnel",
                name: "", note: "", band_member: band.length > 0,
                alias: "" }],
    band,
  });

  test("adding an address inside the static band asks first", async ({
    page,
  }) => {
    await page.route("**/v1/devices", (route) => {
      if (route.request().method() !== "GET") return route.continue();
      return route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify(devices(["192.0.2.64/28"])),
      });
    });
    await page.goto(PANEL, { waitUntil: "networkidle" });

    const asked = [];
    page.on("dialog", (d) => { asked.push(d.message()); d.dismiss(); });

    await page.locator('[data-testid="add-address"]').fill("192.0.2.70");
    await page.locator('[data-testid="add-submit"]').click();
    await page.waitForTimeout(300);
    expect(asked.length, "a band address must be confirmed before it is added")
      .toBeGreaterThan(0);
  });

  test("an address outside the band is not gated", async ({ page }) => {
    // The other direction: a guard that fires on everything is a guard
    // nobody reads, and this is what tells the two apart.
    await page.route("**/v1/devices", (route) => {
      if (route.request().method() !== "GET") return route.continue();
      return route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify(devices([])),
      });
    });
    await page.goto(PANEL, { waitUntil: "networkidle" });

    const asked = [];
    page.on("dialog", (d) => { asked.push(d.message()); d.dismiss(); });

    await page.locator('[data-testid="add-address"]').fill("198.51.100.5");
    await page.locator('[data-testid="add-submit"]').click();
    await page.waitForTimeout(300);
    expect(asked, "a non-band address must not be gated").toEqual([]);
  });
});

test("the add path re-reads the band instead of trusting a stale cache",
  async ({ page }) => {
    // The sharpest of the three properties the retired textual gate held,
    // and the one a naive spec misses: if the FIRST load saw no band, only
    // an implementation that re-fetches before deciding will discover the
    // address is inside one. A cached empty list would sail straight past
    // the guard - which is a band member silently escaping the confirm.
    let seen = 0;
    await page.route("**/v1/devices", (route) => {
      if (route.request().method() !== "GET") return route.continue();
      seen += 1;
      return route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify({
          devices: [],
          // empty on first paint, populated by the time the add happens
          band: seen === 1 ? [] : ["192.0.2.64/28"],
        }),
      });
    });
    await page.goto(PANEL, { waitUntil: "networkidle" });

    const asked = [];
    page.on("dialog", (d) => { asked.push(d.message()); d.dismiss(); });

    await page.locator('[data-testid="add-address"]').fill("192.0.2.70");
    await page.locator('[data-testid="add-submit"]').click();
    await page.waitForTimeout(400);
    expect(seen, "the add path must re-read /v1/devices before deciding")
      .toBeGreaterThan(1);
    expect(asked.length,
      "a band discovered by the refresh must still trigger the confirm")
      .toBeGreaterThan(0);
  });
