"""stats.db's shape: the forced retention and attribution constants, the
migrations, the opener, and the small helpers every part of the store shares.
"""

from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path

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
        with suppress(OSError):
            total += candidate.stat().st_size
    return total


def _parse_ts(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _fmt_ts(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def meta_get(conn, key: str) -> str | None:
    row = conn.execute("SELECT v FROM stats_meta WHERE k = ?",
                       (key,)).fetchone()
    return row["v"] if row else None
