"""Collector maintenance + loop scheduling + the /health stale verdict —
the integration seams the delta/rollup unit tests bypass."""

import threading
import time

import pytest
from app.collector import core as collector_core
from app.collector.core import Collector, CollectorLoop
from app.store.stats import open_stats_db
from app.tests.conftest import conn_fixture
from fastapi.testclient import TestClient


@pytest.fixture()
def stats_conn(panel_env):
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


def test_maintain_runs_rollup_and_cap(panel_env, stats_conn, fake_client):
    col = Collector(client=fake_client, conn=stats_conn)
    stats_conn.execute(
        "INSERT INTO stats_minute (bucket, device, chain, up, down) "
        "VALUES ('2026-07-20T09:01', '192.0.2.20', 'Routing Mode', 3, 30)")
    col.maintain(now="2026-07-23T10:00:00Z")
    assert stats_conn.execute("SELECT * FROM stats_minute").fetchall() == []
    hours = stats_conn.execute("SELECT bucket FROM stats_hour").fetchall()
    assert [r["bucket"] for r in hours] == ["2026-07-20T09"]
    assert col.status["last_error"] is None


def test_maintain_degrades_on_failure(panel_env, stats_conn, fake_client,
                                      monkeypatch):
    col = Collector(client=fake_client, conn=stats_conn)

    def exploding_rollup(conn, now):
        raise RuntimeError("rollup defect")

    monkeypatch.setattr(collector_core.stats_store, "rollup",
                        exploding_rollup)
    col.maintain(now="2026-07-23T10:00:00Z")  # must not raise
    assert "RuntimeError" in col.status["last_error"]


def test_loop_schedules_polls_and_maintenance(panel_env, stats_conn,
                                              fake_client, monkeypatch):
    # a real thread, tiny cadence: polls repeat and maintenance fires once
    # the accumulated interval crosses the (patched) threshold
    monkeypatch.setattr(collector_core, "MAINTENANCE_EVERY_S", 2)
    fake_client.conns = [conn_fixture("c1", "192.0.2.20", 10, 100)]
    col = Collector(client=fake_client, conn=stats_conn)
    maintained = threading.Event()
    real_maintain = col.maintain

    def spy_maintain(now=None):
        maintained.set()
        real_maintain(now)

    col.maintain = spy_maintain
    loop = CollectorLoop(col, threading.RLock(), interval_s=1)
    loop.start()
    try:
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and not maintained.is_set():
            time.sleep(0.1)
    finally:
        loop.stop()
    assert col.status["last_poll_ts"], "the loop must poll"
    assert maintained.is_set(), "maintenance must fire past the threshold"


def test_health_stale_verdict(panel_env, fake_client, notifier, monkeypatch):
    # polling nominally ON (interval > 0) but the loop suppressed: never
    # polled -> stale; an old last-poll -> stale; a fresh one -> ok
    monkeypatch.setenv("PANEL_STATS_POLL_S", "5")
    monkeypatch.setattr(CollectorLoop, "start", lambda self: None)
    from app.main import create_app
    app = create_app(mihomo_client=fake_client, notifier=notifier)
    with TestClient(app) as c:
        assert c.get("/health").json()["collector"] == "stale"
        app.state.collector.status["last_poll_ts"] = "2026-01-01T00:00:00Z"
        assert c.get("/health").json()["collector"] == "stale"
        from datetime import UTC, datetime
        app.state.collector.status["last_poll_ts"] = datetime.now(
            UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        health = c.get("/health").json()
        assert health["collector"] == "ok"
        assert health["collector_last_ts"]
