"""Single-tier reads (the `tier`-only API, unchanged since v1.8.0) and the
domain and gap reads."""


_TIER_TABLES = {"minute": "stats_minute", "hour": "stats_hour",
                "day": "stats_day"}


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
        f"FROM {table} {clause} GROUP BY {group_col} "
        f"ORDER BY {group_col}", params).fetchall()
    return [dict(r) for r in rows]


def day_framings(conn, since: str = "", until: str = "") -> list:
    """Every (bucket_tz, day_boundary) present in a day-tier window.

    `read_grouped` deliberately keeps summing ACROSS framings: each hour
    bucket is rolled exactly once, so the total is exact - no double count,
    no loss - and splitting a by-device total into one row per framing
    would change the shape of a table that answers "how much traffic".

    What summing cannot show is that the WINDOW changed meaning partway:
    two framings of one calendar date are two different 24-hour windows.
    So the framings travel alongside the totals, and a caller seeing more
    than one knows the boundary moved inside the range it asked about.
    """
    where, params = [], []
    if since:
        where.append("bucket >= ?")
        params.append(since)
    if until:
        where.append("bucket <= ?")
        params.append(until)
    clause = f"WHERE {' AND '.join(where)}" if where else ""
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
            f"GROUP BY bucket, bucket_tz, day_boundary "
            f"ORDER BY bucket, bucket_tz, day_boundary", params).fetchall()
        return [dict(r) for r in rows]
    rows = conn.execute(
        f"SELECT bucket, SUM(up) AS up, SUM(down) AS down FROM {table} "
        f"{clause} GROUP BY bucket ORDER BY bucket", params).fetchall()
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


def read_gaps(conn, limit: int = 100) -> list:
    rows = conn.execute(
        "SELECT started, ended, reason FROM stats_gap "
        "ORDER BY id DESC LIMIT ?", (max(1, min(limit, 1000)),)).fetchall()
    return [dict(r) for r in rows]
