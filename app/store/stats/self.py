"""The collector's own gauges (#96): one stats_self row per maintenance pass,
kept seven days, behind /v1/stats/self and /health's growth figure."""

from datetime import timedelta

from app.store.stats.schema import SELF_TABLE, _parse_ts

# every gauge but the bucket; NULL means "not measured", never 0
SELF_FIELDS = ("poll_ms", "conns", "failed_polls", "lag_s", "db_bytes",
               "mihomo_mem_mb")

# a growth rate measured over less than this says nothing about a day
_GROWTH_MIN_SPAN_MIN = 60


def record_self(conn, bucket: str, sample: dict) -> None:
    """Store one sample under BUCKET (a minute key); a second sample in the
    same minute replaces the first."""
    conn.execute(
        f"INSERT INTO {SELF_TABLE} (bucket, {', '.join(SELF_FIELDS)}) "
        f"VALUES (?, {', '.join('?' * len(SELF_FIELDS))}) "
        f"ON CONFLICT(bucket) DO UPDATE SET "
        + ", ".join(f"{f} = excluded.{f}" for f in SELF_FIELDS),
        (bucket, *(sample.get(f) for f in SELF_FIELDS)))


def read_self(conn, since: str = "", until: str = "") -> list:
    where, params = [], []
    if since:
        where.append("bucket >= ?")
        params.append(since)
    if until:
        where.append("bucket <= ?")
        params.append(until)
    clause = f" WHERE {' AND '.join(where)}" if where else ""
    rows = conn.execute(
        f"SELECT bucket, {', '.join(SELF_FIELDS)} FROM {SELF_TABLE}{clause} "
        f"ORDER BY bucket", params).fetchall()
    return [dict(r) for r in rows]


def self_growth_mb_day(conn, now_bucket: str) -> float | None:
    """How fast stats.db grows, MiB per day, from the samples of the last
    24 h: (newest - oldest) over the time between them. None until those
    samples span an hour. Negative after a purge or a cap prune - reported
    as measured, not clamped."""
    start = (_parse_ts(now_bucket + ":00Z") - timedelta(days=1)).strftime(
        "%Y-%m-%dT%H:%M")
    rows = conn.execute(
        f"SELECT bucket, db_bytes FROM {SELF_TABLE} WHERE bucket >= ? AND "
        f"bucket <= ? AND db_bytes IS NOT NULL ORDER BY bucket",
        (start, now_bucket)).fetchall()
    if len(rows) < 2:
        return None
    first, last = rows[0], rows[-1]
    span_min = (_parse_ts(last["bucket"] + ":00Z")
                - _parse_ts(first["bucket"] + ":00Z")).total_seconds() / 60
    if span_min < _GROWTH_MIN_SPAN_MIN:
        return None
    grown_mb = (last["db_bytes"] - first["db_bytes"]) / (1024 * 1024)
    return round(grown_mb / (span_min / 1440), 2)
