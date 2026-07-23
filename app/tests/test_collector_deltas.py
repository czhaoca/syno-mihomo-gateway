"""Delta accounting: per-connection cumulative counters against persisted
baselines. Restart-safe (no double-count), first sighting contributes the
full cumulative, a closed connection loses at most one interval, counter
resets are treated as a fresh connection, and the baseline+rollup flush is
one transaction (all-or-nothing)."""

import pytest
from app.collector.core import Collector
from app.store.stats import open_stats_db
from app.tests.conftest import conn_fixture

T0 = "2026-07-23T10:00:00Z"
T1 = "2026-07-23T10:00:10Z"
T2 = "2026-07-23T10:00:20Z"


@pytest.fixture()
def stats_conn(panel_env):
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


def minute_rows(conn):
    return conn.execute(
        "SELECT bucket, device, chain, up, down FROM stats_minute "
        "ORDER BY bucket, device, chain").fetchall()


def test_first_sight_contributes_full_cumulative(stats_conn, fake_client):
    fake_client.conns = [conn_fixture("c1", "192.0.2.20", 100, 2000)]
    col = Collector(client=fake_client, conn=stats_conn)
    col.poll_once(now=T0)
    rows = minute_rows(stats_conn)
    assert len(rows) == 1
    assert rows[0]["device"] == "192.0.2.20"
    assert rows[0]["chain"] == "Routing Mode"
    assert rows[0]["up"] == 100 and rows[0]["down"] == 2000


def test_growth_counts_only_the_delta(stats_conn, fake_client):
    col = Collector(client=fake_client, conn=stats_conn)
    fake_client.conns = [conn_fixture("c1", "192.0.2.20", 100, 2000)]
    col.poll_once(now=T0)
    fake_client.conns = [conn_fixture("c1", "192.0.2.20", 150, 2600)]
    col.poll_once(now=T1)
    rows = minute_rows(stats_conn)
    assert rows[0]["up"] == 150 and rows[0]["down"] == 2600


def test_restart_never_double_counts(panel_env, stats_conn, fake_client):
    col = Collector(client=fake_client, conn=stats_conn)
    fake_client.conns = [conn_fixture("c1", "192.0.2.20", 100, 2000)]
    col.poll_once(now=T0)
    # a NEW collector over the SAME db (restart): baselines persisted, so an
    # unchanged connection contributes zero
    col2 = Collector(client=fake_client, conn=stats_conn)
    col2.poll_once(now=T1)
    rows = minute_rows(stats_conn)
    assert rows[0]["up"] == 100 and rows[0]["down"] == 2000


def test_closed_connection_bounded_loss(stats_conn, fake_client):
    col = Collector(client=fake_client, conn=stats_conn)
    fake_client.conns = [conn_fixture("c1", "192.0.2.20", 100, 2000)]
    col.poll_once(now=T0)
    fake_client.conns = []  # closed between polls: post-T0 growth is lost
    col.poll_once(now=T1)
    rows = minute_rows(stats_conn)
    assert rows[0]["up"] == 100 and rows[0]["down"] == 2000
    baselines = stats_conn.execute("SELECT conn_id FROM conn_baseline").fetchall()
    assert baselines == []  # closed baselines are reaped
    # the id coming BACK later is a fresh connection (full cumulative again)
    fake_client.conns = [conn_fixture("c1", "192.0.2.20", 40, 400)]
    col.poll_once(now=T2)
    rows = minute_rows(stats_conn)
    assert rows[0]["up"] == 140 and rows[0]["down"] == 2400


def test_counter_reset_treated_as_fresh(stats_conn, fake_client):
    col = Collector(client=fake_client, conn=stats_conn)
    fake_client.conns = [conn_fixture("c1", "192.0.2.20", 100, 2000)]
    col.poll_once(now=T0)
    # cumulative went BACKWARDS (id reuse after mihomo restart): treat the
    # new cumulative as a fresh first sighting, never a negative delta
    fake_client.conns = [conn_fixture("c1", "192.0.2.20", 30, 300)]
    col.poll_once(now=T1)
    rows = minute_rows(stats_conn)
    assert rows[0]["up"] == 130 and rows[0]["down"] == 2300


def test_flush_is_transactional(stats_conn, fake_client, monkeypatch):
    col = Collector(client=fake_client, conn=stats_conn)
    fake_client.conns = [
        conn_fixture("c1", "192.0.2.20", 100, 2000),
        {"id": "c2", "upload": "poison", "download": 1,
         "metadata": {"sourceIP": "192.0.2.21", "host": ""},
         "chains": ["DIRECT"]},
    ]
    with pytest.raises(ValueError):  # int("poison") explodes mid-flush
        col.poll_once(now=T0, _strict=True)
    # nothing persisted: neither the minute rows nor the baselines
    assert minute_rows(stats_conn) == []
    assert stats_conn.execute("SELECT * FROM conn_baseline").fetchall() == []


def test_per_chain_dimension_uses_outermost(stats_conn, fake_client):
    fake_client.conns = [
        conn_fixture("c1", "192.0.2.20", 10, 100, chain="Full-Tunnel Devices"),
        conn_fixture("c2", "192.0.2.20", 5, 50, chain="Routing Mode"),
        {"id": "c3", "upload": 1, "download": 2,
         "metadata": {"sourceIP": "192.0.2.21", "host": ""},
         "chains": ["DIRECT"]},
    ]
    col = Collector(client=fake_client, conn=stats_conn)
    col.poll_once(now=T0)
    chains = {r["chain"] for r in minute_rows(stats_conn)}
    assert chains == {"Full-Tunnel Devices", "Routing Mode", "DIRECT"}


def test_collector_failure_degrades(stats_conn, fake_client):
    fake_client.fail_connections = True
    col = Collector(client=fake_client, conn=stats_conn)
    col.poll_once(now=T0)  # must not raise
    assert col.status["last_error"]
    assert minute_rows(stats_conn) == []
