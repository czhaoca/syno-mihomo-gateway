"""Window-complete stats reads (#91): `range=` presets and `tier` as resolution.

The bug this pins: rollup MOVES rows (minute -> hour -> day, deleting the
source), and the shipped reads each touch ONE tier table. So a 7-day view
read `tier=hour` and silently lost the newest 48 hours (still in minute),
and "daily" read only the day tier, which holds nothing younger than 90
days. A `range=` read unions the requested resolution's tier with every
FINER tier, which hold the newer tail.

Two named invariants (docs/brainstorms/gateway-insights.md):
  I-1  any window total == the bytes whose resolution key falls in the
       window, whatever the rollup state - the read cannot tell a row that
       was rolled from one that was not;
  I-2  rollup is lossless: the bytes summed over all tiers are the same
       before and after any rollup, at any `now`.

Requests that carry only `tier` keep the single-table answer byte for byte
(acceptance criterion) - the window-complete union is opt-in through
`range`, which is what the panel UI now sends.

All addresses are TEST-NET (192.0.2.0/24); clocks are pinned.
"""

import json
import threading
import time
from datetime import UTC, datetime, timedelta
from typing import get_args
from uuid import uuid4

import pytest
from app.api import routes
from app.store import dayframe
from app.store import settings as settings_store
from app.store import stats as stats_store
from app.tests.conftest import auth_headers
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

NOW = datetime(2026, 10, 15, 12, 0, tzinfo=UTC)
A, B = "192.0.2.20", "192.0.2.21"
_UTC = dayframe.utc_frame()


def put(conn, table, bucket, device=A, chain="Routing Mode", up=1, down=10,
        stamp=None):
    if table == "stats_day":
        tz, cut = stamp or ("UTC", "00:00")
        conn.execute(
            "INSERT INTO stats_day (bucket, device, chain, up, down, "
            "bucket_tz, day_boundary) VALUES (?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(bucket, device, chain, bucket_tz, day_boundary) "
            "DO UPDATE SET up = up + excluded.up, down = down + excluded.down",
            (bucket, device, chain, up, down, tz, cut))
        return
    conn.execute(
        f"INSERT INTO {table} (bucket, device, chain, up, down) "
        f"VALUES (?, ?, ?, ?, ?) ON CONFLICT(bucket, device, chain) "
        f"DO UPDATE SET up = up + excluded.up, down = down + excluded.down",
        (bucket, device, chain, up, down))


@pytest.fixture()
def sconn(panel_env):
    conn = stats_store.open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


def seed_three_tiers(conn):
    """One device's history spread the way a live store holds it:
    minute rows inside the last 48 h, hour rows between 48 h and 90 d,
    day rows older than 90 d - plus a second device in the newest tail."""
    put(conn, "stats_minute", "2026-10-15T11:58", up=1, down=10)
    put(conn, "stats_minute", "2026-10-14T09:30", up=2, down=20)
    put(conn, "stats_minute", "2026-10-15T11:59", device=B, up=5, down=50)
    put(conn, "stats_hour", "2026-10-12T08", up=100, down=1000)       # 3 d
    put(conn, "stats_hour", "2026-09-20T23", up=200, down=2000)       # 25 d
    put(conn, "stats_hour", "2026-08-01T00", up=400, down=4000)       # 75 d
    put(conn, "stats_day", "2026-06-01", up=7000, down=70000)          # 136 d
    conn.commit() if conn.in_transaction else None


@pytest.fixture()
def pinned_clock(monkeypatch):
    monkeypatch.setattr(routes, "_utcnow", lambda: NOW)


def _rows(resp):
    assert resp.status_code == 200, resp.text
    return {r["device"]: (r["up"], r["down"]) for r in resp.json()["rows"]}


# --- the regression: a 7-day window includes the newest 48 hours ----------------

def test_7d_includes_the_newest_48h_that_tier_hour_drops(client, panel_env,
                                                          sconn, pinned_clock):
    seed_three_tiers(sconn)
    # what the shipped UI asked for: tier=hour since 7 days ago
    legacy = _rows(client.get("/v1/stats/devices",
                              params={"tier": "hour", "since": "2026-10-08T12"}))
    assert legacy == {A: (100, 1000)}, "the pre-fix read misses the 48 h tail"
    fixed = _rows(client.get("/v1/stats/devices", params={"range": "7d"}))
    assert fixed == {A: (103, 1030), B: (5, 50)}


def test_30d_spans_minute_and_hour_tiers(client, panel_env, sconn,
                                         pinned_clock):
    seed_three_tiers(sconn)
    got = _rows(client.get("/v1/stats/devices", params={"range": "30d"}))
    assert got == {A: (303, 3030), B: (5, 50)}


def test_48h_is_the_minute_tier(client, panel_env, sconn, pinned_clock):
    seed_three_tiers(sconn)
    # a minute row OLDER than the window that has not been rolled yet (a
    # minute retention above 48 h keeps it there): only the window bound
    # keeps it out of the 48 h answer
    put(sconn, "stats_minute", "2026-10-13T10:00", up=1000, down=1000)
    got = _rows(client.get("/v1/stats/devices", params={"range": "48h"}))
    assert got == {A: (3, 30), B: (5, 50)}
    assert client.get("/v1/stats/devices",
                      params={"range": "48h"}).json()["tier"] == "minute"


def test_daily_includes_everything_with_the_frame_reported(client, panel_env,
                                                           sconn,
                                                           pinned_clock):
    seed_three_tiers(sconn)
    r = client.put("/v1/settings",
                   json={"values": {"timezone": "Asia/Shanghai",
                                    "day_boundary": "03:00"}},
                   headers=auth_headers(panel_env))
    assert r.status_code == 200, r.text
    body = client.get("/v1/stats/devices", params={"range": "daily"}).json()
    assert body["tier"] == "day"
    assert {r["device"]: (r["up"], r["down"]) for r in body["rows"]} == {
        A: (7703, 77030), B: (5, 50)}
    # the stored day row keeps its own framing; the not-yet-rolled tail is
    # keyed under the CURRENT one - both are reported, so the seam is visible
    assert body["framings"] == [
        {"bucket_tz": "Asia/Shanghai", "day_boundary": "03:00"},
        {"bucket_tz": "UTC", "day_boundary": "00:00"}]


def test_chains_follow_the_same_window(client, panel_env, sconn, pinned_clock):
    seed_three_tiers(sconn)
    put(sconn, "stats_minute", "2026-10-15T10:00", chain="Full-Tunnel Devices",
        up=9, down=90)
    rows = client.get("/v1/stats/chains", params={"range": "7d"}).json()["rows"]
    assert {r["chain"]: (r["up"], r["down"]) for r in rows} == {
        "Full-Tunnel Devices": (9, 90), "Routing Mode": (108, 1080)}


def test_timeline_7d_is_hourly_and_continuous(client, panel_env, sconn,
                                              pinned_clock):
    seed_three_tiers(sconn)
    # a minute row in an hour that ALSO has a rolled hour row: one bucket
    put(sconn, "stats_hour", "2026-10-15T11", up=1000, down=1)
    rows = client.get("/v1/stats/timeline",
                      params={"range": "7d"}).json()["rows"]
    assert rows == [
        {"bucket": "2026-10-12T08", "up": 100, "down": 1000},
        {"bucket": "2026-10-14T09", "up": 2, "down": 20},
        {"bucket": "2026-10-15T11", "up": 1006, "down": 61},
    ]


def test_timeline_daily_synthesises_local_days_for_the_unrolled_tail(
        client, panel_env, sconn, pinned_clock):
    seed_three_tiers(sconn)
    client.put("/v1/settings",
               json={"values": {"timezone": "Asia/Shanghai",
                                "day_boundary": "03:00"}},
               headers=auth_headers(panel_env))
    rows = client.get("/v1/stats/timeline", params={"range": "daily",
                                                    "device": A}).json()["rows"]
    # 2026-10-15T11 UTC = 19:00 Shanghai -> local day 10-15 (cut 03:00);
    # 2026-10-14T09 UTC = 17:00 -> 10-14; 2026-10-12T08 = 16:00 -> 10-12;
    # 2026-09-20T23 UTC = 09-21 07:00 -> 09-21; 2026-08-01T00 = 08:00 -> 08-01
    assert rows == [
        {"bucket": "2026-06-01", "bucket_tz": "UTC", "day_boundary": "00:00",
         "up": 7000, "down": 70000},
        {"bucket": "2026-08-01", "bucket_tz": "Asia/Shanghai",
         "day_boundary": "03:00", "up": 400, "down": 4000},
        {"bucket": "2026-09-21", "bucket_tz": "Asia/Shanghai",
         "day_boundary": "03:00", "up": 200, "down": 2000},
        {"bucket": "2026-10-12", "bucket_tz": "Asia/Shanghai",
         "day_boundary": "03:00", "up": 100, "down": 1000},
        {"bucket": "2026-10-14", "bucket_tz": "Asia/Shanghai",
         "day_boundary": "03:00", "up": 2, "down": 20},
        {"bucket": "2026-10-15", "bucket_tz": "Asia/Shanghai",
         "day_boundary": "03:00", "up": 1, "down": 10},
    ]


def test_a_synthesised_day_merges_with_a_rolled_day_of_the_same_frame(sconn):
    # half a local day already rolled (stamped UTC/00:00), the other half
    # still in the hour tier: ONE row, not two
    put(sconn, "stats_day", "2026-07-01", up=1, down=1)
    put(sconn, "stats_hour", "2026-07-01T20", up=2, down=2)
    rows = stats_store.read_window_timeline(sconn, "day", "", None, _UTC)
    assert rows == [{"bucket": "2026-07-01", "bucket_tz": "UTC",
                     "day_boundary": "00:00", "up": 3, "down": 3}]


# --- parameters: tier overrides resolution; range is exclusive of since ---------

def test_an_explicit_tier_sets_the_resolution_of_a_range_read(
        client, panel_env, sconn, pinned_clock):
    seed_three_tiers(sconn)
    body = client.get("/v1/stats/timeline",
                      params={"range": "7d", "tier": "day"}).json()
    assert body["tier"] == "day"
    assert {r["bucket"] for r in body["rows"]} == {
        "2026-10-12", "2026-10-14", "2026-10-15"}


def test_range_with_since_or_until_is_refused(client, panel_env, pinned_clock):
    for extra in ({"since": "2026-10-01"}, {"until": "2026-10-01"}):
        for path in ("/v1/stats/devices", "/v1/stats/chains",
                     "/v1/stats/timeline"):
            r = client.get(path, params={"range": "7d", **extra})
            assert r.status_code == 422, (path, extra, r.text)
            assert "range" in r.text


def test_an_empty_since_or_until_beside_range_is_still_refused(client,
                                                               panel_env):
    # presence, not value: an empty `since=` is still a second way of naming
    # the window
    for extra in ({"since": ""}, {"until": ""}):
        r = client.get("/v1/stats/devices", params={"range": "7d", **extra})
        assert r.status_code == 422, (extra, r.text)


def test_minute_and_hour_range_reads_do_not_wait_on_the_policy_mutex(
        client, panel_env, sconn, pinned_clock):
    """Only a day-resolution read needs the framing, which lives in
    policy.db behind the POLICY mutex - and a policy change holds that mutex
    across its mihomo controller calls. The landing 7d view must not stall
    behind an apply in flight."""
    seed_three_tiers(sconn)
    held, release = threading.Event(), threading.Event()

    def hold():
        with client.app.state.mutex:
            held.set()
            release.wait(5)

    holder = threading.Thread(target=hold)
    holder.start()
    try:
        assert held.wait(5)
        for rng in ("48h", "7d", "30d"):
            start = time.monotonic()
            r = client.get("/v1/stats/devices", params={"range": rng})
            assert r.status_code == 200
            assert time.monotonic() - start < 1.0, f"{rng} waited on the mutex"
    finally:
        release.set()
        holder.join(5)


def test_an_unknown_range_is_refused(client, panel_env):
    assert client.get("/v1/stats/devices",
                      params={"range": "90d"}).status_code == 422


def test_the_server_range_vocabulary_is_the_settings_list():
    # one list: the UI selector, the stored default and the server presets
    assert get_args(routes.StatsRange) == settings_store.STATS_RANGES
    assert tuple(stats_store.RANGE_SPECS) == settings_store.STATS_RANGES


# --- tier-only reads are unchanged, byte for byte -------------------------------

def _wire(body) -> bytes:
    # the exact bytes FastAPI's JSONResponse renders (compact separators)
    return json.dumps(body, ensure_ascii=False, allow_nan=False,
                      separators=(",", ":")).encode()


@pytest.mark.parametrize("path, params, body", [
    ("/v1/stats/devices", {"tier": "hour"},
     {"tier": "hour", "rows": [{"device": A, "up": 700, "down": 7000}]}),
    ("/v1/stats/devices", {},
     {"tier": "minute", "rows": [{"device": A, "up": 3, "down": 30},
                                 {"device": B, "up": 5, "down": 50}]}),
    ("/v1/stats/devices", {"tier": "day"},
     {"tier": "day", "rows": [{"device": A, "up": 7000, "down": 70000}],
      "framings": [{"bucket_tz": "UTC", "day_boundary": "00:00"}]}),
    ("/v1/stats/devices", {"tier": "hour", "since": "2026-10-08T12"},
     {"tier": "hour", "rows": [{"device": A, "up": 100, "down": 1000}]}),
    ("/v1/stats/chains", {"tier": "hour"},
     {"tier": "hour", "rows": [{"chain": "Routing Mode", "up": 700,
                                "down": 7000}]}),
    ("/v1/stats/timeline", {"tier": "hour"},
     {"tier": "hour", "device": "",
      "rows": [{"bucket": "2026-08-01T00", "up": 400, "down": 4000},
               {"bucket": "2026-09-20T23", "up": 200, "down": 2000},
               {"bucket": "2026-10-12T08", "up": 100, "down": 1000}]}),
    ("/v1/stats/timeline", {"tier": "day", "device": A},
     {"tier": "day", "device": A,
      "rows": [{"bucket": "2026-06-01", "bucket_tz": "UTC",
                "day_boundary": "00:00", "up": 7000, "down": 70000}]}),
    ("/v1/stats/timeline", {"tier": "minute", "until": "2026-10-14T23:59"},
     {"tier": "minute", "device": "",
      "rows": [{"bucket": "2026-10-14T09:30", "up": 2, "down": 20}]}),
])
def test_tier_only_reads_return_exactly_what_they_did_before(
        client, panel_env, sconn, path, params, body):
    """Byte for byte: a request that does not send `range` reads the one
    tier table it always read (literals checked against v1.10.2's output on
    the same seed)."""
    seed_three_tiers(sconn)
    r = client.get(path, params=params)
    assert r.status_code == 200
    assert r.content == _wire(body)


# --- the invariants -----------------------------------------------------------

_FRAMES = {"UTC 00:00": ("UTC", "00:00"),
           "Shanghai 03:00": ("Asia/Shanghai", "03:00"),
           "Denver 00:00": ("America/Denver", "00:00"),
           # a half-hour offset: local hour boundaries are NOT UTC hour
           # boundaries, so the bounded day windows below have to find the
           # first local day of the window from where each UTC hour starts
           "Kolkata 05:00": ("Asia/Kolkata", "05:00"),
           "Lord Howe 00:00": ("Australia/Lord_Howe", "00:00")}

# Read clocks chosen so ~100 days of history cross DST transitions: US
# spring-forward (2026-03-08), US fall-back (2026-11-01), Lord Howe's
# half-hour fall-back (2026-04-05).
_NOWS = (NOW, datetime(2026, 3, 9, 12, tzinfo=UTC),
         datetime(2026, 11, 2, 7, tzinfo=UTC),
         datetime(2026, 4, 6, 0, 30, tzinfo=UTC))

# up to ~100 days of history, at minute granularity
_minutes = st.integers(min_value=0, max_value=100 * 24 * 60)
_event = st.tuples(_minutes, st.sampled_from([A, B]),
                   st.integers(min_value=0, max_value=1000),
                   st.integers(min_value=0, max_value=1000))


def _fresh(panel_env, name):
    # a UNIQUE file per hypothesis example: unlinking a closed database can
    # leave a -wal sidecar behind that SQLite would replay into a new file
    # of the same name
    path = panel_env["data"] / "state" / f"{name}-{uuid4().hex}.db"
    path.parent.mkdir(parents=True, exist_ok=True)
    return stats_store.open_stats_db(path)


def _load(conn, events, now=NOW):
    for back, device, up, down in events:
        ts = now - timedelta(minutes=back)
        put(conn, "stats_minute", ts.strftime("%Y-%m-%dT%H:%M"),
            device=device, up=up, down=down)


def _all_bytes(conn):
    total = 0
    for table in ("stats_minute", "stats_hour", "stats_day"):
        total += conn.execute(
            f"SELECT COALESCE(SUM(up + down), 0) FROM {table}").fetchone()[0]
    return total


def _stamp(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


_SETTINGS = settings(max_examples=40, deadline=None,
                     suppress_health_check=[HealthCheck.function_scoped_fixture])


@_SETTINGS
@given(events=st.lists(_event, max_size=40),
       rollups=st.lists(st.integers(min_value=0, max_value=100 * 24 * 60),
                        max_size=4),
       frame_name=st.sampled_from(sorted(_FRAMES)),
       now=st.sampled_from(_NOWS))
def test_I2_rollup_is_lossless_at_any_now(panel_env, events, rollups,
                                         frame_name, now):
    conn = _fresh(panel_env, "i2")
    try:
        _load(conn, events, now)
        before = _all_bytes(conn)
        frame = dayframe.resolve(*_FRAMES[frame_name])
        # rollups run forward in time, ending at NOW at the latest
        for back in sorted(rollups, reverse=True):
            stats_store.rollup(conn, _stamp(now - timedelta(minutes=back)),
                               day=frame)
            assert _all_bytes(conn) == before
    finally:
        conn.close()


def _expected(events, resolution, since, frame, now):
    if since is None:
        return sum(up + down for _, _, up, down in events)
    want = stats_store.window_key(since, resolution, frame)
    total = 0
    for back, _, up, down in events:
        ts = now - timedelta(minutes=back)
        if stats_store.window_key(ts, resolution, frame) >= want:
            total += up + down
    return total


@_SETTINGS
@given(events=st.lists(_event, max_size=40),
       rollups=st.lists(st.integers(min_value=0, max_value=3 * 24 * 60),
                        min_size=1, max_size=3),
       range_name=st.sampled_from(settings_store.STATS_RANGES),
       as_days=st.booleans(),
       hour_days=st.sampled_from([1, 3, 90]),
       frame_name=st.sampled_from(sorted(_FRAMES)),
       now=st.sampled_from(_NOWS))
def test_I1_a_window_total_is_independent_of_rollup_state(
        panel_env, monkeypatch, events, rollups, range_name, as_days,
        hour_days, frame_name, now):
    """I-1, in its strong form: the window read of a store that was rolled
    up any number of times is IDENTICAL - per device, per bucket, per stamp,
    and in its framings - to the read of the same bytes never rolled, and
    its total is the bytes whose resolution key falls inside the window.

    `as_days` reads the preset at DAY resolution (an explicit `tier=day`),
    which is the only bounded window that has to find a window's first
    local day; a small hour retention then puts rolled day rows INSIDE that
    window, next to synthesised ones."""
    frame = dayframe.resolve(*_FRAMES[frame_name])
    resolution, since = stats_store.range_window(range_name, now)
    if as_days:
        resolution = "day"
    else:
        # a minute/hour read covers the resolution tier's retention only,
        # so it is checked under the shipped retention. Events older than
        # the window stay IN the sample on purpose: unrolled they sit in the
        # tier the read covers and only the window bound excludes them - the
        # bound a 48 h read would otherwise never be tested on.
        hour_days = 90
    monkeypatch.setenv("PANEL_STATS_HOUR_DAYS", str(hour_days))
    if resolution == "day":
        monkeypatch.setenv("PANEL_STATS_MINUTE_HOURS", "1")
    else:
        monkeypatch.delenv("PANEL_STATS_MINUTE_HOURS", raising=False)
    expected = _expected(events, resolution, since, frame, now)
    raw = _fresh(panel_env, "i1raw")
    rolled = _fresh(panel_env, "i1rolled")
    try:
        _load(raw, events, now)
        _load(rolled, events, now)
        for back in sorted(rollups, reverse=True):
            stats_store.rollup(rolled, _stamp(now - timedelta(minutes=back)),
                               day=frame)
        reads = []
        for conn in (raw, rolled):
            rows = stats_store.read_window_grouped(conn, resolution, "device",
                                                   since, frame)
            line = stats_store.read_window_timeline(conn, resolution, "",
                                                    since, frame)
            assert sum(r["up"] + r["down"] for r in rows) == expected
            assert sum(r["up"] + r["down"] for r in line) == expected
            framings = (stats_store.window_framings(conn, since, frame)
                        if resolution == "day" else None)
            reads.append((rows, line, framings))
        assert reads[0] == reads[1], "the read can tell rolled rows apart"
    finally:
        raw.close()
        rolled.close()
