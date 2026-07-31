"""Attribution coverage (#77, DEC-6): measure before building a dictionary.

The panel already sees a classification signal on every flow and throws it
away. This retains it and answers one question: what share of bytes could
be attributed to an app at all? DEC-6 exists because the per-app feature's
point is BLOCKING, and blocking on bad attribution takes out the wrong app
on a gateway carrying all LAN traffic.

Two panel-confirmed decisions shape everything here:

DEC-B (hostname-only): a hostname is the only signal that names an app.
`rule`/`rulePayload` are ROUTING categories - the repo's own release gate
rejects `GeoSite/cn` as proof of anything at `validate_release.sh:1089` -
so counting them as attributed would inflate the exact number this ticket
exists to measure honestly.

DEC-A (inherit the forced 7 days): the retained fields are hostname-
bearing, and `sniffHost` is the same datum as `metadata.host`, which is
persisted ONLY behind the off-by-default `PANEL_STATS_DOMAINS` gate. So
the always-on coverage counters carry no hostname at all, and the raw
hostname stays behind the gate it already had.
"""

import pytest
from app.store import dayframe
from app.store import stats as stats_store
from app.store.stats import STATS_MIGRATIONS, open_stats_db

_UTC = dayframe.utc_frame()


@pytest.fixture()
def sconn(tmp_path, panel_env):
    c = open_stats_db(tmp_path / "stats.db")
    yield c
    c.close()


def flow(cid, source="192.0.2.20", up=10, down=100, host="",
         sniff="", rule="Match", payload=""):
    """A /connections entry in the controller's wire shape."""
    meta = {"sourceIP": source, "network": "tcp", "type": "tun"}
    if host:
        meta["host"] = host
    if sniff:
        meta["sniffHost"] = sniff
    return {"id": cid, "upload": up, "download": down, "metadata": meta,
            "chains": ["DIRECT"], "rule": rule, "rulePayload": payload}


def push(conn, flows, now="2026-07-29T18:30:00Z", domains=False):
    stats_store.flush_poll(conn, flows, now, domains_enabled=domains,
                           gap_threshold_s=30)


def coverage(conn):
    return {r["klass"]: (r["up"], r["down"])
            for r in stats_store.read_coverage(conn)}


# --- the retained signal (AC1) ------------------------------------------------

def test_rule_and_payload_are_retained_per_flow(sconn):
    push(sconn, [flow("1", host="example.com", rule="RuleSet",
                      payload="dyn-full-direct")])
    rows = [dict(r) for r in sconn.execute(
        "SELECT klass, rule, rule_payload, up, down FROM stats_coverage")]
    assert rows == [{"klass": "hostname", "rule": "RuleSet",
                     "rule_payload": "dyn-full-direct", "up": 10, "down": 100}]


def test_retention_does_not_alter_any_existing_stats_number(sconn):
    """AC1's real protection: the shipped tiers must read back exactly as
    they did before this ticket existed."""
    flows = [flow("1", host="example.com", up=10, down=100),
             flow("2", source="192.0.2.21", up=5, down=50)]
    push(sconn, flows)
    devices = {r["device"]: (r["up"], r["down"])
               for r in stats_store.read_grouped(sconn, "minute", "device")}
    assert devices == {"192.0.2.20": (10, 100), "192.0.2.21": (5, 50)}
    chains = {r["chain"]: (r["up"], r["down"])
              for r in stats_store.read_grouped(sconn, "minute", "chain")}
    assert chains == {"DIRECT": (15, 150)}

    # and a SECOND poll still accumulates into the same bucket - a single
    # flush cannot tell an upsert from an insert-once, so a change that
    # silently stopped merging would read as correct on one poll
    push(sconn, [flow("3", up=1, down=2)])
    devices = {r["device"]: (r["up"], r["down"])
               for r in stats_store.read_grouped(sconn, "minute", "device")}
    assert devices["192.0.2.20"] == (11, 102), devices


def test_no_hostname_is_persisted_anywhere_in_the_default_configuration(sconn):
    """DEC-A's binding rider, stated as the invariant that actually matters.
    `PANEL_STATS_DOMAINS` is off by default and the bilingual docs promise
    the panel persists no hostname-derived rows in that configuration - so
    the test is not "the column does not exist" but "nothing wrote a
    hostname", which is what the promise says and what a future column
    could quietly break."""
    push(sconn, [flow("1", host="secret.example.com",
                      sniff="also-secret.example.com")], domains=False)
    for table in stats_store.PURGE_TABLES:
        blob = " ".join(
            str(v) for row in sconn.execute(f"SELECT * FROM {table}")
            for v in row)
        assert "secret.example.com" not in blob, table
        assert "also-secret.example.com" not in blob, table
    assert sconn.execute(
        "SELECT COUNT(*) FROM stats_domain").fetchone()[0] == 0
    # the coverage row still exists - the flow is counted, just not named
    assert coverage(sconn) == {"hostname": (10, 100)}


def test_sniff_host_is_retained_only_behind_the_opt_in_gate(sconn):
    """sniffHost IS a hostname, so it is persisted only under the same
    off-by-default gate every other hostname obeys - and under the same
    forced 7-day cap."""
    push(sconn, [flow("1", sniff="sniffed.example.com")], domains=False)
    assert [r[0] for r in sconn.execute(
        "SELECT sniff_host FROM stats_coverage")] == [""]
    push(sconn, [flow("2", sniff="sniffed.example.com")], domains=True)
    assert "sniffed.example.com" in {
        r[0] for r in sconn.execute("SELECT sniff_host FROM stats_coverage")}


def test_the_shipped_domain_table_semantics_are_untouched(sconn):
    """AC1 forbids altering EXISTING stats semantics, and stats_domain is
    a shipped table. Under an unchanged operator configuration it must
    store exactly what it stored before this ticket: `metadata.host`, and
    nothing else. Routing sniffHost into it would have silently widened
    what an existing opt-in table collects."""
    push(sconn, [flow("1", host="named.example.com", up=1, down=1),
                 flow("2", sniff="sniffed.example.com", up=2, down=2)],
         domains=True)
    rows = [(r["domain"], r["up"], r["down"]) for r in sconn.execute(
        "SELECT domain, up, down FROM stats_domain ORDER BY domain")]
    assert rows == [("named.example.com", 1, 1)], rows


# --- the classification (AC2, DEC-B hostname-only) ---------------------------

def test_a_hostname_counts_and_a_bare_ip_does_not(sconn):
    push(sconn, [flow("1", host="example.com", up=10, down=100),
                 flow("2", up=3, down=30)])
    assert coverage(sconn) == {"hostname": (10, 100), "ip_only": (3, 30)}


def test_a_sniffed_hostname_counts_as_attributable(sconn):
    """The sniffer exists precisely to recover a name the DNS path missed;
    a flow it named is attributable even though `metadata.host` is empty."""
    push(sconn, [flow("1", sniff="sniffed.example.com", up=7, down=70)])
    assert coverage(sconn) == {"hostname": (7, 70)}


@pytest.mark.parametrize("rule,payload", [
    ("GeoSite", "cn"),          # an entire country
    ("RuleSet", "dyn-full-direct"),   # the panel's own routing policy
    ("GeoIP", "CN"),
    ("Match", ""),
])
def test_a_routing_signal_alone_is_never_attribution(sconn, rule, payload):
    """DEC-B, and the repo already encodes it: validate_release.sh:1089-1092
    accepts RuleSet/dyn-full-direct as proof a RULE routed a flow and
    explicitly REJECTS GeoSite/cn as proof of anything else. A routing
    category is not an app, and counting it would inflate the number this
    ticket exists to measure."""
    push(sconn, [flow("1", rule=rule, payload=payload, up=4, down=40)])
    assert coverage(sconn) == {"ip_only": (4, 40)}


def test_the_shares_sum_to_one_hundred_percent(sconn, client, panel_env):
    push(sconn, [flow("1", host="a.example.com", up=60, down=600),
                 flow("2", up=40, down=400)])
    report = stats_store.coverage_report(sconn)
    assert report["total"] == {"up": 100, "down": 1000}
    shares = {c["klass"]: c["share"] for c in report["classes"]}
    assert shares == {"hostname": 60.0, "ip_only": 40.0}
    assert round(sum(shares.values()), 6) == 100.0


def test_an_empty_window_reports_zero_shares_not_a_division_by_zero(sconn):
    report = stats_store.coverage_report(sconn)
    assert report["total"] == {"up": 0, "down": 0}
    assert all(c["share"] == 0.0 for c in report["classes"])
    # every known class is still listed, so a consumer never has to guess
    # whether a missing class means zero or means "not measured"
    assert {c["klass"] for c in report["classes"]} == {"hostname", "ip_only"}


def test_the_report_says_when_the_window_asked_for_exceeds_what_it_kept(sconn):
    """Attribution lives ONLY in the 7-day-capped table - the 90/730 day
    byte tiers carry no klass or rule column at all. So a 30-day question
    gets a percentage computed over at most 7 days, and the report has to
    say so. A silently truncated window is exactly the quiet inaccuracy
    DEC-6 exists to keep out of a blocking decision."""
    push(sconn, [flow("1", host="a.example.com")])
    report = stats_store.coverage_report(sconn, since="2026-01-01T00")
    assert report["window"]["truncated"] is True
    assert report["window"]["retention_days"] == 7
    assert report["window"]["oldest_bucket"] == "2026-07-29T18"
    # a window the table CAN answer in full is not flagged. Note the flag
    # means "the range you asked about is not fully covered" - it does not
    # try to distinguish retention pruning from a young install, because
    # the consequence for the caller is identical either way.
    inside = stats_store.coverage_report(sconn, since="2026-07-29T18")
    assert inside["window"]["truncated"] is False
    assert stats_store.coverage_report(sconn)["window"]["truncated"] is False


def test_unattributable_bytes_are_broken_down_by_the_rule_that_routed_them(
        sconn):
    """AC2 asks for "deliberately excluded" as a third share. It is not
    observable: the template's skip-domain exclusions affect SNIFFING, not
    routing, so an excluded flow is byte-for-byte indistinguishable on the
    wire from ordinary IP-only residue - and deciding otherwise would mean
    hardcoding the exclusion list, which CLAUDE.md forbids outright.

    What IS observable, and strictly more useful, is WHICH RULE routed each
    unattributable byte. The deliberate exclusions surface under their own
    rule names, so the operator can tell a designed exclusion from a
    genuine attribution gap without the panel guessing on their behalf."""
    push(sconn, [flow("1", rule="GeoIP", payload="CN", up=10, down=100),
                 flow("2", rule="Match", payload="", up=5, down=50),
                 flow("3", host="a.example.com", rule="GeoSite",
                      payload="youtube", up=1, down=1)])
    rows = stats_store.coverage_rules(sconn)
    named = {(r["rule"], r["rule_payload"]): (r["up"], r["down"])
             for r in rows}
    assert named == {("GeoIP", "CN"): (10, 100), ("Match", ""): (5, 50)}, rows
    # heaviest first: the operator reads this to find where the
    # attribution gap actually is, so the order is part of the answer
    assert [(r["rule"], r["rule_payload"]) for r in rows] == [
        ("GeoIP", "CN"), ("Match", "")], rows


# --- retention, cap, and purge (DEC-A) ---------------------------------------

def test_coverage_inherits_the_forced_seven_day_retention(sconn):
    """Not a knob, by decision: the fields are hostname-adjacent and the
    DEC-8 privacy rider is deliberately non-configurable."""
    sconn.execute(
        "INSERT INTO stats_coverage (bucket, device, klass, rule, "
        "rule_payload, up, down) VALUES "
        "('2026-07-01T10', '192.0.2.20', 'hostname', 'Match', '', 1, 1)")
    sconn.execute(
        "INSERT INTO stats_coverage (bucket, device, klass, rule, "
        "rule_payload, up, down) VALUES "
        "('2026-07-29T10', '192.0.2.20', 'hostname', 'Match', '', 2, 2)")
    stats_store.rollup(sconn, "2026-07-30T00:00:00Z", day=_UTC)
    kept = [r[0] for r in sconn.execute(
        "SELECT bucket FROM stats_coverage ORDER BY bucket")]
    assert kept == ["2026-07-29T10"]


def test_no_new_retention_knob_was_introduced(sconn):
    """The rejected DEC-A option was "a separate longer cap", which would
    have meant a new PANEL_STATS_* knob extending retention of
    hostname-bearing data past a documented, deliberately knob-less
    promise. Assert the knob does not exist."""
    import app.config as cfg
    names = [n for n in dir(cfg) if "coverage" in n.lower()
             or "categor" in n.lower()]
    assert names == [], names
    assert stats_store.DOMAIN_RETENTION_DAYS == 7


def test_coverage_is_drained_late_by_the_cap_not_before_the_day_tier(sconn):
    """`enforce_cap` prunes data-age-first and eats the DAY tier first.
    A 7-day-bounded table belongs beside stats_domain at the END, or the
    cap would destroy long-term history to make room for a week of
    counters."""
    order = [name for name, _table, _col in stats_store._CAP_TIERS]
    assert order.index("coverage") > order.index("day")
    # strictly after the other 7-day table too, matching the real tuple -
    # a >= here would pass against an ordering the code does not have
    assert order.index("coverage") > order.index("domain")


def test_the_token_gated_purge_clears_coverage_too(sconn, client, panel_env):
    """Otherwise the purge silently leaves the newest privacy-adjacent
    rows behind - the one operation whose entire promise is that it does
    not."""
    push(sconn, [flow("1", host="a.example.com")], domains=True)
    assert sconn.execute(
        "SELECT COUNT(*) FROM stats_coverage").fetchone()[0] > 0
    stats_store.purge_stats(sconn)
    # every stats table, checked by RUNNING the purge - asserting membership
    # in PURGE_TABLES would only prove the tuple contains what the tuple
    # contains, and a loop that filtered the table back out would pass
    for table in stats_store.PURGE_TABLES:
        assert sconn.execute(
            f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0, table


def test_coverage_is_stats_migration_three(sconn):
    versions = [v for v, _ in STATS_MIGRATIONS]
    assert versions == [1, 2, 3], versions
    assert sconn.execute("PRAGMA user_version").fetchone()[0] == 3


def test_the_migration_leaves_every_shipped_stats_table_untouched(sconn):
    for table in ("stats_minute", "stats_hour", "stats_day", "stats_domain",
                  "stats_gap", "stats_meta", "conn_baseline"):
        assert sconn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
            (table,)).fetchone() is not None, table
    # #76's stamps survived
    day_ddl = sconn.execute(
        "SELECT sql FROM sqlite_master WHERE name='stats_day'").fetchone()[0]
    assert "bucket_tz" in day_ddl and "day_boundary" in day_ddl


# --- the API surface ----------------------------------------------------------

def test_the_coverage_endpoint_is_additive_and_lan_open(client, panel_env):
    r = client.get("/v1/stats/coverage")
    assert r.status_code == 200
    body = r.json()
    assert "total" in body and "classes" in body and "rules" in body

    sconn = client.app.state.stats_conn
    push(sconn, [flow("1", rule="GeoIP", payload="CN", up=9, down=90),
                 flow("2", host="a.example.com", up=1, down=10)])
    body = client.get("/v1/stats/coverage").json()
    # the breakdown must carry CONTENT: asserting only that the key exists
    # would pass against an endpoint that always returned an empty list
    assert [(r["rule"], r["rule_payload"], r["up"], r["down"])
            for r in body["rules"]] == [("GeoIP", "CN", 9, 90)]
    assert {c["klass"]: c["share"] for c in body["classes"]} == {
        "hostname": 10.0, "ip_only": 90.0}


def test_the_coverage_endpoint_reports_the_unclassified_share_explicitly(
        client, panel_env):
    """The constraint is that the unclassified share is never absorbed
    into a named app. With no dictionary yet, EVERYTHING attributable is
    unnamed - so the report must still say so rather than implying
    coverage it has not got."""
    body = client.get("/v1/stats/coverage").json()
    klasses = {c["klass"] for c in body["classes"]}
    assert "ip_only" in klasses
