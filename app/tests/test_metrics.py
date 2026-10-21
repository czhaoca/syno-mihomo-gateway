"""GET /metrics (#99): the Prometheus text exposition behind PANEL_METRICS -
404 when off, per-dimension byte counters fed after each committed poll,
the collector's gauges, and a label set no hostname-class value can reach.
Synthesised flows only (TEST-NET, example.com)."""

import re
import sqlite3

import pytest
from app.api import metrics as metrics_mod
from app.collector.core import Collector
from app.store.stats import Counters, flush_poll
from app.tests.conftest import example_dictionary, geo_conn
from scripts.ci import panel_contract_check

A, B = "192.0.2.20", "192.0.2.21"
SAMPLE = re.compile(r'^([a-z_]+)(?:\{(.*)\})? (\S+)$')
LABEL = re.compile(r'([a-z_]+)="((?:[^"\\]|\\.)*)"')


@pytest.fixture()
def on(monkeypatch):
    monkeypatch.setenv("PANEL_METRICS", "true")


def poll(client, frames, now="2026-10-15T12:00:00Z", domains=False):
    collector = client.app.state.collector
    flush_poll(collector.conn, frames, now, domains_enabled=domains,
               gap_threshold_s=6, interval_s=2,
               dictionary=example_dictionary(), counters=collector.counters)


def scrape(client):
    r = client.get("/metrics")
    assert r.status_code == 200, r.text
    assert r.headers["content-type"] == "text/plain; version=0.0.4; charset=utf-8"
    samples = {}
    for line in r.text.splitlines():
        if line.startswith("#") or not line:
            continue
        m = SAMPLE.match(line)
        assert m, line
        labels = tuple(LABEL.findall(m.group(2) or ""))
        samples[(m.group(1), labels)] = float(m.group(3))
    return r.text, samples


def test_it_is_off_unless_enabled(client):
    r = client.get("/metrics")
    assert r.status_code == 404
    assert "PANEL_METRICS" in r.json()["detail"]


def test_every_family_is_declared(client, on):
    text, _ = scrape(client)
    for name in ("insights_device_bytes_total", "insights_group_bytes_total",
                 "insights_exit_bytes_total", "insights_rule_bytes_total",
                 "insights_category_bytes_total",
                 "insights_country_bytes_total", "insights_collector_up",
                 "insights_collector_lag_seconds",
                 "insights_collector_failed_polls_total",
                 "insights_stats_db_bytes", "insights_stats_cap_bytes",
                 "insights_mihomo_info"):
        assert f"# TYPE {name} " in text, name
    assert "# TYPE insights_device_bytes_total counter" in text


def test_the_counters_carry_each_dimension(client, on):
    poll(client, [geo_conn("c1", A, 10, 100, chains=("JP 01", "Auto"),
                           rule="GeoSite", payload="example-video",
                           host="video.example.com", geo=["JP"]),
                  geo_conn("c2", B, 1, 2, chains=("US 01", "Auto"))])
    _, s = scrape(client)
    assert s[("insights_device_bytes_total",
              (("device", A), ("direction", "up")))] == 10
    assert s[("insights_device_bytes_total",
              (("device", A), ("direction", "down")))] == 100
    assert s[("insights_group_bytes_total",
              (("group", "Auto"), ("direction", "down")))] == 102
    assert s[("insights_exit_bytes_total",
              (("exit", "US 01"), ("direction", "up")))] == 1
    assert s[("insights_rule_bytes_total",
              (("rule_type", "GeoSite"), ("direction", "up")))] == 10
    assert s[("insights_category_bytes_total",
              (("category", "video"), ("direction", "up")))] == 10
    assert s[("insights_country_bytes_total",
              (("country", "unknown"), ("direction", "up")))] == 1


def test_counters_only_grow_across_polls(client, on):
    poll(client, [geo_conn("c1", A, 10, 100)])
    _, first = scrape(client)
    poll(client, [geo_conn("c1", A, 15, 160)], now="2026-10-15T12:00:02Z")
    poll(client, [geo_conn("c1", A, 15, 160)], now="2026-10-15T12:00:04Z")
    _, later = scrape(client)
    key = ("insights_device_bytes_total", (("device", A), ("direction", "up")))
    assert (first[key], later[key]) == (10, 15)
    for k, v in first.items():
        if k[0].endswith("_bytes_total"):
            assert later[k] >= v, k


def test_a_poll_the_store_rolled_back_counts_nothing(panel_env, monkeypatch):
    from app.store.stats import open_stats_db
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    counters = Counters()
    conn.execute("DROP TABLE stats_coverage")  # the flush fails mid-way
    with pytest.raises(sqlite3.OperationalError):
        flush_poll(conn, [geo_conn("c1", A, 10, 100, host="video.example.com")],
                   "2026-10-15T12:00:00Z", domains_enabled=False,
                   gap_threshold_s=6, interval_s=2, counters=counters)
    conn.close()
    assert all(not values for values in counters.snapshot().values())


def test_the_collector_feeds_its_own_counters(panel_env, fake_client):
    from app.store.stats import open_stats_db
    from app.tests.conftest import conn_fixture
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    fake_client.conns = [conn_fixture("c1", A, 7, 70)]
    collector = Collector(client=fake_client, conn=conn)
    collector.poll_once(now="2026-10-15T12:00:00Z")
    conn.close()
    assert collector.counters.snapshot()["device"] == {A: (7, 70)}


def test_an_idle_new_connection_adds_no_series(client, on):
    poll(client, [geo_conn("c1", A, 0, 0, chains=("JP 01", "Idle"))])
    text, _ = scrape(client)
    assert "Idle" not in text and A not in text


# --- the label set (DEC-A, DEC-C) -------------------------------------------------

def test_no_hostname_class_value_ever_reaches_a_label(client, on):
    # the domains gate on: hostnames, sniffed names, ASNs, ports and app ids
    # are all stored - and none of them may appear
    poll(client, [geo_conn("c1", A, 10, 100, host="video.example.com",
                           sniff="cdn.example.org", asn="AS64496 Example Net",
                           port="8443")], domains=True)
    text, samples = scrape(client)
    for leaked in ("example.com", "example.org", "AS64496", "8443",
                   "example-video"):
        assert leaked not in text, leaked
    names = {name for _metric, labels in samples for name, _v in labels}
    assert names <= metrics_mod.LABELS


def test_the_label_allowlist_is_exactly_the_long_term_class():
    pinned = {"device", "group", "exit", "rule_type", "category", "country",
              "direction", "mihomo_version"}
    assert pinned == set(metrics_mod.LABELS)


def test_values_that_render_alike_are_one_series(client, on):
    poll(client, [geo_conn("c1", A, 5, 5, chains=("",)),
                  geo_conn("c2", A, 7, 7, chains=("none",))])
    text, s = scrape(client)
    lines = [ln for ln in text.splitlines()
             if ln.startswith('insights_exit_bytes_total{exit="none",'
                              'direction="up"}')]
    assert len(lines) == 1
    assert s[("insights_exit_bytes_total",
              (("exit", "none"), ("direction", "up")))] == 12


def test_the_renderer_refuses_a_label_outside_the_allowlist():
    with pytest.raises(ValueError, match="allowlist"):
        metrics_mod.render([("x_total", "counter", "x",
                             [({"host": "video.example.com"}, 1)])])


def test_an_empty_value_gets_its_placeholder(client, on):
    collector = client.app.state.collector
    flush_poll(collector.conn, [geo_conn("c1", A, 3, 4, rule="")],
               "2026-10-15T12:00:00Z", domains_enabled=False,
               gap_threshold_s=6, interval_s=2, dictionary=None,
               counters=collector.counters)
    _, s = scrape(client)
    assert s[("insights_category_bytes_total",
              (("category", "no_dictionary"), ("direction", "up")))] == 3
    assert s[("insights_rule_bytes_total",
              (("rule_type", "none"), ("direction", "down")))] == 4
    # `unknown`, `gateway` and `DIRECT` are values, not placeholders
    assert metrics_mod.label_value("country", "unknown") == "unknown"


def test_label_values_are_escaped(client, on):
    poll(client, [geo_conn("c1", A, 1, 1, chains=('JP "01"\\x\nB', "Auto"))])
    text, _ = scrape(client)
    assert 'exit="JP \\"01\\"\\\\x\\nB"' in text


def test_a_purge_resets_the_counters_it_mirrors(client, on, panel_env):
    from app.tests.conftest import auth_headers
    poll(client, [geo_conn("c1", A, 10, 100)])
    # a purge of a table the counters do not mirror leaves them
    r = client.post("/v1/stats/purge", json={"tables": ["stats_gap"]},
                    headers=auth_headers(panel_env))
    assert r.status_code == 200, r.text
    assert A in scrape(client)[0]
    r = client.post("/v1/stats/purge", json={"device": A},
                    headers=auth_headers(panel_env))
    assert r.status_code == 200, r.text
    assert A not in scrape(client)[0]


def test_the_gauges_mirror_health(client, on):
    health = client.get("/health").json()
    _, s = scrape(client)
    assert s[("insights_stats_cap_bytes", ())] == health["stats_cap_mb"] * 1048576
    # base units only: no megabytes in a metric name
    assert "megabytes" not in scrape(client)[0]
    assert s[("insights_collector_failed_polls_total", ())] == \
        health["collector_failed_polls"]
    assert s[("insights_collector_interval_seconds", ())] == \
        health["collector_interval_s"]
    # not measured yet: no sample, never a zero
    assert ("insights_collector_poll_seconds", ()) not in s


def test_every_knob_the_panel_reads_reaches_its_container():
    """A knob app/config.py reads but docker-compose.yml never passes in is
    a knob that silently does nothing on a real deployment."""
    from pathlib import Path
    repo = Path(__file__).resolve().parents[2]
    source = (repo / "app" / "config.py").read_text()
    read = set(re.findall(r'environ\.get\("([A-Z_]+)"', source)) | set(
        re.findall(r'_int_env\("([A-Z_]+)"', source))
    compose = (repo / "docker-compose.yml").read_text()
    start = compose.index("\n  panel:")
    # the panel block ends at the next service or top-level key, so another
    # service passing the same variable cannot hide a missing panel line
    following = re.search(r"\n(?:  )?[a-z][a-z0-9_-]*:", compose[start + 1:])
    panel = (compose[start:start + 1 + following.start()] if following
             else compose[start:])
    passed = set(re.findall(r"^      - ([A-Z_]+)=", panel, re.M))
    assert "PANEL_METRICS" in read
    assert read <= passed, sorted(read - passed)


# --- the contract gate (#99) -------------------------------------------------------

def test_the_contract_admits_metrics_and_health_only_at_the_root():
    def doc(*paths):
        return {"paths": {path: {} for path in paths}}
    assert panel_contract_check.path_problems(
        doc("/health", "/metrics", "/v1/stats/devices")) == []
    assert panel_contract_check.path_problems(doc("/debug"))
    assert panel_contract_check.path_problems(doc("/v2/x"))
    assert all(panel_contract_check.ROOT_PATHS.values())  # each has a reason
