"""stats.db migration v5 (#95): the star schema is CREATE + INDEX + backfill.

A populated v4 store gains the v5 minute tier, the dimension and seven-day
class tables, the (device, bucket) indexes, and an hour tier made complete
from the minute rows not rolled yet - those rows are folded into their
hours and MOVED to `stats_minute_v5`, so from v5 on the hour tier holds
every byte the minute tier does. Nothing is dropped and no column is
rewritten, and the shipped tables keep their meaning: an older image
(the updater rolls the panel back on its own when a health gate fails)
opens a v5 store and counts it correctly, and whatever it collects in the
shipped `stats_minute` is folded in again when v5 returns.
"""

import re

from app.store import dayframe
from app.store.db import open_db
from app.store.stats import (
    _CAP_TIERS,
    CLASS_TABLES,
    DIMENSIONS,
    MINUTE_TABLE,
    PURGE_TABLES,
    STATS_MIGRATIONS,
    flush_poll,
    open_stats_db,
    read_window_grouped,
    read_window_timeline,
)
from app.tests.conftest import conn_fixture

A, B = "192.0.2.20", "192.0.2.21"


def _v4_db(path):
    conn = open_db(path, migrations=STATS_MIGRATIONS[:4],
                   pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 4
    return conn


def _minute(conn, bucket, device, up, down, samples=1, conns=0, peak=0):
    conn.execute(
        "INSERT INTO stats_minute (bucket, device, chain, up, down, samples, "
        "conns, peak_up, peak_down) VALUES (?, ?, 'Routing Mode', ?, ?, ?, ?, "
        "?, ?)", (bucket, device, up, down, samples, conns, peak, peak))


def _hour(conn, bucket, device, up, down, samples=0, conns=0, peak=0):
    conn.execute(
        "INSERT INTO stats_hour (bucket, device, chain, up, down, samples, "
        "conns, peak_up, peak_down) VALUES (?, ?, 'Routing Mode', ?, ?, ?, ?, "
        "?, ?)", (bucket, device, up, down, samples, conns, peak, peak))


def test_the_star_schema_is_stats_migration_five():
    assert [v for v, _ in STATS_MIGRATIONS] == [1, 2, 3, 4, 5]


def test_v5_creates_indexes_and_backfills_only():
    sql = STATS_MIGRATIONS[4][1]
    statements = [s.strip() for s in sql.split(";") if s.strip()]
    for stmt in statements:
        assert re.match(r"(CREATE TABLE|CREATE INDEX|INSERT INTO)\b", stmt) \
            or stmt == "DELETE FROM stats_minute", stmt
    # the one DELETE completes the move of the legacy minute rows
    assert statements.count("DELETE FROM stats_minute") == 1
    # the backfill's ON CONFLICT ... DO UPDATE is an upsert, not a rewrite;
    # no statement may start with UPDATE/DELETE (checked above)
    assert not re.search(r"\b(DROP|ALTER)\b", sql)


def test_a_populated_v4_store_gains_a_complete_hour_tier(tmp_path, panel_env):
    path = tmp_path / "stats.db"
    old = _v4_db(path)
    # 09:00-09:29 of 10-14 already rolled into its hour; 09:45 not yet -
    # the half-rolled hour the backfill must complete, not duplicate
    _hour(old, "2026-10-14T09", A, 100, 1000, samples=30, conns=4, peak=60)
    _minute(old, "2026-10-14T09:45", A, 5, 50, samples=2, conns=1, peak=70)
    _minute(old, "2026-10-15T11:58", A, 1, 10, samples=1, conns=1, peak=1)
    _minute(old, "2026-10-15T11:59", A, 2, 20, samples=3, conns=0, peak=2)
    _minute(old, "2026-10-15T11:59", B, 7, 70, samples=1, conns=1, peak=7)
    # an older hour and a day row the migration must not touch
    _hour(old, "2026-09-01T00", A, 400, 4000)
    old.execute("INSERT INTO stats_day (bucket, device, chain, up, down) "
                "VALUES ('2026-06-01', ?, 'Routing Mode', 9, 90)", (A,))
    minutes_before = [tuple(r) for r in old.execute(
        "SELECT bucket, device, chain, up, down, samples, conns, peak_up, "
        "peak_down FROM stats_minute ORDER BY bucket, device")]
    days_before = [tuple(r) for r in old.execute("SELECT * FROM stats_day")]
    old.close()

    new = open_stats_db(path)
    try:
        assert new.execute("PRAGMA user_version").fetchone()[0] == 5
        hours = {(r["bucket"], r["device"]): tuple(r)[3:] for r in new.execute(
            "SELECT bucket, device, chain, up, down, samples, conns, peak_up, "
            "peak_down FROM stats_hour")}
        assert hours == {
            ("2026-10-14T09", A): (105, 1050, 32, 5, 70, 70),
            ("2026-10-15T11", A): (3, 30, 4, 1, 2, 2),
            ("2026-10-15T11", B): (7, 70, 1, 1, 7, 7),
            ("2026-09-01T00", A): (400, 4000, 0, 0, 0, 0)}
        # the minute rows moved to the v5 minute tier, unchanged, and are a
        # finer copy of the hour tier; the shipped table is left empty
        assert [tuple(r) for r in new.execute(
            f"SELECT bucket, device, chain, up, down, samples, conns, peak_up, "
            f"peak_down FROM {MINUTE_TABLE} ORDER BY bucket, device")] == \
            minutes_before
        assert new.execute("SELECT COUNT(*) FROM stats_minute").fetchone()[0] == 0
        for bucket, device, up, down in new.execute(
                f"SELECT substr(bucket, 1, 13), device, SUM(up), SUM(down) "
                f"FROM {MINUTE_TABLE} GROUP BY 1, 2"):
            hu, hd = hours[(bucket, device)][:2]
            assert up <= hu and down <= hd, (bucket, device)
        assert [tuple(r) for r in new.execute(
            "SELECT * FROM stats_day")] == days_before
    finally:
        new.close()


def test_the_new_tables_and_indexes_exist(tmp_path, panel_env):
    conn = open_stats_db(tmp_path / "stats.db")
    try:
        tables = {r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'")}
        for dim in DIMENSIONS:
            assert {f"stats_{dim}_hour", f"stats_{dim}_day"} <= tables, dim
            day_cols = [r["name"] for r in conn.execute(
                f"PRAGMA table_info(stats_{dim}_day)")]
            assert day_cols == ["bucket", "device", "value", "up", "down",
                                "bucket_tz", "day_boundary"], dim
        assert set(CLASS_TABLES) <= tables
        # every bucketed table answers a per-device read from an index
        for table in tables:
            cols = [r["name"] for r in conn.execute(f"PRAGMA table_info({table})")]
            if "device" not in cols or "bucket" not in cols:
                continue
            indexed = set()
            for idx in conn.execute(f"PRAGMA index_list({table})"):
                indexed.add(tuple(r["name"] for r in conn.execute(
                    f"PRAGMA index_info({idx['name']})")))
            assert ("device", "bucket") in indexed, table
    finally:
        conn.close()


def test_every_stats_table_is_purged_and_capped(tmp_path, panel_env):
    """A table the purge or the cap forgot would survive the one operation
    promising nothing does, or grow past the hard cap. `stats_meta` is
    accounting state (the poll stamp), kept by the purge for the same reason
    as conn_baseline, and holds a handful of rows."""
    conn = open_stats_db(tmp_path / "stats.db")
    try:
        tables = {r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name LIKE 'stats_%'")} - {"stats_meta"}
    finally:
        conn.close()
    assert tables == set(PURGE_TABLES)
    assert tables == {entry[1] for entry in _CAP_TIERS}


def test_an_older_image_opens_a_v5_store_without_migrating_back(tmp_path,
                                                               panel_env):
    path = tmp_path / "stats.db"
    open_stats_db(path).close()  # v5
    older = open_db(path, migrations=STATS_MIGRATIONS[:4],
                    pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    try:
        assert older.execute("PRAGMA user_version").fetchone()[0] == 5
        older.execute("INSERT INTO stats_minute (bucket, device, chain, up, "
                      "down) VALUES ('2026-10-15T12:00', ?, 'X', 3, 4)", (A,))
        assert older.execute("SELECT up FROM stats_minute").fetchone()[0] == 3
    finally:
        older.close()


# --- a downgrade and a return ---------------------------------------------------
#
# What a v1.10.x panel does with stats.db, as SQL: it writes minute rows to
# `stats_minute`, reads a window as minute UNION hour, and rolls minute rows
# older than its window into hours. (The real older code is not importable
# here; these statements are its behaviour, quoted from the v4 store module.)

def _older_poll(conn, bucket, up, down):
    conn.execute(
        "INSERT INTO stats_minute (bucket, device, chain, up, down, samples) "
        "VALUES (?, ?, 'Routing Mode', ?, ?, 1) ON CONFLICT(bucket, device, "
        "chain) DO UPDATE SET up = up + excluded.up, down = down + excluded.down",
        (bucket, A, up, down))


def _older_7d_total(conn, since_hour):
    return conn.execute(
        "SELECT COALESCE(SUM(up), 0) FROM (SELECT up FROM stats_hour WHERE "
        "bucket >= ? UNION ALL SELECT up FROM stats_minute WHERE "
        "substr(bucket, 1, 13) >= ?)", (since_hour, since_hour)).fetchone()[0]


def _older_rollup(conn, minute_cut):
    conn.execute(
        "INSERT INTO stats_hour (bucket, device, chain, up, down) "
        "SELECT substr(bucket, 1, 13), device, chain, SUM(up), SUM(down) "
        "FROM stats_minute WHERE bucket < ? GROUP BY 1, 2, 3 "
        "ON CONFLICT(bucket, device, chain) DO UPDATE SET "
        "up = up + excluded.up, down = down + excluded.down", (minute_cut,))
    conn.execute("DELETE FROM stats_minute WHERE bucket < ?", (minute_cut,))


def test_an_older_image_counts_a_v5_store_once(tmp_path, panel_env):
    path = tmp_path / "stats.db"
    v5 = open_stats_db(path)
    flush_poll(v5, [conn_fixture("c1", A, 300, 3000)], "2026-10-15T11:00:00Z",
               domains_enabled=False, gap_threshold_s=30)
    v5.close()
    older = open_db(path, migrations=STATS_MIGRATIONS[:4],
                    pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    try:
        # its window read and its rollup see each v5 byte exactly once
        assert _older_7d_total(older, "2026-10-08T12") == 300
        _older_rollup(older, "2026-10-17T12:00")
        assert older.execute("SELECT SUM(up) FROM stats_hour").fetchone()[0] == 300
    finally:
        older.close()


def test_a_return_from_a_downgrade_folds_in_what_the_older_image_collected(
        tmp_path, panel_env):
    path = tmp_path / "stats.db"
    v5 = open_stats_db(path)
    flush_poll(v5, [conn_fixture("c1", A, 300, 3000)], "2026-10-15T11:00:00Z",
               domains_enabled=False, gap_threshold_s=30)
    v5.close()
    older = open_db(path, migrations=STATS_MIGRATIONS[:4],
                    pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    _older_poll(older, "2026-10-15T12:00", 50, 500)
    _older_poll(older, "2026-10-15T13:30", 7, 70)
    _older_rollup(older, "2026-10-15T13:00")   # rolls its 12:00 row itself
    older.close()

    back = open_stats_db(path)
    try:
        assert back.execute("SELECT COUNT(*) FROM stats_minute").fetchone()[0] == 0
        frame = dayframe.utc_frame()
        # nothing lost (the 13:30 row only the older image saw) and nothing
        # doubled (the 12:00 row it rolled itself)
        hourly = read_window_timeline(back, "hour", "", None, frame)
        assert [(r["bucket"], r["up"]) for r in hourly] == [
            ("2026-10-15T11", 300), ("2026-10-15T12", 50),
            ("2026-10-15T13", 7)]
        minutes = read_window_grouped(back, "minute", "device", None, frame)
        assert minutes == [{"device": A, "up": 307, "down": 3070}]
    finally:
        back.close()
