"""Rollup cascade, per-tier retention, the hard size cap and the purge -
the store's maintenance path."""

from contextlib import suppress
from datetime import timedelta
from pathlib import Path

from app import config
from app.store import dayframe
from app.store.stats.schema import (
    DOMAIN_RETENTION_DAYS,
    PURGE_TABLES,
    _db_bytes,
    _parse_ts,
)


def rollup(conn, now: str, *, day) -> None:
    """Cascade + retention in one transaction: minute rows older than the
    minute window aggregate into hours, hours into days, days expire; the
    domain table prunes at its FORCED 7-day horizon.

    DAY is a `dayframe.DayFrame` and is REQUIRED, deliberately. Defaulting
    it would let a call site that forgot the framing produce UTC-keyed rows
    that look like a decision; "cannot key locally" is a value
    (`DayFrame.ok is False`), not an omitted argument, so it has exactly
    one representation. An unusable frame degrades to UTC here rather than
    skipping the roll: the hour DELETE below is also the hour tier's ONLY
    retention, and `_CAP_TIERS` drains the DAY tier first under size
    pressure - so a paused roll would grow `stats_hour` without bound while
    the cap destroyed the long-term day history to make room for it.
    """
    now_dt = _parse_ts(now)
    minute_cut = (now_dt - timedelta(
        hours=config.stats_minute_hours())).strftime("%Y-%m-%dT%H:%M")
    hour_cut = (now_dt - timedelta(
        days=config.stats_hour_days())).strftime("%Y-%m-%dT%H")
    day_slack = (now_dt - timedelta(
        days=config.stats_day_days() + 1)).strftime("%Y-%m-%d")
    domain_cut = (now_dt - timedelta(
        days=DOMAIN_RETENTION_DAYS)).strftime("%Y-%m-%dT%H")
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute(
            "INSERT INTO stats_hour (bucket, device, chain, up, down) "
            "SELECT substr(bucket, 1, 13), device, chain, "
            "SUM(up), SUM(down) FROM stats_minute WHERE bucket < ? "
            "GROUP BY substr(bucket, 1, 13), device, chain "
            "ON CONFLICT(bucket, device, chain) DO UPDATE SET "
            "up = up + excluded.up, down = down + excluded.down",
            (minute_cut,))
        conn.execute("DELETE FROM stats_minute WHERE bucket < ?",
                     (minute_cut,))
        # The day tier is LOCAL-keyed, and SQLite cannot do timezone maths,
        # so the key is computed per distinct hour bucket in Python while
        # SQL still does every summation. `frame` supplies both the mapping
        # and the stamp written into the row's identity.
        frame = day if day.ok else dayframe.utc_frame()
        for (hour_bucket,) in conn.execute(
                "SELECT DISTINCT bucket FROM stats_hour WHERE bucket < ?",
                (hour_cut,)).fetchall():
            conn.execute(
                "INSERT INTO stats_day (bucket, device, chain, up, down, "
                "bucket_tz, day_boundary) "
                "SELECT ?, device, chain, SUM(up), SUM(down), ?, ? "
                "FROM stats_hour WHERE bucket = ? GROUP BY device, chain "
                "ON CONFLICT(bucket, device, chain, bucket_tz, day_boundary) "
                "DO UPDATE SET up = up + excluded.up, "
                "down = down + excluded.down",
                (dayframe.day_key(hour_bucket, frame), frame.tz, frame.cut,
                 hour_bucket))
        conn.execute("DELETE FROM stats_hour WHERE bucket < ?", (hour_cut,))
        # Retention stays UTC-derived with a day of slack: a local day key
        # can sit either side of the UTC date it was rolled from, so
        # comparing it against a UTC-derived horizon could otherwise evict
        # a day the operator has not yet finished accumulating.
        conn.execute("DELETE FROM stats_day WHERE bucket < ?", (day_slack,))
        conn.execute("DELETE FROM stats_domain WHERE bucket < ?",
                     (domain_cut,))
        # DEC-A (panel-confirmed): coverage inherits the domain table's
        # FORCED horizon rather than gaining a knob of its own. The rejected
        # option would have extended retention of hostname-adjacent data
        # past a documented, deliberately non-configurable promise.
        conn.execute("DELETE FROM stats_coverage WHERE bucket < ?",
                     (domain_cut,))
        # gap history ages out with the oldest data tier: a gap older than
        # any retained measurement explains nothing (and an unbounded gap
        # table could otherwise defeat the hard size cap)
        conn.execute("DELETE FROM stats_gap WHERE ended < ?", (day_slack,))
        conn.execute("COMMIT")
    except BaseException:
        with suppress(Exception):
            conn.execute("ROLLBACK")
        raise


# Cap pruning drains data-age-first: the day tier holds the OLDEST data,
# so it gives way before hour/minute; the (already 7d-bounded) domain
# table and the gap history go last. Each entry carries its age-order
# column (the gap table has no bucket).
_CAP_TIERS = (("day", "stats_day", "bucket"),
              ("hour", "stats_hour", "bucket"),
              ("minute", "stats_minute", "bucket"),
              ("domain", "stats_domain", "bucket"),
              # After the day tier, deliberately: enforce_cap drains
              # data-age-first and eats `day` FIRST, so a 7-day-bounded
              # table placed early would cost long-term history to reclaim
              # a week of counters.
              ("coverage", "stats_coverage", "bucket"),
              ("gap", "stats_gap", "started"))


def _checkpoint(conn) -> bool:
    """A TRUNCATE checkpoint; True when it completed.

    Since #93 the stats API reads through its own read-only connections,
    and a TRUNCATE checkpoint has to wait for every reader still using the
    WAL. It does wait - through `busy_timeout` (5 s), far longer than any
    request's read - but a snapshot held past that leaves the WAL in place
    and the checkpoint answers busy=1 instead of raising.
    """
    busy, _log, _done = conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    return busy == 0


def enforce_cap(conn, path: Path, cap_mb: int) -> dict:
    """Hard size cap: while over, delete the oldest bucket batches from
    the oldest tier, vacuum + checkpoint, re-measure. Returns rows pruned
    per tier.

    The size measured includes the WAL, so a pass whose checkpoint came
    back busy stops where it is: measuring a WAL a reader still pins would
    count bytes that are about to go, and keep deleting history to pay for
    them. The next maintenance pass retries. Without readers the checkpoint
    is never busy and the pass is exactly what it always was.
    """
    pruned = {tier: 0 for tier, _, _ in _CAP_TIERS}
    if cap_mb <= 0:
        return pruned
    cap = cap_mb * 1024 * 1024
    if not _checkpoint(conn):
        return pruned
    if _db_bytes(path) <= cap:
        return pruned
    for tier, table, order_col in _CAP_TIERS:
        while _db_bytes(path) > cap:
            cur = conn.execute(
                f"DELETE FROM {table} WHERE {order_col} IN "
                f"(SELECT DISTINCT {order_col} FROM {table} "
                f"ORDER BY {order_col} LIMIT 20)")
            if cur.rowcount <= 0:
                break
            pruned[tier] += cur.rowcount
            conn.execute("PRAGMA incremental_vacuum").fetchall()
            if not _checkpoint(conn):
                return pruned
        if _db_bytes(path) <= cap:
            break
    return pruned


def purge_stats(conn) -> None:
    """The token-gated purge: every VISIBLE stats surface goes - rollup
    tiers, domains, gap history. conn_baseline and the poll stamp are
    ACCOUNTING STATE, not stats, and deliberately survive: dropping a
    baseline would make every still-open connection re-contribute its
    entire pre-purge cumulative on the very next poll - the exact
    double-count the delta model exists to prevent. The POLICY audit
    lives in policy.db and is untouched by construction."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        # PURGE_TABLES is the single list, so a table added later cannot
        # quietly survive the one operation whose promise is that none does.
        for table in PURGE_TABLES:
            conn.execute(f"DELETE FROM {table}")
        conn.execute("COMMIT")
    except BaseException:
        with suppress(Exception):
            conn.execute("ROLLBACK")
        raise
    conn.execute("PRAGMA incremental_vacuum").fetchall()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
