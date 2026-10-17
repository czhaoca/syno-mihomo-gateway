"""stats.db's shape: the forced retention and attribution constants, the
migrations, the opener, and the small helpers every part of the store shares.
"""

import sqlite3
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path

from app.store.db import StoreError, open_db

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

# The minute tier since v5 (#95). The collector writes every poll to it AND
# to the hour tier, so its bytes are always in stats_hour too. It is NOT the
# shipped `stats_minute`, deliberately: an older panel image - the nightly
# updater rolls the panel back on its own when a health gate fails - reads
# `stats_minute` as bytes NOT yet in an hour, unions it with the hour tier
# and rolls it into hours. Had v5 kept its minute rows there, every one of
# them would be counted twice by an older image, for good. `stats_minute` is
# now only where an older image writes; v5 folds whatever it finds there
# into the hour tier (`fold_legacy_minutes`) at the migration and on every
# start, so a downgrade and a return lose and double nothing.
MINUTE_TABLE = "stats_minute_v5"

# The long-term dimensions (#95, brief DEC-4), one table per dimension on
# the hour and the day tier, keyed (bucket, device, value), bytes only
# (DEC-D). The policy GROUP is not among them: it is the tier tables' own
# `chain` column. `category` holds a coarse category id from the dictionary
# (#97), UNATTRIBUTED when it has no answer, or NO_DICTIONARY for bytes
# counted without one - every byte has exactly one row, so a category total
# always equals the device total (DEC-B rider).
DIMENSIONS = ("exit", "rule", "category", "country")
DIMENSION_TABLES = tuple(f"stats_{dim}_{tier}" for dim in DIMENSIONS
                         for tier in ("hour", "day"))

# The seven-day class beside `stats_domain` (hostname): sniffHost, ASN and
# destination port. Written only behind the opt-in PANEL_STATS_DOMAINS gate
# and pruned at the FORCED DOMAIN_RETENTION_DAYS - an ASN or a port names an
# app almost as well as a hostname does. Hour-keyed, like stats_domain.
# The app-level category id (#97, DEC-5: an app identity per device is as
# sensitive as a hostname) joined them in v7; the v5 migration keeps its own
# list, because a migration's SQL never changes once shipped.
_V5_CLASS_TABLES = ("stats_sniff", "stats_asn", "stats_port")
APP_TABLE = "stats_app"
CLASS_TABLES = (*_V5_CLASS_TABLES, APP_TABLE)

# The collector's own gauges (#96): one row per maintenance pass, minute
# keyed, no device, under the forced DOMAIN_RETENTION_DAYS like the other
# seven-day tables.
SELF_TABLE = "stats_self"

# The selected node's delay per policy group (#102): mihomo's own test
# results, keyed by the test's time, no device, retained for
# PANEL_NODE_DELAY_DAYS. Airport node labels are stored as given.
NODE_DELAY_TABLE = "stats_node_delay"

# The value written when a field is absent from the snapshot (DEC-A: the
# geo fields are feature-detected per snapshot) - a row, never a drop.
UNKNOWN = "unknown"
# The category of a byte the dictionary had no answer for: no hostname, or
# one it does not know (#97 DEC-E) - the permanent, honest class.
UNATTRIBUTED = UNKNOWN
# The category of a byte counted WITHOUT a dictionary: everything before
# v1.12, and whatever an older image writes after a rollback. Distinct from
# UNATTRIBUTED so "before the dictionary" stays readable as such.
NO_DICTIONARY = ""
# The dictionary's attribution classes in /v1/stats/coverage (#97 DEC-D): a
# byte is classified with its app id kept (the 7-day opt-in class), with only
# its coarse id kept, not classified, or counted with no dictionary at all.
DICTIONARY_CLASSES = ("app", "coarse", "unattributed", "no_dictionary")
# The device mihomo's own traffic (`metadata.type == "Inner"`: provider
# pulls, health checks) is attributed to - it has no LAN source.
GATEWAY_DEVICE = "gateway"

# Every table the token-gated purge clears. A new privacy-adjacent table
# that is not in here would survive the one operation whose whole promise
# is that nothing does.
PURGE_TABLES = ("stats_minute", MINUTE_TABLE, "stats_hour", "stats_day",
                "stats_domain", "stats_coverage", "stats_gap",
                *DIMENSION_TABLES, *CLASS_TABLES, SELF_TABLE, NODE_DELAY_TABLE)


def _value_table(name: str, *, day: bool = False) -> str:
    """DDL for one (bucket, device, value) fact table. A day table carries
    the same framing stamps as stats_day, in its key, for the same reason
    (migration 2)."""
    stamps = ("bucket_tz TEXT NOT NULL DEFAULT 'UTC', "
              "day_boundary TEXT NOT NULL DEFAULT '00:00', ") if day else ""
    key = ("bucket, device, value, bucket_tz, day_boundary" if day
           else "bucket, device, value")
    return (f"CREATE TABLE {name} (bucket TEXT NOT NULL, device TEXT NOT NULL, "
            f"value TEXT NOT NULL, up INTEGER NOT NULL DEFAULT 0, "
            f"down INTEGER NOT NULL DEFAULT 0, {stamps}PRIMARY KEY ({key}));")


_INDEXED = ("stats_minute", MINUTE_TABLE, "stats_hour", "stats_day",
            "stats_domain", "stats_coverage", *DIMENSION_TABLES,
            *_V5_CLASS_TABLES)

# The fold of the legacy minute table (see MINUTE_TABLE): its rows are bytes
# no hour holds yet, so they are added to their hours (into an hour a
# partial roll already started, which the upsert completes rather than
# duplicates; counts sum, peaks keep the largest, as in rollup), moved to
# the v5 minute tier, and removed - a no-op when the table is empty.
_FOLD_LEGACY_MINUTES = (
    """INSERT INTO stats_hour (bucket, device, chain, up, down, samples,
        conns, peak_up, peak_down)
    SELECT substr(bucket, 1, 13), device, chain, SUM(up), SUM(down),
        SUM(samples), SUM(conns), MAX(peak_up), MAX(peak_down)
    FROM stats_minute WHERE true GROUP BY substr(bucket, 1, 13), device, chain
    ON CONFLICT(bucket, device, chain) DO UPDATE SET
        up = up + excluded.up, down = down + excluded.down,
        samples = samples + excluded.samples, conns = conns + excluded.conns,
        peak_up = max(peak_up, excluded.peak_up),
        peak_down = max(peak_down, excluded.peak_down)""",
    f"""INSERT INTO {MINUTE_TABLE} (bucket, device, chain, up, down, samples,
        conns, peak_up, peak_down)
    SELECT bucket, device, chain, up, down, samples, conns, peak_up, peak_down
    FROM stats_minute WHERE true
    ON CONFLICT(bucket, device, chain) DO UPDATE SET
        up = up + excluded.up, down = down + excluded.down,
        samples = samples + excluded.samples, conns = conns + excluded.conns,
        peak_up = max(peak_up, excluded.peak_up),
        peak_down = max(peak_down, excluded.peak_down)""",
    "DELETE FROM stats_minute",
)

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
    # v4 - per-bucket facts (#94): how many polls fed a row, how many
    # connections were first seen in it, and its largest single-poll delta.
    # ADD COLUMN only, every column NOT NULL DEFAULT 0, so the shipped
    # five-column INSERT idiom keeps working, every shipped number stays put,
    # and an older image (which never selects them) rolls back safely over a
    # v4 store. A pre-v4 row reads 0 here, meaning "not measured" - never a
    # real zero peak.
    (4, """
    ALTER TABLE stats_minute ADD COLUMN samples INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_minute ADD COLUMN conns INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_minute ADD COLUMN peak_up INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_minute ADD COLUMN peak_down INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_hour ADD COLUMN samples INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_hour ADD COLUMN conns INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_hour ADD COLUMN peak_up INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_hour ADD COLUMN peak_down INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_day ADD COLUMN samples INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_day ADD COLUMN conns INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_day ADD COLUMN peak_up INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE stats_day ADD COLUMN peak_down INTEGER NOT NULL DEFAULT 0;
    """),
    # v5 - the star schema (#95): the v5 minute tier (see MINUTE_TABLE), the
    # dimension tables, the seven-day class tables, a (device, bucket) index
    # on every bucketed table (the primary keys lead with bucket, which a
    # one-device read cannot use), and the hour tier made complete.
    #
    # From v5 the collector writes every poll to the minute AND the hour
    # tier, and rollup only expires minute rows. The backfill brings a v4
    # store to that state: the minute rows still held (the newest 48 h) are
    # folded into their hours and moved to the v5 minute tier.
    #
    # CREATE / INDEX / the fold only - nothing dropped, no column rewritten,
    # and the shipped tables keep their meaning, so an older image still
    # opens a v5 store and counts it correctly (what it cannot do is
    # maintain the tables it does not know: docs/panel.md).
    (5, "\n".join([
        f"CREATE TABLE {MINUTE_TABLE} (bucket TEXT NOT NULL, "
        "device TEXT NOT NULL, chain TEXT NOT NULL, "
        "up INTEGER NOT NULL DEFAULT 0, down INTEGER NOT NULL DEFAULT 0, "
        "samples INTEGER NOT NULL DEFAULT 0, conns INTEGER NOT NULL DEFAULT 0, "
        "peak_up INTEGER NOT NULL DEFAULT 0, "
        "peak_down INTEGER NOT NULL DEFAULT 0, "
        "PRIMARY KEY (bucket, device, chain));",
        *(_value_table(f"stats_{dim}_hour") for dim in DIMENSIONS),
        *(_value_table(f"stats_{dim}_day", day=True) for dim in DIMENSIONS),
        *(_value_table(name) for name in _V5_CLASS_TABLES),
        *(f"CREATE INDEX {name}_device ON {name} (device, bucket);"
          for name in _INDEXED),
        *(f"{stmt};" for stmt in _FOLD_LEGACY_MINUTES)])),
    # v6 - the collector's own gauges (#96). NULL is "not measured".
    (6, f"""
    CREATE TABLE {SELF_TABLE} (
        bucket TEXT PRIMARY KEY,
        poll_ms INTEGER, conns INTEGER, failed_polls INTEGER,
        lag_s INTEGER, db_bytes INTEGER, mihomo_mem_mb INTEGER
    );
    """),
    # v7 - the app-level category ids (#97): one more seven-day class table,
    # behind the same gate. CREATE only, so an older image opens a v7 store
    # unchanged (it cannot prune or purge this table: docs/panel.md).
    (7, "\n".join([
        _value_table(APP_TABLE),
        f"CREATE INDEX {APP_TABLE}_device ON {APP_TABLE} (device, bucket);"])),
    # v8 - the selected node's delay per policy group (#102). A failed test
    # is NULL, never 0. CREATE only, so an older image opens a v8 store
    # unchanged (it cannot prune or purge this table: the v1.14.0 notes).
    (8, f"""
    CREATE TABLE {NODE_DELAY_TABLE} (
        tested_at TEXT NOT NULL,
        grp TEXT NOT NULL,
        node TEXT NOT NULL,
        delay_ms INTEGER,
        PRIMARY KEY (grp, node, tested_at)
    );
    CREATE INDEX {NODE_DELAY_TABLE}_tested ON {NODE_DELAY_TABLE} (tested_at);
    """),
]


def fold_legacy_minutes(conn) -> None:
    """Fold minute rows an OLDER panel image wrote into the v5 tiers (see
    MINUTE_TABLE) - one transaction. Run on every open, so a return from a
    downgrade picks up what the older image collected meanwhile; a no-op
    on a store only v5 has written."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        if conn.execute("SELECT 1 FROM stats_minute LIMIT 1").fetchone():
            for stmt in _FOLD_LEGACY_MINUTES:
                conn.execute(stmt)
        conn.execute("COMMIT")
    except BaseException:
        with suppress(Exception):
            conn.execute("ROLLBACK")
        raise


def open_stats_db(path: Path):
    """auto_vacuum must be INCREMENTAL from birth (it cannot be enabled on
    a populated db without a full VACUUM) - the cap enforcement's
    incremental_vacuum depends on it. Every open also folds any minute rows
    an older image left behind (`fold_legacy_minutes`)."""
    conn = open_db(Path(path), migrations=STATS_MIGRATIONS,
                   pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    try:
        fold_legacy_minutes(conn)
    except sqlite3.Error as exc:
        conn.close()
        raise StoreError(f"{Path(path).name} failed to fold legacy minute "
                         f"rows: {exc}") from exc
    return conn


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
