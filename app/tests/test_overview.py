"""GET /v1/stats/overview (#98 DEC-A): the landing page from ONE read
transaction, scoped to a device, a category or a host, with every section
the stored tables cannot answer `null` and explained. Synthesised flows only
(TEST-NET, example.com)."""

from datetime import UTC, datetime

import pytest
from app.api import routes
from app.store.stats import flush_poll
from app.store.stats import overview as overview_mod
from app.tests.conftest import example_dictionary, geo_conn

A, B = "192.0.2.20", "192.0.2.21"
NOW = datetime(2026, 10, 15, 12, 30, tzinfo=UTC)


@pytest.fixture()
def pinned_clock(monkeypatch):
    monkeypatch.setattr(routes, "_utcnow", lambda: NOW)


def push(conn, frames, now="2026-10-15T12:00:00Z", domains=False):
    flush_poll(conn, frames, now, domains_enabled=domains, gap_threshold_s=6,
               interval_s=2, dictionary=example_dictionary())


def seed(conn, domains=False):
    push(conn, [geo_conn("c1", A, 10, 100, chains=("JP 01", "Auto"),
                         host="video.example.com", geo=["JP"]),
                geo_conn("c2", B, 1, 2, chains=("US 01", "Auto"),
                         host="cdn.example.org", geo=["US"])],
         domains=domains)


def overview(client, query="", status=200):
    r = client.get(f"/v1/stats/overview?{query}")
    assert r.status_code == status, r.text
    return r.json()


def test_the_overview_shape(client, pinned_clock):
    seed(client.app.state.stats_conn)
    body = overview(client, "range=7d")
    assert set(body) == {"range", "scope", "totals", "timeline", "top",
                         "unavailable", "gaps", "gaps_truncated", "coverage",
                         "invisible_traffic_hint"}
    assert body["gaps_truncated"] is False
    assert body["range"] == "7d"
    assert body["totals"] == {"tier": "hour", "up": 11, "down": 102}
    assert body["timeline"]["rows"] == [{"bucket": "2026-10-15T12", "up": 11,
                                         "down": 102}]
    assert set(body["top"]) == {"device", "exit", "category", "country",
                                "host"}
    assert [r["value"] for r in body["top"]["device"]["rows"]] == [A, B]
    assert [r["value"] for r in body["top"]["exit"]["rows"]] == ["JP 01",
                                                                 "US 01"]
    assert [r["value"] for r in body["top"]["category"]["rows"]] == [
        "video", "cdn"]
    assert body["top"]["host"]["enabled"] is False
    assert body["unavailable"] == {}
    assert body["invisible_traffic_hint"]["code"] == "gateway_only"
    assert {c["klass"] for c in body["coverage"]["classes"]} == {
        "hostname", "ip_only"}


def test_the_default_range_is_the_settings_default(client, pinned_clock):
    assert overview(client)["range"] == "7d"


def test_the_24h_preset_reads_the_last_day_at_minute_resolution(
        client, pinned_clock):
    """#101: `24h` is the 48h read over one day - minute resolution, and
    nothing from before the day it covers."""
    conn = client.app.state.stats_conn
    push(conn, [geo_conn("old", A, 5, 50, chains=("JP 01", "Auto"),
                         host="video.example.com", geo=["JP"])],
         now="2026-10-14T10:00:00Z")
    push(conn, [geo_conn("new", B, 1, 2, chains=("US 01", "Auto"),
                         host="cdn.example.org", geo=["US"])])
    day = overview(client, "range=24h")
    assert day["range"] == "24h"
    assert day["totals"] == {"tier": "minute", "up": 1, "down": 2}
    assert overview(client, "range=48h")["totals"]["up"] == 6


def test_a_day_window_carries_its_framings(client, pinned_clock):
    seed(client.app.state.stats_conn)
    body = overview(client, "range=daily")
    assert body["totals"]["tier"] == "day"
    assert len(body["framings"]) == 1


def test_the_top_lists_are_limited(client, pinned_clock):
    seed(client.app.state.stats_conn)
    body = overview(client, "range=7d&limit=1")
    assert [r["value"] for r in body["top"]["device"]["rows"]] == [A]
    assert body["top"]["device"]["total_rows"] == 2


def test_gaps_are_scoped_to_the_window(client, pinned_clock):
    conn = client.app.state.stats_conn
    conn.execute("INSERT INTO stats_gap (started, ended, reason) VALUES "
                 "('2026-09-01T00:00:00Z', '2026-09-01T01:00:00Z', 'old'), "
                 "('2026-10-15T10:00:00Z', '2026-10-15T10:05:00Z', 'new')")
    conn.commit()
    assert [g["reason"] for g in overview(client, "range=48h")["gaps"]] == [
        "new"]


def test_the_overview_is_one_consistent_snapshot(client, pinned_clock,
                                                 monkeypatch):
    """A write that lands between two of the overview's reads is not seen
    by the later one: every section describes the same moment."""
    conn = client.app.state.stats_conn
    seed(conn)
    real = overview_mod.read_breakdown
    wrote = []

    def write_then_read(*args, **kwargs):
        if not wrote:
            push(conn, [geo_conn("c1", A, 510, 1100, chains=("JP 01",
                                                             "Auto"))],
                 now="2026-10-15T12:00:02Z")
            wrote.append(True)
        return real(*args, **kwargs)
    monkeypatch.setattr(overview_mod, "read_breakdown", write_then_read)
    body = overview(client, "range=7d")
    assert wrote
    assert body["totals"]["up"] == 11
    assert body["top"]["device"]["total"] == {"up": 11, "down": 102}
    assert body["top"]["exit"]["total"] == {"up": 11, "down": 102}
    # the write did land; the next overview sees it
    assert overview(client, "range=7d")["totals"]["up"] == 511


# --- scopes ----------------------------------------------------------------------

def test_a_device_scope(client, pinned_clock):
    seed(client.app.state.stats_conn)
    body = overview(client, f"range=7d&device={B}")
    assert body["totals"] == {"tier": "hour", "up": 1, "down": 2}
    assert body["top"]["device"] is None
    assert body["unavailable"]["top.device"] == "scoped to one device"
    # coverage is gateway-wide only: never shown as if it were the device's
    assert body["coverage"] is None and body["unavailable"]["coverage"]
    assert [r["value"] for r in body["top"]["exit"]["rows"]] == ["US 01"]


def test_a_category_scope_answers_what_the_tables_hold(client, pinned_clock):
    seed(client.app.state.stats_conn)
    body = overview(client, "range=7d&category=video")
    totals = dict(body["totals"])
    window = totals.pop("window")
    assert totals == {"tier": "hour", "up": 10, "down": 100}
    assert window["oldest_bucket"] == "2026-10-15T12"
    device_list = body["top"]["device"]
    assert [r["value"] for r in device_list["rows"]] == [A]
    # the list is devices, behind one category
    assert device_list["dim"] == "device"
    assert device_list["within"] == {"dim": "category", "value": "video"}
    # no exit x category table: unknown, never zero
    for dim in ("exit", "country", "host", "category"):
        assert body["top"][dim] is None, dim
        assert body["unavailable"][f"top.{dim}"], dim


def test_an_empty_category_is_the_bytes_counted_without_a_dictionary(
        client, pinned_clock):
    conn = client.app.state.stats_conn
    flush_poll(conn, [geo_conn("c1", A, 4, 4)], "2026-10-15T12:00:00Z",
               domains_enabled=False, gap_threshold_s=6, interval_s=2,
               dictionary=None)
    assert overview(client, "range=7d&category=")["totals"]["up"] == 4


def test_a_host_scope_needs_the_gate(client, pinned_clock, monkeypatch):
    seed(client.app.state.stats_conn, domains=True)
    body = overview(client, "range=7d&host=video.example.com")
    assert body["totals"] is None and body["timeline"] is None
    assert "PANEL_STATS_DOMAINS" in body["unavailable"]["totals"]
    monkeypatch.setenv("PANEL_STATS_DOMAINS", "true")
    body = overview(client, "range=30d&host=video.example.com")
    assert (body["totals"]["up"], body["totals"]["down"]) == (10, 100)
    # a 30-day header over at most seven days of host data says so
    assert body["totals"]["window"]["retention_days"] == 7
    assert body["totals"]["window"]["truncated"] is True
    assert [r["value"] for r in body["top"]["device"]["rows"]] == [A]
    assert body["top"]["exit"] is None
    with_device = overview(client, f"range=30d&host=video.example.com"
                                   f"&device={A}")
    assert with_device["top"]["device"] is None
    assert with_device["totals"]["window"]["since"] == "2026-10-08T12"


def test_a_category_and_a_host_together_are_refused(client, pinned_clock):
    overview(client, "category=video&host=video.example.com", status=422)


def test_an_undeclared_tier_does_not_change_the_read(client, pinned_clock):
    seed(client.app.state.stats_conn)
    body = overview(client, "range=daily&tier=hour")
    assert body["totals"]["tier"] == "day" and "framings" in body


def test_a_gap_ending_inside_the_first_bucket_is_listed(client, pinned_clock):
    # the 48h window starts at 2026-10-13T12:30 - inside the minute bucket
    # 12:30 - and the 7d one inside the hour 2026-10-08T12
    conn = client.app.state.stats_conn
    conn.execute("INSERT INTO stats_gap (started, ended, reason) VALUES "
                 "('2026-10-08T11:00:00Z', '2026-10-08T12:10:00Z', 'h'), "
                 "('2026-10-13T12:00:00Z', '2026-10-13T12:30:20Z', 'm')")
    conn.commit()
    assert {g["reason"] for g in overview(client, "range=7d")["gaps"]} == {
        "h", "m"}
    assert [g["reason"] for g in overview(client, "range=48h")["gaps"]] == [
        "m"]


def test_a_scoped_48h_overview_bounds_its_gaps_on_the_hour(client,
                                                           pinned_clock):
    # a category timeline is hourly: its first bucket starts at 12:00, so a
    # gap ending at 12:10 is a hole in what it shows
    conn = client.app.state.stats_conn
    push(conn, [geo_conn("c1", A, 4, 4, host="video.example.com")],
         now="2026-10-13T12:05:00Z")
    conn.execute("INSERT INTO stats_gap (started, ended, reason) VALUES "
                 "('2026-10-13T11:50:00Z', '2026-10-13T12:10:00Z', 'g')")
    conn.commit()
    body = overview(client, "range=48h&category=video")
    assert body["timeline"]["tier"] == "hour"
    assert [g["reason"] for g in body["gaps"]] == ["g"]
    # unscoped, the 48h timeline is per minute: that gap ended before it
    assert overview(client, "range=48h")["gaps"] == []


def test_a_category_with_no_rows_is_not_a_complete_window(client,
                                                          pinned_clock):
    conn = client.app.state.stats_conn
    conn.execute("INSERT INTO stats_hour (bucket, device, chain, up, down) "
                 "VALUES ('2026-10-12T08', ?, 'Routing Mode', 400, 4000)", (A,))
    conn.commit()
    body = overview(client, "range=7d&category=video")
    assert (body["totals"]["up"], body["totals"]["down"]) == (0, 0)
    # the zero is a hole the dimension never recorded, not "no traffic"
    assert body["totals"]["window"]["truncated"] is True


def test_more_gaps_than_the_list_holds_are_flagged(client, pinned_clock):
    conn = client.app.state.stats_conn
    conn.executemany(
        "INSERT INTO stats_gap (started, ended, reason) VALUES (?, ?, 'x')",
        [(f"2026-10-15T0{i % 10}:00:00Z", f"2026-10-15T0{i % 10}:01:00Z")
         for i in range(120)])
    conn.commit()
    body = overview(client, "range=48h")
    assert len(body["gaps"]) == 100 and body["gaps_truncated"] is True
    conn.execute("DELETE FROM stats_gap WHERE id > 100")
    conn.commit()
    body = overview(client, "range=48h")
    # exactly the list's size: nothing more exists
    assert len(body["gaps"]) == 100 and body["gaps_truncated"] is False


def test_since_beside_the_range_is_refused(client, pinned_clock):
    overview(client, "range=7d&since=2026-10-01", status=422)


def test_the_gaps_read_takes_a_window_and_keeps_its_bare_form(client):
    conn = client.app.state.stats_conn
    conn.execute("INSERT INTO stats_gap (started, ended, reason) VALUES "
                 "('2026-09-01T00:00:00Z', '2026-09-01T01:00:00Z', 'a'), "
                 "('2026-10-14T23:50:00Z', '2026-10-15T00:10:00Z', 'b'), "
                 "('2026-10-15T10:00:00Z', '2026-10-15T10:05:00Z', 'c')")
    conn.commit()

    def reasons(query):
        r = client.get(f"/v1/stats/gaps?{query}")
        assert r.status_code == 200, r.text
        return [g["reason"] for g in r.json()["rows"]]
    assert reasons("") == ["c", "b", "a"]
    # overlapping the window counts: b ended inside it
    assert reasons("since=2026-10-15") == ["c", "b"]
    assert reasons("since=2026-10-15&until=2026-10-15T05") == ["b"]
    assert reasons("until=2026-09-30") == ["a"]
    # a short until names its whole bucket, like since
    assert reasons("since=2026-10-15T10&until=2026-10-15T10") == ["c"]
    assert reasons("until=2026-10-15") == ["c", "b", "a"]
    assert reasons("since=2026-10-15&limit=1") == ["c"]
