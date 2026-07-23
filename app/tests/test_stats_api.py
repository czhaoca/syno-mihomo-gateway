"""Stats read endpoints + the token-gated purge: reads are LAN-open,
purge is a bearer-gated mutation that clears stats/domains/gaps but
never conn_baseline (dropping it would re-count still-open connections)
while the POLICY audit stays untouched (and records the purge itself)."""

from app.collector.core import Collector
from app.store.stats import open_stats_db
from app.tests.conftest import auth_headers, conn_fixture
from fastapi.testclient import TestClient


def _seed(panel_env, fake_client, monkeypatch=None, with_domain=False):
    if with_domain and monkeypatch:
        monkeypatch.setenv("PANEL_STATS_DOMAINS", "true")
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    fake_client.conns = [
        conn_fixture("c1", "192.0.2.20", 100, 1000,
                     host="video.example.com"),
        conn_fixture("c2", "192.0.2.21", 5, 50,
                     chain="Full-Tunnel Devices"),
    ]
    Collector(client=fake_client, conn=conn).poll_once(
        now="2026-07-23T10:00:00Z")
    conn.close()


def test_stats_reads_open_and_aggregated(client, panel_env, fake_client):
    _seed(panel_env, fake_client)
    r = client.get("/v1/stats/devices")
    assert r.status_code == 200
    devices = {row["device"]: row for row in r.json()["rows"]}
    assert devices["192.0.2.20"]["down"] == 1000
    assert devices["192.0.2.21"]["up"] == 5
    r = client.get("/v1/stats/chains")
    chains = {row["chain"] for row in r.json()["rows"]}
    assert chains == {"Routing Mode", "Full-Tunnel Devices"}


def test_stats_domains_endpoint_reports_enabled_state(client, panel_env,
                                                      fake_client,
                                                      monkeypatch):
    r = client.get("/v1/stats/domains")
    assert r.status_code == 200
    assert r.json()["enabled"] is False and r.json()["rows"] == []
    _seed(panel_env, fake_client, monkeypatch, with_domain=True)
    r = client.get("/v1/stats/domains")
    assert r.json()["enabled"] is True
    assert [row["domain"] for row in r.json()["rows"]] == ["video.example.com"]


def test_purge_is_token_gated(client, panel_env):
    assert client.post("/v1/stats/purge").status_code == 403
    assert client.post(
        "/v1/stats/purge",
        headers={"Authorization": "Bearer wrong"}).status_code == 403


def test_purge_clears_stats_not_audit(client, panel_env, fake_client,
                                      monkeypatch):
    h = auth_headers(panel_env)
    # a policy mutation first, so the audit has something to protect
    assert client.post("/v1/devices",
                       json={"address": "198.51.100.7",
                             "mode": "full-tunnel"},
                       headers=h).status_code == 201
    _seed(panel_env, fake_client, monkeypatch, with_domain=True)
    assert client.get("/v1/stats/devices").json()["rows"]

    r = client.post("/v1/stats/purge", headers=h)
    assert r.status_code == 200
    assert r.json()["purged"] is True

    assert client.get("/v1/stats/devices").json()["rows"] == []
    assert client.get("/v1/stats/domains").json()["rows"] == []
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    for table in ("stats_minute", "stats_hour", "stats_day", "stats_domain",
                  "stats_gap"):
        assert conn.execute(f"SELECT * FROM {table}").fetchall() == [], table
    # accounting state SURVIVES the purge: dropping baselines would make
    # every still-open connection re-count its full cumulative next poll
    assert conn.execute("SELECT * FROM conn_baseline").fetchall() != []
    conn.close()

    # the POLICY audit is untouched by design - and records the purge
    entries = client.get("/v1/audit").json()["entries"]
    actions = [e["action"] for e in entries]
    assert "add" in actions, "policy audit must survive a stats purge"
    assert "stats-purge" in actions


def test_purge_never_recounts_open_connections(panel_env, fake_client):
    """The panelist-found double-count class: a purge must NOT make a
    still-open connection re-contribute its pre-purge cumulative."""
    from app.store.stats import purge_stats

    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    col = Collector(client=fake_client, conn=conn)
    fake_client.conns = [conn_fixture("big", "192.0.2.20", 500_000, 900_000)]
    col.poll_once(now="2026-07-23T10:00:00Z")
    purge_stats(conn)
    # the SAME connection, ZERO growth: nothing may be recorded
    col.poll_once(now="2026-07-23T10:00:10Z")
    assert conn.execute("SELECT * FROM stats_minute").fetchall() == []
    # growth after the purge counts only the delta
    fake_client.conns = [conn_fixture("big", "192.0.2.20", 500_100, 900_500)]
    col.poll_once(now="2026-07-23T10:00:20Z")
    rows = conn.execute("SELECT up, down FROM stats_minute").fetchall()
    assert [(r["up"], r["down"]) for r in rows] == [(100, 500)]
    conn.close()


def test_stats_survive_when_stats_db_unavailable(panel_env, fake_client,
                                                 notifier):
    # stats.db unopenable (a directory): policy serving is unaffected,
    # stats endpoints answer structurally, /health says collector error
    (panel_env["data"] / "state").mkdir(parents=True)
    (panel_env["data"] / "state" / "stats.db").mkdir()
    from app.main import create_app
    app = create_app(mihomo_client=fake_client, notifier=notifier)
    with TestClient(app) as c:
        assert c.get("/v1/devices").status_code == 200  # policy unaffected
        assert c.get("/health").json()["collector"] == "error"
        r = c.get("/v1/stats/devices")
        assert r.status_code == 503
