import { expect, test } from "@playwright/test";

/**
 * The browser gate (#79, moved onto the React tree by #80).
 *
 * Everything here asserts against the RENDERED page, which is the only layer
 * that can see layout - and layout is the defect that started this epic. The
 * subject is the BUILT panel at /ui/, served by uvicorn against the same
 * FakeController the API e2e uses (scripts/ci/ui_e2e_server.py).
 *
 * Since #80 this file also carries the two claims that used to be made by
 * regexes over app/static/style.css. That stylesheet is gone - MUI is
 * CSS-in-JS and the built tree contains no .css asset at all - so porting the
 * regexes would have meant re-implementing a cascade resolver to mean
 * anything. Both regressions are asserted here instead, against real
 * geometry and real computed style.
 */

const PANEL = "/ui/";
const TOKEN = "e2e-fixture-secret";

/** A populated audit log. The fixture DB starts empty, and an EMPTY log makes
 *  both audit-layout assertions vacuous: an empty container is not "visible",
 *  and there is no cell whose computed style could be read. The first draft of
 *  the wrapping spec passed for exactly that reason - it looped over zero
 *  cells - which is the failure mode this epic keeps finding, so the row count
 *  is asserted rather than assumed. */
async function routeAudit(page) {
  await page.route("**/v1/audit*", (route) => route.fulfill({
    status: 200, contentType: "application/json",
    body: JSON.stringify({ entries: [
      { ts: "2026-07-26T14:03:11Z", action: "flip", cidr: "192.0.2.70/32",
        mode: "full-tunnel", requester: "192.0.2.10", note: "",
        details: "'full-direct' -> 'full-tunnel'" },
      { ts: "2026-07-26T14:01:02Z", action: "add", cidr: "198.51.100.5/32",
        mode: "full-direct", requester: "192.0.2.10", note: "kitchen",
        details: "" },
    ] }),
  }));
}

/** Wait for the shell AND its dictionary: every label renders as its own key
 *  until the fetch lands, so asserting on text before then is a race. */
async function open(page, tab) {
  await page.goto(PANEL, { waitUntil: "networkidle" });
  await expect(page.locator('[data-testid="app-shell"]')).toBeVisible();
  if (tab) {
    await page.locator(`[data-testid="tab-${tab}"]`).click();
    await page.waitForLoadState("networkidle");
  }
}

test.describe("the panel makes no external request", () => {
  test("nothing leaves the origin, at runtime rather than by grep", async ({
    page,
  }) => {
    // The zero-external-request promise has only a source grep behind it,
    // which cannot see a URL assembled at runtime from fragments. Route
    // interception can. Resolve the origin from the page itself rather than a
    // private Playwright field: an undefined baseURL there would silently
    // compare against the wrong host and make this assert nothing.
    await open(page);
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
    // exercise every tab so their fetches happen too, not just first paint
    for (const id of ["devices", "audit", "settings", "stats"]) {
      await page.locator(`[data-testid="tab-${id}"]`).click();
      await page.waitForLoadState("networkidle");
    }
    // and the language toggle, which fetches a second dictionary
    await page.locator('[data-testid="lang-toggle"]').click();
    await page.waitForLoadState("networkidle");
    expect(offOrigin, `off-origin requests: ${offOrigin.join(", ")}`)
      .toEqual([]);
  });
});

test.describe("testids exist in the rendered DOM", () => {
  test("every interactive element carries one after render", async ({
    page,
  }) => {
    // The source-side gate reads JSX. This reads what the browser actually
    // built, which is the only version a Playwright selector - or a human -
    // can use. MUI is exactly why it matters: several of its components
    // render the real control inside a wrapper, and a testid left on the
    // wrapper names something nobody can type into.
    for (const tab of ["stats", "devices", "audit", "settings"]) {
      await open(page, tab);
      const missing = await page.evaluate(() => {
        const out = [];
        for (const el of document.querySelectorAll(
          "button, input, select, textarea, a[href]",
        )) {
          if (el.offsetParent === null && el.tagName !== "A") continue;
          if (!el.hasAttribute("data-testid")) {
            out.push(`${el.tagName.toLowerCase()}.${el.className || "?"}`);
          }
        }
        return out;
      });
      expect(missing, `${tab}: rendered elements without data-testid`)
        .toEqual([]);
    }
    const count = await page.locator("[data-testid]").count();
    expect(count, "the rendered page must carry stable testids")
      .toBeGreaterThan(9);
  });
});

test.describe("the health surfaces are honest", () => {
  // The panel's core promise is that a badge never claims a change reached
  // mihomo when it did not. Both directions are asserted, because a banner
  // that is ALWAYS shown is exactly as useless as one that never is - and a
  // happy-path-only test cannot tell the two apart.

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
    await open(page);
    await expect(page.locator('[data-testid="parity-banner"]')).toBeVisible();
    await expect(page.locator('[data-testid="health-dot"]'))
      .toHaveAttribute("title", /parity=failed/);
  });

  test("a health read that fails does NOT retract a known drift", async ({
    page,
  }) => {
    /* The sharpest honesty rule on this surface, and the one the rewrite got
       wrong on its first pass: the React shell replaced the whole health
       object on every poll, so a single failed /health took the drift banner
       down and let every badge fall back to `saved` - while no API response
       had said parity recovered. The classic tree returned early here.

       Silence is not evidence of recovery. */
    let answers = 0;
    await page.route("**/health", (route) => {
      answers += 1;
      if (answers === 1) {
        return route.fulfill({
          status: 200, contentType: "application/json",
          body: JSON.stringify(health("failed")),
        });
      }
      return route.fulfill({ status: 503, contentType: "application/json",
                             body: '{"detail":"down"}' });
    });
    // Re-apply is the shortest path to a SECOND health read - the polling
    // loop is on a 10s timer, and a tab switch does not re-read /health at
    // all. It is also the realistic version of this: the operator reacts to
    // the banner, and the panel goes quiet exactly then.
    await page.route("**/v1/apply", (route) => route.fulfill({
      status: 200, contentType: "application/json",
      body: '{"applied":false,"parity":"failed"}',
    }));
    await open(page);
    await expect(page.locator('[data-testid="parity-banner"]')).toBeVisible();
    const dot = page.locator('[data-testid="health-dot"]');
    const fresh = await dot.getAttribute("title");

    await page.locator('[data-testid="reapply-btn"]').click();
    await page.waitForTimeout(600);
    expect(answers, "the spec must actually have driven a failed poll - "
                    + "without one it would pass while proving nothing")
      .toBeGreaterThan(1);
    await expect(page.locator('[data-testid="parity-banner"]'),
      "a failed health read must not retract a drift the API did report")
      .toBeVisible();
    // and the retained reading must SAY it is stale rather than pass for
    // current. Asserted as "the title changed and still reports the drift",
    // not against the English wording, so the zh UI is held to it too.
    await expect(dot).toHaveAttribute("title", /parity=failed/);
    const stale = await dot.getAttribute("title");
    expect(stale, "a retained health reading must say it is no longer current")
      .not.toBe(fresh);
  });

  test("an ok parity leaves it down", async ({ page }) => {
    await page.route("**/health", (route) => route.fulfill({
      status: 200, contentType: "application/json",
      body: JSON.stringify(health("ok")),
    }));
    await open(page);
    await expect(page.locator('[data-testid="parity-banner"]')).toHaveCount(0);
    await expect(page.locator('[data-testid="health-dot"]'))
      .toHaveAttribute("title", /parity=ok/);
  });
});

test.describe("the panel is readable at both ends", () => {
  for (const [label, width, height] of [
    ["desktop", 1280, 900],
    ["phone", 390, 844],
  ]) {
    test(`no horizontal overflow at ${label} (${width}px)`, async ({ page }) => {
      // The defect that started this epic was layout, and layout is exactly
      // what no amount of string-matching could see. A page wider than its own
      // viewport is the machine-checkable form of "unreadable".
      await page.setViewportSize({ width, height });
      for (const tab of ["stats", "devices", "audit", "settings"]) {
        await open(page, tab);
        const overflow = await page.evaluate(
          () => document.documentElement.scrollWidth
            - document.documentElement.clientWidth,
        );
        expect(overflow, `${tab} overflows its viewport by ${overflow}px`)
          .toBeLessThanOrEqual(1);
      }
    });
  }

  test("the audit log folds to cards on a phone and is a table on a desktop",
    async ({ page }) => {
      /* The regression the retired CSS gate held: ONE unconditional
         `max-width: 640px` capped every view at phone width, so the
         five-column audit log rendered in ~614px on a 2560px desktop. That is
         under-use of space, not overflow - the assertion above cannot see it,
         and neither could any check that only asked "does it fit". */
      await routeAudit(page);
      await page.setViewportSize({ width: 390, height: 844 });
      await open(page, "audit");
      await expect(page.locator('[data-testid="audit-card"]')).toHaveCount(2);
      await expect(page.locator('[data-testid="audit-table"]')).toHaveCount(0);

      await page.setViewportSize({ width: 1280, height: 900 });
      await open(page, "audit");
      const table = page.locator('[data-testid="audit-table"]');
      await expect(table).toBeVisible();
      await expect(page.locator('[data-testid="audit-card"]')).toHaveCount(0);
      // and it must actually USE the desktop it was given
      const box = await table.boundingBox();
      expect(box.width, "the audit table must use the desktop width it has")
        .toBeGreaterThan(900);
    });

  test("an atomic token never wraps, in either layout", async ({ page }) => {
    /* The other retired CSS gate. `word-break: break-all` on the shared cell
       rule shattered every cell at whatever character hit the edge, so
       `2026-07-26T14:03:11Z` rendered as `2026-07-2 / 6T14:03:1 / 1Z` and
       requester IPs split mid-octet. Removing the rule is necessary but NOT
       sufficient: the default line breaker still offers a break after the `/`
       in a CIDR, so the atomic columns need an explicit `nowrap` - which is a
       COMPUTED style, and only a browser can report it. */
    await routeAudit(page);
    for (const [width, height] of [[1280, 900], [390, 844]]) {
      await page.setViewportSize({ width, height });
      await open(page, "audit");
      for (const field of ["time", "target", "requester"]) {
        const cell = page.locator(`[data-field="${field}"]`).first();
        // Asserted, never skipped: a loop over zero cells is a green test that
        // checked nothing, and that is how this spec passed on its first run.
        await expect(cell, `no ${field} cell rendered at ${width}px - this `
                           + "assertion would otherwise pass vacuously")
          .toHaveCount(1);
        const wrap = await cell.evaluate(
          (el) => getComputedStyle(el).whiteSpace);
        expect(wrap, `${field} at ${width}px carries an atomic token `
                     + "(ISO stamp / CIDR / IP) and must not wrap")
          .toBe("nowrap");
      }
    }
  });
});

test.describe("stats is the landing view", () => {
  test("the panel opens on stats, not on the policy editor", async ({ page }) => {
    // The point of the rewrite: the question an operator opens the panel with
    // is "what is my network doing".
    await open(page);
    await expect(page.locator('[data-testid="stats-range"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-stats"]'))
      .toHaveAttribute("aria-selected", "true");
  });

  test("the landing range comes from the setting, not from the bundle",
    async ({ page }) => {
      /* A default baked into the JavaScript can only be changed by shipping a
         new bundle. This proves the view actually READS the stored value:
         30d is not the shipped default, so a view ignoring the setting would
         still be showing 7d. */
      await page.route("**/v1/settings", (route) => {
        if (route.request().method() !== "GET") return route.continue();
        return route.fulfill({
          status: 200, contentType: "application/json",
          body: JSON.stringify({ settings: {
            timezone: { value: "UTC", default: "UTC", overridden: false },
            day_boundary: { value: "03:00", default: "03:00", overridden: false },
            stats_default_range: { value: "30d", default: "7d", overridden: true },
          } }),
        });
      });
      await open(page);
      await expect(page.locator('[data-testid="stats-range"]'))
        .toHaveValue("30d");
    });

  test("the attribution note is measured over the window on screen",
    async ({ page }) => {
      /* Attribution lives in one 7-day table, so a 30-day request cannot
         widen it - but sending the window is what makes the server answer
         `truncated`. Without it the panel shows a 7-day percentage beside a
         30-day table and claims nothing is missing, which is precisely the
         quiet inaccuracy the coverage measurement exists to prevent. */
      const asked = [];
      await page.route("**/v1/stats/coverage**", (route) => {
        asked.push(route.request().url());
        return route.continue();
      });
      await open(page);
      await page.locator('[data-testid="stats-range"]').selectOption("30d");
      await page.waitForLoadState("networkidle");
      expect(asked.length, "the coverage report must be fetched").toBeGreaterThan(0);
      expect(asked[asked.length - 1],
        `coverage must be scoped to the selected window, got ${asked}`)
        .toMatch(/[?&]since=/);
    });

  test("a slow answer for an abandoned window never repaints over a newer one",
    async ({ page }) => {
      /* Switching 48h (a minute-tier aggregation, the heaviest query the
         panel issues) to daily (a small one with no `since` at all) reliably
         lands the OLDER answer last. Without a request id the table then
         shows 48h numbers while the selector says daily, and nothing on
         screen says so - the quiet inaccuracy this view exists to prevent.
         AuditView spends a ref on exactly this; StatsView did not. */
      await page.route("**/v1/stats/devices**", async (route) => {
        const url = route.request().url();
        if (url.includes("tier=minute")) {
          await new Promise((done) => setTimeout(done, 1500));
          return route.fulfill({
            status: 200, contentType: "application/json",
            body: '{"tier":"minute","rows":[{"device":"10.0.0.48","up":1,"down":1}]}',
          });
        }
        return route.fulfill({
          status: 200, contentType: "application/json",
          body: '{"tier":"day","rows":[{"device":"10.0.0.99","up":2,"down":2}],'
                + '"framings":[]}',
        });
      });
      await open(page);
      await page.locator('[data-testid="stats-range"]').selectOption("48h");
      await page.locator('[data-testid="stats-range"]').selectOption("daily");
      await page.waitForTimeout(2500);
      await expect(page.locator('[data-testid="stats-range"]'))
        .toHaveValue("daily");
      await expect(page.locator('[data-testid="stats-rows"]'),
        "the rows must belong to the window the selector names")
        .toContainText("10.0.0.99");
      await expect(page.locator('[data-testid="stats-rows"]'))
        .not.toContainText("10.0.0.48");
    });

  test("a stats store that did not answer is not reported as no traffic",
    async ({ page }) => {
      // `_stats_conn` answers 503 when collection is degraded while policy
      // serving is fine. "No traffic recorded in this range" would be a
      // statement about the network; this is a statement about the panel.
      await page.route("**/v1/stats/devices**", (route) => route.fulfill({
        status: 503, contentType: "application/json",
        body: '{"detail":"stats store unavailable - collection degraded"}',
      }));
      await open(page);
      const empty = page.locator('[data-testid="stats-empty"]');
      await expect(empty).toBeVisible();
      const shown = await empty.textContent();
      await expect(empty).not.toHaveText(/no traffic/i);
      expect(shown.length, "the failure must be explained, not left blank")
        .toBeGreaterThan(0);
    });

  test("a slow or broken settings read never blanks the tab", async ({ page }) => {
    // /v1/settings reads policy.db while every stats route reads the separate
    // stats.db, so a policy-store failure says nothing about whether stats are
    // servable. The view must paint at the shipped default rather than wait.
    await page.route("**/v1/settings", (route) => {
      if (route.request().method() !== "GET") return route.continue();
      return route.fulfill({ status: 503, contentType: "application/json",
                             body: '{"detail":"policy store unavailable"}' });
    });
    await open(page);
    await expect(page.locator('[data-testid="stats-range"]')).toHaveValue("7d");
  });
});

test.describe("the settings page round-trips", () => {
  test("timezone, day boundary and default range survive a save", async ({
    page,
  }) => {
    await open(page, "settings");
    // The origin caption only renders once /v1/settings has answered, so this
    // is the seed landing - filling before it would be racing the response.
    await expect(page.locator('[data-testid="settings-timezone-origin"]'))
      .toBeVisible();
    await page.locator('[data-testid="settings-timezone"]').fill("Asia/Tokyo");
    await page.locator('[data-testid="settings-day_boundary"]').fill("05:00");
    await page.locator('[data-testid="settings-stats_default_range"]')
      .selectOption("30d");
    await page.locator('[data-testid="settings-save"]').click();

    // The write is token-gated, so this also exercises the 403 -> prompt ->
    // retry path, which nothing else covers.
    const dialog = page.locator('[data-testid="token-dialog"]');
    await expect(dialog).toBeVisible();
    await page.locator('[data-testid="token-input"]').fill(TOKEN);
    await page.locator('[data-testid="token-save"]').click();

    await expect(page.locator('[data-testid="settings-changed"]'))
      .toBeVisible({ timeout: 10000 });
    // A settings page that showed its own draft back would pass any weaker
    // assertion, so re-enter the tab and read what the SERVER returns.
    await open(page, "stats");
    await open(page, "settings");
    await expect(page.locator('[data-testid="settings-timezone"]'))
      .toHaveValue("Asia/Tokyo");
    await expect(page.locator('[data-testid="settings-day_boundary"]'))
      .toHaveValue("05:00");
    await expect(page.locator('[data-testid="settings-stats_default_range"]'))
      .toHaveValue("30d");
    // and an override must be reported AS an override - an inherited value
    // shown as a stored choice is the same class of lie as a dishonest badge
    await expect(page.locator('[data-testid="settings-timezone-origin"]'))
      .not.toContainText("inherited");
  });

  test("a settings response landing mid-edit does not wipe what was typed",
    async ({ page }) => {
      /* The form seeds itself from `/v1/settings`, which answers
         asynchronously. The first version of this page let that response
         overwrite an unsaved edit, so a keystroke typed just after the tab
         opened vanished with no error and no explanation - and the value that
         got saved was the one the operator had just replaced.

         Only a real browser could show this: every source-level reading of
         that code looks correct. */
      await page.route("**/v1/settings", async (route) => {
        if (route.request().method() !== "GET") return route.continue();
        await new Promise((done) => setTimeout(done, 1200));
        return route.fulfill({
          status: 200, contentType: "application/json",
          body: JSON.stringify({ settings: {
            timezone: { value: "UTC", default: "UTC", overridden: false },
            day_boundary: { value: "03:00", default: "03:00", overridden: false },
            stats_default_range: { value: "7d", default: "7d", overridden: false },
          } }),
        });
      });
      await page.goto(PANEL, { waitUntil: "domcontentloaded" });
      await page.locator('[data-testid="tab-settings"]').click();
      const field = page.locator('[data-testid="settings-timezone"]');
      await field.fill("Asia/Tokyo");
      // the seeding response lands during this wait
      await expect(page.locator('[data-testid="settings-timezone-origin"]'))
        .toBeVisible();
      await expect(field, "an unsaved edit must survive the seed arriving")
        .toHaveValue("Asia/Tokyo");
      // ...and ONLY that field is held back. One dirty flag for the whole
      // form would let a single keystroke suppress the seed for every other
      // key, leaving them blank while the panel holds real values for them.
      await expect(page.locator('[data-testid="settings-day_boundary"]'),
        "an untouched field must still be seeded")
        .toHaveValue("03:00");
      await expect(page.locator('[data-testid="settings-stats_default_range"]'))
        .toHaveValue("7d");
    });

  test("an unseeded form cannot be saved", async ({ page }) => {
    /* Every field renders empty until /v1/settings answers, and a blank value
       REVERTS its key. Saving in that window would wipe every override at
       once - a destructive act triggered by nothing more than being fast. */
    await page.route("**/v1/settings", async (route) => {
      if (route.request().method() !== "GET") return route.continue();
      await new Promise((done) => setTimeout(done, 1500));
      return route.continue();
    });
    await page.goto(PANEL, { waitUntil: "domcontentloaded" });
    await page.locator('[data-testid="tab-settings"]').click();
    await expect(page.locator('[data-testid="settings-save"]'),
      "save must wait for the form to know what it is editing")
      .toBeDisabled();
    await expect(page.locator('[data-testid="settings-save"]'))
      .toBeEnabled({ timeout: 10000 });
  });

  test("an alias round-trips and can be removed", async ({ page }) => {
    await page.addInitScript((token) => {
      localStorage.setItem("panel_token", token);
    }, TOKEN);
    await open(page, "settings");
    await page.locator('[data-testid="alias-ip"]').fill("192.0.2.44");
    await page.locator('[data-testid="alias-name"]').fill("kitchen-tv");
    await page.locator('[data-testid="alias-save"]').click();
    await expect(page.locator('[data-testid="alias-row-192.0.2.44"]'))
      .toContainText("kitchen-tv");

    await page.locator('[data-testid="alias-row-192.0.2.44"]')
      .locator('[data-testid="alias-remove"]').click();
    await expect(page.locator('[data-testid="alias-row-192.0.2.44"]'))
      .toHaveCount(0);
  });
});

test.describe("the naming rule is applied once", () => {
  test("an alias displaces the policy label, and says that it did", async ({
    page,
  }) => {
    /* DEC-C. A device can carry two independent human names and the store
       defines no precedence between them, deliberately, so the interface
       decides once. The alias wins - but the displaced name must stay VISIBLE:
       dropping a stored name from the UI is the only version of this rule that
       would be a lie. */
    await page.route("**/v1/devices", (route) => {
      if (route.request().method() !== "GET") return route.continue();
      return route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify({
          devices: [{
            id: 1, cidr: "192.0.2.70/32", mode: "full-tunnel",
            name: "old-policy-label", note: "", band_member: false,
            alias: "living-room-tv",
          }],
          band: [],
        }),
      });
    });
    await open(page, "devices");
    await expect(page.locator('[data-testid="device-name"]'))
      .toHaveText("living-room-tv");
    await expect(page.locator('[data-testid="device-legacy-name"]'))
      .toContainText("old-policy-label");
    await expect(page.locator('[data-testid="device-legacy-retire"]'))
      .toBeVisible();
  });

  /** One device, and every write captured instead of executed. The write
   *  TARGET is the whole decision here, so the assertion has to be on which
   *  endpoint was called - not on what the row ends up showing, which a
   *  refetch would paper over. */
  async function routeOneDevice(page, device, writes) {
    await page.route("**/v1/devices**", (route) => {
      if (route.request().method() === "GET") {
        return route.fulfill({
          status: 200, contentType: "application/json",
          body: JSON.stringify({ devices: [device], band: [] }),
        });
      }
      writes.push(`${route.request().method()} ${new URL(route.request().url()).pathname}`);
      return route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify({ device, applied: true, parity: "ok" }),
      });
    });
    await page.route("**/v1/identity/**", (route) => {
      writes.push(`${route.request().method()} ${new URL(route.request().url()).pathname}`);
      return route.fulfill({
        status: 200, contentType: "application/json",
        body: '{"identity":{"ip":"192.0.2.70","alias":"x"},"source":"hand-edit"}',
      });
    });
  }

  const HOST = {
    id: 1, cidr: "192.0.2.70/32", mode: "full-tunnel", name: "old-policy-label",
    note: "", band_member: false, alias: "living-room-tv",
  };
  const RANGE = {
    id: 2, cidr: "192.0.2.0/24", mode: "full-direct", name: "lab-subnet",
    note: "", band_member: false, alias: "",
  };

  test("renaming a host writes the alias, never the policy label", async ({
    page,
  }) => {
    const writes = [];
    await routeOneDevice(page, HOST, writes);
    await open(page, "devices");
    page.on("dialog", (d) => d.accept("study-tv"));
    await page.locator('[data-testid="device-rename"]').click();
    await page.waitForTimeout(400);
    expect(writes.some((w) => w.startsWith("PUT /v1/identity/")),
      `a /32 rename must write the identity layer, got: ${writes}`).toBe(true);
    expect(writes.some((w) => w.startsWith("PATCH /v1/devices/")),
      `a /32 rename must NOT write the policy label, got: ${writes}`).toBe(false);
  });

  test("renaming a range writes the policy name, the only one it can carry",
    async ({ page }) => {
      // An alias is structurally impossible for a range - identity keys on a
      // /32, and a CIDR's `/` cannot even address that endpoint. A single
      // unconditional write path would fail here with no visible reason.
      const writes = [];
      await routeOneDevice(page, RANGE, writes);
      await open(page, "devices");
      page.on("dialog", (d) => d.accept("lab-net"));
      await page.locator('[data-testid="device-rename"]').click();
      await page.waitForTimeout(400);
      expect(writes.some((w) => w.startsWith("PATCH /v1/devices/")),
        `a range rename must write devices.name, got: ${writes}`).toBe(true);
      expect(writes.some((w) => w.includes("/v1/identity/")),
        `a range cannot carry an alias, got: ${writes}`).toBe(false);
    });

  test("retiring a policy label asks first, and a refusal writes nothing",
    async ({ page }) => {
      // Destroying the second name must be a deliberate answer to a question,
      // never a side effect. A guard that is skipped writes on refusal, which
      // is precisely what this catches.
      const writes = [];
      await routeOneDevice(page, HOST, writes);
      await open(page, "devices");

      const asked = [];
      page.on("dialog", (d) => { asked.push(d.message()); d.dismiss(); });
      await page.locator('[data-testid="device-legacy-retire"]').click();
      await page.waitForTimeout(400);
      expect(asked.length, "retiring a stored name must be confirmed")
        .toBeGreaterThan(0);
      expect(writes, "a refused confirm must write nothing").toEqual([]);
    });

  test("a history read that fails says so instead of drawing an empty chart",
    async ({ page }) => {
      // An empty sparkline and one that could not be read are pixel-identical
      // and mean opposite things: one says this device sent nothing, the other
      // says nobody knows.
      const writes = [];
      await routeOneDevice(page, HOST, writes);
      await page.route("**/v1/stats/timeline**", (route) => route.fulfill({
        status: 503, contentType: "application/json",
        body: '{"detail":"stats store unavailable"}',
      }));
      await open(page, "devices");
      await page.locator('[data-testid="device-history"]').click();
      await expect(page.locator('[data-testid="notice-text"]'),
        "an unreadable history must be reported, not drawn as a flat line")
        .toBeVisible({ timeout: 10000 });
      await expect(page.locator('[data-testid^="device-sparkline"]'))
        .toHaveCount(0);
    });

  test("a range keeps its policy name and offers no retire action", async ({
    page,
  }) => {
    // The other direction: an alias is structurally impossible for a range
    // (identity keys on a /32), so its `name` is not displaced by anything and
    // there is nothing to retire. A UI that annotated it anyway would be
    // reporting a divergence that cannot exist.
    await page.route("**/v1/devices", (route) => {
      if (route.request().method() !== "GET") return route.continue();
      return route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify({
          devices: [{
            id: 2, cidr: "192.0.2.0/24", mode: "full-direct", name: "lab-subnet",
            note: "", band_member: false, alias: "",
          }],
          band: [],
        }),
      });
    });
    await open(page, "devices");
    await expect(page.locator('[data-testid="device-name"]'))
      .toHaveText("lab-subnet");
    await expect(page.locator('[data-testid="device-legacy-name"]'))
      .toHaveCount(0);
  });
});

test.describe("the band confirm guards both mutation paths", () => {
  // This replaces a textual gate that string-split `app.js` function bodies to
  // assert the guard existed. Splitting on a function name proves the SOURCE
  // contains a call; it can never prove the dialog fires, and it breaks on a
  // rename that changes nothing real. The browser can just ask.

  const devices = (band) => ({
    devices: [{ id: 1, cidr: "192.0.2.70/32", mode: "full-tunnel", name: "",
                note: "", band_member: band.length > 0, alias: "" }],
    band,
  });

  test("adding an address inside the static band asks first", async ({ page }) => {
    await page.route("**/v1/devices", (route) => {
      if (route.request().method() !== "GET") return route.continue();
      return route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify(devices(["192.0.2.64/28"])),
      });
    });
    await open(page, "devices");

    const asked = [];
    page.on("dialog", (d) => { asked.push(d.message()); d.dismiss(); });

    await page.locator('[data-testid="add-address"]').fill("192.0.2.70");
    await page.locator('[data-testid="add-submit"]').click();
    await page.waitForTimeout(400);
    expect(asked.length, "a band address must be confirmed before it is added")
      .toBeGreaterThan(0);
  });

  test("a host added but not named says so, even on a 403", async ({ page }) => {
    /* The add path writes twice with no transaction between them: the policy
       row, then the alias. The other calls stay silent on a 403 because there
       it means the operator dismissed the token prompt and nothing happened.
       Here the device already exists, so silence would leave it named in the
       form and unnamed in the panel - the name simply gone. */
    await page.route("**/v1/devices", (route) => {
      if (route.request().method() === "GET") {
        return route.fulfill({
          status: 200, contentType: "application/json",
          body: JSON.stringify(devices([])),
        });
      }
      return route.fulfill({
        status: 201, contentType: "application/json",
        body: JSON.stringify({
          device: { id: 9, cidr: "198.51.100.5/32", mode: "full-tunnel" },
          applied: true, parity: "ok",
        }),
      });
    });
    await page.route("**/v1/identity/**", (route) => route.fulfill({
      status: 403, contentType: "application/json",
      body: '{"detail":"invalid or missing bearer token"}',
    }));
    await open(page, "devices");
    await page.locator('[data-testid="add-address"]').fill("198.51.100.5");
    await page.locator('[data-testid="add-name"]').fill("kitchen-tv");
    await page.locator('[data-testid="add-submit"]').click();
    // The 403 prompts for a token first; cancelling is the operator saying
    // "no", which is exactly when the device is left existing and unnamed.
    await expect(page.locator('[data-testid="token-dialog"]')).toBeVisible();
    await page.locator('[data-testid="token-cancel"]').click();
    await expect(page.locator('[data-testid="notice-text"]'),
      "a device added without its name must say so")
      .toBeVisible({ timeout: 10000 });
  });

  test("an address outside the band is not gated", async ({ page }) => {
    // The other direction: a guard that fires on everything is a guard nobody
    // reads, and this is what tells the two apart.
    await page.route("**/v1/devices", (route) => {
      if (route.request().method() !== "GET") return route.continue();
      return route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify(devices([])),
      });
    });
    await open(page, "devices");

    const asked = [];
    page.on("dialog", (d) => { asked.push(d.message()); d.dismiss(); });

    await page.locator('[data-testid="add-address"]').fill("198.51.100.5");
    await page.locator('[data-testid="add-submit"]').click();
    await page.waitForTimeout(400);
    expect(asked, "a non-band address must not be gated").toEqual([]);
  });

  test("the add path re-reads the band instead of trusting a stale cache",
    async ({ page }) => {
      // The sharpest of the three properties the retired textual gate held,
      // and the one a naive spec misses: if the FIRST load saw no band, only
      // an implementation that re-fetches before deciding will discover the
      // address is inside one. A cached empty list would sail straight past
      // the guard - a band member silently escaping the confirm.
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
      await open(page, "devices");

      const asked = [];
      page.on("dialog", (d) => { asked.push(d.message()); d.dismiss(); });

      await page.locator('[data-testid="add-address"]').fill("192.0.2.70");
      await page.locator('[data-testid="add-submit"]').click();
      await page.waitForTimeout(500);
      expect(seen, "the add path must re-read /v1/devices before deciding")
        .toBeGreaterThan(1);
      expect(asked.length,
        "a band discovered by the refresh must still trigger the confirm")
        .toBeGreaterThan(0);
    });
});
