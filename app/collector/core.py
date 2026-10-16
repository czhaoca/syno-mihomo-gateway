"""The /connections poll collector (GET polling; 2 s by default since #94).

POLL_INTERVAL_DEFAULT_S mirrors `config.STATS_POLL_DEFAULT_S`, the one place
the default lives - `PANEL_STATS_POLL_S` overrides it at deploy time and `0`
disables the loop entirely (unit tests drive poll_once() directly with fake
clocks).
Every failure path DEGRADES (status.last_error + a skipped flush), never
crashes — the #64 degraded-knob discipline; downtime becomes honest gap
rows at the store layer, never interpolation.
"""

import contextlib
import threading
import time
from collections import deque
from datetime import UTC, datetime

from app import config
from app.store import dayframe
from app.store import stats as stats_store

POLL_INTERVAL_DEFAULT_S = config.STATS_POLL_DEFAULT_S
GAP_FACTOR = 3  # a hole wider than 3x the effective cadence is a gap
MAINTENANCE_EVERY_S = 60  # rollup + cap enforcement cadence
POLL_MS_WINDOW = 30  # collector_poll_ms = mean of this many successful polls


def _now_str() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def effective_interval_s() -> int:
    """The configured cadence, with 0 meaning 'loop disabled' — gap math
    still needs a non-zero yardstick, so it falls back to the default."""
    knob = config.stats_poll_s()
    return knob if knob > 0 else POLL_INTERVAL_DEFAULT_S


def _lag_s(last_ts: str | None, now: str) -> int | None:
    if last_ts is None:
        return None
    lag = (stats_store._parse_ts(now) - stats_store._parse_ts(last_ts))
    return max(0, int(lag.total_seconds()))


def _no_day_source() -> dayframe.DayFrame:
    """The default when nobody wired a timezone source in: loudly unusable
    rather than quietly UTC. A collector that guessed the framing would
    stamp rows with a decision no one made."""
    return dayframe.unusable("no timezone source is wired into this collector")


class Collector:
    def __init__(self, *, client, conn, day_source=_no_day_source,
                 clock=time.monotonic):
        self.client = client
        self.conn = conn
        self.clock = clock
        # DAY_SOURCE is a zero-arg callable resolved FRESH on every
        # maintenance pass, never cached: a timezone change has to take
        # effect on the next pass (<=60s) with no panel restart, and a
        # cache with an invalidation hook would turn one missed bump into
        # silently mis-filed rows - the failure class this epic removes.
        self.day_source = day_source
        # The telemetry fields (#96) are counts and numbers only - never
        # error text - and None means "not measured yet", never 0.
        self.status = {"last_poll_ts": None, "last_error": None,
                       "day_tz": "", "day_cut": "", "day_framing": "unknown",
                       "failed_polls": 0, "poll_ms": None, "conns": None,
                       "mihomo_version": "", "mihomo_mem_mb": None,
                       "db_growth_mb_day": None}
        self._last_maintenance = None
        self._poll_ms = deque(maxlen=POLL_MS_WINDOW)
        # the growth rate from the gauges already stored, so it is not
        # blank for the first minute after every restart
        with contextlib.suppress(Exception):
            self.status["db_growth_mb_day"] = stats_store.self_growth_mb_day(
                conn, _now_str()[:16])

    def day_frame(self) -> dayframe.DayFrame:
        """Resolve the framing, converting a raising source into a recorded
        degraded frame. Called OUTSIDE the stats lock (see CollectorLoop):
        the production source takes the POLICY mutex, and the two locks are
        never nested anywhere today."""
        try:
            return self.day_source()
        except Exception as exc:
            return dayframe.unusable(
                f"timezone lookup failed: {exc.__class__.__name__}: {exc}")

    def poll_once(self, now: str | None = None, _strict: bool = False,
                  lock=None) -> None:
        """One poll -> one transactional flush. The network fetch runs
        OUTSIDE the (optional) lock — a slow controller (urlopen bounded
        at 10s) must never hold the writer lock, which the maintenance pass
        and the purge also take. (Since #93 the stats API reads through its
        own read-only connections and never waits on this lock.) _strict
        re-raises (test hook proving flush atomicity); the default
        degrades."""
        now = now or _now_str()
        started = self.clock()
        try:
            raw = self.client.connections()
            with lock if lock is not None else contextlib.nullcontext():
                stats_store.flush_poll(
                    self.conn, raw, now,
                    domains_enabled=config.stats_domains(),
                    gap_threshold_s=GAP_FACTOR * effective_interval_s(),
                    interval_s=effective_interval_s())
            self.status["last_poll_ts"] = now
            self.status["last_error"] = None
            # the whole poll - fetch, parse, flush (and any wait for the
            # lock) - over the last POLL_MS_WINDOW successful polls, so one
            # slow poll moves the figure without flipping a gate on it
            self._poll_ms.append((self.clock() - started) * 1000)
            self.status["poll_ms"] = round(sum(self._poll_ms)
                                           / len(self._poll_ms))
            self.status["conns"] = len(raw)
        except Exception as exc:
            self.status["failed_polls"] += 1
            if _strict:
                raise
            self.status["last_error"] = f"{exc.__class__.__name__}: {exc}"

    def sample_mihomo(self) -> None:
        """mihomo's version and in-use memory, for /health and the gauges.
        Network reads - the loop runs this on a side thread (see
        CollectorLoop), at start and then once per maintenance pass, never
        on the poll path, never under the stats lock and never per /health
        request. A failure is not a collector error: the controller being
        slow to answer /memory says nothing about whether traffic is being
        counted. A failed version read keeps the last version read (a
        restarting mihomo is still the same build); a failed memory read is
        "unknown" (None), because an old figure would pass for a current one.
        """
        with contextlib.suppress(Exception):
            self.status["mihomo_version"] = self.client.version()
        try:
            inuse = self.client.memory_inuse()
        except Exception:
            inuse = None
        self.status["mihomo_mem_mb"] = (round(inuse / (1024 * 1024))
                                        if inuse else None)

    def maintain(self, now: str | None = None, *, day=None) -> None:
        """Rollup cascade + cap enforcement; failures degrade like polls.

        DAY is the resolved framing. The loop passes it in, having resolved
        it outside the stats lock; a direct caller may omit it and have it
        resolved here (tests hold no lock, so the ordering cannot bite).
        The day-tier state is recorded in its OWN status fields rather than
        `last_error`, which every successful poll clears within 10s - a
        rollup failing once a minute would otherwise erase its own symptom.
        """
        now = now or _now_str()
        frame = day if day is not None else self.day_frame()
        self.status["day_tz"] = frame.tz or dayframe.UTC_TZ
        self.status["day_cut"] = frame.cut or dayframe.UTC_CUT
        self.status["day_framing"] = "ok" if frame.ok else "degraded"
        self.status["day_error"] = frame.error
        try:
            stats_store.rollup(self.conn, now, day=frame)
            stats_store.enforce_cap(self.conn, config.stats_db_path(),
                                    config.stats_cap_mb())
            self._record_gauges(now)
        except Exception as exc:
            self.status["last_error"] = f"{exc.__class__.__name__}: {exc}"

    def _record_gauges(self, now: str) -> None:
        """One stats_self row per pass (#96), and the growth rate /health
        reports, computed here once a minute rather than per request."""
        bucket = now[:16]
        stats_store.record_self(self.conn, bucket, {
            "poll_ms": self.status["poll_ms"],
            "conns": self.status["conns"],
            "failed_polls": self.status["failed_polls"],
            "lag_s": _lag_s(self.status["last_poll_ts"], now),
            "db_bytes": stats_store._db_bytes(config.stats_db_path()),
            "mihomo_mem_mb": self.status["mihomo_mem_mb"]})
        self.status["db_growth_mb_day"] = stats_store.self_growth_mb_day(
            self.conn, bucket)


class CollectorLoop:
    """The background thread: poll every interval, maintain every minute.
    Every stats-db WRITE serializes through LOCK - the flush, the
    maintenance pass and the purge route. Reads do not take it (#93)."""

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
        self._sampler = None

    def _sample_mihomo(self) -> None:
        """Start a mihomo telemetry sample on a side thread unless the last
        one is still running: a controller that hangs on /version or
        /memory must never delay a poll (a late poll is a gap row)."""
        if self._sampler is not None and self._sampler.is_alive():
            return
        self._sampler = threading.Thread(target=self.collector.sample_mihomo,
                                         daemon=True,
                                         name="panel-mihomo-sampler")
        self._sampler.start()

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread.is_alive():  # tolerate a never-started loop
            self._thread.join(timeout=5)

    def _run(self) -> None:
        # first poll immediately so /health goes fresh without waiting a
        # full interval, then tick until stopped. The poll's network fetch
        # happens outside the lock (see poll_once); only the db writes
        # (flush + maintenance) hold it, alongside the purge route.
        self._sample_mihomo()
        while True:
            self.collector.poll_once(lock=self.lock)
            self._since_maintenance += self.interval_s
            if self._since_maintenance >= MAINTENANCE_EVERY_S:
                # Resolved BEFORE the stats lock: the production source
                # takes the POLICY mutex, and routes.py takes the two
                # strictly sequentially, never nested. Resolving inside the
                # lock would invent a stats->policy ordering that no path
                # has today, leaving a deadlock one future route away.
                frame = self.collector.day_frame()
                self._sample_mihomo()   # network, off the poll path
                with self.lock:
                    self.collector.maintain(day=frame)
                self._since_maintenance = 0.0
            if self._stop.wait(self.interval_s):
                return
