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
from app.store import dayframe
from app.store.db import open_db

# Forced, deliberately NOT a knob: per-domain data is privacy-sensitive
# (brief DEC-8 rider), so its retention never exceeds 7 days regardless of
# what the PANEL_STATS_* knobs say.
DOMAIN_RETENTION_DAYS = 7

# The attribution classes (#77, DEC-B: hostname-only). A hostname is the
# only signal that names an application; `rule`/`rulePayload` are routing
# categories, and the release gate already refuses to treat GeoSite/cn as
# proof of anything (validate_release.sh:1089-1092). Counting a routing
# category as attribution would inflate the exact number DEC-6 exists to
# measure honestly before blocking is built on it.
KLASS_HOSTNAME = "hostname"
KLASS_IP_ONLY = "ip_only"
COVERAGE_CLASSES = (KLASS_HOSTNAME, KLASS_IP_ONLY)

# Every table the token-gated purge clears. A new privacy-adjacent table
# that is not in here would survive the one operation whose whole promise
# is that nothing does.
PURGE_TABLES = ("stats_minute", "stats_hour", "stats_day", "stats_domain",
                "stats_coverage", "stats_gap")

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
    # v2 - the day tier becomes LOCAL-keyed and stamps the framing that
    # produced each row (#76, DEC-4). Minute and hour stay UTC.
    #
    # A full rebuild is unavoidable: the stamps have to join the PRIMARY
    # KEY, SQLite cannot widen one, and `ALTER TABLE ADD COLUMN` cannot add
    # to it. Leaving the shipped key alone is the actual danger - with
    # PRIMARY KEY (bucket, device, chain), a locally-keyed row would UPSERT
    # into the UTC row for the same date, which is precisely the silent
    # relabel of shipped history this ticket forbids.
    #
    # The stamps are APPENDED (not inserted) so v1 column positions
    # survive, and both carry DEFAULTs so the shipped five-column
    # `INSERT INTO stats_day (bucket, device, chain, up, down)` idiom keeps
    # working - a migration that broke the existing write shape would be a
    # breaking change wearing an additive costume.
    #
    # Every pre-existing row is stamped UTC/00:00 because that is the
    # framing that genuinely produced it, so no shipped number changes
    # meaning. `auto_vacuum` is a database-level pragma and survives the
    # table swap (enforce_cap's incremental_vacuum depends on it).
    (2, """
    CREATE TABLE stats_day_v2 (
        bucket TEXT NOT NULL, device TEXT NOT NULL, chain TEXT NOT NULL,
        up INTEGER NOT NULL DEFAULT 0, down INTEGER NOT NULL DEFAULT 0,
        bucket_tz TEXT NOT NULL DEFAULT 'UTC',
        day_boundary TEXT NOT NULL DEFAULT '00:00',
        PRIMARY KEY (bucket, device, chain, bucket_tz, day_boundary)
    );
    INSERT INTO stats_day_v2
        (bucket, device, chain, up, down, bucket_tz, day_boundary)
        SELECT bucket, device, chain, up, down, 'UTC', '00:00'
        FROM stats_day;
    DROP TABLE stats_day;
    ALTER TABLE stats_day_v2 RENAME TO stats_day;
    """),
    # v3 - attribution coverage (#77, DEC-6): measure what share of traffic
    # could be attributed to an app at all, BEFORE a dictionary exists to
    # attribute it with.
    #
    # `sniff_host` is retained here rather than in stats_domain, because
    # widening THAT table's write-guard would change what an existing,
    # shipped table stores under an unchanged operator configuration -
    # which AC1 forbids outright. It is written ONLY when the
    # off-by-default PANEL_STATS_DOMAINS gate is on, so in the default
    # configuration the column is uniformly empty and the panel still
    # persists zero hostname-derived rows, exactly as the bilingual docs
    # promise. That is the panel's DEC-A rider met literally: a raw
    # hostname may be persisted only behind the opt-in gate AND under the
    # forced 7-day cap, never by default.
    #
    # `rule`/`rule_payload` ARE stored: they are routing categories, the
    # same class of fact the chain tier already keeps, and the breakdown
    # they give is what lets an operator tell a designed exclusion from a
    # real attribution gap. Hour-keyed like stats_domain, which keeps it
    # UTC and out of the day tier's bucket_tz/day_boundary contract.
    (3, """
    CREATE TABLE stats_coverage (
        bucket TEXT NOT NULL, device TEXT NOT NULL, klass TEXT NOT NULL,
        rule TEXT NOT NULL DEFAULT '', rule_payload TEXT NOT NULL DEFAULT '',
        sniff_host TEXT NOT NULL DEFAULT '',
        up INTEGER NOT NULL DEFAULT 0, down INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (bucket, device, klass, rule, rule_payload, sniff_host)
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
            # #77: the classification signal already on the wire, previously
            # discarded. `sniffHost` is what the sniffer recovered when the
            # DNS path gave no name - so for CLASSIFYING a flow it counts
            # exactly like `host`, but as a hostname it is stored only where
            # hostnames already live (the opt-in domain table below).
            sniff = str(meta.get("sniffHost") or "")
            rule = str(rc.get("rule") or "")
            payload = str(rc.get("rulePayload") or "")
            named = host or sniff
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
                conn.execute(
                    "INSERT INTO stats_coverage (bucket, device, klass, "
                    "rule, rule_payload, sniff_host, up, down) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
                    "ON CONFLICT(bucket, device, klass, rule, rule_payload, "
                    "sniff_host) "
                    "DO UPDATE SET up = up + excluded.up, "
                    "down = down + excluded.down",
                    (hour_bucket, device,
                     KLASS_HOSTNAME if named else KLASS_IP_ONLY,
                     rule, payload,
                     # the raw hostname ONLY behind the opt-in gate; empty
                     # in the default configuration, so the column adds no
                     # cardinality and no privacy surface there
                     sniff if domains_enabled else "",
                     d_up, d_down))
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
              # After the day tier, deliberately: enforce_cap drains
              # data-age-first and eats `day` FIRST, so a 7-day-bounded
              # table placed early would cost long-term history to reclaim
              # a week of counters.
              ("coverage", "stats_coverage", "bucket"),
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
        # PURGE_TABLES is the single list, so a table added later cannot
        # quietly survive the one operation whose promise is that none does.
        for table in PURGE_TABLES:
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


def read_coverage(conn, since: str = "", until: str = "") -> list:
    """Bytes per attribution class over a window.

    The classes are the whole point of #77: `hostname` means the flow
    carried a name an app dictionary could eventually match, `ip_only`
    means it did not. Routing signals never promote a flow (DEC-B) - the
    release gate already refuses to read GeoSite/cn as proof of anything.
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
        f"SELECT klass, SUM(up) AS up, SUM(down) AS down "
        f"FROM stats_coverage {clause} GROUP BY klass ORDER BY klass",
        params).fetchall()
    return [dict(r) for r in rows]


def coverage_rules(conn, since: str = "", until: str = "") -> list:
    """Unattributable bytes, broken down by the rule that routed them.

    AC2 asks for a "deliberately excluded" share. This does not produce
    one, for a reason worth stating precisely rather than confidently.

    VERIFIED here: the template's skip-domain list lives entirely inside
    the `sniffer:` block and no `rules:` entry references it, so it
    changes sniffing rather than routing.

    NOT verified here, and deliberately not asserted: whether mihomo still
    reports `metadata.sniffHost` for a flow whose sniffing was skipped.
    This repo vendors no mihomo source and captures no fixture of such a
    flow. If it DOES report one, that flow carries a name and is
    attributable under DEC-B - correctly counted, just not visible as an
    exclusion. If it does NOT, the flow is indistinguishable from ordinary
    IP-only residue. Either way, separating exclusions out would require
    hardcoding the exclusion list, which CLAUDE.md forbids outright.

    So what is reported is what is observable: which rule routed each
    unattributable byte. An operator can read a designed exclusion off its
    own rule name where one exists, without the panel guessing on their
    behalf - and which of the two cases actually holds is precisely the
    sort of thing this ticket's own output is meant to reveal.
    """
    where = ["klass = ?"]
    params = [KLASS_IP_ONLY]
    if since:
        where.append("bucket >= ?")
        params.append(since)
    if until:
        where.append("bucket <= ?")
        params.append(until)
    clause = "WHERE " + " AND ".join(where)
    rows = conn.execute(
        f"SELECT rule, rule_payload, SUM(up) AS up, SUM(down) AS down "
        f"FROM stats_coverage {clause} GROUP BY rule, rule_payload "
        f"ORDER BY SUM(up) + SUM(down) DESC, rule, rule_payload",
        params).fetchall()
    return [dict(r) for r in rows]


def coverage_report(conn, since: str = "", until: str = "") -> dict:
    """The measurement DEC-6 asks for: what share of bytes is attributable.

    EVERY known class is listed even at zero, so a consumer never has to
    guess whether a missing class means "none" or means "not measured" -
    the same honesty rule the apply badge and the import ledger follow.
    Shares are of total bytes (up + down) and sum to 100 by construction,
    or to 0 on an empty window rather than dividing by it.
    """
    counted = {r["klass"]: r for r in read_coverage(conn, since, until)}
    oldest = conn.execute(
        "SELECT MIN(bucket) FROM stats_coverage").fetchone()[0]
    total_up = sum(r["up"] for r in counted.values())
    total_down = sum(r["down"] for r in counted.values())
    total = total_up + total_down
    classes = []
    for klass in COVERAGE_CLASSES:
        row = counted.get(klass) or {"up": 0, "down": 0}
        share = round(100.0 * (row["up"] + row["down"]) / total, 6) if total else 0.0
        classes.append({"klass": klass, "up": row["up"], "down": row["down"],
                        "share": share})
    # Attribution lives ONLY here, under the forced 7-day cap - the 90/730
    # day byte tiers carry no klass or rule column at all. So a caller
    # asking for 30 days gets a percentage computed over at most 7, and
    # saying so is the difference between a measurement and a number.
    # DEC-6 exists to stop a blocking decision resting on quiet inaccuracy;
    # a silently truncated window would be exactly that.
    return {"total": {"up": total_up, "down": total_down},
            "classes": classes,
            "rules": coverage_rules(conn, since, until),
            "window": {
                "requested_since": since,
                "requested_until": until,
                "oldest_bucket": oldest or "",
                "retention_days": DOMAIN_RETENTION_DAYS,
                # True when the requested range starts before the oldest
                # row held: the answer is correct for what it covers but
                # does not answer the question asked. Deliberately does NOT
                # distinguish retention pruning from a young install - the
                # consequence for the caller is identical, and guessing
                # which it was would be the panel inventing a story.
                "truncated": bool(since and oldest and since < oldest),
            }}
