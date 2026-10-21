"""One poll's flush: bounded SQL, and the facts it records (#94).

Before #94 the flush ran one SELECT per connection, upserted every
connection's baseline, and walked the whole baseline table to reap closed
ones - three statements per open connection on every poll, the first thing
to break at a 2 s cadence. Now the baseline set is read once, every table
is written with one statement per poll, and only connections whose
counters MOVED rewrite their baseline (an idle connection costs no write).

Each tier row also carries what the bytes alone could not say:
  samples   polls in which this device/chain had activity
  conns     connection ids first seen (or counter-reset) in the bucket
  peak_*    the largest single-poll delta of the row
and the poll interval is recorded, so a peak reads as bytes per interval.

The series below is synthesised (TEST-NET addresses, example.com only).
"""

import pytest
from app.store import dayframe
from app.store.stats import (
    CLASS_TABLES,
    DIMENSIONS,
    flush_poll,
    meta_get,
    open_stats_db,
    rollup,
)
from app.tests.conftest import example_dictionary

_UTC = dayframe.utc_frame()
# every fleet hostname is an example.com name, which this dictionary files
# under its vendor - so with the gate on the app table is written too
DICT = example_dictionary()
A, B = "192.0.2.20", "192.0.2.21"


def frame_conn(cid, src, up, down, chain="Routing Mode", host=""):
    return {"id": cid, "upload": up, "download": down,
            "metadata": {"sourceIP": src, "host": host, "sniffHost": "",
                         "network": "tcp", "type": "Tun"},
            "chains": ["JP 01", chain], "rule": "Match", "rulePayload": ""}


def poll(conn, frames, now, interval=2, domains=False):
    flush_poll(conn, frames, now, domains_enabled=domains,
               gap_threshold_s=3 * interval, interval_s=interval,
               dictionary=DICT)


@pytest.fixture()
def sconn(panel_env):
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


def fleet(n, step):
    """N connections whose counters all moved at STEP, each carrying a
    hostname and a sniffed name, so with the gate on every table is written."""
    frames = [frame_conn(f"c{i}", f"192.0.2.{i % 50}", 100 * step + i,
                         1000 * step + i, host=f"h{i % 7}.example.com")
              for i in range(n)]
    for f in frames:
        f["metadata"]["sniffHost"] = f["metadata"]["host"]
    return frames


def counted(conn, fn):
    seen = []
    conn.set_trace_callback(seen.append)
    try:
        fn()
    finally:
        conn.set_trace_callback(None)
    return len(seen)


# --- the flush is bounded ---------------------------------------------------

# The ceiling is the fixed statements of a poll (BEGIN, the stamp and the
# baseline reads, the baseline write and reap, the stamps, COMMIT) plus ONE
# per table written - minute, hour, the long-term dimensions, coverage, and
# with the gate on the domain and seven-day class tables (#95, and the app
# table since #97). It must
# never depend on how many connections are open.
_FIXED = 7
_TABLES_GATE_OFF = 2 + len(DIMENSIONS) + 1
_TABLES_GATE_ON = _TABLES_GATE_OFF + 1 + len(CLASS_TABLES)


@pytest.mark.parametrize("domains, ceiling", [
    (False, _FIXED + _TABLES_GATE_OFF), (True, _FIXED + _TABLES_GATE_ON)])
def test_statement_count_does_not_grow_with_the_connection_count(
        panel_env, domains, ceiling):
    small = open_stats_db(panel_env["data"] / "state" / "small.db")
    big = open_stats_db(panel_env["data"] / "state" / "big.db")
    try:
        first_small = counted(small, lambda: poll(small, fleet(10, 1),
                                                  "2026-10-15T12:00:00Z",
                                                  domains=domains))
        first_big = counted(big, lambda: poll(big, fleet(1000, 1),
                                              "2026-10-15T12:00:00Z",
                                              domains=domains))
        # steady state: every counter moved, a few connections closed
        next_small = counted(small, lambda: poll(small, fleet(8, 2),
                                                 "2026-10-15T12:00:02Z",
                                                 domains=domains))
        next_big = counted(big, lambda: poll(big, fleet(990, 2),
                                             "2026-10-15T12:00:02Z",
                                             domains=domains))
    finally:
        small.close()
        big.close()
    assert first_big <= first_small + 2, (first_small, first_big)
    assert next_big <= next_small + 2, (next_small, next_big)
    assert next_big <= ceiling, (next_big, ceiling)


def test_an_idle_connection_costs_no_write(sconn):
    poll(sconn, fleet(500, 1), "2026-10-15T12:00:00Z")
    before = sconn.total_changes
    poll(sconn, fleet(500, 1), "2026-10-15T12:00:02Z")  # nothing moved
    assert sconn.total_changes - before <= 3, sconn.total_changes - before
    assert sconn.execute("SELECT COUNT(*) FROM conn_baseline").fetchone()[0] == 500


def test_a_closed_connection_is_reaped(sconn):
    poll(sconn, fleet(5, 1), "2026-10-15T12:00:00Z")
    poll(sconn, fleet(3, 2), "2026-10-15T12:00:02Z")
    ids = {r[0] for r in sconn.execute("SELECT conn_id FROM conn_baseline")}
    assert ids == {"c0", "c1", "c2"}


def test_a_restart_still_never_double_counts(sconn):
    poll(sconn, [frame_conn("c1", A, 100, 1000)], "2026-10-15T12:00:00Z")
    poll(sconn, [frame_conn("c1", A, 100, 1000)], "2026-10-15T12:00:02Z")
    row = sconn.execute("SELECT up, down FROM stats_minute_v5").fetchone()
    assert (row["up"], row["down"]) == (100, 1000)


# --- the facts ----------------------------------------------------------------

def minute(conn, device=A, chain="Routing Mode"):
    return conn.execute(
        "SELECT up, down, samples, conns, peak_up, peak_down FROM stats_minute_v5 "
        "WHERE device = ? AND chain = ? ORDER BY bucket", (device, chain)).fetchall()


def test_samples_conns_and_peaks_from_a_series(sconn):
    poll(sconn, [], "2026-10-15T11:59:58Z")  # the store's first poll: a baseline
    # 12:00:00  c1 new (100/1000), c2 new (10/0)          -> row delta 110/1000
    # 12:00:02  c1 +50/+500, c3 new (5/5)                  -> row delta  55/505
    # 12:00:04  nothing moved                              -> no activity
    # 12:00:06  c4 new with no bytes yet                   -> activity, 0 bytes
    poll(sconn, [frame_conn("c1", A, 100, 1000), frame_conn("c2", A, 10, 0)],
         "2026-10-15T12:00:00Z")
    poll(sconn, [frame_conn("c1", A, 150, 1500), frame_conn("c2", A, 10, 0),
                 frame_conn("c3", A, 5, 5)], "2026-10-15T12:00:02Z")
    poll(sconn, [frame_conn("c1", A, 150, 1500), frame_conn("c2", A, 10, 0),
                 frame_conn("c3", A, 5, 5)], "2026-10-15T12:00:04Z")
    poll(sconn, [frame_conn("c1", A, 150, 1500), frame_conn("c2", A, 10, 0),
                 frame_conn("c3", A, 5, 5), frame_conn("c4", A, 0, 0)],
         "2026-10-15T12:00:06Z")
    [row] = minute(sconn)
    assert (row["up"], row["down"]) == (165, 1505)
    assert row["samples"] == 3
    assert row["conns"] == 4
    assert (row["peak_up"], row["peak_down"]) == (110, 1000)


def test_a_counter_reset_counts_as_a_new_connection(sconn):
    poll(sconn, [frame_conn("c1", A, 100, 1000)], "2026-10-15T12:00:00Z")
    poll(sconn, [frame_conn("c1", A, 7, 9)], "2026-10-15T12:00:02Z")  # reset
    [row] = minute(sconn)
    assert row["conns"] == 2
    assert (row["up"], row["down"]) == (107, 1009)


def test_rows_are_per_device_and_chain(sconn):
    poll(sconn, [], "2026-10-15T11:59:58Z")
    poll(sconn, [frame_conn("c1", A, 10, 10),
                 frame_conn("c2", B, 20, 20, chain="Full-Tunnel Devices")],
         "2026-10-15T12:00:00Z")
    assert minute(sconn, A)[0]["conns"] == 1
    assert minute(sconn, B, "Full-Tunnel Devices")[0]["peak_down"] == 20


def test_rollup_sums_counts_and_keeps_the_largest_peak(sconn, monkeypatch):
    monkeypatch.setenv("PANEL_STATS_MINUTE_HOURS", "1")
    monkeypatch.setenv("PANEL_STATS_HOUR_DAYS", "1")
    # two minutes of the same hour, two days apart from the roll time; a
    # 60 s cadence so one minute apart is a normal interval
    poll(sconn, [], "2026-10-13T07:59:00Z", interval=60)
    poll(sconn, [frame_conn("c1", A, 100, 1000)], "2026-10-13T08:00:00Z",
         interval=60)
    poll(sconn, [frame_conn("c1", A, 300, 1100), frame_conn("c2", A, 1, 1)],
         "2026-10-13T08:01:00Z", interval=60)
    rollup(sconn, "2026-10-13T10:00:00Z", day=_UTC)  # minute -> hour
    hour = sconn.execute(
        "SELECT up, down, samples, conns, peak_up, peak_down FROM stats_hour"
    ).fetchone()
    assert (hour["up"], hour["down"]) == (301, 1101)
    assert (hour["samples"], hour["conns"]) == (2, 2)
    assert (hour["peak_up"], hour["peak_down"]) == (201, 1000)
    rollup(sconn, "2026-10-15T12:00:00Z", day=_UTC)  # hour -> day
    day = sconn.execute(
        "SELECT up, down, samples, conns, peak_up, peak_down FROM stats_day"
    ).fetchone()
    assert tuple(day) == (301, 1101, 2, 2, 201, 1000)


def test_a_minute_split_across_the_roll_keeps_its_facts(sconn, monkeypatch):
    # the same hour bucket filled from two rolls accumulates, peak = max
    monkeypatch.setenv("PANEL_STATS_MINUTE_HOURS", "1")
    # a 3600 s cadence, so polls 59 minutes apart are one normal interval
    poll(sconn, [], "2026-10-15T07:59:00Z", interval=3600)
    poll(sconn, [frame_conn("c1", A, 100, 0)], "2026-10-15T08:00:00Z",
         interval=3600)
    rollup(sconn, "2026-10-15T09:30:00Z", day=_UTC)
    poll(sconn, [frame_conn("c1", A, 400, 0)], "2026-10-15T08:59:00Z",
         interval=3600)
    rollup(sconn, "2026-10-15T10:30:00Z", day=_UTC)
    hour = sconn.execute(
        "SELECT up, samples, conns, peak_up FROM stats_hour").fetchone()
    assert tuple(hour) == (400, 2, 1, 300)


def test_the_poll_interval_is_recorded(sconn):
    poll(sconn, [frame_conn("c1", A, 1, 1)], "2026-10-15T12:00:00Z", interval=2)
    assert meta_get(sconn, "poll_interval_s") == "2"
    poll(sconn, [frame_conn("c1", A, 2, 2)], "2026-10-15T12:00:05Z", interval=5)
    assert meta_get(sconn, "poll_interval_s") == "5"


def test_a_gap_is_still_relative_to_the_interval(sconn):
    poll(sconn, [], "2026-10-15T12:00:00Z", interval=2)
    poll(sconn, [], "2026-10-15T12:00:05Z", interval=2)   # 5 s < 3 x 2 s
    assert sconn.execute("SELECT COUNT(*) FROM stats_gap").fetchone()[0] == 0
    poll(sconn, [], "2026-10-15T12:00:12Z", interval=2)   # 7 s > 6 s
    assert sconn.execute("SELECT COUNT(*) FROM stats_gap").fetchone()[0] == 1


# --- a peak is only ever a per-interval delta ------------------------------------

def test_the_first_poll_of_a_store_records_bytes_but_no_peak(sconn):
    # a long-lived connection the store never saw arrives with its lifetime
    # counters: they are real bytes, but not "bytes per interval"
    poll(sconn, [frame_conn("c1", A, 10 ** 9, 10 ** 9)], "2026-10-15T12:00:00Z")
    [row] = minute(sconn)
    assert (row["up"], row["down"]) == (10 ** 9, 10 ** 9)
    assert (row["samples"], row["conns"]) == (1, 1)
    assert (row["peak_up"], row["peak_down"]) == (0, 0)


def test_the_first_poll_after_a_hole_records_bytes_but_no_peak(sconn):
    poll(sconn, [frame_conn("c1", A, 1, 1)], "2026-10-15T12:00:00Z")
    poll(sconn, [frame_conn("c1", A, 6, 6)], "2026-10-15T12:00:02Z")   # +5, normal
    poll(sconn, [frame_conn("c1", A, 1806, 1806)], "2026-10-15T12:00:44Z")  # 42 s hole
    rows = sconn.execute(
        "SELECT bucket, up, peak_up FROM stats_minute_v5 ORDER BY bucket").fetchall()
    assert [tuple(r) for r in rows] == [("2026-10-15T12:00", 1806, 5)]
    assert sconn.execute("SELECT COUNT(*) FROM stats_gap").fetchone()[0] == 1
    # and the next normal poll measures again
    poll(sconn, [frame_conn("c1", A, 1816, 1816)], "2026-10-15T12:00:46Z")
    assert minute(sconn)[0]["peak_up"] == 10


def test_a_hole_exactly_at_the_threshold_is_still_a_normal_interval(sconn):
    # the peak rule and the gap row share one boundary: a hole of exactly
    # GAP_FACTOR x interval (6 s here) is measured and writes no gap row
    poll(sconn, [frame_conn("c1", A, 1, 1)], "2026-10-15T12:00:00Z")
    poll(sconn, [frame_conn("c1", A, 4, 4)], "2026-10-15T12:00:06Z")
    assert minute(sconn)[0]["peak_up"] == 3
    assert sconn.execute("SELECT COUNT(*) FROM stats_gap").fetchone()[0] == 0


def test_two_hours_of_one_day_roll_into_one_day_row_with_their_facts(sconn,
                                                                    monkeypatch):
    """The day tier's ON CONFLICT path: hours of one local day rolled in
    separate passes accumulate counts and keep the largest peak."""
    monkeypatch.setenv("PANEL_STATS_HOUR_DAYS", "1")
    sconn.execute(
        "INSERT INTO stats_hour (bucket, device, chain, up, down, samples, "
        "conns, peak_up, peak_down) VALUES "
        "('2026-10-12T08', ?, 'X', 100, 10, 3, 2, 40, 5)", (A,))
    rollup(sconn, "2026-10-13T09:30:00Z", day=_UTC)  # cut 09: rolls hour 08
    sconn.execute(
        "INSERT INTO stats_hour (bucket, device, chain, up, down, samples, "
        "conns, peak_up, peak_down) VALUES "
        "('2026-10-12T09', ?, 'X', 50, 20, 2, 1, 30, 9)", (A,))
    rollup(sconn, "2026-10-13T10:30:00Z", day=_UTC)  # cut 10: rolls hour 09, same day
    day = sconn.execute(
        "SELECT bucket, up, down, samples, conns, peak_up, peak_down "
        "FROM stats_day").fetchall()
    assert [tuple(r) for r in day] == [("2026-10-12", 150, 30, 5, 3, 40, 9)]


def test_a_clock_stepped_backwards_writes_no_peak(sconn):
    poll(sconn, [frame_conn("c1", A, 1, 1)], "2026-10-15T12:00:00Z")
    # the clock steps back an hour while the counters jump: real bytes, but
    # nothing says they took one interval
    poll(sconn, [frame_conn("c1", A, 10 ** 9, 10 ** 9)], "2026-10-15T11:00:00Z")
    rows = {r["bucket"]: (r["up"], r["peak_up"]) for r in sconn.execute(
        "SELECT bucket, up, peak_up FROM stats_minute_v5")}
    assert rows["2026-10-15T11:00"] == (10 ** 9 - 1, 0)


def test_a_duplicate_connection_id_in_one_snapshot_counts_once(sconn):
    poll(sconn, [], "2026-10-15T11:59:58Z")
    poll(sconn, [frame_conn("c1", A, 10, 10), frame_conn("c1", A, 30, 30)],
         "2026-10-15T12:00:00Z")
    [row] = minute(sconn)
    assert (row["up"], row["conns"]) == (10, 1)
    assert sconn.execute("SELECT up FROM conn_baseline").fetchone()[0] == 10


def test_non_ascii_names_round_trip_through_the_batched_upserts(sconn,
                                                               monkeypatch):
    monkeypatch.setenv("PANEL_STATS_DOMAINS", "true")
    chain = "\U0001F1EF\U0001F1F5 日本 Auto \"quoted\" \\ tab\t"
    host = "视频.example.com"
    rc = frame_conn("c1", A, 5, 7, chain=chain, host=host)
    rc["rulePayload"] = "geosite:\u4e2d\u6587"
    flush_poll(sconn, [rc], "2026-10-15T12:00:00Z", domains_enabled=True,
               gap_threshold_s=6, interval_s=2)
    assert sconn.execute("SELECT chain FROM stats_minute_v5").fetchone()[0] == chain
    assert sconn.execute("SELECT domain FROM stats_domain").fetchone()[0] == host
    assert sconn.execute(
        "SELECT rule_payload FROM stats_coverage").fetchone()[0] == "geosite:中文"
