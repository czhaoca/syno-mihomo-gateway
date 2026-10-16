"""Read-only reader connections for the stats API (#93).

Before this, every stats read took the ONE stats connection under the one
RLock the collector also holds for its flush and its maintenance pass - so
a slow rollup or cap prune stalled the landing view. Reads now open their
own read-only (`mode=ro`) connection per request: WAL lets a reader see the
last committed snapshot while the writer works, and the lock is left to the
writer alone. A reader runs its queries in ONE read transaction, so a
response built from several queries still describes a single moment, as it
did when the lock serialised them.

All addresses are TEST-NET (192.0.2.0/24).
"""

import sqlite3
import threading
import time
from types import SimpleNamespace

import pytest
from app.api import routes
from app.store.db import StoreError, open_reader
from app.store.stats import maintain as stats_maintain
from app.store.stats import open_stats_db

READS = [
    ("/v1/stats/devices", {}),
    ("/v1/stats/devices", {"range": "7d"}),
    ("/v1/stats/chains", {"tier": "hour"}),
    ("/v1/stats/timeline", {"range": "48h"}),
    ("/v1/stats/domains", {}),
    ("/v1/stats/coverage", {}),
    ("/v1/stats/gaps", {}),
]


@pytest.fixture()
def seeded(panel_env):
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    conn.execute(
        "INSERT INTO stats_minute_v5 (bucket, device, chain, up, down) "
        "VALUES ('2026-10-15T11:58', '192.0.2.20', 'Routing Mode', 1, 10)")
    conn.close()
    return panel_env["data"] / "state" / "stats.db"


@pytest.mark.parametrize("path, params", READS)
def test_a_stats_read_does_not_wait_on_the_writer_lock(client, seeded, path,
                                                       params):
    held, release = threading.Event(), threading.Event()

    def hold():
        with client.app.state.stats_lock:
            held.set()
            release.wait(5)

    holder = threading.Thread(target=hold)
    holder.start()
    try:
        assert held.wait(5)
        start = time.monotonic()
        r = client.get(path, params=params)
        elapsed = time.monotonic() - start
        assert r.status_code == 200, r.text
        assert elapsed < 0.5, f"{path} {params} waited {elapsed:.2f}s on the lock"
    finally:
        release.set()
        holder.join(5)


def test_a_reader_refuses_writes(seeded):
    reader = open_reader(seeded)
    try:
        assert reader.execute(
            "SELECT COUNT(*) FROM stats_minute_v5").fetchone()[0] == 1
        with pytest.raises(sqlite3.OperationalError):
            reader.execute(
                "INSERT INTO stats_minute_v5 (bucket, device, chain, up, down) "
                "VALUES ('2026-10-15T11:59', '192.0.2.21', 'X', 1, 1)")
        with pytest.raises(sqlite3.OperationalError):
            reader.execute("CREATE TABLE intruder (x INTEGER)")
    finally:
        reader.close()


def test_a_reader_rows_are_addressable_by_name(seeded):
    reader = open_reader(seeded)
    try:
        row = reader.execute("SELECT device, up FROM stats_minute_v5").fetchone()
        assert row["device"] == "192.0.2.20" and row["up"] == 1
    finally:
        reader.close()


def test_opening_a_reader_on_a_missing_store_fails_cleanly(tmp_path):
    with pytest.raises(StoreError):
        open_reader(tmp_path / "absent" / "stats.db")
    # and it never creates the file it was asked to read
    assert not (tmp_path / "absent" / "stats.db").exists()


def test_a_reader_sees_writes_committed_after_it_opened(seeded):
    # per-request readers are opened fresh, so the snapshot a request reads
    # is the latest committed one - nothing is cached across requests
    writer = open_stats_db(seeded)
    reader = open_reader(seeded)
    try:
        writer.execute(
            "INSERT INTO stats_minute_v5 (bucket, device, chain, up, down) "
            "VALUES ('2026-10-15T11:59', '192.0.2.21', 'X', 2, 2)")
        assert reader.execute(
            "SELECT COUNT(*) FROM stats_minute_v5").fetchone()[0] == 2
    finally:
        reader.close()
        writer.close()


def test_a_path_with_spaces_and_percent_signs_opens(tmp_path):
    odd = tmp_path / "data dir %20 #1" / "stats.db"
    open_stats_db(odd).close()
    reader = open_reader(odd)
    try:
        assert reader.execute("PRAGMA user_version").fetchone()[0] >= 1
    finally:
        reader.close()


def test_one_request_reads_one_snapshot(panel_env, seeded):
    """The lock used to keep a multi-query response (window rows + framings,
    the coverage report) on one moment; the reader's read transaction does
    now. A write committed between two queries of one request stays
    invisible to the second, and is visible to the next request."""
    writer = open_stats_db(seeded)
    request = SimpleNamespace(app=SimpleNamespace(
        state=SimpleNamespace(stats_conn=writer)))
    try:
        with routes._stats_reader(request) as conn:
            first = conn.execute("SELECT COUNT(*) FROM stats_minute_v5").fetchone()[0]
            writer.execute(
                "INSERT INTO stats_minute_v5 (bucket, device, chain, up, down) "
                "VALUES ('2026-10-15T11:59', '192.0.2.21', 'X', 2, 2)")
            again = conn.execute("SELECT COUNT(*) FROM stats_minute_v5").fetchone()[0]
            assert again == first == 1
        with routes._stats_reader(request) as conn:
            assert conn.execute(
                "SELECT COUNT(*) FROM stats_minute_v5").fetchone()[0] == 2
    finally:
        writer.close()


def test_the_cap_does_not_prune_against_a_wal_a_reader_still_pins(panel_env):
    """A TRUNCATE checkpoint waits for readers through busy_timeout; a
    snapshot held past it leaves the WAL in place and the checkpoint says
    busy. The cap measures db + WAL, so pruning then would delete history
    to pay for bytes that are about to go - the pass must stop instead, and
    prune normally once the reader is gone."""
    path = panel_env["data"] / "state" / "stats.db"
    writer = open_stats_db(path)
    # keep the rows IN the WAL: an automatic checkpoint at commit would
    # backfill them, and a reader that then reads the db file alone pins no
    # WAL at all - the situation under test would never arise
    writer.execute("PRAGMA wal_autocheckpoint = 0")
    rows = [(f"2026-{1 + i % 12:02d}-{1 + i % 28:02d}", f"192.0.2.{i % 250}",
             f"chain-{i}", i, i) for i in range(30000)]
    writer.execute("BEGIN")
    writer.executemany(
        "INSERT INTO stats_day (bucket, device, chain, up, down) "
        "VALUES (?, ?, ?, ?, ?)", rows)
    writer.execute("COMMIT")
    reader = open_reader(path)
    try:
        reader.execute("BEGIN")
        assert reader.execute("SELECT COUNT(*) FROM stats_day").fetchone()[0] == 30000
        writer.execute("PRAGMA busy_timeout = 50")  # the reader outlives it
        pruned = stats_maintain.enforce_cap(writer, path, cap_mb=1)
        assert sum(pruned.values()) == 0, pruned
        assert writer.execute("SELECT COUNT(*) FROM stats_day").fetchone()[0] == 30000
    finally:
        reader.execute("ROLLBACK")
        reader.close()
    pruned = stats_maintain.enforce_cap(writer, path, cap_mb=1)
    assert pruned["day"] > 0
    writer.close()


def test_the_stats_routes_answer_503_when_the_store_is_down(client):
    real = client.app.state.stats_conn
    client.app.state.stats_conn = None
    try:
        for path, params in READS:
            assert client.get(path, params=params).status_code == 503, path
    finally:
        client.app.state.stats_conn = real  # the lifespan closes it
