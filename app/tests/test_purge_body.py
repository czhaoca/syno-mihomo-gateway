"""The purge gains an optional scope (#95): `{device?, tables?, before?}`.

The bare call keeps its exact meaning - every visible stats table, every
row - and so does an empty body. A scope narrows it:
  device  only that device's rows (the gap history has no device and stays)
  tables  only those tables (names from PURGE_TABLES; anything else is 422)
  before  only rows whose bucket STARTS before that UTC moment, given in
          the bucket vocabulary (`YYYY-MM-DD`, `...THH`, `...THH:MM`); a
          bucket that straddles it goes, so nothing older survives
Accounting state (baselines, the poll stamp) survives every form, and the
policy audit records each purge with its scope.
"""

from typing import get_args

import pytest
from app.api import routes
from app.store import stats as stats_store
from app.tests.conftest import auth_headers

A, B = "192.0.2.20", "192.0.2.21"


@pytest.fixture()
def sconn(panel_env):
    conn = stats_store.open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


def _put(conn, table, bucket, device=A):
    col = {"stats_minute_v5": "chain", "stats_hour": "chain",
           "stats_day": "chain", "stats_domain": "domain"}.get(table, "value")
    conn.execute(f"INSERT INTO {table} (bucket, device, {col}, up, down) "
                 f"VALUES (?, ?, 'x', 1, 1)", (bucket, device))


def _seed(conn):
    for device in (A, B):
        _put(conn, "stats_minute_v5", "2026-07-23T07:59", device)
        _put(conn, "stats_minute_v5", "2026-07-23T08:00", device)
        _put(conn, "stats_hour", "2026-07-23T07", device)
        _put(conn, "stats_hour", "2026-07-23T08", device)
        _put(conn, "stats_day", "2026-07-22", device)
        _put(conn, "stats_day", "2026-07-23", device)
        _put(conn, "stats_exit_hour", "2026-07-23T08", device)
        _put(conn, "stats_domain", "2026-07-23T08", device)
    conn.execute("INSERT INTO stats_gap (started, ended, reason) VALUES "
                 "('2026-07-23T06:00:00Z', '2026-07-23T06:05:00Z', 'test')")
    conn.execute("INSERT INTO conn_baseline (conn_id, up, down, last_seen) "
                 "VALUES ('c1', 1, 1, '2026-07-23T08:00:00Z')")
    conn.execute("INSERT INTO stats_meta (k, v) VALUES "
                 "('last_poll_ts', '2026-07-23T08:00:00Z')")


def _left(conn, table, device=None):
    clause, params = (" WHERE device = ?", (device,)) if device else ("", ())
    column = {"stats_gap": "started", "stats_node_delay": "tested_at"}.get(
        table, "bucket")
    return sorted(r[0] for r in conn.execute(
        f"SELECT {column} FROM {table}{clause}", params))


def _purge(client, panel_env, body=None):
    kwargs = {"headers": auth_headers(panel_env)}
    if body is not None:
        kwargs["json"] = body
    return client.post("/v1/stats/purge", **kwargs)


def test_the_contract_names_exactly_the_purgeable_tables():
    # the body's enum is what the published contract lists
    assert get_args(routes.PurgeTable) == stats_store.PURGE_TABLES


@pytest.mark.parametrize("body", [None, {}])
def test_the_bare_call_and_an_empty_body_clear_everything(client, panel_env,
                                                          sconn, body):
    _seed(sconn)
    r = _purge(client, panel_env, body)
    assert r.status_code == 200, r.text
    assert r.json()["purged"] is True
    for table in stats_store.PURGE_TABLES:
        assert _left(sconn, table) == [], table
    assert sconn.execute("SELECT COUNT(*) FROM conn_baseline").fetchone()[0] == 1
    assert stats_store.meta_get(sconn, "last_poll_ts") is not None


def test_the_response_counts_rows_per_table(client, panel_env, sconn):
    _seed(sconn)
    rows = _purge(client, panel_env, {"tables": ["stats_hour"]}).json()["rows"]
    assert rows == {"stats_hour": 4}


def test_a_device_scope_leaves_every_other_device(client, panel_env, sconn):
    _seed(sconn)
    assert _purge(client, panel_env, {"device": A}).status_code == 200
    for table in ("stats_minute_v5", "stats_hour", "stats_day",
                  "stats_exit_hour", "stats_domain"):
        assert _left(sconn, table, A) == [], table
        assert _left(sconn, table, B) != [], table
    # the gap history belongs to no device
    assert _left(sconn, "stats_gap") == ["2026-07-23T06:00:00Z"]


def test_a_table_scope_clears_only_those_tables(client, panel_env, sconn):
    _seed(sconn)
    r = _purge(client, panel_env, {"tables": ["stats_domain", "stats_gap"]})
    assert r.status_code == 200, r.text
    assert _left(sconn, "stats_domain") == []
    assert _left(sconn, "stats_gap") == []
    assert len(_left(sconn, "stats_hour")) == 4


@pytest.mark.parametrize("before, minute, hour, day, gap", [
    # aligned: an hour bucket starting AT the moment is not before it
    ("2026-07-23T08", ["2026-07-23T08:00"], ["2026-07-23T08"], [], []),
    ("2026-07-23T08:00", ["2026-07-23T08:00"], ["2026-07-23T08"], [], []),
    # straddled: the 08 hour started before 08:30, so it goes
    ("2026-07-23T08:30", [], [], [], []),
    # a date: the day starting at it stays, every finer bucket of it stays
    ("2026-07-23", ["2026-07-23T07:59", "2026-07-23T08:00"],
     ["2026-07-23T07", "2026-07-23T08"], ["2026-07-23"],
     ["2026-07-23T06:00:00Z"]),
])
def test_a_before_scope_removes_buckets_that_start_before_it(
        client, panel_env, sconn, before, minute, hour, day, gap):
    _seed(sconn)
    r = _purge(client, panel_env, {"before": before})
    assert r.status_code == 200, r.text
    assert _left(sconn, "stats_minute_v5", A) == minute
    assert _left(sconn, "stats_hour", A) == hour
    assert _left(sconn, "stats_day", A) == day
    assert _left(sconn, "stats_gap") == gap


def test_scopes_combine(client, panel_env, sconn):
    _seed(sconn)
    r = _purge(client, panel_env, {"device": B, "tables": ["stats_minute_v5"],
                                   "before": "2026-07-23T08"})
    assert r.status_code == 200, r.text
    assert r.json()["rows"] == {"stats_minute_v5": 1}
    assert _left(sconn, "stats_minute_v5", B) == ["2026-07-23T08:00"]
    assert len(_left(sconn, "stats_minute_v5", A)) == 2
    assert len(_left(sconn, "stats_hour")) == 4


@pytest.mark.parametrize("body", [
    {"tables": ["conn_baseline"]},
    {"tables": ["stats_meta"]},
    {"tables": ["stats_nope"]},
    {"tables": []},
    {"before": "2026-07-23T08:00:00Z"},
    {"before": "yesterday"},
    {"before": "2026-13-45"},
    {"device": ""},
    {"surprise": True},
])
def test_a_malformed_scope_is_refused_and_purges_nothing(client, panel_env,
                                                         sconn, body):
    _seed(sconn)
    r = _purge(client, panel_env, body)
    assert r.status_code == 422, (body, r.text)
    assert len(_left(sconn, "stats_hour")) == 4


def test_a_scoped_purge_is_still_token_gated(client, panel_env, sconn):
    _seed(sconn)
    r = client.post("/v1/stats/purge", json={"device": A})
    assert r.status_code == 403
    assert len(_left(sconn, "stats_hour", A)) == 2


def test_the_audit_records_the_scope(client, panel_env, sconn):
    _seed(sconn)
    _purge(client, panel_env, {"device": A, "before": "2026-07-23"})
    _purge(client, panel_env)
    entries = [e for e in client.get("/v1/audit").json()["entries"]
               if e["action"] == "stats-purge"]
    details = sorted(e["details"] for e in entries)
    assert details == ["", f"before=2026-07-23 device={A}"]
