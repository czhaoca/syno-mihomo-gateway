"""Single-tier reads (the `tier`-only API, unchanged since v1.8.0), the
dimension, domain and gap reads."""

from app.store.stats.schema import DIMENSIONS, MINUTE_TABLE

_TIER_TABLES = {"minute": MINUTE_TABLE, "hour": "stats_hour",
                "day": "stats_day"}

# The byte reads list a group only when it moved bytes (#98 DEC-E). Since
# #94 a tier row is also written for a connection that only appeared, so its
# `conns` fact survives; before #94 no such row existed, and these reads
# never listed a zero-byte group. The filter keeps their answers exactly as
# they were, while the stored rows keep their facts.
MOVED = "HAVING SUM(up) + SUM(down) > 0"


def dimension_tables(dim: str) -> dict:
    """{tier: table} for one long-term dimension (#95) - hour and day only:
    nothing new enters the minute tier (brief DEC-4)."""
    if dim not in DIMENSIONS:
        raise ValueError(f"unknown dimension {dim!r}")
    return {"hour": f"stats_{dim}_hour", "day": f"stats_{dim}_day"}


def read_dimension(conn, dim: str, tier: str, since: str = "",
                   until: str = "", device: str = "") -> list:
    """Per-value totals of one dimension's TIER table - the single-tier
    counterpart of `read_window_dimension`. A day read sums across
    framings, as `read_grouped` does. Rows: [{"value", "up", "down"}],
    largest first."""
    tables = dimension_tables(dim)
    if tier not in tables:
        raise ValueError(f"no {tier} tier for dimension {dim!r}")
    where, params = [], []
    if device:
        where.append("device = ?")
        params.append(device)
    if since:
        where.append("bucket >= ?")
        params.append(since)
    if until:
        where.append("bucket <= ?")
        params.append(until)
    clause = f"WHERE {' AND '.join(where)}" if where else ""
    rows = conn.execute(
        f"SELECT value, SUM(up) AS up, SUM(down) AS down FROM {tables[tier]} "
        f"{clause} GROUP BY value ORDER BY SUM(up) + SUM(down) DESC, value",
        params).fetchall()
    return [dict(r) for r in rows]


def read_grouped(conn, tier: str, group_col: str, since: str = "",
                 until: str = "") -> list:
    table = _TIER_TABLES[tier]
    where, params = [], []
    if since:
        where.append("bucket >= ?")
        params.append(since)
    if until:
        where.append("bucket <= ?")
        params.append(until)
    clause = f"WHERE {' AND '.join(where)}" if where else ""
    rows = conn.execute(
        f"SELECT {group_col}, SUM(up) AS up, SUM(down) AS down "
        f"FROM {table} {clause} GROUP BY {group_col} {MOVED} "
        f"ORDER BY {group_col}", params).fetchall()
    return [dict(r) for r in rows]


def day_framings(conn, since: str = "", until: str = "") -> list:
    """Every (bucket_tz, day_boundary) under a day row that moved bytes in
    a day-tier window (a zero-byte row, MOVED, reports no boundary).

    `read_grouped` deliberately keeps summing ACROSS framings: each hour
    bucket is rolled exactly once, so the total is exact - no double count,
    no loss - and splitting a by-device total into one row per framing
    would change the shape of a table that answers "how much traffic".

    What summing cannot show is that the WINDOW changed meaning partway:
    two framings of one calendar date are two different 24-hour windows.
    So the framings travel alongside the totals, and a caller seeing more
    than one knows the boundary moved inside the range it asked about.
    """
    # a framing is listed only under a row that moved bytes, like the rows
    # themselves (MOVED): a zero-byte day must not report a boundary
    where, params = ["up + down > 0"], []
    if since:
        where.append("bucket >= ?")
        params.append(since)
    if until:
        where.append("bucket <= ?")
        params.append(until)
    clause = f"WHERE {' AND '.join(where)}"
    rows = conn.execute(
        f"SELECT DISTINCT bucket_tz, day_boundary FROM stats_day {clause} "
        f"ORDER BY bucket_tz, day_boundary", params).fetchall()
    return [dict(r) for r in rows]


def read_timeline(conn, tier: str, device: str = "", since: str = "",
                  until: str = "") -> list:
    """Bucket-granular rows (optionally one device) - the UI's history
    sparklines ride this."""
    table = _TIER_TABLES[tier]
    where, params = [], []
    if device:
        where.append("device = ?")
        params.append(device)
    if since:
        where.append("bucket >= ?")
        params.append(since)
    if until:
        where.append("bucket <= ?")
        params.append(until)
    clause = f"WHERE {' AND '.join(where)}" if where else ""
    if tier == "day":
        # The day tier groups by the STAMP as well as the bucket. Grouping
        # on `bucket` alone would sum two framings of the same calendar
        # date back into one row - hiding the seam in exactly the read
        # someone would look at to find it. Minute and hour are unchanged.
        rows = conn.execute(
            f"SELECT bucket, bucket_tz, day_boundary, SUM(up) AS up, "
            f"SUM(down) AS down FROM {table} {clause} "
            f"GROUP BY bucket, bucket_tz, day_boundary {MOVED} "
            f"ORDER BY bucket, bucket_tz, day_boundary", params).fetchall()
        return [dict(r) for r in rows]
    rows = conn.execute(
        f"SELECT bucket, SUM(up) AS up, SUM(down) AS down FROM {table} "
        f"{clause} GROUP BY bucket {MOVED} ORDER BY bucket",
        params).fetchall()
    return [dict(r) for r in rows]


def read_domains(conn, since: str = "", until: str = "") -> list:
    where, params = [], []
    if since:
        where.append("bucket >= ?")
        params.append(since)
    if until:
        where.append("bucket <= ?")
        params.append(until)
    clause = f"WHERE {' AND '.join(where)}" if where else ""
    rows = conn.execute(
        f"SELECT domain, device, SUM(up) AS up, SUM(down) AS down "
        f"FROM stats_domain {clause} GROUP BY domain, device "
        f"ORDER BY domain, device", params).fetchall()
    return [dict(r) for r in rows]


def read_gaps(conn, limit: int = 100, since: str = "",
              until: str = "") -> list:
    """The newest LIMIT gaps - or, with SINCE/UNTIL (#98), the newest LIMIT
    that overlap that window: a gap that ended at or after SINCE and started
    at or before UNTIL. String comparison over the stored `...Z` stamps, as
    every stats read compares; a shorter key (`2026-10-15T12`) names its
    whole bucket on either side - UNTIL is extended past every stamp it
    prefixes, which as a bare string it would sort before."""
    where, params = [], []
    if since:
        where.append("ended >= ?")
        params.append(since)
    if until:
        where.append("started <= ?")
        params.append(until + "~")
    clause = f"WHERE {' AND '.join(where)} " if where else ""
    rows = conn.execute(
        f"SELECT started, ended, reason FROM stats_gap {clause}"
        f"ORDER BY id DESC LIMIT ?",
        (*params, max(1, min(limit, 1000)))).fetchall()
    return [dict(r) for r in rows]
