"""The byte reads list only groups that moved bytes (#98 DEC-E).

Since #94 a tier row is also written for a poll in which a connection only
APPEARED - zero bytes, one `conns` - so the facts it records survive. Before
#94 no such row existed, and every /v1 byte read (devices, chains, timeline)
listed only groups that moved bytes. The reads filter the zero-byte groups,
so those responses stay exactly what they were while the stored rows keep
their `conns` and `samples`. A window holding only zero-byte activity reads
empty - which is what the Stats view's "no traffic in this range" state
checks for. Synthesised flows only (TEST-NET, example.com).
"""

from datetime import UTC, datetime

import pytest
from app.api import routes
from app.store import dayframe
from app.store import stats as stats_store
from app.store.stats import flush_poll, open_stats_db
from app.tests.conftest import geo_conn

A, B = "192.0.2.20", "192.0.2.21"
NOW = datetime(2026, 10, 15, 12, 30, tzinfo=UTC)


@pytest.fixture()
def pinned_clock(monkeypatch):
    monkeypatch.setattr(routes, "_utcnow", lambda: NOW)


def push(conn, frames, now):
    flush_poll(conn, frames, now, domains_enabled=False, gap_threshold_s=6,
               interval_s=2)


def seed(conn):
    # A only ever opens a connection that has moved nothing yet; B moves
    # bytes on another chain
    push(conn, [geo_conn("c1", A, 0, 0, chains=("JP 01", "Idle Group")),
                geo_conn("c2", B, 5, 50)], "2026-10-15T12:00:00Z")


def rows(client, path):
    r = client.get(path)
    assert r.status_code == 200, r.text
    return r.json()["rows"]


def test_the_zero_byte_rows_are_still_stored(client):
    seed(client.app.state.stats_conn)
    stored = client.app.state.stats_conn.execute(
        "SELECT up, down, conns FROM stats_hour WHERE device = ?",
        (A,)).fetchone()
    assert tuple(stored) == (0, 0, 1)


@pytest.mark.parametrize("path", [
    "/v1/stats/devices?tier=minute", "/v1/stats/devices?tier=hour",
    "/v1/stats/devices?range=48h", "/v1/stats/devices?range=7d",
    "/v1/stats/devices?range=daily"])
def test_a_device_that_moved_nothing_is_not_listed(client, pinned_clock, path):
    seed(client.app.state.stats_conn)
    assert [r["device"] for r in rows(client, path)] == [B]


@pytest.mark.parametrize("path", [
    "/v1/stats/chains?tier=minute", "/v1/stats/chains?range=7d",
    "/v1/stats/chains?range=daily"])
def test_a_chain_that_moved_nothing_is_not_listed(client, pinned_clock, path):
    seed(client.app.state.stats_conn)
    assert [r["chain"] for r in rows(client, path)] == ["Routing Mode"]


@pytest.mark.parametrize("path", [
    "/v1/stats/timeline?tier=minute&device=192.0.2.20",
    "/v1/stats/timeline?tier=hour&device=192.0.2.20",
    "/v1/stats/timeline?range=48h&device=192.0.2.20",
    "/v1/stats/timeline?range=7d&device=192.0.2.20",
    "/v1/stats/timeline?range=daily&device=192.0.2.20"])
def test_a_window_with_only_zero_byte_activity_reads_empty(client,
                                                           pinned_clock, path):
    seed(client.app.state.stats_conn)
    assert rows(client, path) == []


def test_a_zero_byte_bucket_beside_a_moving_one_drops_out(client):
    conn = client.app.state.stats_conn
    push(conn, [geo_conn("c1", A, 0, 0)], "2026-10-15T12:00:00Z")
    push(conn, [geo_conn("c1", A, 7, 70)], "2026-10-15T12:01:00Z")
    assert [r["bucket"] for r in rows(
        client, "/v1/stats/timeline?tier=minute")] == ["2026-10-15T12:01"]


def test_a_stored_zero_day_row_is_not_listed(sconn_day):
    conn = sconn_day
    conn.execute("INSERT INTO stats_day (bucket, device, chain, up, down, "
                 "conns) VALUES ('2026-06-01', ?, 'Routing Mode', 0, 0, 3)",
                 (A,))
    conn.commit()
    assert stats_store.read_grouped(conn, "day", "device") == []
    assert stats_store.read_timeline(conn, "day") == []
    assert stats_store.read_window_timeline(conn, "day", "", None,
                                            dayframe.utc_frame()) == []


def test_a_day_half_rolled_at_zero_and_half_moving_is_one_listed_day(
        sconn_day):
    conn = sconn_day
    conn.execute("INSERT INTO stats_day (bucket, device, chain, up, down, "
                 "conns) VALUES ('2026-10-15', ?, 'Routing Mode', 0, 0, 2)",
                 (A,))
    conn.execute("INSERT INTO stats_hour (bucket, device, chain, up, down) "
                 "VALUES ('2026-10-15T09', ?, 'Routing Mode', 4, 40)", (A,))
    conn.commit()
    assert stats_store.read_window_timeline(
        conn, "day", "", None, dayframe.utc_frame()) == [
        {"bucket": "2026-10-15", "bucket_tz": "UTC", "day_boundary": "00:00",
         "up": 4, "down": 40}]


def test_a_zero_byte_day_reports_no_framing(sconn_day):
    conn = sconn_day
    conn.execute("INSERT INTO stats_day (bucket, device, chain, up, down, "
                 "conns, bucket_tz, day_boundary) VALUES ('2026-06-01', ?, "
                 "'Routing Mode', 0, 0, 1, 'Asia/Shanghai', '03:00')", (A,))
    conn.execute("INSERT INTO stats_hour (bucket, device, chain, up, down, "
                 "conns) VALUES ('2026-10-15T09', ?, 'Routing Mode', 0, 0, 1)",
                 (A,))
    conn.commit()
    assert stats_store.day_framings(conn) == []
    assert stats_store.window_framings(conn, None, dayframe.utc_frame()) == []
    conn.execute("INSERT INTO stats_day (bucket, device, chain, up, down) "
                 "VALUES ('2026-06-02', ?, 'Routing Mode', 3, 3)", (A,))
    conn.commit()
    assert stats_store.day_framings(conn) == [
        {"bucket_tz": "UTC", "day_boundary": "00:00"}]


def test_a_bounded_window_reports_no_framing_for_zero_bytes(sconn_day):
    # the bounded path (range=7d&tier=day and the like) filters too
    conn = sconn_day
    conn.execute("INSERT INTO stats_day (bucket, device, chain, up, down, "
                 "conns, bucket_tz, day_boundary) VALUES ('2026-10-10', ?, "
                 "'Routing Mode', 0, 0, 1, 'Asia/Shanghai', '03:00')", (A,))
    conn.execute("INSERT INTO stats_hour (bucket, device, chain, up, down, "
                 "conns) VALUES ('2026-10-15T09', ?, 'Routing Mode', 0, 0, 1)",
                 (A,))
    conn.commit()
    since = datetime(2026, 10, 8, tzinfo=UTC)
    assert stats_store.window_framings(conn, since, dayframe.utc_frame()) == []
    conn.execute("INSERT INTO stats_hour (bucket, device, chain, up, down) "
                 "VALUES ('2026-10-15T10', ?, 'Routing Mode', 2, 2)", (A,))
    conn.commit()
    assert stats_store.window_framings(conn, since, dayframe.utc_frame()) == [
        {"bucket_tz": "UTC", "day_boundary": "00:00"}]


@pytest.fixture()
def sconn_day(panel_env):
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()
