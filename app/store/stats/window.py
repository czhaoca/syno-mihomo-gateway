"""Window-complete reads (#91): a `range=` read unions the resolution's tier
with every finer one. See the section comment below for why that is exact."""

from bisect import bisect_left
from datetime import UTC, datetime, timedelta

from app.store import dayframe
from app.store.stats.read import _TIER_TABLES

# --- window-complete reads (#91) ---------------------------------------------
#
# Rollup MOVES rows: minute rows older than the minute window are summed into
# hours and deleted, hours older than the hour window into local days and
# deleted. So the three tiers are DISJOINT - every byte lives in exactly one
# of them - and a read that touches one tier table sees only that tier's
# slice of time. A `range=` read therefore unions the resolution's own tier
# with every FINER tier, which hold the newer tail not rolled yet. Disjoint
# tiers make the union exact: no byte can be counted twice (invariant I-1,
# docs/brainstorms/gateway-insights.md).
#
# Coarser tiers are never consulted: a window longer than the resolution
# tier's retention ends at that tier's horizon, as a single-tier read always
# has. The presets below are chosen so that never happens under the shipped
# retention knobs (48 h minute / 90 d hour / 730 d day).

# The panel's range vocabulary: settings.STATS_RANGES is the one list (the UI
# selector and the stored default use it; a test pins these keys to it).
# Each preset is (resolution, window in hours; None = everything held).
RANGE_SPECS = {"48h": ("minute", 48), "7d": ("hour", 24 * 7),
               "30d": ("hour", 24 * 30), "daily": ("day", None)}

_TIER_RANK = {"minute": 0, "hour": 1, "day": 2}

# Sorts after every digit, so `key >= _NOTHING` matches no bucket at all.
_NOTHING = "~"


def range_window(range_name: str, now: datetime):
    """(resolution, window start or None) for a range preset at NOW."""
    resolution, hours = RANGE_SPECS[range_name]
    if hours is None:
        return resolution, None
    return resolution, now - timedelta(hours=hours)


def _usable(frame):
    # the same degradation rollup applies: a frame that cannot key locally
    # keys in UTC, and says so through the stamp it writes
    return frame if frame.ok else dayframe.utc_frame()


def window_key(moment: datetime, resolution: str, frame) -> str:
    """The bucket key MOMENT falls in at RESOLUTION.

    A local day is keyed from the UTC HOUR bucket the moment falls in - the
    exact mapping rollup applies when it files that hour into the day tier,
    so a window boundary and a stored row can never disagree about which
    day an hour belongs to.
    """
    moment = moment.astimezone(UTC)
    if resolution == "minute":
        return moment.strftime("%Y-%m-%dT%H:%M")
    hour = moment.strftime("%Y-%m-%dT%H")
    if resolution == "hour":
        return hour
    return dayframe.day_key(hour, _usable(frame))


def _first_hour_of_day(conn, since_day: str, frame) -> str:
    """The earliest UTC hour bucket, among those the hour and minute tiers
    hold, whose LOCAL day is >= SINCE_DAY - or _NOTHING when none is.

    SQLite cannot do timezone arithmetic, so the day boundary is found in
    Python, but only O(log n) hours are converted: the local day of an hour
    does not decrease as the hour advances, which makes the held hours a
    sorted sequence under `day_key`. Every hour at or after the one found
    belongs to the window; every hour before it does not.

    "Does not decrease" holds for every zone whose DST shift is no larger
    than the gap between the cut and the shift - all inhabited zones with
    a whole-hour cut. A pathological pairing (a 2-hour fall-back across the
    cut, e.g. Antarctica/Troll with a 02:00 cut) can step one hour backwards
    once a year, misplacing the window start by that hour on that day.
    """
    hours = [r[0] for r in conn.execute(
        "SELECT DISTINCT hk FROM (SELECT bucket AS hk FROM stats_hour "
        "UNION SELECT substr(bucket, 1, 13) FROM stats_minute) ORDER BY hk")]
    i = bisect_left(hours, since_day, key=lambda h: dayframe.day_key(h, frame))
    return hours[i] if i < len(hours) else _NOTHING


def _window_plan(conn, resolution: str, since, frame) -> list:
    """[(table, hour_or_finer_key_expr, lower_bound_or_None)] - the
    resolution's tier plus every finer one, each with the lower bound it is
    filtered on. Finer rows are compared at the RESOLUTION's granularity, so
    the window starts on a resolution boundary in every tier alike and a
    row's rollup state cannot move it in or out of the window.

    A bounded DAY window starts on a local day of the CURRENT framing. A
    stored day row stamped under a different framing is a whole day of that
    other framing and cannot be split, so it is kept or dropped by its date
    alone - the same approximation every multi-framing day read makes, and
    the reason `framings` reports more than one stamp when it happens."""
    plan = []
    if since is None:
        bounds = {"minute": None, "hour": None, "day": None}
    elif resolution == "minute":
        bounds = {"minute": window_key(since, "minute", frame)}
    elif resolution == "hour":
        key = window_key(since, "hour", frame)
        bounds = {"minute": key, "hour": key}
    else:
        since_day = window_key(since, "day", frame)
        first = _first_hour_of_day(conn, since_day, frame)
        bounds = {"minute": first, "hour": first, "day": since_day}
    for tier in ("day", "hour", "minute"):
        if _TIER_RANK[tier] > _TIER_RANK[resolution]:
            continue
        # a minute row is compared at minute granularity only when minute IS
        # the resolution; otherwise by the hour it falls in
        expr = ("substr(bucket, 1, 13)"
                if tier == "minute" and resolution != "minute" else "bucket")
        plan.append((_TIER_TABLES[tier], expr, bounds.get(tier)))
    return plan


def _union(plan, columns: str, device: str = "") -> tuple[str, list]:
    selects, params = [], []
    for table, expr, bound in plan:
        where = []
        if device:
            where.append("device = ?")
            params.append(device)
        if bound is not None:
            where.append(f"{expr} >= ?")
            params.append(bound)
        clause = f" WHERE {' AND '.join(where)}" if where else ""
        selects.append(f"SELECT {columns.format(k=expr)} FROM {table}{clause}")
    return " UNION ALL ".join(selects), params


def read_window_grouped(conn, resolution: str, group_col: str, since,
                        frame) -> list:
    """Per-GROUP_COL totals over a window, summed across every tier at or
    finer than RESOLUTION. Same row shape as `read_grouped`."""
    frame = _usable(frame)
    union, params = _union(_window_plan(conn, resolution, since, frame),
                           f"{group_col} AS g, up, down")
    rows = conn.execute(
        f"SELECT g AS {group_col}, SUM(up) AS up, SUM(down) AS down "
        f"FROM ({union}) GROUP BY g ORDER BY g", params).fetchall()
    return [dict(r) for r in rows]


def read_window_timeline(conn, resolution: str, device: str, since,
                         frame) -> list:
    """Bucket rows at RESOLUTION over a window, every tier at or finer than
    it included. Same row shapes as `read_timeline`.

    At day resolution the not-yet-rolled hours are keyed into local days
    under FRAME - the current framing, the same key and stamp rollup will
    give them - and merged with the day tier's stored rows. A synthesised
    day and a stored one with the same date AND stamp are one row (half a
    day rolled, half not); with different stamps they stay two, so a
    changed day boundary remains visible rather than summed away.
    """
    frame = _usable(frame)
    plan = _window_plan(conn, resolution, since, frame)
    if resolution != "day":
        union, params = _union(plan, "{k} AS k, up, down", device)
        rows = conn.execute(
            f"SELECT k AS bucket, SUM(up) AS up, SUM(down) AS down "
            f"FROM ({union}) GROUP BY k ORDER BY k", params).fetchall()
        return [dict(r) for r in rows]
    days = {}
    day_plan = [p for p in plan if p[0] == "stats_day"]
    finer = [p for p in plan if p[0] != "stats_day"]
    union, params = _union(day_plan,
                           "bucket, bucket_tz, day_boundary, up, down", device)
    for r in conn.execute(
            f"SELECT bucket, bucket_tz, day_boundary, SUM(up) AS up, "
            f"SUM(down) AS down FROM ({union}) "
            f"GROUP BY bucket, bucket_tz, day_boundary", params):
        days[(r["bucket"], r["bucket_tz"], r["day_boundary"])] = [r["up"],
                                                                  r["down"]]
    union, params = _union(finer, "{k} AS k, up, down", device)
    for r in conn.execute(
            f"SELECT k, SUM(up) AS up, SUM(down) AS down FROM ({union}) "
            f"GROUP BY k", params):
        key = (dayframe.day_key(r["k"], frame), frame.tz, frame.cut)
        acc = days.setdefault(key, [0, 0])
        acc[0] += r["up"]
        acc[1] += r["down"]
    return [{"bucket": b, "bucket_tz": tz, "day_boundary": cut,
             "up": up, "down": down}
            for (b, tz, cut), (up, down) in sorted(days.items())]


def window_framings(conn, since, frame) -> list:
    """The framings a day-resolution window is made of: every stamp stored
    in the day tier inside it, plus the CURRENT frame when any not-yet-rolled
    hour falls inside it (those are keyed under it). Same shape and order as
    `day_framings`; more than one means the day boundary moved inside the
    window."""
    frame = _usable(frame)
    plan = _window_plan(conn, "day", since, frame)
    found = set()
    for table, expr, bound in plan:
        clause, params = (f" WHERE {expr} >= ?", [bound]) if bound else ("", [])
        if table == "stats_day":
            found.update(
                (r[0], r[1]) for r in conn.execute(
                    f"SELECT DISTINCT bucket_tz, day_boundary FROM stats_day"
                    f"{clause}", params))
        elif conn.execute(f"SELECT 1 FROM {table}{clause} LIMIT 1",
                          params).fetchone():
            found.add((frame.tz, frame.cut))
    return [{"bucket_tz": tz, "day_boundary": cut}
            for tz, cut in sorted(found)]
