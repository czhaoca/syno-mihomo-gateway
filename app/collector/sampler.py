"""The sampler (#102): the selected node's delay per policy group every
300 s, and the subscription quota every hour - both read from mihomo,
PASSIVELY (the panel never probes a node itself).

It runs on the collector loop's side thread, after #96's version and memory
sample, never on the poll path: a controller that hangs here delays nothing
but the next sample. Network reads happen outside the stats lock; only the
inserts take it, together with the sample's state and cadence stamp. Each
cadence runs on an injectable monotonic clock, and a sample that FAILED is
retried on the next maintenance pass rather than a whole cadence later. One
sample failing never stops the other, and every failure is counted.
"""

import contextlib
import time
from datetime import UTC, datetime, timedelta

from app import config
from app.store import stats as stats_store

DELAY_EVERY_S = stats_store.DELAY_EVERY_S
QUOTA_EVERY_S = 3600
# mode=global's selector: not a routing decision in rule mode
SKIP_GROUPS = ("GLOBAL",)
# built-in outbounds and the empty-provider placeholder: a group parked on
# one has no node to chart (a group latency test still records history on
# them - REJECT's would chart as a node whose every test failed)
SKIP_SELECTIONS = ("DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE")
# the whole node delay sample's time budget: per-node reads are sequential
# and a controller slow on /proxies must not outlive the 60 s pass (the
# memory read shares the side thread); the next sample starts where this
# one was cut
DELAY_BUDGET_S = 20


def _now_str() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _latest_test(history):
    """(tested_at, delay_ms) of the newest test in HISTORY that has a time;
    delay 0 (a failed test) is None - "no answer", never 0 ms."""
    for entry in reversed(history):
        tested = stats_store.utc_stamp(entry.get("time"))
        if tested is None:
            continue
        delay = entry.get("delay")
        ok = (not isinstance(delay, bool) and isinstance(delay, (int, float))
              and 0 < delay < float("inf"))
        return tested, int(delay) if ok else None
    return None


class Sampler:
    def __init__(self, *, client, conn, lock, clock=time.monotonic):
        self.client = client
        self.conn = conn
        self.lock = lock
        self.clock = clock
        self._delay_at = None
        self._quota_at = None
        # in memory only: what the last attempt saw, for the reads to tell
        # "nothing reports a quota" from "not sampled yet / unreachable"
        self.status = {"delay_ts": None, "delay_state": "pending",
                       "quota_ts": None, "quota_state": "pending",
                       "delay_failures": 0, "quota_failures": 0}
        # bumped with every published quota state (under the stats lock):
        # the quota read compares it to pair a snapshot with its state
        self.quota_epoch = 0
        # where the budget cut the last delay sample: the next one starts
        # there, so a slow controller never starves the same groups
        self._delay_start = 0
        # no test older than this is written (back): the last purge of the
        # delay history, as an ISO stamp
        self._delay_floor = ""

    def forget_quota(self) -> None:
        """The stored quota was purged: until the next sample (due at once)
        the read says "pending", never "ok" over an empty list."""
        self._quota_at = None
        self.quota_epoch += 1
        self.status.update(quota_ts=None, quota_state="pending")

    def forget_delays(self, before: str) -> None:
        """The delay history was purged up to BEFORE (an ISO stamp): mihomo
        still holds those tests, and the next sample must not write them
        back."""
        self._delay_floor = max(self._delay_floor, before)

    def run_due(self, now: str | None = None) -> None:
        """Every sample whose cadence has passed (each one at start)."""
        mono = self.clock()
        # each sample on its own: a store error in one never stops the
        # other, and it is said (state "error", a failure counted)
        if self._due(self._delay_at, DELAY_EVERY_S, mono):
            try:
                self.sample_delays(now)
            except Exception:
                self.status["delay_state"] = "error"
                self.status["delay_failures"] += 1
        if self._due(self._quota_at, QUOTA_EVERY_S, mono):
            try:
                self.sample_quota(now)
            except Exception:
                self.status["quota_state"] = "error"
                self.status["quota_failures"] += 1

    @staticmethod
    def _due(last, every, mono) -> bool:
        return last is None or mono - last >= every

    def sample_delays(self, now: str | None = None) -> bool:
        """The newest test of each group's selected node, stored as given
        (a group whose selection is itself a group is stored with that
        group's own history; DIRECT or a COMPATIBLE placeholder has none,
        so adds nothing). True when /group answered."""
        now = now or _now_str()
        started = self.clock()
        try:
            groups = self.client.groups()
        except Exception:
            self.status["delay_state"] = "error"
            self.status["delay_failures"] += 1
            return False
        rows = []
        asked = failed = 0
        # nothing older than the retention or the last purge is (re)written:
        # mihomo keeps a node's history for its whole uptime
        floor = max(self._delay_floor, (datetime.now(UTC) - timedelta(
            days=config.node_delay_days())).strftime("%Y-%m-%dT%H:%M:%SZ"))
        start = self._delay_start % len(groups) if groups else 0
        order = groups[start:] + groups[:start]
        cut = None
        for index, group in enumerate(order):
            name, node = group.get("name"), group.get("now")
            if not isinstance(name, str) or not name or name in SKIP_GROUPS:
                continue
            if not isinstance(node, str) or not node or node in SKIP_SELECTIONS:
                continue
            if self.clock() - started > DELAY_BUDGET_S:
                cut = (start + index) % len(groups)
                break
            asked += 1
            try:
                test = _latest_test(self.client.proxy_history(node))
            except Exception:
                failed += 1
                continue
            if test is not None and test[0] >= floor:
                rows.append((test[0], name, node, test[1]))
        # every lookup failing is not a sample: retried on the next pass
        if asked and failed == asked:
            self.status["delay_state"] = "error"
            self.status["delay_failures"] += 1
            return False
        with self.lock:
            stats_store.record_delays(self.conn, rows)
            self._delay_at = self.clock()
            self._delay_start = cut if cut is not None else 0
            # a budget-cut sample says so: the rest come first next time
            self.status.update(delay_ts=now,
                               delay_state="partial" if cut is not None else "ok")
        return True

    def sample_quota(self, now: str | None = None) -> bool:
        """Every provider's quota, the five fields only, replacing the stored
        set. A read that fails or does not parse leaves the stored set as it
        was - unknown is not "no quota". True when the read answered."""
        now = now or _now_str()
        try:
            providers = self.client.proxy_providers()
        except Exception:
            self.status["quota_state"] = "error"
            self.status["quota_failures"] += 1
            return False
        entries = {}
        for name, info in providers.items():
            entry = stats_store.quota_entry(info)
            if isinstance(name, str) and name and entry is not None:
                entries[name] = entry
        # the write, the state and the cadence stamp in ONE lock hold: a bare
        # purge (which takes the lock, then forgets the quota) lands either
        # before all three or after all three - never between them
        with self.lock:
            stats_store.write_quota(self.conn, entries)
            self._quota_at = self.clock()
            self.quota_epoch += 1
            self.status.update(quota_ts=now,
                               quota_state="ok" if entries else "none")
        return True


def run_quietly(sampler) -> None:
    """The side thread's call: a sampler fault must never kill the thread
    that also carries the next memory sample."""
    with contextlib.suppress(Exception):
        sampler.run_due()
