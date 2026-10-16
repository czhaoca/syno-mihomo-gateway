"""Collector self-telemetry (#96): flat /health keys, the 7-day stats_self
gauge table behind /v1/stats/self, and the mihomo version / memory reads.

/health stays FLAT (the doctor reads it with a sed scalar extractor) and
carries counts and numbers only - never error text. "Not measured" is
`null` (or "" for the version), never an invented 0. The interval and the
cap the app is actually using travel with them (DEC-C), so the doctor and
the release validator compare numbers the app reports instead of parsing
the knobs a second time.
"""

import io
import json

import pytest
from app.collector.core import Collector
from app.mihomo_client import client as mihomo_client
from app.mihomo_client.client import MihomoClient, MihomoError
from app.store import dayframe
from app.store import stats as stats_store
from app.tests.conftest import auth_headers, conn_fixture
from fastapi.testclient import TestClient

A = "192.0.2.20"
_UTC = dayframe.utc_frame()

NEW_KEYS = {
    "collector_lag_s": (int, type(None)),
    "collector_poll_ms": (int, type(None)),
    "collector_conns": (int, type(None)),
    "collector_failed_polls": (int,),
    "stats_db_growth_mb_day": (float, int, type(None)),
    "mihomo_mem_mb": (int, type(None)),
    "mihomo_version": (str,),
    "collector_interval_s": (int,),
    "stats_cap_mb": (int,),
}


@pytest.fixture()
def sconn(panel_env):
    conn = stats_store.open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


class Clock:
    """A monotonic clock a test advances by hand."""

    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


# --- /health -------------------------------------------------------------------

def test_health_carries_every_new_key_flat_and_typed(client):
    health = client.get("/health").json()
    for key, types in NEW_KEYS.items():
        assert key in health, key
        assert isinstance(health[key], types), (key, health[key])
    # flat: no nested object anywhere the doctor's extractor cannot read
    assert not any(isinstance(v, dict | list) for v in health.values())


def test_health_reports_the_cadence_and_cap_the_app_is_using(panel_env,
                                                             fake_client,
                                                             notifier,
                                                             monkeypatch):
    from app.main import create_app
    monkeypatch.setenv("PANEL_STATS_CAP_MB", "64")
    with TestClient(create_app(mihomo_client=fake_client,
                               notifier=notifier)) as c:
        health = c.get("/health").json()
    # the conftest turns the loop off (PANEL_STATS_POLL_S=0)
    assert (health["collector_interval_s"], health["stats_cap_mb"]) == (0, 64)


def test_before_any_poll_nothing_is_invented(client):
    health = client.get("/health").json()
    assert health["collector_lag_s"] is None
    assert health["collector_poll_ms"] is None
    assert health["collector_conns"] is None
    assert health["collector_failed_polls"] == 0
    assert health["stats_db_growth_mb_day"] is None
    assert health["mihomo_mem_mb"] is None
    assert health["mihomo_version"] == ""


def test_health_after_polls(client, fake_client):
    collector = client.app.state.collector
    fake_client.conns = [conn_fixture("c1", A, 1, 1), conn_fixture("c2", A, 2, 2)]
    collector.poll_once()
    health = client.get("/health").json()
    assert health["collector_conns"] == 2
    assert isinstance(health["collector_poll_ms"], int)
    assert 0 <= health["collector_lag_s"] <= 5
    assert "secret" not in json.dumps(health).lower()


# --- the collector's counters ----------------------------------------------------

def test_a_failed_fetch_counts_and_keeps_the_last_good_numbers(sconn,
                                                               fake_client):
    col = Collector(client=fake_client, conn=sconn)
    fake_client.conns = [conn_fixture("c1", A, 1, 1)]
    col.poll_once(now="2026-10-15T12:00:00Z")
    fake_client.fail_connections = True
    col.poll_once(now="2026-10-15T12:00:02Z")
    col.poll_once(now="2026-10-15T12:00:04Z")
    assert col.status["failed_polls"] == 2
    assert col.status["conns"] == 1          # the last snapshot read
    assert col.status["last_poll_ts"] == "2026-10-15T12:00:00Z"


def test_poll_ms_is_the_mean_of_the_last_thirty_successful_polls(sconn,
                                                                 fake_client):
    clock = Clock()
    col = Collector(client=fake_client, conn=sconn, clock=clock)
    real = fake_client.connections

    def slow(ms):
        def fetch():
            clock.now += ms / 1000
            return real()
        return fetch

    for i in range(30):
        fake_client.connections = slow(1000)       # 30 slow polls
        col.poll_once(now=f"2026-10-15T12:00:{i:02d}Z")
    assert col.status["poll_ms"] == 1000
    for i in range(30):
        fake_client.connections = slow(10)         # then 30 fast ones
        col.poll_once(now=f"2026-10-15T12:01:{i:02d}Z")
    assert col.status["poll_ms"] == 10             # the slow ones aged out
    fake_client.connections = slow(5000)
    col.poll_once(now="2026-10-15T12:02:00Z")      # one spike moves it a little
    assert col.status["poll_ms"] == round((29 * 10 + 5000) / 30)


def test_a_failed_poll_does_not_enter_the_timing(sconn, fake_client):
    clock = Clock()
    col = Collector(client=fake_client, conn=sconn, clock=clock)

    def hang():
        clock.now += 10
        raise MihomoError("GET /connections failed: timed out")

    fake_client.connections = hang
    col.poll_once(now="2026-10-15T12:00:00Z")
    assert col.status["poll_ms"] is None
    assert col.status["failed_polls"] == 1


# --- mihomo version and memory ---------------------------------------------------

def test_sampling_mihomo_records_version_and_memory(sconn, fake_client):
    col = Collector(client=fake_client, conn=sconn)
    fake_client.version_text = "v1.19.32"
    fake_client.mem_bytes = 143716352
    col.sample_mihomo()
    assert col.status["mihomo_version"] == "v1.19.32"
    assert col.status["mihomo_mem_mb"] == 137


def test_an_unreachable_mihomo_keeps_the_version_but_not_the_memory(
        sconn, fake_client):
    col = Collector(client=fake_client, conn=sconn)
    fake_client.version_text = "v1.19.32"
    fake_client.mem_bytes = 143716352
    col.sample_mihomo()
    fake_client.fail_meta = True
    col.sample_mihomo()
    # a restarting mihomo is still the same build; an old memory figure
    # would pass for a current one
    assert col.status["mihomo_version"] == "v1.19.32"
    assert col.status["mihomo_mem_mb"] is None
    assert col.status["last_error"] is None   # telemetry never marks a poll


def test_a_never_reached_mihomo_has_no_version(sconn, fake_client):
    col = Collector(client=fake_client, conn=sconn)
    fake_client.fail_meta = True
    col.sample_mihomo()
    assert col.status["mihomo_version"] == ""


def test_a_hung_controller_never_delays_a_poll(panel_env, sconn, fake_client):
    """The loop samples mihomo on a side thread: a /memory read that hangs
    must not hold up the next poll (a late poll becomes a gap row)."""
    import threading
    import time

    from app.collector.core import CollectorLoop
    release = threading.Event()

    def hang():
        release.wait(5)
        return None

    fake_client.memory_inuse = hang
    col = Collector(client=fake_client, conn=sconn)
    loop = CollectorLoop(col, threading.RLock(), interval_s=1)
    loop.start()
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and col.status["last_poll_ts"] is None:
            time.sleep(0.05)
        assert col.status["last_poll_ts"] is not None, "the poll waited on /memory"
    finally:
        release.set()
        loop.stop()


def test_growth_is_known_right_after_a_restart(sconn, fake_client):
    from datetime import UTC, datetime, timedelta
    now = datetime.now(UTC)
    for back, size in ((120, 10 * 1048576), (0, 11 * 1048576)):
        stats_store.record_self(
            sconn, (now - timedelta(minutes=back)).strftime("%Y-%m-%dT%H:%M"),
            {"db_bytes": size})
    col = Collector(client=fake_client, conn=sconn)
    assert col.status["db_growth_mb_day"] == 12.0


def test_the_telemetry_reads_use_the_short_timeout(monkeypatch):
    seen = []
    monkeypatch.setattr(mihomo_client.urllib.request, "urlopen",
                        lambda req, timeout: seen.append(timeout) or _Stream(
                            [{"inuse": 5}]))
    MihomoClient("http://127.0.0.1:9").memory_inuse()
    assert seen == [mihomo_client.TELEMETRY_TIMEOUT_S]
    assert mihomo_client.TELEMETRY_TIMEOUT_S < mihomo_client.TIMEOUT_S


class _Stream:
    """A never-ending /memory stream: frames as lines, then it would block."""

    def __init__(self, frames):
        self.buf = io.BytesIO(b"".join(
            json.dumps(f).encode() + b"\n" for f in frames))
        self.reads = 0

    def readline(self, limit=-1):
        self.reads += 1
        line = self.buf.readline(limit)
        if not line:
            raise TimeoutError("the stream would block here")
        return line

    def read(self, *a):
        raise AssertionError("a stream must never be read to the end")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_memory_skips_the_zero_first_frame(monkeypatch):
    stream = _Stream([{"inuse": 0, "oslimit": 0},
                      {"inuse": 150000000, "oslimit": 0},
                      {"inuse": 160000000, "oslimit": 0}])
    monkeypatch.setattr(mihomo_client.urllib.request, "urlopen",
                        lambda req, timeout: stream)
    assert MihomoClient("http://127.0.0.1:9").memory_inuse() == 150000000
    assert stream.reads == 2


def test_memory_gives_up_after_a_few_zero_frames(monkeypatch):
    stream = _Stream([{"inuse": 0}] * 10)
    monkeypatch.setattr(mihomo_client.urllib.request, "urlopen",
                        lambda req, timeout: stream)
    assert MihomoClient("http://127.0.0.1:9").memory_inuse() is None
    assert stream.reads <= 3


def test_memory_and_version_failures_raise_mihomo_errors(monkeypatch):
    monkeypatch.setattr(mihomo_client.urllib.request, "urlopen",
                        lambda req, timeout: _Stream([]))
    with pytest.raises(MihomoError):
        MihomoClient("http://127.0.0.1:9").memory_inuse()


@pytest.mark.parametrize("raw, shown", [
    ({"version": "v1.19.32", "meta": True}, "v1.19.32"),
    ({"version": "alpha-g1a2b3c4"}, "alpha-g1a2b3c4"),
    # whatever comes back, the doctor's extractor must be able to read it
    ({"version": 'v1,"2"} <x>'}, "v12x"),
    ({"version": "v" * 200}, "v" * 64),
    ({"meta": True}, ""),
])
def test_the_version_is_sanitised(monkeypatch, raw, shown):
    monkeypatch.setattr(MihomoClient, "_request",
                        lambda self, method, path, timeout=10:
                        json.dumps(raw).encode())
    assert MihomoClient("http://127.0.0.1:9").version() == shown


# --- the stats_self gauge table --------------------------------------------------

def _sample(col, now):
    col.maintain(now=now, day=_UTC)


def test_every_maintenance_pass_records_a_sample(sconn, fake_client):
    col = Collector(client=fake_client, conn=sconn)
    fake_client.conns = [conn_fixture("c1", A, 1, 1)]
    col.poll_once(now="2026-10-15T12:00:00Z")
    fake_client.version_text, fake_client.mem_bytes = "v1.19.32", 143716352
    col.sample_mihomo()
    _sample(col, "2026-10-15T12:00:30Z")
    rows = stats_store.read_self(sconn)
    assert len(rows) == 1
    row = rows[0]
    assert row["bucket"] == "2026-10-15T12:00"
    assert row["conns"] == 1 and row["failed_polls"] == 0
    assert row["mihomo_mem_mb"] == 137
    assert row["db_bytes"] > 0
    assert row["lag_s"] == 30


def test_the_growth_rate_needs_an_hour_of_samples(sconn):
    for bucket, size in (("2026-10-15T00:00", 10 * 1048576),
                         ("2026-10-15T00:30", 11 * 1048576)):
        stats_store.record_self(sconn, bucket, {"db_bytes": size})
    assert stats_store.self_growth_mb_day(sconn, "2026-10-15T00:30") is None
    stats_store.record_self(sconn, "2026-10-15T12:00", {"db_bytes": 16 * 1048576})
    # 6 MB over 12 h -> 12 MB per day
    assert stats_store.self_growth_mb_day(sconn, "2026-10-15T12:00") == 12.0


def test_the_growth_rate_reads_the_last_day_only(sconn):
    stats_store.record_self(sconn, "2026-10-10T00:00", {"db_bytes": 0})
    stats_store.record_self(sconn, "2026-10-15T00:00", {"db_bytes": 100 * 1048576})
    stats_store.record_self(sconn, "2026-10-15T06:00", {"db_bytes": 101 * 1048576})
    assert stats_store.self_growth_mb_day(sconn, "2026-10-15T06:00") == 4.0


def test_the_gauges_keep_seven_days(sconn):
    stats_store.record_self(sconn, "2026-10-01T10:00", {"db_bytes": 1})
    stats_store.record_self(sconn, "2026-10-14T10:00", {"db_bytes": 2})
    stats_store.rollup(sconn, "2026-10-15T12:00:00Z", day=_UTC)
    assert [r["bucket"] for r in stats_store.read_self(sconn)] == [
        "2026-10-14T10:00"]


def test_the_gauges_are_purged_capped_and_have_no_device(sconn):
    assert "stats_self" in stats_store.PURGE_TABLES
    assert any(e[1] == "stats_self" for e in stats_store._CAP_TIERS)
    stats_store.record_self(sconn, "2026-10-14T10:00", {"db_bytes": 2})
    # a device-scoped purge leaves device-less tables alone instead of failing
    stats_store.purge_stats(sconn, device=A)
    assert len(stats_store.read_self(sconn)) == 1
    stats_store.purge_stats(sconn)
    assert stats_store.read_self(sconn) == []


def test_the_self_endpoint_serves_the_timeline(client, panel_env):
    conn = client.app.state.stats_conn
    stats_store.record_self(conn, "2026-10-14T10:00",
                            {"db_bytes": 2048, "poll_ms": 12, "conns": 3})
    stats_store.record_self(conn, "2026-10-14T10:01", {"db_bytes": 4096})
    body = client.get("/v1/stats/self").json()
    assert body["retention_days"] == 7
    assert [r["bucket"] for r in body["rows"]] == ["2026-10-14T10:00",
                                                   "2026-10-14T10:01"]
    assert body["rows"][0]["poll_ms"] == 12
    assert body["rows"][1]["poll_ms"] is None    # not measured, not 0
    since = client.get("/v1/stats/self",
                       params={"since": "2026-10-14T10:01"}).json()
    assert [r["bucket"] for r in since["rows"]] == ["2026-10-14T10:01"]


def test_a_scoped_purge_of_the_gauges_works_over_the_api(client, panel_env):
    stats_store.record_self(client.app.state.stats_conn, "2026-10-14T10:00",
                            {"db_bytes": 1})
    r = client.post("/v1/stats/purge", json={"tables": ["stats_self"]},
                    headers=auth_headers(panel_env))
    assert r.status_code == 200, r.text
    assert r.json()["rows"] == {"stats_self": 1}
