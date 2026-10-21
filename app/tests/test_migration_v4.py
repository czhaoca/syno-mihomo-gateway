"""stats.db migration v4 (#94): the per-bucket facts are ADDITIVE columns.

A populated v3 store (as v1.10.x ships it) gains samples / conns / peak_up /
peak_down on all three tiers with every shipped number intact; old rows read
the new columns as 0 ("not measured"). The shipped five-column INSERT idiom
keeps working, and an OLDER image opening a v4 store (a rollback) neither
migrates backwards nor breaks.
"""

from app.store.db import open_db
from app.store.stats import STATS_MIGRATIONS, open_stats_db

NEW = ("samples", "conns", "peak_up", "peak_down")
TIERS = ("stats_minute", "stats_hour", "stats_day")


def _v3_db(path):
    conn = open_db(path, migrations=STATS_MIGRATIONS[:3],
                   pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 3
    return conn


def _v4(path):
    # this file pins the v3 -> v4 step; v5 (#95) has its own test file
    return open_db(path, migrations=STATS_MIGRATIONS[:4],
                   pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))


def test_the_facts_are_stats_migration_four():
    assert [v for v, _ in STATS_MIGRATIONS][:4] == [1, 2, 3, 4]
    assert "peak_down" in STATS_MIGRATIONS[3][1]


def test_a_populated_v3_store_migrates_with_every_number_intact(tmp_path,
                                                               panel_env):
    path = tmp_path / "stats.db"
    old = _v3_db(path)
    old.execute("INSERT INTO stats_minute (bucket, device, chain, up, down) "
                "VALUES ('2026-10-15T11:58', '192.0.2.20', 'X', 1, 10)")
    old.execute("INSERT INTO stats_hour (bucket, device, chain, up, down) "
                "VALUES ('2026-10-12T08', '192.0.2.20', 'X', 100, 1000)")
    old.execute("INSERT INTO stats_day (bucket, device, chain, up, down, "
                "bucket_tz, day_boundary) VALUES "
                "('2026-06-01', '192.0.2.21', 'Y', 7, 70, 'Asia/Shanghai', '03:00')")
    before = {t: [tuple(r) for r in old.execute(
        f"SELECT bucket, device, chain, up, down FROM {t}")] for t in TIERS}
    old.close()

    new = _v4(path)
    try:
        assert new.execute("PRAGMA user_version").fetchone()[0] == 4
        for table in TIERS:
            cols = {r["name"] for r in new.execute(f"PRAGMA table_info({table})")}
            assert set(NEW) <= cols, (table, cols)
            after = [tuple(r) for r in new.execute(
                f"SELECT bucket, device, chain, up, down FROM {table}")]
            assert after == before[table], table
            facts = new.execute(
                f"SELECT {', '.join(NEW)} FROM {table}").fetchall()
            assert all(tuple(r) == (0, 0, 0, 0) for r in facts), table
        stamp = new.execute(
            "SELECT bucket_tz, day_boundary FROM stats_day").fetchone()
        assert tuple(stamp) == ("Asia/Shanghai", "03:00")
    finally:
        new.close()


def test_the_shipped_five_column_insert_still_works_on_v4(tmp_path, panel_env):
    conn = open_stats_db(tmp_path / "stats.db")
    try:
        for table in TIERS:
            conn.execute(f"INSERT INTO {table} (bucket, device, chain, up, down) "
                         f"VALUES ('2026-10-15', '192.0.2.20', 'X', 1, 2)")
            row = conn.execute(f"SELECT up, samples, conns FROM {table}").fetchone()
            assert tuple(row) == (1, 0, 0)
    finally:
        conn.close()


def test_an_older_image_opens_a_v4_store_without_migrating_back(tmp_path,
                                                               panel_env):
    path = tmp_path / "stats.db"
    _v4(path).close()
    older = open_db(path, migrations=STATS_MIGRATIONS[:3],
                    pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    try:
        assert older.execute("PRAGMA user_version").fetchone()[0] == 4
        older.execute("INSERT INTO stats_minute (bucket, device, chain, up, down) "
                      "VALUES ('2026-10-15T12:00', '192.0.2.20', 'X', 3, 4)")
        assert older.execute("SELECT up, down FROM stats_minute").fetchone()[0] == 3
    finally:
        older.close()
