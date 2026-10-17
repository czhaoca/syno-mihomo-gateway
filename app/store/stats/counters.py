"""In-memory byte counters for the Prometheus exposition (#99 DEC-B).

Monotonic since the panel started, fed by the collector after each poll's
flush has COMMITTED - a rolled-back flush counts nothing - and reset by a
restart, which a Prometheus `rate()` handles as a counter reset. They are
never stored: nothing here touches stats.db, so an image rollback cannot
disturb them. One family per dimension (DEC-A): the device and its policy
group from the tier rows, and the four long-term dimensions. Never a
hostname-class value: the seven-day class is not fed here.
"""

import threading

FAMILIES = ("device", "group", "exit", "rule", "category", "country")


class Counters:
    def __init__(self):
        self._lock = threading.Lock()
        self._values: dict = {family: {} for family in FAMILIES}

    def _add(self, family: str, value: str, up: int, down: int) -> None:
        acc = self._values[family].setdefault(value, [0, 0])
        acc[0] += up
        acc[1] += down

    def add_poll(self, rows: dict, dims: dict) -> None:
        """Add one committed poll. ROWS: {(device, chain): [up, down, ...]}
        (the tier rows); DIMS: {dimension: {(device, value): [up, down]}}.
        A group that moved no bytes (a new idle connection) adds nothing."""
        with self._lock:
            for (device, chain), acc in rows.items():
                up, down = acc[0], acc[1]
                if up or down:
                    self._add("device", device, up, down)
                    self._add("group", chain, up, down)
            for dim, table in dims.items():
                for (_device, value), (up, down) in table.items():
                    self._add(dim, value, up, down)

    def reset(self) -> None:
        """Back to zero - a counter reset, which Prometheus `rate()` handles.
        A purge of the tables these mirror calls it, so purged traffic is
        not served on as if it were still held."""
        with self._lock:
            self._values = {family: {} for family in FAMILIES}

    def snapshot(self) -> dict:
        """{family: {value: (up, down)}} - a copy, safe to render."""
        with self._lock:
            return {family: {v: tuple(acc) for v, acc in values.items()}
                    for family, values in self._values.items()}
