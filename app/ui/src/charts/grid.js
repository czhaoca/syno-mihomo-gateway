/* The bucket grid (#100 DEC-D): the one place a sparse timeline becomes the
   regular sequence of buckets a chart draws, and the one place each bucket
   is told what it may claim.

   The backend lists a bucket only when it moved bytes (#98), and records a
   collection gap only as a row in /v1/stats/gaps. So, between the first row
   held and the last good poll:
     a bucket with a row          a value
     a bucket without one         a real zero - the collector ran and saw
                                  nothing
     either, overlapped by a gap  a hole: a bucket WITHOUT a row is a
                                  value-less hatched band (`gap: "full"`),
                                  one WITH a row keeps its value and is
                                  marked `gap: "partial"`
   and outside that span nothing is claimed at all: the span before the
   first row (`before`) and the one after the last good poll (`stale`) are
   regions, not zeros. A day that changed its boundary is a SEAM: a day row
   whose framing stamp differs from the previous day row's, and a date held
   under two framings is two bars sharing its slot.

   Keys are the backend's own strings, joined by equality: UTC minute and
   hour keys, and day keys that are LOCAL dates - stepped one calendar day
   at a time. A gap is mapped onto a local day through that day's own
   framing (its zone and day boundary, which every day row is stamped
   with); a day with no framing to go by is widened by the largest UTC
   offset either way instead, so a gap marks too many days rather than too
   few. Mark counts depend on the data alone, never on a measured width. */

export const KEY_LEN = { minute: 16, hour: 13, day: 10 };
const STEP_MS = { minute: 60_000, hour: 3_600_000, day: 86_400_000 };
const SUFFIX = { minute: ":00Z", hour: ":00:00Z", day: "T00:00:00Z" };
// the widest UTC offset either way: a local day can start this far from
// its UTC date
const DAY_SLACK_MS = 14 * 3_600_000;

export function keyAt(moment, tier) {
  return new Date(moment).toISOString().slice(0, KEY_LEN[tier]);
}

export function keyStart(key, tier) {
  return Date.parse(key + SUFFIX[tier]);
}

function step(key, tier) {
  return keyAt(keyStart(key, tier) + STEP_MS[tier], tier);
}

function offset(fromKey, toKey, tier) {
  return Math.round((keyStart(toKey, tier) - keyStart(fromKey, tier))
                    / STEP_MS[tier]);
}

/* ZONE's offset from UTC at INSTANT, in ms (local minus UTC). */
function zoneOffset(zone, instant) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: zone, hourCycle: "h23", year: "numeric", month: "2-digit",
    day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(instant)).map((p) => [p.type, p.value]));
  return Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour,
                  +parts.minute, +parts.second) - instant;
}

/* The UTC instant the local day KEY starts at under ZONE with day boundary
   CUT ("HH:MM") - the day runs from KEY's CUT to the next date's. */
function dayStart(key, zone, cut) {
  const [h, m] = cut.split(":").map(Number);
  const wall = Date.parse(`${key}T00:00:00Z`) + (h * 60 + m) * 60_000;
  const first = wall - zoneOffset(zone, wall);
  // once more at the found instant: a DST change near the boundary
  return wall - zoneOffset(zone, first);
}

function span(key, tier, frame) {
  const start = keyStart(key, tier);
  const end = start + STEP_MS[tier];
  if (tier !== "day") return [start, end];
  if (frame) {
    try {
      return [dayStart(key, frame.tz, frame.cut),
              dayStart(step(key, tier), frame.tz, frame.cut)];
    } catch {
      // an unknown zone: fall back to the widest offsets
    }
  }
  return [start - DAY_SLACK_MS, end + DAY_SLACK_MS];
}

function overlapsGap(key, tier, gaps, frame) {
  const [start, end] = span(key, tier, frame);
  return gaps.some(([from, to]) => from < end && to > start);
}

/* The local day INSTANT falls in under FRAME (a day key), or its UTC date
   when no framing is known. A late boundary west of UTC (or an early one
   east of it) can put the local day two dates from the UTC one, so this
   walks rather than stepping once. */
function localDay(instant, frame) {
  let key = keyAt(instant, "day");
  if (!frame) return key;
  try {
    for (let i = 0; i < 3 && instant < dayStart(key, frame.tz, frame.cut); i += 1) {
      key = keyAt(keyStart(key, "day") - STEP_MS.day, "day");
    }
    for (let i = 0; i < 3
         && instant >= dayStart(step(key, "day"), frame.tz, frame.cut); i += 1) {
      key = step(key, "day");
    }
  } catch {
    // an unknown zone: the UTC date
  }
  return key;
}

/* Whether the bucket KEY ends at or before INSTANT - for a day without a
   framing, at the EARLIEST it could end, so an unknown day is never taken
   for a known one. */
function endsBy(key, tier, frame, instant) {
  const end = tier === "day" && !frame
    ? keyStart(key, tier) + STEP_MS.day - DAY_SLACK_MS
    : span(key, tier, frame)[1];
  return end <= instant;
}

function frameOf(row) {
  return row && row.bucket_tz && row.day_boundary
    ? { tz: row.bucket_tz, cut: row.day_boundary } : null;
}

function framing(row) {
  return row.bucket_tz === undefined ? null
    : `${row.bucket_tz} ${row.day_boundary}`;
}

/* The grid of a window read at TIER. ROWS are the read's rows; WINDOW_START
   (a Date or null for "everything held") and NOW bound the axis; LAST_POLL
   (an ISO stamp or null) is the last good poll; GAPS are /v1/stats/gaps
   rows, and GAPS_TRUNCATED says the list was cut at its limit - then no
   bucket older than its oldest gap is known to be gap-free, so a bucket
   there without a row is a break rather than a zero (rows held there still
   show). GAPS_KNOWN false (the gap read failed for this window) makes every
   bucket without a row a break. Returns the cells and the regions, in slot
   units. */
const MAX_SLOTS = 20_000;

export function buildGrid({ rows, tier, windowStart = null, lastPoll = null,
                            gaps = [], gapsTruncated = false,
                            gapsKnown = true, now = Date.now() }) {
  // a row whose key is not this tier's key is dropped, not drawn - and
  // never allowed to send the slot arithmetic to NaN
  const held = (rows || []).filter((r) => r && typeof r.bucket === "string"
      && KEY_LEN[tier] && r.bucket.length === KEY_LEN[tier]
      && Number.isFinite(keyStart(r.bucket, tier)))
    .slice().sort((a, b) => (a.bucket < b.bucket ? -1
      : a.bucket > b.bucket ? 1
        : String(framing(a)).localeCompare(String(framing(b)))));
  const intervals = (gaps || []).map((g) => [Date.parse(g.started),
                                              Date.parse(g.ended)])
    .filter(([a, b]) => Number.isFinite(a) && Number.isFinite(b));
  const empty = { tier, units: 0, cells: [], before: null, stale: null,
                  max: 0, axisStart: null, axisEnd: null };
  if (!held.length) return empty;
  const dataStart = held[0].bucket;
  // with a truncated gap list, the instant from which a missing row is
  // known to be a zero: a bucket that ENDS by then lies wholly in time the
  // list does not cover (on the day tier through the day's own framing)
  const knownSince = gapsTruncated && intervals.length
    ? Math.min(...intervals.map(([from]) => from)) : -Infinity;
  let lastKey = held[held.length - 1].bucket;
  // the newest framing held: the one "now" and the last poll are read in
  const newest = frameOf(held[held.length - 1]);
  const bucketOf = (instant) => (tier === "day"
    ? localDay(instant, newest) : keyAt(instant, tier));
  const polledAt = lastPoll ? Date.parse(lastPoll) : NaN;
  // a poll more than a day past "now" is a broken stamp, not a clock skew:
  // trusted, it would stretch the grid past its slot limit and blank it
  if (Number.isFinite(polledAt) && polledAt <= now + STEP_MS.day) {
    // the bucket the last good poll fell in: up to there the collector ran
    // and a missing row is a zero (on the day tier the LOCAL day it fell
    // in, under the newest framing held)
    const polled = bucketOf(polledAt);
    if (polled > lastKey) lastKey = polled;
  }
  let axisStart = dataStart;
  if (windowStart) {
    const asked = keyAt(windowStart, tier);
    if (asked < axisStart) axisStart = asked;
  }
  let axisEnd = bucketOf(now);
  if (axisEnd < lastKey) axisEnd = lastKey;

  const byKey = new Map();
  for (const row of held) {
    if (!byKey.has(row.bucket)) byKey.set(row.bucket, []);
    byKey.get(row.bucket).push(row);
  }
  const cells = [];
  let previous = null;   // the framing of the previous day row
  // the framing a day without a row is read under: the previous day row's,
  // or for days before any, the first one's
  let frameNow = frameOf(held[0]);
  let max = 0;
  if (offset(dataStart, lastKey, tier) > MAX_SLOTS) return empty;
  for (let key = dataStart; key <= lastKey; key = step(key, tier)) {
    const x = offset(axisStart, key, tier);
    const here = byKey.get(key);
    if (here) frameNow = frameOf(here[here.length - 1]) || frameNow;
    const gapped = intervals.length > 0
      && overlapsGap(key, tier, intervals, here ? frameOf(here[0]) : frameNow);
    if (!here) {
      // unknown: a break, not a zero
      if (!gapsKnown || endsBy(key, tier, frameNow, knownSince)) continue;
      cells.push({ key, x, width: 1, up: 0, down: 0, held: false,
                   gap: gapped ? "full" : "", seam: false });
      continue;
    }
    // a date held under two framings: the bar that continues the previous
    // day's framing first, so the one seam falls where the boundary moved
    const ordered = previous === null ? here : [
      ...here.filter((r) => framing(r) === previous),
      ...here.filter((r) => framing(r) !== previous)];
    ordered.forEach((row, i) => {
      const frame = framing(row);
      const seam = tier === "day" && previous !== null && frame !== previous;
      if (frame !== null) previous = frame;
      const up = Number(row.up) || 0;
      const down = Number(row.down) || 0;
      if (up + down > max) max = up + down;
      cells.push({ key, x: x + i / here.length, width: 1 / here.length, up,
                   down, held: true, gap: gapped ? "partial" : "", seam,
                   framing: frame });
    });
  }
  const units = offset(axisStart, axisEnd, tier) + 1;
  const firstX = offset(axisStart, dataStart, tier);
  const lastX = offset(axisStart, lastKey, tier) + 1;
  return {
    tier, units, cells, max, axisStart, axisEnd,
    before: firstX > 0 ? { from: 0, to: firstX, until: dataStart } : null,
    stale: lastX < units ? { from: lastX, to: units, since: lastKey } : null,
  };
}

/* A grid of the rows alone - no zero-fill, no axis window. For a strip
   that reads no gap list (a device's history): each bar sits at its own
   time, so a missing bucket is a break - empty space, never a zero drawn
   across it. Without a TIER (or with keys that do not parse) the bars sit
   in order instead. */
export function sparseGrid(rows, tier = null) {
  const held = (rows || []).filter((r) => r && typeof r.bucket === "string")
    .slice().sort((a, b) => (a.bucket < b.bucket ? -1 : 1));
  const timed = Boolean(KEY_LEN[tier]) && held.length > 0
    && held.every((r) => Number.isFinite(keyStart(r.bucket, tier)))
    && offset(held[0].bucket, held[held.length - 1].bucket, tier) <= MAX_SLOTS;
  let max = 0;
  const cells = held.map((row, i) => {
    const up = Number(row.up) || 0;
    const down = Number(row.down) || 0;
    if (up + down > max) max = up + down;
    return { key: row.bucket, x: timed ? offset(held[0].bucket, row.bucket, tier) : i,
             width: 1, up, down, held: true, gap: "", seam: false };
  });
  const units = !cells.length ? 0
    : timed ? cells[cells.length - 1].x + 1 : cells.length;
  return { tier, units, cells, max, before: null, stale: null,
           axisStart: held.length ? held[0].bucket : null,
           axisEnd: held.length ? held[held.length - 1].bucket : null };
}
