"""The sampler (#102): the selected node's delay per group and the
subscription quota, read passively from the fake controller on an injected
clock - never a sleep. Synthesised names only (TEST-NET, example.com)."""

import threading

import pytest
from app.collector.sampler import DELAY_EVERY_S, QUOTA_EVERY_S, Sampler
from app.store import stats as stats_store
from app.store.stats import open_stats_db
from app.tests.conftest import FakeMihomoClient

SECRET_URL = "https://sub.example.com/link/planted-subscription-token"


@pytest.fixture()
def sconn(panel_env):
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


@pytest.fixture()
def fake(panel_env):
    client = FakeMihomoClient(panel_env["providers"])
    client.groups_doc = [
        # GLOBAL selecting a real member: skipped as a group, not by its pick
        {"name": "GLOBAL", "type": "Selector", "now": "Auto"},
        {"name": "Proxy", "type": "Selector", "now": "Auto"},
        {"name": "Auto", "type": "URLTest", "now": "JP 01"},
        {"name": "Fallback", "type": "Fallback", "now": "COMPATIBLE"},
        {"name": "Manual", "type": "Selector", "now": "US 01"},
    ]
    client.histories = {
        "Auto": [{"time": "2026-10-16T20:00:01.123456789+08:00", "delay": 41}],
        "JP 01": [{"time": "2026-10-16T11:55:00Z", "delay": 38},
                  {"time": "2026-10-16T12:00:00.5Z", "delay": 40}],
        "US 01": [{"time": "2026-10-16T12:00:00Z", "delay": 0}],
        "DIRECT": [{"time": "2026-10-16T12:00:00Z", "delay": 1}],
    }
    client.providers_doc = {
        "my-airport": {
            "name": "my-airport", "type": "Proxy", "vehicleType": "HTTP",
            "updatedAt": "2026-10-16T19:30:00.25+08:00", "url": SECRET_URL,
            "testUrl": "https://probe.example.com/generate_204",
            "proxies": [{"name": "JP 01", "server": "192.0.2.80", "port": 443}],
            "subscriptionInfo": {"Upload": 1024, "Download": 4096,
                                 "Total": 0, "Expire": 0}},
        "spare": {"name": "spare", "vehicleType": "HTTP",
                  "updatedAt": "0001-01-01T00:00:00Z",
                  "subscriptionInfo": {"upload": 5, "download": 6,
                                       "total": 100, "expire": 1790000000}},
        "default": {"name": "default", "vehicleType": "Compatible",
                    "proxies": []},
    }
    return client


def sampler(fake, sconn, clock=None):
    return Sampler(client=fake, conn=sconn, lock=threading.RLock(),
                   clock=clock or Clock())


def rows_of(conn):
    return [tuple(r) for r in conn.execute(
        "SELECT tested_at, grp, node, delay_ms FROM stats_node_delay ORDER BY grp")]


# --- node delay ------------------------------------------------------------------

def test_the_selected_node_s_newest_test_is_stored_as_given(fake, sconn):
    assert sampler(fake, sconn).sample_delays("2026-10-16T12:00:05Z")
    assert rows_of(sconn) == [
        # nanoseconds and an offset, normalised to the panel's UTC stamp
        ("2026-10-16T12:00:00Z", "Auto", "JP 01", 40),
        # a failed test (delay 0) is no answer, never 0 ms
        ("2026-10-16T12:00:00Z", "Manual", "US 01", None),
        # a group selecting a group: that group's own history, no recursion
        ("2026-10-16T12:00:01Z", "Proxy", "Auto", 41),
    ]
    # GLOBAL is skipped; a COMPATIBLE placeholder has no history, so no row


def test_resampling_without_a_new_test_adds_nothing(fake, sconn):
    s = sampler(fake, sconn)
    s.sample_delays()
    s.sample_delays()
    assert len(rows_of(sconn)) == 3
    fake.histories["JP 01"].append({"time": "2026-10-16T12:05:00Z", "delay": 39})
    s.sample_delays()
    assert len(rows_of(sconn)) == 4


@pytest.mark.parametrize("entry", [{"time": "yesterday", "delay": 40},
                                   {"time": None, "delay": 40},
                                   {"time": "9999-12-31T23:59:59-05:00", "delay": 40},
                                   {"time": "2026-02-30T00:00:00Z", "delay": 40},
                                   {"delay": 40}])
def test_a_test_without_a_readable_time_is_skipped(fake, sconn, entry):
    fake.groups_doc = [{"name": "Auto", "now": "JP 01"}]
    fake.histories = {"JP 01": [entry]}
    sampler(fake, sconn).sample_delays()
    assert rows_of(sconn) == []


def test_every_history_lookup_failing_is_no_sample(fake, sconn, monkeypatch):
    def broken(_name):
        raise RuntimeError("down")
    monkeypatch.setattr(fake, "proxy_history", broken)
    s = sampler(fake, sconn)
    assert s.sample_delays() is False and s.status["delay_state"] == "error"


def test_an_extreme_provider_time_never_aborts_the_quota(fake, sconn):
    fake.providers_doc["my-airport"]["updatedAt"] = "9999-12-31T23:59:59-05:00"
    assert sampler(fake, sconn).sample_quota()
    assert stats_store.read_quota(sconn)[0]["updatedAt"] is None


def test_a_failing_controller_writes_nothing_and_says_so(fake, sconn):
    fake.fail_samples = True
    s = sampler(fake, sconn)
    assert s.sample_delays() is False and s.sample_quota() is False
    assert rows_of(sconn) == [] and stats_store.read_quota(sconn) == []
    assert s.status["delay_state"] == "error" and s.status["quota_state"] == "error"


# --- the quota -------------------------------------------------------------------

def test_the_quota_keeps_five_fields_and_never_the_url_or_the_nodes(
        fake, sconn, panel_env):
    s = sampler(fake, sconn)
    assert s.sample_quota("2026-10-16T12:00:05Z")
    assert stats_store.read_quota(sconn) == [
        # mihomo zero-fills what the provider never sent: total and expire 0
        # mean unknown/unlimited, never a real limit
        {"provider": "my-airport", "upload": 1024, "download": 4096,
         "total": None, "expire": None, "updatedAt": "2026-10-16T11:30:00Z"},
        # lower-case spellings too; Go's zero time is no time at all
        {"provider": "spare", "upload": 5, "download": 6, "total": 100,
         "expire": 1790000000, "updatedAt": None},
    ]
    assert s.status["quota_state"] == "ok"
    # every stored quota value carries exactly the five fields
    import json
    for (value,) in sconn.execute(
            "SELECT v FROM stats_meta WHERE substr(k, 1, 6) = 'quota:'"):
        assert sorted(json.loads(value)) == sorted(stats_store.QUOTA_FIELDS)
    # nothing else of the provider reached the store: not the URL, not the
    # node list or its server, not the probe URL
    blob = " ".join(str(v) for row in sconn.execute("SELECT * FROM stats_meta")
                    for v in row)
    sconn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    raw = (panel_env["data"] / "state" / "stats.db").read_bytes()
    for leak in ("planted-subscription-token", "sub.example.com",
                 "probe.example.com", "192.0.2.80"):
        assert leak not in blob, leak
        assert leak.encode() not in raw, leak


def test_each_allowlist_holds_on_its_own(sconn):
    """Two layers keep the quota to five fields - reading a provider entry,
    and writing one - and each holds without the other."""
    entry = stats_store.quota_entry({
        "url": SECRET_URL, "proxies": [{"server": "192.0.2.80"}],
        "subscriptionInfo": {"Upload": 1, "Token": "planted"}})
    assert sorted(entry) == sorted(stats_store.QUOTA_FIELDS)
    stats_store.write_quota(sconn, {"p": {**entry, "url": SECRET_URL}})
    (value,) = sconn.execute(
        "SELECT v FROM stats_meta WHERE k = 'quota:p'").fetchone()
    assert SECRET_URL not in value and "url" not in value


@pytest.mark.parametrize(("value", "kept"), [(-5, None), ("12", None),
                                             (True, None), (float("nan"), None),
                                             (7.9, 7), (0, 0)])
def test_a_quota_number_is_a_count_or_unknown(fake, sconn, value, kept):
    fake.providers_doc = {"p": {"subscriptionInfo": {"Upload": value}}}
    sampler(fake, sconn).sample_quota()
    assert stats_store.read_quota(sconn)[0]["upload"] == kept


def test_a_provider_no_longer_reported_loses_its_quota(fake, sconn):
    s = sampler(fake, sconn)
    s.sample_quota()
    del fake.providers_doc["spare"]
    s.sample_quota()
    assert [q["provider"] for q in stats_store.read_quota(sconn)] == ["my-airport"]
    fake.providers_doc = {"default": {"vehicleType": "Compatible"}}
    s.sample_quota()
    assert stats_store.read_quota(sconn) == []
    assert s.status["quota_state"] == "none"


def test_a_failed_quota_read_keeps_the_last_good_set(fake, sconn):
    s = sampler(fake, sconn)
    s.sample_quota()
    fake.fail_samples = True
    s.sample_quota()
    assert len(stats_store.read_quota(sconn)) == 2


# --- cadence ---------------------------------------------------------------------

def test_each_sample_runs_on_its_own_cadence(fake, sconn):
    clock = Clock()
    s = sampler(fake, sconn, clock)
    calls = []
    delays, quota = s.sample_delays, s.sample_quota
    s.sample_delays = lambda now=None: calls.append("delay") or delays(now)
    s.sample_quota = lambda now=None: calls.append("quota") or quota(now)
    s.run_due()                                    # both at start
    clock.t += DELAY_EVERY_S - 1
    s.run_due()                                    # nothing due
    clock.t += 1
    s.run_due()                                    # delay
    clock.t += QUOTA_EVERY_S
    s.run_due()                                    # both
    assert calls == ["delay", "quota", "delay", "delay", "quota"]


def test_a_store_error_in_one_sample_never_stops_the_other(fake, sconn,
                                                          monkeypatch):
    def full(*_a, **_k):
        raise RuntimeError("database or disk is full")
    monkeypatch.setattr(stats_store, "record_delays", full)
    s = sampler(fake, sconn)
    s.run_due()
    assert s.status["delay_state"] == "error" and s.status["delay_failures"] == 1
    assert s.status["quota_state"] == "ok" and len(stats_store.read_quota(sconn)) == 2


def test_a_purge_never_falls_between_the_write_and_its_state(fake, sconn):
    """The bare purge takes the stats lock, then forgets the quota. A purge
    released into the instant after the sample's write must find the
    sample's state already published, or it would be overwritten with "ok"
    over an empty store."""

    class PurgeOnRelease:
        def __init__(self):
            self.inner = threading.RLock()
            self.armed = False
            self.sampler = None

        def __enter__(self):
            self.inner.acquire()
            return self

        def __exit__(self, *exc):
            self.inner.release()
            if self.armed:
                self.armed = False
                with self.inner:
                    sconn.execute(stats_store.node_delay.delete_quota_sql(),
                                  (stats_store.QUOTA_PREFIX,))
                    self.sampler.forget_quota()

    lock = PurgeOnRelease()
    s = Sampler(client=fake, conn=sconn, lock=lock, clock=Clock())
    lock.sampler = s
    lock.armed = True
    s.sample_quota()
    assert stats_store.read_quota(sconn) == []
    assert s.status["quota_state"] == "pending" and s._quota_at is None


def test_a_group_parked_on_a_built_in_charts_nothing(fake, sconn):
    fake.groups_doc = [{"name": "Kill", "now": "REJECT"},
                       {"name": "Routing Mode", "now": "DIRECT"}]
    fake.histories = {"REJECT": [{"time": "2026-10-16T12:00:00Z", "delay": 0}],
                      "DIRECT": [{"time": "2026-10-16T12:00:00Z", "delay": 1}]}
    sampler(fake, sconn).sample_delays()
    assert rows_of(sconn) == []


def test_the_node_delay_sample_keeps_to_its_time_budget(fake, sconn):
    from app.collector import sampler as sampler_mod
    clock = Clock()
    fake.groups_doc = [{"name": f"G{i}", "now": f"N{i}"} for i in range(10)]
    fake.histories = {f"N{i}": [{"time": f"2026-10-16T12:00:0{i}Z", "delay": 40}]
                      for i in range(10)}
    real = fake.proxy_history

    def slow(name):
        clock.t += 3
        return real(name)
    fake.proxy_history = slow
    s = sampler(fake, sconn, clock)
    s.sample_delays()
    # 3 s a lookup: only those started inside the budget ran - and the
    # sample says it was cut
    first = {r[1] for r in rows_of(sconn)}
    assert 0 < len(first) <= sampler_mod.DELAY_BUDGET_S // 3 + 1 < 10
    assert s.status["delay_state"] == "partial"
    # the next sample starts where this one was cut: nothing is starved
    s.sample_delays()
    assert {r[1] for r in rows_of(sconn)} == {f"G{i}" for i in range(10)}


def test_no_test_older_than_the_retention_or_a_purge_is_written_back(
        fake, sconn, monkeypatch):
    from datetime import UTC, datetime, timedelta
    now = datetime.now(UTC)
    stamp = lambda dt: dt.strftime("%Y-%m-%dT%H:%M:%SZ")  # noqa: E731
    monkeypatch.setenv("PANEL_NODE_DELAY_DAYS", "14")
    fake.groups_doc = [{"name": "Old", "now": "N0"}, {"name": "New", "now": "N1"}]
    fake.histories = {"N0": [{"time": stamp(now - timedelta(days=20)), "delay": 40}],
                      "N1": [{"time": stamp(now - timedelta(minutes=10)), "delay": 41}]}
    s = sampler(fake, sconn)
    s.sample_delays()
    # a node nobody re-tests for weeks: its old test is never re-inserted
    assert [r[1] for r in rows_of(sconn)] == ["New"]
    # a purge of the history leaves a floor: mihomo's older tests stay out
    sconn.execute("DELETE FROM stats_node_delay")
    s.forget_delays(stamp(now))
    s.sample_delays()
    assert rows_of(sconn) == []


def test_a_failed_sample_is_retried_on_the_next_pass(fake, sconn):
    clock = Clock()
    s = sampler(fake, sconn, clock)
    fake.fail_samples = True
    s.run_due()
    fake.fail_samples = False
    clock.t += 60                                  # the next maintenance pass
    s.run_due()
    assert len(rows_of(sconn)) == 3 and len(stats_store.read_quota(sconn)) == 2
