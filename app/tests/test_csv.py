"""`?format=csv` on the breakdown and the timeline (#98 DEC-B): a
`text/csv; charset=utf-8` attachment, header row first, no byte-order mark,
RFC 4180 quoting, and no cell a spreadsheet would run as a formula."""

import csv
import io
from datetime import UTC, datetime

import pytest
from app.api import csv_export, routes
from app.store.stats import flush_poll
from app.tests.conftest import example_dictionary, geo_conn

A, B = "192.0.2.20", "192.0.2.21"
NOW = datetime(2026, 10, 15, 12, 30, tzinfo=UTC)


@pytest.fixture()
def pinned_clock(monkeypatch):
    monkeypatch.setattr(routes, "_utcnow", lambda: NOW)


def push(conn, frames, domains=False):
    flush_poll(conn, frames, "2026-10-15T12:00:00Z", domains_enabled=domains,
               gap_threshold_s=6, interval_s=2,
               dictionary=example_dictionary())


def fetch(client, path):
    r = client.get(path)
    assert r.status_code == 200, r.text
    assert r.headers["content-type"] == "text/csv; charset=utf-8"
    assert r.headers["content-disposition"].startswith(
        'attachment; filename="stats-')
    assert not r.content.startswith(b"\xef\xbb\xbf")  # no BOM
    return list(csv.reader(io.StringIO(r.text)))


def test_a_breakdown_exports_its_page_and_the_unrecorded_row(client,
                                                             pinned_clock):
    conn = client.app.state.stats_conn
    push(conn, [geo_conn("c1", A, 10, 100, chains=("JP 01", "Auto")),
                geo_conn("c2", B, 1, 2, chains=("US, West", "Auto"))])
    conn.execute("INSERT INTO stats_hour (bucket, device, chain, up, down) "
                 "VALUES ('2026-10-12T08', ?, 'Auto', 7, 7)", (A,))
    conn.commit()
    rows = fetch(client, "/v1/stats/breakdown?dim=exit&range=7d&format=csv")
    assert rows == [["kind", "value", "up", "down"],
                    ["value", "JP 01", "10", "100"],
                    # a comma inside a value survives the quoting
                    ["value", "US, West", "1", "2"],
                    ["unrecorded", "", "7", "7"]]


def test_the_unrecorded_row_rides_the_first_page_only(client, pinned_clock):
    push(client.app.state.stats_conn,
         [geo_conn("c1", A, 10, 100, chains=("JP 01",)),
          geo_conn("c2", B, 1, 2, chains=("US 01",))])
    rows = fetch(client, "/v1/stats/breakdown?dim=exit&range=7d&limit=1"
                         "&offset=1&format=csv")
    assert [r[0] for r in rows] == ["kind", "value"]


def test_a_category_export_carries_the_class(client, pinned_clock):
    push(client.app.state.stats_conn,
         [geo_conn("c1", A, 10, 100, host="video.example.com"),
          geo_conn("c2", A, 1, 1)])
    rows = fetch(client,
                 "/v1/stats/breakdown?dim=category&range=7d&format=csv")
    assert rows[0] == ["kind", "value", "up", "down", "class"]
    assert ["value", "unknown", "1", "1", "unattributed"] in rows
    assert ["unrecorded", "", "0", "0", ""] in rows


def test_a_class_export_with_the_gate_off_is_the_header_alone(client,
                                                              pinned_clock):
    push(client.app.state.stats_conn,
         [geo_conn("c1", A, 10, 100, host="video.example.com")], domains=True)
    assert fetch(client, "/v1/stats/breakdown?dim=host&range=7d&format=csv"
                 ) == [["kind", "value", "up", "down"]]


def test_a_formula_in_a_host_name_is_written_as_text(client, pinned_clock,
                                                     monkeypatch):
    monkeypatch.setenv("PANEL_STATS_DOMAINS", "true")
    push(client.app.state.stats_conn,
         [geo_conn("c1", A, 1, 1, host="=HYPERLINK(1)"),
          geo_conn("c2", A, 2, 2, host="+cmd.example.com"),
          geo_conn("c3", A, 3, 3, host="-x.example.com"),
          geo_conn("c4", A, 4, 4, host="@sum.example.com")], domains=True)
    rows = fetch(client, "/v1/stats/breakdown?dim=host&range=7d&format=csv")
    assert {r[1] for r in rows[1:]} == {
        "'=HYPERLINK(1)", "'+cmd.example.com", "'-x.example.com",
        "'@sum.example.com"}


@pytest.mark.parametrize("raw, written", [
    ("=1+1", "'=1+1"), ("\tx", "'\tx"), ("\rx", "'\rx"),
    ("ok.example.com", "ok.example.com"), (5, 5), ("", "")])
def test_the_cell_rule(raw, written):
    assert csv_export.cell(raw) == written


def test_a_minute_timeline_exports_bucket_up_down(client):
    push(client.app.state.stats_conn, [geo_conn("c1", A, 10, 100)])
    assert fetch(client, "/v1/stats/timeline?tier=minute&format=csv") == [
        ["bucket", "up", "down"], ["2026-10-15T12:00", "10", "100"]]


def test_a_day_timeline_exports_its_framing(client, pinned_clock):
    push(client.app.state.stats_conn, [geo_conn("c1", A, 10, 100)])
    rows = fetch(client, "/v1/stats/timeline?range=daily&format=csv")
    day = client.get("/v1/stats/timeline?range=daily").json()["rows"][0]
    assert rows == [["bucket", "up", "down", "bucket_tz", "day_boundary"],
                    [day["bucket"], "10", "100", day["bucket_tz"],
                     day["day_boundary"]]]


def test_json_stays_the_default(client):
    push(client.app.state.stats_conn, [geo_conn("c1", A, 10, 100)])
    r = client.get("/v1/stats/timeline?tier=minute")
    assert r.headers["content-type"].startswith("application/json")
    assert r.json()["rows"] == [{"bucket": "2026-10-15T12:00", "up": 10,
                                 "down": 100}]
