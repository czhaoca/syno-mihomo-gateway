"""The node delay history and the quota store (#102): migration v8, the
retention knob, the purge and cap, and the two reads. Synthesised node and
provider names only."""

import json
from datetime import UTC, datetime

import pytest
from app import config
from app.api import routes
from app.store import stats as stats_store
from app.store.db import open_db
from app.store.stats import STATS_MIGRATIONS, open_stats_db
from app.tests.conftest import auth_headers

NOW = datetime(2026, 10, 16, 12, 0, tzinfo=UTC)


@pytest.fixture()
def sconn(panel_env):
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


@pytest.fixture()
def pinned_clock(monkeypatch):
    monkeypatch.setattr(routes, "_utcnow", lambda: NOW)


def rows_of(conn):
    return [tuple(r) for r in conn.execute(
        "SELECT tested_at, grp, node, delay_ms FROM stats_node_delay "
        "ORDER BY grp, tested_at")]


# --- the store -----------------------------------------------------------------

def test_v8_adds_the_node_delay_table_and_an_older_image_leaves_it(panel_env):
    path = panel_env["data"] / "state" / "stats.db"
    conn = open_stats_db(path)
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 8
    stats_store.record_delays(conn, [("2026-10-16T11:00:00Z", "Auto", "JP 01", 40)])
    conn.close()
    # an image that knows seven migrations opens it and reads its own tables
    older = open_db(path, migrations=STATS_MIGRATIONS[:7],
                    pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    try:
        assert older.execute("SELECT COUNT(*) FROM stats_app").fetchone()[0] == 0
        assert rows_of(older) == [("2026-10-16T11:00:00Z", "Auto", "JP 01", 40)]
    finally:
        older.close()
    assert stats_store.NODE_DELAY_TABLE in stats_store.PURGE_TABLES
    assert "node_delay" in {e[0] for e in stats_store._CAP_TIERS}


def test_a_test_is_stored_once_and_a_failed_one_is_null(sconn):
    rows = [("2026-10-16T11:00:00Z", "Auto", "JP 01", 40),
            ("2026-10-16T11:05:00Z", "Auto", "JP 01", None)]
    assert stats_store.record_delays(sconn, rows) == 2
    # sampling the same tests again adds nothing
    assert stats_store.record_delays(sconn, rows) == 0
    assert rows_of(sconn)[1] == ("2026-10-16T11:05:00Z", "Auto", "JP 01", None)


@pytest.mark.parametrize(("raw", "days"), [("", 14), ("3", 7), ("21", 21),
                                           ("90", 30), ("x", 14)])
def test_the_retention_knob_is_clamped(monkeypatch, raw, days):
    monkeypatch.setenv("PANEL_NODE_DELAY_DAYS", raw)
    assert config.node_delay_days() == days


def test_rollup_keeps_the_knob_horizon(sconn, monkeypatch):
    monkeypatch.setenv("PANEL_NODE_DELAY_DAYS", "7")
    stats_store.record_delays(sconn, [
        ("2026-10-09T11:59:59Z", "Auto", "JP 01", 40),   # past 7 days
        ("2026-10-09T12:00:00Z", "Auto", "JP 01", 41),   # the horizon itself
        ("2026-10-16T11:00:00Z", "Auto", "JP 01", 42)])
    from app.store import dayframe
    stats_store.rollup(sconn, "2026-10-16T12:00:00Z", day=dayframe.utc_frame())
    assert [r[0] for r in rows_of(sconn)] == ["2026-10-09T12:00:00Z",
                                             "2026-10-16T11:00:00Z"]


def test_the_purge_takes_node_delay_and_only_a_bare_purge_takes_quota(
        client, panel_env):
    sconn = client.app.state.stats_conn
    seed = lambda: (  # noqa: E731
        stats_store.record_delays(sconn, [("2026-10-16T11:00:00Z", "Auto",
                                           "JP 01", 40)]),
        stats_store.write_quota(sconn, {"my-airport": {
            "upload": 1, "download": 2, "total": 3, "expire": 4,
            "updatedAt": "2026-10-16T10:00:00Z"}}))
    seed()
    # a device scope leaves both: neither has a device
    r = client.post("/v1/stats/purge", json={"device": "192.0.2.20"},
                    headers=auth_headers(panel_env))
    assert r.status_code == 200, r.text
    assert len(rows_of(sconn)) == 1 and stats_store.read_quota(sconn)
    # a table scope takes the table, never the quota
    r = client.post("/v1/stats/purge", json={"tables": ["stats_node_delay"]},
                    headers=auth_headers(panel_env))
    assert r.status_code == 200, r.text
    assert rows_of(sconn) == [] and stats_store.read_quota(sconn)
    assert r.json()["rows"] == {"stats_node_delay": 1}
    seed()
    # the bare purge takes both, and the poll stamp survives it
    sconn.execute("INSERT OR REPLACE INTO stats_meta (k, v) VALUES "
                  "('last_poll_ts', '2026-10-16T11:59:58Z')")
    r = client.post("/v1/stats/purge", headers=auth_headers(panel_env))
    assert r.status_code == 200, r.text
    assert rows_of(sconn) == [] and stats_store.read_quota(sconn) == []
    assert stats_store.meta_get(sconn, "last_poll_ts") == "2026-10-16T11:59:58Z"
    assert "stats_meta" not in r.json()["rows"]
    # and stats_meta is still no table a purge may name
    r = client.post("/v1/stats/purge", json={"tables": ["stats_meta"]},
                    headers=auth_headers(panel_env))
    assert r.status_code == 422


def test_quota_keys_never_touch_the_accounting_state(sconn):
    sconn.execute("INSERT OR REPLACE INTO stats_meta (k, v) VALUES "
                  "('last_poll_ts', 'x'), ('quotaX', 'y'), ('Quota:z', 'w')")
    stats_store.write_quota(sconn, {})
    left = {r[0] for r in sconn.execute("SELECT k FROM stats_meta")}
    # the exact prefix only - never a case-insensitive or a looser match
    assert {"last_poll_ts", "quotaX", "Quota:z"} <= left


# --- the reads -------------------------------------------------------------------

def seed_delays(conn):
    stats_store.record_delays(conn, [
        ("2026-10-15T10:01:00Z", "Auto", "JP 01", 40),
        ("2026-10-15T10:06:00Z", "Auto", "JP 01", None),
        ("2026-10-15T10:11:00Z", "Auto", "JP 01", 60),
        ("2026-10-15T11:01:00Z", "Auto", "JP 01", None),
        ("2026-10-16T11:00:00Z", "Auto", "US 01", 120),
        ("2026-10-16T11:30:00Z", "Proxy", "Auto", 125),
        ("2026-09-01T00:00:00Z", "Auto", "JP 01", 99)])   # past retention


def test_a_minute_preset_lists_the_tests_and_names_the_selection(
        client, pinned_clock):
    seed_delays(client.app.state.stats_conn)
    r = client.get("/v1/stats/node-delay?range=48h")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["resolution"] == "test" and body["truncated"] is False
    assert body["since"] == "2026-10-14T12:00:00Z"
    auto = next(g for g in body["groups"] if g["group"] == "Auto")
    assert [p["delay_ms"] for p in auto["points"]] == [40, None, 60, None, 120]
    assert auto["latest"] == {"node": "US 01", "tested_at": "2026-10-16T11:00:00Z",
                              "delay_ms": 120}
    # a group whose selection is itself a group is stored as given
    proxy = next(g for g in body["groups"] if g["group"] == "Proxy")
    assert proxy["latest"]["node"] == "Auto"


def test_latest_is_the_newest_test_and_a_tie_goes_to_the_last_written(
        client, pinned_clock):
    stats_store.record_delays(client.app.state.stats_conn, [
        ("2026-10-16T11:00:00Z", "Auto", "ZZ 09", 30),
        ("2026-10-16T11:00:00Z", "Auto", "AA 01", 50)])
    auto = client.get("/v1/stats/node-delay?range=24h").json()["groups"][0]
    assert auto["latest"]["node"] == "AA 01"


def test_the_read_stays_fast_at_a_full_retention(client, pinned_clock):
    """A fortnight of 300 s tests for 20 groups: the read is one pass, not a
    lookup per row (that was seconds per read, holding the WAL snapshot the
    maintenance checkpoint waits on)."""
    import time
    from datetime import timedelta
    sconn = client.app.state.stats_conn
    start = NOW - timedelta(days=14)
    rows = [((start + timedelta(seconds=300 * i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
             f"G{g:02d}", "JP 01", 40)
            for g in range(20) for i in range(14 * 288)]
    sconn.execute("BEGIN")
    sconn.executemany("INSERT INTO stats_node_delay VALUES (?, ?, ?, ?)", rows)
    sconn.execute("COMMIT")
    for preset in ("48h", "daily"):
        began = time.monotonic()
        body = client.get(f"/v1/stats/node-delay?range={preset}").json()
        assert time.monotonic() - began < 2.0, preset
        assert len(body["groups"]) == 20


def test_a_long_preset_is_hourly_and_never_averages_a_failure_as_zero(
        client, pinned_clock):
    seed_delays(client.app.state.stats_conn)
    body = client.get("/v1/stats/node-delay?range=7d").json()
    assert body["resolution"] == "hour"
    auto = next(g for g in body["groups"] if g["group"] == "Auto")
    by_hour = {(p["at"], p["node"]): p for p in auto["points"]}
    ten = by_hour[("2026-10-15T10", "JP 01")]
    assert (ten["delay_ms"], ten["tests"], ten["failed"]) == (50, 2, 1)
    assert (ten["min_ms"], ten["max_ms"]) == (40, 60)
    eleven = by_hour[("2026-10-15T11", "JP 01")]
    assert (eleven["delay_ms"], eleven["tests"], eleven["failed"]) == (None, 0, 1)


def test_the_window_is_cut_at_the_retention_and_says_so(client, pinned_clock,
                                                       monkeypatch):
    monkeypatch.setenv("PANEL_NODE_DELAY_DAYS", "7")
    seed_delays(client.app.state.stats_conn)
    body = client.get("/v1/stats/node-delay?range=30d").json()
    assert body["retention_days"] == 7 and body["truncated"] is True
    assert body["since"] == "2026-10-09T12:00:00Z"
    assert all(p["at"] >= "2026-10-09" for g in body["groups"] for p in g["points"])
    daily = client.get("/v1/stats/node-delay?range=daily").json()
    assert daily["truncated"] is True and daily["since"] == "2026-10-09T12:00:00Z"


def test_an_empty_store_answers_empty_not_zero(client, pinned_clock):
    body = client.get("/v1/stats/node-delay").json()
    assert body["groups"] == [] and body["range"] == "7d"
    quota = client.get("/v1/stats/quota").json()
    # no collector loop in tests: the sampler is not running
    assert quota == {"providers": [], "state": "off", "sampled_at": None}


def test_the_reads_need_no_token_and_write_nothing(client, pinned_clock):
    sconn = client.app.state.stats_conn
    seed_delays(sconn)
    before = sconn.total_changes
    for path in ("/v1/stats/node-delay?range=24h", "/v1/stats/quota"):
        assert client.get(path).status_code == 200, path
    assert sconn.total_changes == before


def test_a_degraded_store_answers_503(client):
    client.app.state.stats_conn = None
    assert client.get("/v1/stats/node-delay").status_code == 503
    assert client.get("/v1/stats/quota").status_code == 503


def test_the_reads_never_serve_the_provider_url_or_nodes(client, fake_client):
    """The sampler's real output, through both reads (the store-level leak
    scan is test_sampler's)."""
    import threading

    from app.collector.sampler import Sampler
    token = "https://sub.example.com/link/planted-subscription-token"
    fake_client.groups_doc = [{"name": "Auto", "now": "JP 01"}]
    fake_client.histories = {"JP 01": [{"time": "2026-10-16T11:00:00Z",
                                        "delay": 40}]}
    fake_client.providers_doc = {"my-airport": {
        "url": token, "testUrl": "https://probe.example.com/generate_204",
        "proxies": [{"name": "HK 99", "server": "192.0.2.81", "port": 443}],
        "subscriptionInfo": {"Upload": 1, "Download": 2, "Total": 3,
                             "Expire": 4}}}
    sampler = Sampler(client=fake_client, conn=client.app.state.stats_conn,
                      lock=threading.RLock())
    client.app.state.sampler = sampler
    sampler.run_due()
    bodies = [client.get("/v1/stats/quota").text,
              client.get("/v1/stats/node-delay?range=24h").text]
    for leak in ("planted-subscription-token", "sub.example.com",
                 "probe.example.com", "HK 99", "192.0.2.81"):
        assert all(leak not in body for body in bodies), leak
    assert '"state":"ok"' in bodies[0] and "JP 01" in bodies[1]


def test_the_quota_read_says_what_the_newest_sample_found(client, fake_client,
                                                         panel_env):
    import threading

    from app.collector.sampler import Sampler
    sampler = Sampler(client=fake_client, conn=client.app.state.stats_conn,
                      lock=threading.RLock())
    client.app.state.sampler = sampler
    state = lambda: client.get("/v1/stats/quota").json()["state"]  # noqa: E731
    assert state() == "pending"
    fake_client.providers_doc = {"p": {"subscriptionInfo": {"Upload": 1}}}
    sampler.sample_quota("2026-10-16T12:00:00Z")
    assert state() == "ok"
    fake_client.fail_samples = True
    sampler.sample_quota()
    body = client.get("/v1/stats/quota").json()
    # the last good list stands, said to be stale
    assert body["state"] == "error" and len(body["providers"]) == 1
    fake_client.fail_samples = False
    fake_client.providers_doc = {}
    sampler.sample_quota()
    assert state() == "none"
    fake_client.providers_doc = {"p": {"subscriptionInfo": {"Upload": 1}}}
    sampler.sample_quota()
    # a bare purge empties the store: not "ok" over an empty list
    r = client.post("/v1/stats/purge", headers=auth_headers(panel_env))
    assert r.status_code == 200
    body = client.get("/v1/stats/quota").json()
    assert body == {"providers": [], "state": "pending", "sampled_at": None}
    # and the quota is due again at once
    sampler.run_due()
    assert state() == "ok"


def test_a_delay_purge_keeps_mihomo_s_older_tests_out(client, fake_client,
                                                      panel_env, pinned_clock):
    import threading

    from app.collector.sampler import Sampler
    fake_client.groups_doc = [{"name": "Auto", "now": "JP 01"}]
    sampler = Sampler(client=fake_client, conn=client.app.state.stats_conn,
                      lock=threading.RLock())
    client.app.state.sampler = sampler
    r = client.post("/v1/stats/purge", json={"before": "2026-10-16T12"},
                    headers=auth_headers(panel_env))
    assert r.status_code == 200
    assert sampler._delay_floor == "2026-10-16T12:00:00Z"
    # a device scope does not touch the device-less history
    client.post("/v1/stats/purge", json={"device": "192.0.2.20"},
                headers=auth_headers(panel_env))
    assert sampler._delay_floor == "2026-10-16T12:00:00Z"
    client.post("/v1/stats/purge", headers=auth_headers(panel_env))
    assert sampler._delay_floor == "2026-10-16T12:00:00Z"   # NOW, pinned


def test_the_quota_read_rereads_when_a_sample_landed_meanwhile(client,
                                                               fake_client,
                                                               monkeypatch):
    import threading

    from app.collector.sampler import Sampler
    sampler = Sampler(client=fake_client, conn=client.app.state.stats_conn,
                      lock=threading.RLock())
    client.app.state.sampler = sampler
    fake_client.providers_doc = {"p": {"subscriptionInfo": {"Upload": 1}}}
    real = stats_store.read_quota
    calls = []

    def racing(conn):
        calls.append(1)
        out = real(conn)
        if len(calls) == 1:
            # a sample commits and publishes between the snapshot and here
            sampler.sample_quota("2026-10-16T12:00:00Z")
        return out
    monkeypatch.setattr(stats_store, "read_quota", racing)
    body = client.get("/v1/stats/quota").json()
    # the first, pre-sample list was not paired with the new "ok"
    assert len(calls) == 2
    assert body["state"] == "ok" and len(body["providers"]) == 1


def test_the_quota_read_serves_the_five_fields(client):
    stats_store.write_quota(client.app.state.stats_conn, {
        "my-airport": {"upload": 1, "download": 2, "total": None, "expire": None,
                       "updatedAt": "2026-10-16T10:00:00Z"}})
    body = client.get("/v1/stats/quota").json()
    assert body["providers"] == [{"provider": "my-airport", "upload": 1,
                                  "download": 2, "total": None, "expire": None,
                                  "updatedAt": "2026-10-16T10:00:00Z"}]
    assert json.dumps(body).count("http") == 0
