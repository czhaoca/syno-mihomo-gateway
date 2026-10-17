import { expect, test } from "@playwright/test";

import { buildGrid, sparseGrid } from "../src/charts/grid.js";

/**
 * The bucket grid's rules (#100 DEC-D), on the module itself - no browser.
 * charts.spec.js draws the golden DAILY series; these are the branches it
 * cannot reach: the minute and hour tiers, a partial gap, the truncated gap
 * list, a moved day boundary, a gap mapped under a real zone across DST, a
 * last poll read as a local day west of UTC, the regions before the data
 * and after the last poll, malformed rows, and the device strip's breaks.
 */

const at = (iso) => Date.parse(iso);
const cells = (g) => g.cells.map((c) => [c.key, c.held ? c.up : null, c.gap]);

test("the grid tells each bucket what it may claim", () => {
  // hour tier: a held bucket a gap touches keeps its value (partial); one
  // without a row inside the gap is a value-less band; one without a row
  // and no gap is a zero; the axis starts at the window, the regions bound
  // it, and nothing after the last poll is zero-filled
  const hour = buildGrid({
    rows: [{ bucket: "2026-10-15T10", up: 1, down: 1 },
           { bucket: "2026-10-15T12", up: 3, down: 3 }],
    tier: "hour", windowStart: new Date("2026-10-15T08:30:00Z"),
    lastPoll: "2026-10-15T13:10:00Z",
    gaps: [{ started: "2026-10-15T10:59:00Z", ended: "2026-10-15T11:30:00Z" }],
    now: at("2026-10-15T14:05:00Z"),
  });
  expect(cells(hour)).toEqual([
    ["2026-10-15T10", 1, "partial"], ["2026-10-15T11", null, "full"],
    ["2026-10-15T12", 3, ""], ["2026-10-15T13", null, ""],
  ]);
  expect(hour.cells[3].up).toBe(0);
  expect(hour.before).toEqual({ from: 0, to: 2, until: "2026-10-15T10" });
  expect(hour.stale).toEqual({ from: 6, to: 7, since: "2026-10-15T13" });
  expect(hour.units).toBe(7);

  // minute tier: the same keys the backend writes
  const minute = buildGrid({
    rows: [{ bucket: "2026-10-15T10:00", up: 1, down: 0 },
           { bucket: "2026-10-15T10:03", up: 2, down: 0 }],
    tier: "minute", lastPoll: "2026-10-15T10:03:30Z",
    now: at("2026-10-15T10:03:40Z"),
  });
  expect(minute.cells.map((c) => c.key)).toEqual([
    "2026-10-15T10:00", "2026-10-15T10:01", "2026-10-15T10:02",
    "2026-10-15T10:03"]);
  expect(minute.stale).toBeNull();

  // a gap list cut at its limit: older missing buckets are breaks, but
  // the rows held there still show
  const cut = buildGrid({
    rows: [{ bucket: "2026-10-15T08", up: 1, down: 1 },
           { bucket: "2026-10-15T12", up: 1, down: 1 }],
    tier: "hour", gapsTruncated: true,
    gaps: [{ started: "2026-10-15T10:30:00Z", ended: "2026-10-15T10:40:00Z" }],
    now: at("2026-10-15T12:10:00Z"),
  });
  expect(cut.cells.map((c) => c.key)).toEqual([
    "2026-10-15T08", "2026-10-15T10", "2026-10-15T11", "2026-10-15T12"]);

  // no gap list for this window at all: every missing bucket is a break
  const unknown = buildGrid({
    rows: [{ bucket: "2026-10-15T08", up: 1, down: 1 },
           { bucket: "2026-10-15T11", up: 1, down: 1 }],
    tier: "hour", gapsKnown: false, now: at("2026-10-15T11:10:00Z"),
  });
  expect(unknown.cells.map((c) => c.key)).toEqual(["2026-10-15T08",
                                                   "2026-10-15T11"]);

  // day tier: a boundary that moves is one seam, and a date held under two
  // framings is two bars
  const ny = { bucket_tz: "America/New_York", day_boundary: "00:00" };
  const utc = { bucket_tz: "UTC", day_boundary: "00:00" };
  const day = buildGrid({
    rows: [{ bucket: "2026-10-31", up: 1, down: 1, ...ny },
           { bucket: "2026-11-01", up: 1, down: 1, ...ny },
           { bucket: "2026-11-01", up: 2, down: 2, ...utc },
           { bucket: "2026-11-03", up: 1, down: 1, ...utc }],
    tier: "day",
    lastPoll: "2026-11-03T10:00:00Z", now: at("2026-11-03T11:00:00Z"),
  });
  expect(day.cells.map((c) => [c.key, c.seam, c.gap, c.width])).toEqual([
    ["2026-10-31", false, "", 1],
    ["2026-11-01", false, "", 0.5],
    ["2026-11-01", true, "", 0.5],
    ["2026-11-02", false, "", 1],
    ["2026-11-03", false, "", 1],
  ]);

  // a gap maps onto the local day it fell in through that day's own zone -
  // across New York's DST end (2026-11-01 06:00 UTC): 2026-11-02 04:10 UTC
  // is 23:10 EST on 11-01, where the summer offset would put it on 11-02.
  // So 11-01 keeps its value under the hatch, and 11-02 is a real zero.
  const dst = buildGrid({
    rows: [{ bucket: "2026-10-31", up: 1, down: 1, ...ny },
           { bucket: "2026-11-01", up: 1, down: 1, ...ny },
           { bucket: "2026-11-03", up: 1, down: 1, ...ny }],
    tier: "day",
    gaps: [{ started: "2026-11-02T04:10:00Z", ended: "2026-11-02T04:20:00Z" }],
    lastPoll: "2026-11-03T15:00:00Z", now: at("2026-11-03T16:00:00Z"),
  });
  expect(dst.cells.map((c) => [c.key, c.gap])).toEqual([
    ["2026-10-31", ""], ["2026-11-01", "partial"], ["2026-11-02", ""],
    ["2026-11-03", ""]]);

  // the last poll and "now" are LOCAL days too: at 03:00 UTC on 10-16 it is
  // still 10-15 in Los Angeles, so nothing - not even a zero - is drawn
  // for a day that has not begun there
  const la = { bucket_tz: "America/Los_Angeles", day_boundary: "00:00" };
  const west = buildGrid({
    rows: [{ bucket: "2026-10-14", up: 1, down: 1, ...la },
           { bucket: "2026-10-15", up: 1, down: 1, ...la }],
    tier: "day",
    lastPoll: "2026-10-16T03:00:00Z", now: at("2026-10-16T03:30:00Z"),
  });
  expect(west.cells.map((c) => c.key)).toEqual(["2026-10-14", "2026-10-15"]);
  expect(west.stale).toBeNull();
  // ... two dates away with a late boundary: under a 20:00 cut, 02:00 UTC
  // on 10-16 is 19:00 on 10-15 in Los Angeles - still local day 10-14
  const late = { bucket_tz: "America/Los_Angeles", day_boundary: "20:00" };
  const later = buildGrid({
    rows: [{ bucket: "2026-10-13", up: 1, down: 1, ...late },
           { bucket: "2026-10-14", up: 1, down: 1, ...late }],
    tier: "day",
    lastPoll: "2026-10-16T02:00:00Z", now: at("2026-10-16T02:30:00Z"),
  });
  expect(later.cells.map((c) => c.key)).toEqual(["2026-10-13", "2026-10-14"]);

  // a truncated gap list, east of UTC: Shanghai's local day 10-05 (03:00
  // cut) ends at 19:00 UTC, before the oldest gap listed - it lies wholly
  // in time the list does not cover, so it is a break, not a zero; 10-06
  // holds that gap
  const sh = { bucket_tz: "Asia/Shanghai", day_boundary: "03:00" };
  const east = buildGrid({
    rows: [{ bucket: "2026-10-03", up: 1, down: 1, ...sh },
           { bucket: "2026-10-07", up: 1, down: 1, ...sh }],
    tier: "day", gapsTruncated: true,
    gaps: [{ started: "2026-10-05T20:00:00Z", ended: "2026-10-05T20:10:00Z" }],
    lastPoll: "2026-10-07T10:00:00Z", now: at("2026-10-07T10:30:00Z"),
  });
  expect(east.cells.map((c) => [c.key, c.gap])).toEqual([
    ["2026-10-03", ""], ["2026-10-06", "full"], ["2026-10-07", ""]]);

  // the span older than the hostname class keeps (#101) is a region of its
  // own, through the bucket that holds the cap - beneath bars that are
  // still real; where a scope's own data IS that class, it replaces
  // "before the data starts" over the same span
  const shadeArgs = {
    rows: [{ bucket: "2026-10-15T08", up: 1, down: 1 },
           { bucket: "2026-10-15T12", up: 1, down: 1 }],
    tier: "hour", windowStart: new Date("2026-10-15T06:00:00Z"),
    lastPoll: "2026-10-15T12:10:00Z", now: at("2026-10-15T12:20:00Z"),
    shadeUntil: at("2026-10-15T09:30:00Z"),
  };
  const shaded = buildGrid(shadeArgs);
  expect(shaded.shade).toEqual({ from: 0, to: 4, until: "2026-10-15T09" });
  expect(shaded.before).toEqual({ from: 0, to: 2, until: "2026-10-15T08" });
  expect(cells(shaded).map(([key, up]) => [key, up])).toEqual([
    ["2026-10-15T08", 1], ["2026-10-15T09", null], ["2026-10-15T10", null],
    ["2026-10-15T11", null], ["2026-10-15T12", 1]]);
  expect(buildGrid({ ...shadeArgs, shadeOverBefore: true }).before).toBeNull();
  expect(buildGrid({ ...shadeArgs, shadeUntil: null }).shade).toBeNull();
  // a floor ON a bucket start: that bucket is the first one kept
  expect(buildGrid({ ...shadeArgs, shadeUntil: at("2026-10-15T10:00:00Z") }).shade)
    .toEqual({ from: 0, to: 4, until: "2026-10-15T09" });

  // nothing to draw is nothing at all - never a zero row
  expect(buildGrid({ rows: [], tier: "hour" }).cells).toEqual([]);
  expect(buildGrid({ rows: [{ bucket: "garbage", up: 1, down: 1 }],
                     tier: "hour" }).cells).toEqual([]);
  // garbage BESIDE valid rows is dropped (it once sent the slot loop to
  // NaN), the valid rows still draw, and a last poll that is not a
  // timestamp is ignored rather than trusted
  const mixed = buildGrid({
    rows: [{ bucket: "garbage", up: 9, down: 9 }, null, { bucket: 7 },
           { bucket: "2026-10-15T1x", up: 9, down: 9 },
           { bucket: "2026-10-15T11:00", up: 9, down: 9 },
           { bucket: "2026-10-15T10", up: 1, down: 1 }],
    tier: "hour", lastPoll: "not-a-date", now: at("2026-10-15T10:30:00Z"),
  });
  expect(cells(mixed)).toEqual([["2026-10-15T10", 1, ""]]);
  // ... and so is a poll stamped far past "now": trusted, it would stretch
  // the grid past its slot limit and blank every bar held
  const future = buildGrid({
    rows: [{ bucket: "2026-10-15T10", up: 1, down: 1 }], tier: "hour",
    lastPoll: "2099-01-01T00:00:00Z", now: at("2026-10-15T10:30:00Z"),
  });
  expect(cells(future)).toEqual([["2026-10-15T10", 1, ""]]);

  // a device strip leaves a missing bucket as a break
  const strip = sparseGrid([{ bucket: "2026-10-15T10:00", up: 1, down: 1 },
                            { bucket: "2026-10-15T10:04", up: 2, down: 2 }],
                           "minute");
  // two bars, four slots apart: the minutes between are empty space, not
  // zeros drawn across
  expect(strip.cells.map((c) => [c.key, c.x])).toEqual([
    ["2026-10-15T10:00", 0], ["2026-10-15T10:04", 4]]);
  expect(strip.units).toBe(5);
});
