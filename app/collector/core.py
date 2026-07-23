"""The /connections poll collector (DEC-C: 10s GET polling).

POLL_INTERVAL_DEFAULT_S is the single tunable constant the DEC mandates —
`PANEL_STATS_POLL_S` overrides it at deploy time and `0` disables the
loop entirely (unit tests drive poll_once() directly with fake clocks).
Every failure path DEGRADES (status.last_error + a skipped flush), never
crashes — the #64 degraded-knob discipline; downtime becomes honest gap
rows at the store layer, never interpolation.
"""

import contextlib
import threading
from datetime import UTC, datetime

from app import config
from app.store import stats as stats_store

POLL_INTERVAL_DEFAULT_S = 10  # DEC-C: the one place the cadence lives
GAP_FACTOR = 3  # a hole wider than 3x the effective cadence is a gap
MAINTENANCE_EVERY_S = 60  # rollup + cap enforcement cadence


def _now_str() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def effective_interval_s() -> int:
    """The configured cadence, with 0 meaning 'loop disabled' — gap math
    still needs a non-zero yardstick, so it falls back to the default."""
    knob = config.stats_poll_s()
    return knob if knob > 0 else POLL_INTERVAL_DEFAULT_S


class Collector:
    def __init__(self, *, client, conn):
        self.client = client
        self.conn = conn
        self.status = {"last_poll_ts": None, "last_error": None}
        self._last_maintenance = None

    def poll_once(self, now: str | None = None, _strict: bool = False,
                  lock=None) -> None:
        """One poll -> one transactional flush. The network fetch runs
        OUTSIDE the (optional) lock — a slow controller (urlopen bounded
        at 10s) must never stall the stats API, which shares the lock only
        for the short db flush. _strict re-raises (test hook proving flush
        atomicity); the default degrades."""
        now = now or _now_str()
        try:
            raw = self.client.connections()
            with lock if lock is not None else contextlib.nullcontext():
                stats_store.flush_poll(
                    self.conn, raw, now,
                    domains_enabled=config.stats_domains(),
                    gap_threshold_s=GAP_FACTOR * effective_interval_s())
            self.status["last_poll_ts"] = now
            self.status["last_error"] = None
        except Exception as exc:
            if _strict:
                raise
            self.status["last_error"] = f"{exc.__class__.__name__}: {exc}"

    def maintain(self, now: str | None = None) -> None:
        """Rollup cascade + cap enforcement; failures degrade like polls."""
        now = now or _now_str()
        try:
            stats_store.rollup(self.conn, now)
            stats_store.enforce_cap(self.conn, config.stats_db_path(),
                                    config.stats_cap_mb())
        except Exception as exc:
            self.status["last_error"] = f"{exc.__class__.__name__}: {exc}"


class CollectorLoop:
    """The background thread: poll every interval, maintain every minute.
    All stats-db access serializes through LOCK (shared with the API)."""

    def __init__(self, collector: Collector, lock, interval_s: int):
        # NOTE: `lock` stays unannotated - threading.RLock is a factory
        # FUNCTION on python 3.12 (the CI image), so `threading.RLock |
        # None` TypeErrors at import there (it only became a class later).
        self.collector = collector
        self.lock = lock
        self.interval_s = interval_s
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name="panel-stats-collector")
        self._since_maintenance = 0.0

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread.is_alive():  # tolerate a never-started loop
            self._thread.join(timeout=5)

    def _run(self) -> None:
        # first poll immediately so /health goes fresh without waiting a
        # full interval, then tick until stopped. The poll's network fetch
        # happens outside the lock (see poll_once); only the db work
        # (flush + maintenance) contends with the stats API.
        while True:
            self.collector.poll_once(lock=self.lock)
            self._since_maintenance += self.interval_s
            if self._since_maintenance >= MAINTENANCE_EVERY_S:
                with self.lock:
                    self.collector.maintain()
                self._since_maintenance = 0.0
            if self._stop.wait(self.interval_s):
                return
