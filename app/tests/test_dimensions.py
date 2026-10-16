"""The star schema's write path (#95, brief DEC-4).

Every poll now writes, beside the minute tier:
  - the HOUR tier, complete at ingest (same facts as the minute rows), so
    minute -> hour is retention only and an hour read needs no union;
  - one long-term table per dimension on the hour tier - exit node
    (`chains[0]`), rule type, category, destination country - each keyed
    (bucket, device, value), bytes only (DEC-D). The policy GROUP is the
    tier tables' existing `chain` column (`chains[-1]`);
  - behind the unchanged PANEL_STATS_DOMAINS gate, the seven-day class
    tables for sniffHost, ASN and destination port (hostname already has
    `stats_domain`).
Each long-term dimension partitions the device tier's bytes exactly: every
byte lands under exactly one value, and a value nobody could determine is
written as such ("unknown" country; "unknown" category when the dictionary
has no answer, "" when no dictionary ran - #97) - never dropped, so a
dimension total always equals the device total.

All frames are synthesised (TEST-NET, example.com, RFC 5398 ASNs).
"""

import pytest
from app.store import dayframe
from app.store import stats as stats_store
from app.store.stats import flush_poll, open_stats_db, rollup
from app.tests.conftest import example_dictionary, geo_conn

NOW = "2026-10-15T12:00:00Z"
A, B = "192.0.2.20", "192.0.2.21"
_UTC = dayframe.utc_frame()


@pytest.fixture()
def sconn(panel_env):
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


DICT = example_dictionary()


def push(conn, frames, now=NOW, domains=False, interval=2, dictionary=DICT):
    flush_poll(conn, frames, now, domains_enabled=domains,
               gap_threshold_s=3 * interval, interval_s=interval,
               dictionary=dictionary)


def values(conn, table):
    return {(r["device"], r["value"]): (r["up"], r["down"]) for r in conn.execute(
        f"SELECT device, value, SUM(up) AS up, SUM(down) AS down FROM {table} "
        f"GROUP BY device, value")}


def total(conn, table):
    return tuple(conn.execute(
        f"SELECT COALESCE(SUM(up), 0), COALESCE(SUM(down), 0) FROM {table}"
    ).fetchone())


# --- the dimensions ----------------------------------------------------------

def test_the_exit_is_the_first_chain_and_the_group_the_last(sconn):
    push(sconn, [geo_conn("c1", A, 10, 100,
                          chains=("JP 01", "Japan Auto", "Routing Mode")),
                 geo_conn("c2", A, 1, 1, chains=())])
    assert values(sconn, "stats_exit_hour") == {(A, "JP 01"): (10, 100),
                                                (A, "DIRECT"): (1, 1)}
    groups = {r["chain"]: r["up"] for r in sconn.execute(
        "SELECT chain, up FROM stats_hour")}
    assert groups == {"Routing Mode": 10, "DIRECT": 1}


def test_the_rule_type_is_a_dimension_of_its_own(sconn):
    push(sconn, [geo_conn("c1", A, 10, 0, rule="GeoSite", payload="cn"),
                 geo_conn("c2", A, 5, 0, rule="DomainSuffix",
                          payload="example.com"),
                 geo_conn("c3", B, 1, 0, rule="Match")])
    assert values(sconn, "stats_rule_hour") == {
        (A, "GeoSite"): (10, 0), (A, "DomainSuffix"): (5, 0),
        (B, "Match"): (1, 0)}


@pytest.mark.parametrize("rule, payload, kept", [
    ("GeoSite", "category-example", True),
    ("GeoIP", "ZZ", True),
    ("RuleSet", "dyn-full-proxy", True),
    ("Match", "", True),
    ("SrcIPCIDR", "192.0.2.0/24", True),
    ("Domain", "airport.example.com", False),
    ("DomainSuffix", "example.com", False),
    ("DomainKeyword", "example", False),
    # fail closed: a type outside the allowlist - including one a future
    # mihomo adds - never persists its payload
    ("IPCIDR", "198.51.100.0/24", False),
    ("ProcessName", "example-app", False),
    ("SomeFutureType", "anything.example.com", False),
])
def test_a_rule_payload_is_kept_only_for_category_bearing_types(sconn, rule,
                                                              payload, kept):
    push(sconn, [geo_conn("c1", A, 10, 10, rule=rule, payload=payload)])
    [row] = sconn.execute("SELECT rule, rule_payload FROM stats_coverage")
    assert row["rule"] == rule
    assert row["rule_payload"] == (payload if kept else "")


@pytest.mark.parametrize("geo, country", [
    (["US"], "US"),
    (["jp"], "JP"),           # one spelling across mihomo versions
    (["DE", "EXTRA"], "DE"),  # the first match names the country
    ("NL", "NL"),             # tolerated: a bare string
    ([], "unknown"),
    ([""], "unknown"),
    (None, "unknown"),
])
def test_the_country_is_read_when_present(sconn, geo, country):
    push(sconn, [geo_conn("c1", A, 3, 4, geo=geo)])
    assert values(sconn, "stats_country_hour") == {(A, country): (3, 4)}


def test_an_absent_geo_field_is_unknown_not_dropped(sconn):
    # the measured baseline: v1.19.32 sends no dstGeoIP at all (DEC-A)
    push(sconn, [geo_conn("c1", A, 3, 4)])
    assert values(sconn, "stats_country_hour") == {(A, "unknown"): (3, 4)}


def test_the_geo_field_is_probed_on_every_snapshot(sconn):
    # the image is `:latest`: a field can appear between two polls
    push(sconn, [geo_conn("c1", A, 1, 1)], now="2026-10-15T12:00:00Z")
    push(sconn, [geo_conn("c1", A, 1, 1), geo_conn("c2", A, 2, 2, geo=["SG"])],
         now="2026-10-15T12:00:02Z")
    assert values(sconn, "stats_country_hour") == {(A, "unknown"): (1, 1),
                                                   (A, "SG"): (2, 2)}


def test_the_category_is_the_coarse_id_of_the_hostname(sconn):
    push(sconn, [geo_conn("c1", A, 10, 100, host="video.example.com"),
                 geo_conn("c2", A, 1, 2, host="edge.example.com"),
                 geo_conn("c3", B, 3, 4, sniff="cdn.example.org")])
    assert values(sconn, "stats_category_hour") == {
        (A, "video"): (10, 100), (A, "platform"): (1, 2), (B, "cdn"): (3, 4)}


def test_a_flow_the_dictionary_cannot_name_is_unattributed(sconn):
    # #97 DEC-E: "unknown" - looked, no answer - for an IP-only flow and for
    # an unknown hostname alike; "" stays reserved for "no dictionary ran"
    push(sconn, [geo_conn("c1", A, 10, 100),
                 geo_conn("c2", B, 1, 2, host="unlisted.example.net")])
    assert values(sconn, "stats_category_hour") == {(A, "unknown"): (10, 100),
                                                    (B, "unknown"): (1, 2)}


def test_a_routing_match_alone_never_classifies(sconn):
    # panel-ui-v2 DEC-C: a GeoSite payload names a routing list, not an app
    push(sconn, [geo_conn("c1", A, 10, 100, rule="GeoSite",
                          payload="example-video")])
    assert values(sconn, "stats_category_hour") == {(A, "unknown"): (10, 100)}


def test_the_sniffed_name_classifies_when_the_host_does_not(sconn):
    push(sconn, [geo_conn("c1", A, 10, 100, host="unlisted.example.net",
                          sniff="video.example.com")])
    assert values(sconn, "stats_category_hour") == {(A, "video"): (10, 100)}


def test_without_a_dictionary_every_byte_is_no_dictionary(sconn):
    # what an older image writes too: the "before the dictionary" segment
    push(sconn, [geo_conn("c1", A, 10, 100, host="video.example.com")],
         dictionary=None)
    assert values(sconn, "stats_category_hour") == {(A, ""): (10, 100)}


def test_the_shipped_dictionary_is_the_default(sconn, monkeypatch):
    from app.store import categories
    monkeypatch.setattr(categories, "_ACTIVE", {"dictionary": DICT,
                                                "error": None})
    flush_poll(sconn, [geo_conn("c1", A, 10, 100, host="video.example.com")],
               NOW, domains_enabled=False, gap_threshold_s=6, interval_s=2)
    assert values(sconn, "stats_category_hour") == {(A, "video"): (10, 100)}


def test_an_unloadable_dictionary_counts_without_one(sconn, monkeypatch):
    from app.store import categories
    monkeypatch.setattr(categories, "_ACTIVE", {"dictionary": None,
                                                "error": "broken"})
    flush_poll(sconn, [geo_conn("c1", A, 10, 100, host="video.example.com")],
               NOW, domains_enabled=True, gap_threshold_s=6, interval_s=2)
    assert values(sconn, "stats_category_hour") == {(A, ""): (10, 100)}
    assert values(sconn, "stats_app") == {}


def test_app_ids_ride_only_the_gated_seven_day_table(sconn):
    frames = [geo_conn("c1", A, 10, 100, host="video.example.com"),
              geo_conn("c2", A, 1, 2, host="unlisted.example.net")]
    push(sconn, frames)
    assert values(sconn, "stats_app") == {}
    moved = [dict(f, upload=f["upload"] * 2, download=f["download"] * 2)
             for f in frames]
    push(sconn, moved, now="2026-10-15T12:00:02Z", domains=True)
    # only the classified flow, and only its delta since the gate opened
    assert values(sconn, "stats_app") == {(A, "example-video"): (10, 100)}
    long_term = {r["value"] for r in sconn.execute(
        "SELECT value FROM stats_category_hour UNION "
        "SELECT value FROM stats_category_day")}
    assert "example-video" not in long_term


def test_every_long_term_dimension_partitions_the_device_bytes(sconn):
    frames = [geo_conn("c1", A, 10, 100, geo=["US"], rule="GeoIP",
                       payload="US", chains=("US 01", "Auto", "Routing Mode")),
              geo_conn("c2", A, 7, 70, rule="DomainSuffix",
                       payload="example.com"),
              geo_conn("c3", B, 3, 30, chains=()),
              geo_conn("c4", "", 1, 1, kind="Inner")]
    push(sconn, frames, now="2026-10-15T12:00:00Z")
    moved = [dict(f, upload=f["upload"] * 2, download=f["download"] * 3)
             for f in frames]
    push(sconn, moved, now="2026-10-15T12:00:02Z")
    device_total = total(sconn, "stats_hour")
    assert device_total == total(sconn, "stats_minute_v5") == (42, 603)
    for dim in stats_store.DIMENSIONS:
        assert total(sconn, f"stats_{dim}_hour") == device_total, dim


# --- the hour tier at ingest -------------------------------------------------

def test_the_hour_tier_is_written_at_ingest_with_the_minute_facts(sconn):
    push(sconn, [], now="2026-10-15T11:59:58Z")
    push(sconn, [geo_conn("c1", A, 100, 1000)], now="2026-10-15T12:00:00Z")
    push(sconn, [geo_conn("c1", A, 150, 1200), geo_conn("c2", A, 5, 5)],
         now="2026-10-15T12:00:02Z")
    push(sconn, [geo_conn("c1", A, 400, 1300), geo_conn("c2", A, 5, 5)],
         now="2026-10-15T12:01:00Z", interval=60)
    minutes = sconn.execute(
        "SELECT up, down, samples, conns, peak_up, peak_down "
        "FROM stats_minute_v5 ORDER BY bucket").fetchall()
    assert len(minutes) == 2
    hour = sconn.execute(
        "SELECT bucket, up, down, samples, conns, peak_up, peak_down "
        "FROM stats_hour").fetchall()
    assert [tuple(r) for r in hour] == [(
        "2026-10-15T12",
        sum(m["up"] for m in minutes), sum(m["down"] for m in minutes),
        sum(m["samples"] for m in minutes), sum(m["conns"] for m in minutes),
        max(m["peak_up"] for m in minutes),
        max(m["peak_down"] for m in minutes))]
    assert tuple(hour[0])[1:] == (405, 1305, 3, 2, 250, 1000)


def test_minute_to_hour_is_retention_only(sconn, monkeypatch):
    monkeypatch.setenv("PANEL_STATS_MINUTE_HOURS", "1")
    push(sconn, [geo_conn("c1", A, 10, 100)], now="2026-10-15T08:00:00Z")
    before = [tuple(r) for r in sconn.execute("SELECT * FROM stats_hour")]
    rollup(sconn, "2026-10-15T10:00:00Z", day=_UTC)
    assert sconn.execute("SELECT COUNT(*) FROM stats_minute_v5").fetchone()[0] == 0
    # the hour row was complete at ingest: the roll neither adds to it
    # nor removes it
    assert [tuple(r) for r in sconn.execute("SELECT * FROM stats_hour")] == before


# --- who a flow belongs to ---------------------------------------------------

def test_inner_flows_belong_to_the_gateway_not_unknown(sconn):
    push(sconn, [geo_conn("c1", "", 9, 99, kind="Inner"),
                 geo_conn("c2", "", 1, 1)])
    hour = {r["device"]: r["up"] for r in sconn.execute(
        "SELECT device, up FROM stats_hour")}
    assert hour == {"gateway": 9, "unknown": 1}
    assert values(sconn, "stats_exit_hour")[("gateway", "JP01")] == (9, 99)


# --- the seven-day class -----------------------------------------------------

def _class_frames():
    return [geo_conn("c1", A, 10, 100, host="video.example.com",
                     sniff="cdn.example.com", asn="AS64496 Example Net",
                     port="443"),
            geo_conn("c2", A, 1, 2, port="53"),
            geo_conn("c3", B, 5, 5, sniff="sniffed.example.com", port="443")]


def test_the_class_tables_stay_empty_with_the_gate_off(sconn):
    push(sconn, _class_frames(), domains=False)
    for table in ("stats_domain", *stats_store.CLASS_TABLES):
        assert sconn.execute(
            f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0, table
    assert {r[0] for r in sconn.execute(
        "SELECT sniff_host FROM stats_coverage")} == {""}


def test_the_class_tables_fill_with_the_gate_on(sconn):
    push(sconn, _class_frames(), domains=True)
    assert values(sconn, "stats_sniff") == {(A, "cdn.example.com"): (10, 100),
                                            (B, "sniffed.example.com"): (5, 5)}
    assert values(sconn, "stats_asn") == {(A, "AS64496 Example Net"): (10, 100),
                                          (A, "unknown"): (1, 2),
                                          (B, "unknown"): (5, 5)}
    assert values(sconn, "stats_port") == {(A, "443"): (10, 100),
                                           (A, "53"): (1, 2),
                                           (B, "443"): (5, 5)}
    buckets = {r[0] for t in stats_store.CLASS_TABLES
               for r in sconn.execute(f"SELECT bucket FROM {t}")}
    assert buckets == {"2026-10-15T12"}  # hour-keyed, like stats_domain


def test_no_hostname_class_value_reaches_a_long_term_table(sconn):
    push(sconn, _class_frames(), domains=True)
    for dim in stats_store.DIMENSIONS:
        for tier in ("hour", "day"):
            got = {r[0] for r in sconn.execute(
                f"SELECT value FROM stats_{dim}_{tier}")}
            assert not any("example.com" in v or v.startswith("AS")
                           for v in got), (dim, got)


# --- zero-byte activity ------------------------------------------------------

def test_a_new_idle_connection_writes_no_dimension_row(sconn):
    push(sconn, [geo_conn("c1", A, 0, 0)])
    assert sconn.execute("SELECT conns FROM stats_hour").fetchone()[0] == 1
    for dim in stats_store.DIMENSIONS:
        assert sconn.execute(
            f"SELECT COUNT(*) FROM stats_{dim}_hour").fetchone()[0] == 0, dim


# --- the day roll and retention ----------------------------------------------

def test_every_dimension_rolls_into_local_days(sconn, monkeypatch):
    monkeypatch.setenv("PANEL_STATS_HOUR_DAYS", "1")
    shanghai = dayframe.resolve("Asia/Shanghai", "03:00")
    # 2026-10-12T20 UTC = 10-13 04:00 Shanghai -> local day 10-13;
    # 2026-10-12T18 UTC = 10-13 02:00 -> before the 03:00 cut -> 10-12
    for now in ("2026-10-12T18:00:00Z", "2026-10-12T20:00:00Z"):
        push(sconn, [geo_conn("c1", A, 0, 0, geo=["US"])], now=now)
        push(sconn, [geo_conn("c1", A, 5, 50, geo=["US"])],
             now=now[:17] + "02Z")
        sconn.execute("DELETE FROM conn_baseline")
    rollup(sconn, "2026-10-15T00:00:00Z", day=shanghai)
    for dim, value in (("exit", "JP01"), ("rule", "Match"),
                       ("category", "unknown"), ("country", "US")):
        rows = [tuple(r) for r in sconn.execute(
            f"SELECT bucket, device, value, up, down, bucket_tz, day_boundary "
            f"FROM stats_{dim}_day ORDER BY bucket")]
        assert rows == [
            ("2026-10-12", A, value, 5, 50, "Asia/Shanghai", "03:00"),
            ("2026-10-13", A, value, 5, 50, "Asia/Shanghai", "03:00")], dim
        assert sconn.execute(
            f"SELECT COUNT(*) FROM stats_{dim}_hour").fetchone()[0] == 0, dim
    # the device tier rolled the same hours into the same days
    days = [tuple(r) for r in sconn.execute(
        "SELECT bucket, up FROM stats_day ORDER BY bucket")]
    assert days == [("2026-10-12", 5), ("2026-10-13", 5)]


def test_the_day_roll_accumulates_across_passes(sconn, monkeypatch):
    monkeypatch.setenv("PANEL_STATS_HOUR_DAYS", "1")
    sconn.execute("INSERT INTO stats_exit_hour (bucket, device, value, up, down)"
                  " VALUES ('2026-10-12T08', ?, 'JP01', 1, 2)", (A,))
    rollup(sconn, "2026-10-13T09:30:00Z", day=_UTC)
    sconn.execute("INSERT INTO stats_exit_hour (bucket, device, value, up, down)"
                  " VALUES ('2026-10-12T09', ?, 'JP01', 10, 20)", (A,))
    rollup(sconn, "2026-10-13T10:30:00Z", day=_UTC)
    assert [tuple(r) for r in sconn.execute(
        "SELECT bucket, up, down FROM stats_exit_day")] == [
        ("2026-10-12", 11, 22)]


def test_dimension_retention_follows_the_tier_knobs(sconn):
    for dim in stats_store.DIMENSIONS:
        sconn.execute(f"INSERT INTO stats_{dim}_day (bucket, device, value, "
                      f"up, down) VALUES ('2023-01-01', ?, 'x', 1, 1)", (A,))
        sconn.execute(f"INSERT INTO stats_{dim}_day (bucket, device, value, "
                      f"up, down) VALUES ('2026-01-01', ?, 'x', 1, 1)", (A,))
    rollup(sconn, "2026-10-15T12:00:00Z", day=_UTC)  # day retention 730 d
    for dim in stats_store.DIMENSIONS:
        assert [r[0] for r in sconn.execute(
            f"SELECT bucket FROM stats_{dim}_day")] == ["2026-01-01"], dim


def test_the_class_tables_keep_the_forced_seven_days(sconn, monkeypatch):
    monkeypatch.setenv("PANEL_STATS_HOUR_DAYS", "99999")
    for table in stats_store.CLASS_TABLES:
        sconn.execute(f"INSERT INTO {table} (bucket, device, value, up, down) "
                      f"VALUES ('2026-10-01T10', ?, 'old', 1, 1)", (A,))
        sconn.execute(f"INSERT INTO {table} (bucket, device, value, up, down) "
                      f"VALUES ('2026-10-14T10', ?, 'new', 1, 1)", (A,))
    rollup(sconn, "2026-10-15T12:00:00Z", day=_UTC)
    for table in stats_store.CLASS_TABLES:
        assert [r[0] for r in sconn.execute(
            f"SELECT value FROM {table}")] == ["new"], table


# --- the readers (used by Sequence 90) ---------------------------------------

def test_the_tier_reader_groups_by_value(sconn):
    push(sconn, [geo_conn("c1", A, 10, 100, geo=["US"]),
                 geo_conn("c2", B, 1, 2, geo=["US"]),
                 geo_conn("c3", B, 3, 4)])
    assert stats_store.read_dimension(sconn, "country", "hour") == [
        {"value": "US", "up": 11, "down": 102},
        {"value": "unknown", "up": 3, "down": 4}]
    # largest first, per device
    assert stats_store.read_dimension(sconn, "country", "hour", device=B) == [
        {"value": "unknown", "up": 3, "down": 4},
        {"value": "US", "up": 1, "down": 2}]


def test_the_window_reader_unions_day_and_hour_at_day_resolution(sconn):
    sconn.execute("INSERT INTO stats_exit_day (bucket, device, value, up, down)"
                  " VALUES ('2026-06-01', ?, 'JP01', 100, 1000)", (A,))
    push(sconn, [geo_conn("c1", A, 1, 10)])
    rows = stats_store.read_window_dimension(sconn, "exit", "day", None, _UTC)
    assert rows == [{"value": "JP01", "up": 101, "down": 1010}]
    hourly = stats_store.read_window_dimension(sconn, "exit", "hour", None,
                                               _UTC)
    assert hourly == [{"value": "JP01", "up": 1, "down": 10}]


def test_an_unknown_dimension_is_refused(sconn):
    with pytest.raises(ValueError):
        stats_store.read_dimension(sconn, "host", "hour")
    with pytest.raises(ValueError):
        stats_store.read_window_dimension(sconn, "exit", "minute", None, _UTC)
