"""The opt-in per-domain table (off by default, FORCED 7-day retention
regardless of any knob), honest gap rows on collector downtime, and the
/health collector verdicts."""

from app.collector.core import Collector
from app.store.stats import open_stats_db, rollup
from app.tests.conftest import conn_fixture
from fastapi.testclient import TestClient


def _stats_conn(panel_env):
    return open_stats_db(panel_env["data"] / "state" / "stats.db")


def test_domains_off_by_default(panel_env, fake_client):
    conn = _stats_conn(panel_env)
    fake_client.conns = [conn_fixture("c1", "192.0.2.20", 10, 100,
                                      host="video.example.com")]
    Collector(client=fake_client, conn=conn).poll_once(
        now="2026-07-23T10:00:00Z")
    assert conn.execute("SELECT * FROM stats_domain").fetchall() == []
    conn.close()


def test_domains_collect_when_enabled(panel_env, fake_client, monkeypatch):
    monkeypatch.setenv("PANEL_STATS_DOMAINS", "true")
    conn = _stats_conn(panel_env)
    fake_client.conns = [
        conn_fixture("c1", "192.0.2.20", 10, 100, host="video.example.com"),
        conn_fixture("c2", "192.0.2.20", 5, 50, host=""),  # hostless skipped
    ]
    Collector(client=fake_client, conn=conn).poll_once(
        now="2026-07-23T10:00:00Z")
    rows = conn.execute(
        "SELECT bucket, device, domain, up, down FROM stats_domain").fetchall()
    assert len(rows) == 1
    assert rows[0]["domain"] == "video.example.com"
    assert rows[0]["bucket"] == "2026-07-23T10"  # hourly buckets
    conn.close()


def test_domain_retention_forced_7d(panel_env, monkeypatch):
    # even with every retention knob cranked, domain rows die at 7 days
    monkeypatch.setenv("PANEL_STATS_DOMAINS", "true")
    monkeypatch.setenv("PANEL_STATS_MINUTE_HOURS", "99999")
    monkeypatch.setenv("PANEL_STATS_HOUR_DAYS", "99999")
    conn = _stats_conn(panel_env)
    conn.execute(
        "INSERT INTO stats_domain (bucket, device, domain, up, down) "
        "VALUES ('2026-07-10T10', '192.0.2.20', 'old.example.com', 1, 1)")
    conn.execute(
        "INSERT INTO stats_domain (bucket, device, domain, up, down) "
        "VALUES ('2026-07-22T10', '192.0.2.20', 'new.example.com', 1, 1)")
    rollup(conn, now="2026-07-23T10:00:00Z")
    rows = conn.execute("SELECT domain FROM stats_domain").fetchall()
    assert [r["domain"] for r in rows] == ["new.example.com"]
    conn.close()


def test_gap_rows_on_downtime(panel_env, fake_client):
    conn = _stats_conn(panel_env)
    col = Collector(client=fake_client, conn=conn)
    fake_client.conns = []
    col.poll_once(now="2026-07-23T10:00:00Z")
    # a poll far beyond the cadence: the hole becomes an explicit gap row
    col.poll_once(now="2026-07-23T10:05:00Z")
    gaps = conn.execute(
        "SELECT started, ended FROM stats_gap").fetchall()
    assert len(gaps) == 1
    assert gaps[0]["started"] == "2026-07-23T10:00:00Z"
    assert gaps[0]["ended"] == "2026-07-23T10:05:00Z"
    conn.close()


def test_gap_survives_restart(panel_env, fake_client):
    conn = _stats_conn(panel_env)
    Collector(client=fake_client, conn=conn).poll_once(
        now="2026-07-23T10:00:00Z")
    # a NEW collector (container restart) sees the persisted last-poll ts
    Collector(client=fake_client, conn=conn).poll_once(
        now="2026-07-23T11:00:00Z")
    gaps = conn.execute("SELECT started, ended FROM stats_gap").fetchall()
    assert len(gaps) == 1 and gaps[0]["started"] == "2026-07-23T10:00:00Z"
    conn.close()


def test_no_gap_at_normal_cadence(panel_env, fake_client):
    conn = _stats_conn(panel_env)
    col = Collector(client=fake_client, conn=conn)
    col.poll_once(now="2026-07-23T10:00:00Z")
    col.poll_once(now="2026-07-23T10:00:10Z")
    assert conn.execute("SELECT * FROM stats_gap").fetchall() == []
    conn.close()


def test_health_collector_verdicts(panel_env, fake_client, notifier):
    from app.main import create_app
    app = create_app(mihomo_client=fake_client, notifier=notifier)
    with TestClient(app) as c:
        health = c.get("/health").json()
        # PANEL_STATS_POLL_S=0 in the fixture: the loop is off
        assert health["collector"] == "off"
        assert "collector_last_ts" in health
        assert isinstance(health["stats_db_bytes"], int)
