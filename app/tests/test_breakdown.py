"""GET /v1/stats/breakdown (#98): one dimension's values over a window,
sorted and paged, with where the dimension's data starts and what it never
recorded. Synthesised flows only (TEST-NET, example.com)."""

from datetime import UTC, datetime

import pytest
from app.api import routes
from app.store.stats import flush_poll
from app.tests.conftest import example_dictionary, geo_conn

A, B = "192.0.2.20", "192.0.2.21"
NOW = datetime(2026, 10, 15, 12, 30, tzinfo=UTC)
DICT = example_dictionary()


@pytest.fixture()
def pinned_clock(monkeypatch):
    monkeypatch.setattr(routes, "_utcnow", lambda: NOW)


def push(conn, frames, now="2026-10-15T12:00:00Z", domains=False):
    flush_poll(conn, frames, now, domains_enabled=domains, gap_threshold_s=6,
               interval_s=2, dictionary=DICT)


def seed(conn, domains=False):
    push(conn, [
        geo_conn("c1", A, 10, 100, chains=("JP 01", "Auto", "Routing Mode"),
                 rule="GeoSite", payload="example-video",
                 host="video.example.com", geo=["JP"]),
        geo_conn("c2", A, 50, 5, chains=("US 01", "Auto", "Routing Mode"),
                 rule="Match", host="unlisted.example.net", geo=["US"]),
        geo_conn("c3", B, 1, 1, chains=("DIRECT",), rule="GeoIP",
                 payload="CN", host="cdn.example.org"),
        geo_conn("c4", B, 0, 0, chains=("SG 01", "Idle")),  # moved nothing
    ], domains=domains)


def get(client, query, status=200):
    r = client.get(f"/v1/stats/breakdown?{query}")
    assert r.status_code == status, r.text
    return r.json()


def values(body):
    return [(r["value"], r["up"], r["down"]) for r in body["rows"]]


# --- every long-term dimension ----------------------------------------------------

def test_the_exit_breakdown_is_largest_first(client, pinned_clock):
    seed(client.app.state.stats_conn)
    body = get(client, "dim=exit&range=7d")
    assert values(body) == [("JP 01", 10, 100), ("US 01", 50, 5),
                            ("DIRECT", 1, 1)]
    assert body["total"] == {"up": 61, "down": 106}
    assert (body["tier"], body["total_rows"], body["range"]) == ("hour", 3,
                                                                 "7d")


def test_the_group_breakdown_reads_the_device_tier(client, pinned_clock):
    seed(client.app.state.stats_conn)
    body = get(client, "dim=group&range=48h")
    # a group whose only activity moved no bytes is not listed (DEC-E)
    assert values(body) == [("Routing Mode", 60, 105), ("DIRECT", 1, 1)]
    assert body["tier"] == "minute"
    assert "unrecorded" not in body


def test_rule_and_country_are_dimensions_too(client, pinned_clock):
    seed(client.app.state.stats_conn)
    assert {v for v, *_ in values(get(client, "dim=rule&range=7d"))} == {
        "GeoSite", "Match", "GeoIP"}
    assert values(get(client, "dim=country&range=7d")) == [
        ("JP", 10, 100), ("US", 50, 5), ("unknown", 1, 1)]


def test_category_rows_say_what_their_value_means(client, pinned_clock):
    conn = client.app.state.stats_conn
    seed(conn)
    # an older image's rows: counted without a dictionary
    flush_poll(conn, [geo_conn("c9", B, 7, 7, host="video.example.com")],
               "2026-10-15T12:00:02Z", domains_enabled=False,
               gap_threshold_s=6, interval_s=2, dictionary=None)
    rows = {r["value"]: r["class"] for r in get(
        client, "dim=category&range=7d")["rows"]}
    assert rows == {"video": "coarse", "unknown": "unattributed",
                    "cdn": "coarse", "": "no_dictionary"}


def test_a_dimension_has_no_minute_tier_so_48h_reads_hours(client,
                                                           pinned_clock):
    seed(client.app.state.stats_conn)
    body = get(client, "dim=country&range=48h")
    assert body["tier"] == "hour"
    assert body["total"] == {"up": 61, "down": 106}


def test_a_device_scopes_the_breakdown(client, pinned_clock):
    seed(client.app.state.stats_conn)
    assert values(get(client, f"dim=exit&range=7d&device={B}")) == [
        ("DIRECT", 1, 1)]


def test_a_minute_bound_on_an_hourly_dimension_keeps_its_hour(client):
    # a dimension has no minute tier: the bound is cut to the hour it falls in
    push(client.app.state.stats_conn,
         [geo_conn("c1", A, 10, 100, chains=("JP 01",))],
         now="2026-10-15T12:40:00Z")
    body = get(client, "dim=exit&tier=minute&since=2026-10-15T12:30"
                       "&until=2026-10-15T12:35")
    assert body["tier"] == "hour"
    assert body["total"] == {"up": 10, "down": 100}


def test_a_day_bound_on_an_hourly_class_keeps_the_whole_day(client,
                                                            pinned_clock,
                                                            monkeypatch):
    # the seven-day class holds hours: `until` names a day, so every hour of
    # that day is inside it
    monkeypatch.setenv("PANEL_STATS_DOMAINS", "true")
    seed(client.app.state.stats_conn, domains=True)
    body = get(client, "dim=host&tier=day&since=2026-10-15&until=2026-10-15")
    assert body["tier"] == "hour"
    assert body["total"] == {"up": 61, "down": 106}
    # the window block keeps one key format: hours
    assert body["window"]["since"] == "2026-10-15T00"


def test_an_unbounded_single_tier_read_is_truncated_before_the_dimension(
        client):
    conn = client.app.state.stats_conn
    seed(conn)
    conn.execute("INSERT INTO stats_hour (bucket, device, chain, up, down) "
                 "VALUES ('2026-10-12T08', ?, 'Routing Mode', 400, 4000)", (A,))
    conn.commit()
    body = get(client, "dim=exit&tier=hour")
    assert body["unrecorded"] == {"up": 400, "down": 4000}
    assert body["window"]["truncated"] is True


def test_a_single_tier_read_takes_since_and_until(client):
    seed(client.app.state.stats_conn)
    body = get(client, "dim=exit&tier=hour&since=2026-10-15T12"
                       "&until=2026-10-15T12")
    assert body["total"] == {"up": 61, "down": 106}
    assert values(get(client, "dim=exit&tier=hour&since=2026-10-15T13")) == []


# --- sort and paging ------------------------------------------------------------------

@pytest.mark.parametrize("sort, first", [("total", "JP 01"), ("up", "US 01"),
                                         ("down", "JP 01")])
def test_sort_orders_by_the_named_direction(client, pinned_clock, sort, first):
    seed(client.app.state.stats_conn)
    assert get(client, f"dim=exit&range=7d&sort={sort}")["rows"][0][
        "value"] == first


def test_limit_and_offset_page_through_the_whole_window(client, pinned_clock):
    seed(client.app.state.stats_conn)
    page = get(client, "dim=exit&range=7d&limit=1&offset=1")
    assert values(page) == [("US 01", 50, 5)]
    # totals stay the whole window's
    assert page["total_rows"] == 3 and page["total"] == {"up": 61,
                                                         "down": 106}


@pytest.mark.parametrize("asked, used", [(0, 1), (-5, 1), (500, 200)])
def test_the_limit_is_clamped(client, pinned_clock, asked, used):
    assert get(client, f"dim=exit&range=7d&limit={asked}")["limit"] == used


@pytest.mark.parametrize("query", ["dim=exit&offset=-1", "dim=nope",
                                   "dim=exit&sort=sideways",
                                   "dim=exit&range=7d&since=2026-10-01",
                                   "range=7d"])
def test_a_bad_query_is_refused(client, pinned_clock, query):
    get(client, query, status=422)


# --- what the dimension never recorded (DEC-D) -----------------------------------

def test_device_bytes_the_dimension_never_saw_are_unrecorded(client,
                                                             pinned_clock):
    conn = client.app.state.stats_conn
    seed(conn)
    # an hour the device tier holds but no dimension does (before v1.11)
    conn.execute("INSERT INTO stats_hour (bucket, device, chain, up, down) "
                 "VALUES ('2026-10-12T08', ?, 'Routing Mode', 400, 4000)", (A,))
    conn.commit()
    body = get(client, "dim=exit&range=7d")
    assert body["unrecorded"] == {"up": 400, "down": 4000}
    assert body["total"] == {"up": 61, "down": 106}
    assert body["window"] == {"oldest_bucket": "2026-10-15T12",
                              "truncated": True}


def test_a_window_the_dimension_covers_is_not_truncated(client, pinned_clock):
    conn = client.app.state.stats_conn
    seed(conn)
    # the dimension (and the device tier) hold data from before the window
    push(conn, [geo_conn("c5", A, 3, 3, chains=("JP 01",))],
         now="2026-10-13T00:00:00Z")
    body = get(client, "dim=exit&range=48h")
    assert body["unrecorded"] == {"up": 0, "down": 0}
    assert body["window"] == {"oldest_bucket": "2026-10-13T00",
                              "truncated": False}
    # like the coverage report: a window reaching before the oldest row held
    # is truncated, whatever the reason (a young store, too)
    assert get(client, "dim=exit&range=7d")["window"]["truncated"] is True


def test_unrecorded_follows_the_device_scope(client, pinned_clock):
    conn = client.app.state.stats_conn
    seed(conn)
    conn.execute("INSERT INTO stats_hour (bucket, device, chain, up, down) "
                 "VALUES ('2026-10-12T08', ?, 'Routing Mode', 400, 4000)", (A,))
    conn.commit()
    assert get(client, f"dim=exit&range=7d&device={B}")["unrecorded"] == {
        "up": 0, "down": 0}


# --- the seven-day class (host, app) -------------------------------------------------

@pytest.mark.parametrize("dim", ["host", "app"])
def test_the_class_answers_nothing_with_the_gate_off(client, pinned_clock,
                                                     monkeypatch, dim):
    seed(client.app.state.stats_conn, domains=True)  # rows ARE stored
    monkeypatch.setenv("PANEL_STATS_DOMAINS", "")
    body = get(client, f"dim={dim}&range=7d")
    assert body["enabled"] is False and body["rows"] == []
    assert body["total"] == {"up": 0, "down": 0}


def test_the_host_breakdown_with_the_gate_on(client, pinned_clock,
                                             monkeypatch):
    monkeypatch.setenv("PANEL_STATS_DOMAINS", "true")
    seed(client.app.state.stats_conn, domains=True)
    body = get(client, "dim=host&range=7d")
    assert body["enabled"] is True
    assert values(body) == [("video.example.com", 10, 100),
                            ("unlisted.example.net", 50, 5),
                            ("cdn.example.org", 1, 1)]
    assert "unrecorded" not in body


def test_the_app_breakdown_names_geosite_ids(client, pinned_clock,
                                            monkeypatch):
    monkeypatch.setenv("PANEL_STATS_DOMAINS", "true")
    seed(client.app.state.stats_conn, domains=True)
    assert values(get(client, "dim=app&range=7d")) == [
        ("example-video", 10, 100), ("example-cdn", 1, 1)]


def test_the_class_never_reaches_back_more_than_seven_days(client,
                                                           pinned_clock,
                                                           monkeypatch):
    """Enforced in the query, not by pruning: an older image after a
    rollback never prunes `stats_app`, so stale rows can still be stored."""
    monkeypatch.setenv("PANEL_STATS_DOMAINS", "true")
    conn = client.app.state.stats_conn
    seed(conn, domains=True)
    conn.execute("INSERT INTO stats_app (bucket, device, value, up, down) "
                 "VALUES ('2026-09-01T00', ?, 'example-video', 9, 9)", (A,))
    conn.execute("INSERT INTO stats_domain (bucket, device, domain, up, down) "
                 "VALUES ('2026-09-01T00', ?, 'old.example.com', 9, 9)", (A,))
    conn.commit()
    for dim in ("app", "host"):
        for query in (f"dim={dim}&range=daily", f"dim={dim}&range=30d",
                      f"dim={dim}&tier=hour"):
            body = get(client, query)
            assert body["total"]["up"] < 70, (query, body["total"])
            assert body["window"]["retention_days"] == 7
            assert body["window"]["since"] == "2026-10-08T12"
    assert get(client, "dim=app&range=daily")["window"]["truncated"] is True
    # the stale row below the floor is a leftover no read returns: it is
    # neither the oldest bucket nor a reason to call the window complete
    for query in ("dim=app&range=7d", "dim=app&range=48h"):
        window = get(client, query)["window"]
        assert window["oldest_bucket"] == "2026-10-15T12", query
    assert get(client, "dim=app&range=48h")["window"]["truncated"] is True
    assert get(client, "dim=app&range=48h")["window"]["since"] == \
        "2026-10-13T12"
