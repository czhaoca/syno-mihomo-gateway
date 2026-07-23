"""stats.db - the persistent traffic store (brief DEC-8: a separate file
from policy.db, same PRAGMA discipline via the shared opener).

Delta accounting: per-connection cumulative counters diffed against the
persisted conn_baseline; the baseline update, the minute-bucket upserts,
the meta last-poll stamp, and any gap row land in ONE transaction, so a
collector restart can never double-count and a crash mid-flush loses the
whole poll, never half of it. Tiers roll minute -> hour -> day with
per-tier retention, a hard size cap prunes oldest-tier-first (batched
deletes + incremental vacuum + WAL checkpoint), and the opt-in per-domain
table carries a FORCED 7-day retention no knob can extend. Collector
downtime becomes explicit stats_gap rows - never interpolated (the
auto_update.sh counts-header honesty style).
"""

from datetime import UTC, datetime, timedelta
from pathlib import Path

from app import config
from app.store.db import open_db

# Forced, deliberately NOT a knob: per-domain data is privacy-sensitive
# (brief DEC-8 rider), so its retention never exceeds 7 days regardless of
# what the PANEL_STATS_* knobs say.
DOMAIN_RETENTION_DAYS = 7

STATS_MIGRATIONS = [
    (1, """
    CREATE TABLE conn_baseline (
        conn_id TEXT PRIMARY KEY,
        up INTEGER NOT NULL,
        down INTEGER NOT NULL,
        last_seen TEXT NOT NULL
    );
    CREATE TABLE stats_minute (
        bucket TEXT NOT NULL, device TEXT NOT NULL, chain TEXT NOT NULL,
        up INTEGER NOT NULL DEFAULT 0, down INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (bucket, device, chain)
    );
    CREATE TABLE stats_hour (
        bucket TEXT NOT NULL, device TEXT NOT NULL, chain TEXT NOT NULL,
        up INTEGER NOT NULL DEFAULT 0, down INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (bucket, device, chain)
    );
    CREATE TABLE stats_day (
        bucket TEXT NOT NULL, device TEXT NOT NULL, chain TEXT NOT NULL,
        up INTEGER NOT NULL DEFAULT 0, down INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (bucket, device, chain)
    );
    CREATE TABLE stats_domain (
        bucket TEXT NOT NULL, device TEXT NOT NULL, domain TEXT NOT NULL,
        up INTEGER NOT NULL DEFAULT 0, down INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (bucket, device, domain)
    );
    CREATE TABLE stats_gap (
        id INTEGER PRIMARY KEY,
        started TEXT NOT NULL,
        ended TEXT NOT NULL,
        reason TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE stats_meta (
        k TEXT PRIMARY KEY,
        v TEXT NOT NULL
    );
    """),
]


def open_stats_db(path: Path):
    """auto_vacuum must be INCREMENTAL from birth (it cannot be enabled on
    a populated db without a full VACUUM) - the cap enforcement's
    incremental_vacuum depends on it."""
    return open_db(Path(path), migrations=STATS_MIGRATIONS,
                   pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))


def _db_bytes(path: Path) -> int:
    """Main db + WAL sidecar - the operator-visible disk footprint."""
    path = Path(path)
    total = 0
    for candidate in (path, Path(str(path) + "-wal")):
        try:
            total += candidate.stat().st_size
        except OSError:
            pass
    return total


def _parse_ts(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _fmt_ts(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def meta_get(conn, key: str) -> str | None:
    row = conn.execute("SELECT v FROM stats_meta WHERE k = ?",
                       (key,)).fetchone()
    return row["v"] if row else None


def flush_poll(conn, raw_conns: list, now: str, *, domains_enabled: bool,
               gap_threshold_s: int) -> None:
    """One poll's delta flush - a single transaction covering the minute
    upserts, the (hourly) domain upserts, the baseline replacement, the
    closed-connection reap, gap detection, and the last-poll stamp."""
    minute_bucket = now[:16]
    hour_bucket = now[:13]
    conn.execute("BEGIN IMMEDIATE")
    try:
        seen = set()
        for rc in raw_conns:
            cid = str(rc.get("id") or "")
            if not cid:
                continue
            up = int(rc.get("upload") or 0)
            down = int(rc.get("download") or 0)
            meta = rc.get("metadata") or {}
            device = str(meta.get("sourceIP") or "") or "unknown"
            chains = rc.get("chains") or []
            chain = str(chains[-1]) if chains else "DIRECT"
            host = str(meta.get("host") or "")
            base = conn.execute(
                "SELECT up, down FROM conn_baseline WHERE conn_id = ?",
                (cid,)).fetchone()
            if base is None or up < base["up"] or down < base["down"]:
                # first sighting, or a counter reset (id reuse after a
                # mihomo restart): the full cumulative counts
                d_up, d_down = up, down
            else:
                d_up, d_down = up - base["up"], down - base["down"]
            if d_up or d_down:
                conn.execute(
                    "INSERT INTO stats_minute (bucket, device, chain, up, down) "
                    "VALUES (?, ?, ?, ?, ?) "
                    "ON CONFLICT(bucket, device, chain) DO UPDATE SET "
                    "up = up + excluded.up, down = down + excluded.down",
                    (minute_bucket, device, chain, d_up, d_down))
                if domains_enabled and host:
                    conn.execute(
                        "INSERT INTO stats_domain "
                        "(bucket, device, domain, up, down) "
                        "VALUES (?, ?, ?, ?, ?) "
                        "ON CONFLICT(bucket, device, domain) DO UPDATE SET "
                        "up = up + excluded.up, down = down + excluded.down",
                        (hour_bucket, device, host, d_up, d_down))
            conn.execute(
                "INSERT INTO conn_baseline (conn_id, up, down, last_seen) "
                "VALUES (?, ?, ?, ?) ON CONFLICT(conn_id) DO UPDATE SET "
                "up = excluded.up, down = excluded.down, "
                "last_seen = excluded.last_seen",
                (cid, up, down, now))
            seen.add(cid)
        # reap baselines for closed connections (their growth since the
        # last poll is lost - the documented <= one-interval bound)
        for row in conn.execute("SELECT conn_id FROM conn_baseline"):
            if row["conn_id"] not in seen:
                conn.execute("DELETE FROM conn_baseline WHERE conn_id = ?",
                             (row["conn_id"],))
        # honest gap accounting: a hole wider than the threshold becomes an
        # explicit row - never interpolated, never backfilled
        last = meta_get(conn, "last_poll_ts")
        if last is not None:
            hole_s = (_parse_ts(now) - _parse_ts(last)).total_seconds()
            if hole_s > gap_threshold_s:
                conn.execute(
                    "INSERT INTO stats_gap (started, ended, reason) "
                    "VALUES (?, ?, ?)",
                    (last, now, f"no poll for {int(hole_s)}s"))
        conn.execute(
            "INSERT INTO stats_meta (k, v) VALUES ('last_poll_ts', ?) "
            "ON CONFLICT(k) DO UPDATE SET v = excluded.v", (now,))
        conn.execute("COMMIT")
    except BaseException:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        raise


def rollup(conn, now: str) -> None:
    """Cascade + retention in one transaction: minute rows older than the
    minute window aggregate into hours, hours into days, days expire; the
    domain table prunes at its FORCED 7-day horizon."""
    now_dt = _parse_ts(now)
    minute_cut = (now_dt - timedelta(
        hours=config.stats_minute_hours())).strftime("%Y-%m-%dT%H:%M")
    hour_cut = (now_dt - timedelta(
        days=config.stats_hour_days())).strftime("%Y-%m-%dT%H")
    day_cut = (now_dt - timedelta(
        days=config.stats_day_days())).strftime("%Y-%m-%d")
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
        conn.execute(
            "INSERT INTO stats_day (bucket, device, chain, up, down) "
            "SELECT substr(bucket, 1, 10), device, chain, "
            "SUM(up), SUM(down) FROM stats_hour WHERE bucket < ? "
            "GROUP BY substr(bucket, 1, 10), device, chain "
            "ON CONFLICT(bucket, device, chain) DO UPDATE SET "
            "up = up + excluded.up, down = down + excluded.down",
            (hour_cut,))
        conn.execute("DELETE FROM stats_hour WHERE bucket < ?", (hour_cut,))
        conn.execute("DELETE FROM stats_day WHERE bucket < ?", (day_cut,))
        conn.execute("DELETE FROM stats_domain WHERE bucket < ?",
                     (domain_cut,))
        # gap history ages out with the oldest data tier: a gap older than
        # any retained measurement explains nothing (and an unbounded gap
        # table could otherwise defeat the hard size cap)
        conn.execute("DELETE FROM stats_gap WHERE ended < ?", (day_cut,))
        conn.execute("COMMIT")
    except BaseException:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        raise


# Cap pruning drains data-age-first: the day tier holds the OLDEST data,
# so it gives way before hour/minute; the (already 7d-bounded) domain
# table and the gap history go last. Each entry carries its age-order
# column (the gap table has no bucket).
_CAP_TIERS = (("day", "stats_day", "bucket"),
              ("hour", "stats_hour", "bucket"),
              ("minute", "stats_minute", "bucket"),
              ("domain", "stats_domain", "bucket"),
              ("gap", "stats_gap", "started"))


def enforce_cap(conn, path: Path, cap_mb: int) -> dict:
    """Hard size cap: while over, delete the oldest bucket batches from
    the oldest tier, vacuum + checkpoint, re-measure. Returns rows pruned
    per tier."""
    pruned = {tier: 0 for tier, _, _ in _CAP_TIERS}
    if cap_mb <= 0:
        return pruned
    cap = cap_mb * 1024 * 1024
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
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
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
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
        for table in ("stats_minute", "stats_hour", "stats_day",
                      "stats_domain", "stats_gap"):
            conn.execute(f"DELETE FROM {table}")
        conn.execute("COMMIT")
    except BaseException:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        raise
    conn.execute("PRAGMA incremental_vacuum").fetchall()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()


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
