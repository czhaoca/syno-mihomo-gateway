"""The hard size cap drains by DATA AGE across every table (#95, DEC-C).

Before the star schema the cap walked a fixed table order - the whole day
tier, then hour, then minute - which with one table per dimension would
have emptied two years of one table before touching an older row of the
next. Now each batch deletes the oldest AGE GROUPS - distinct (start, tie
rank) - across every table at once, in one transaction, so tables written on
the same buckets (the device tier and its dimensions) lose them together and
a batch is never cut to one bucket of one table. On an exact tie the
seven-day class goes first (it expires within the week anyway).

Buckets of different granularity compare by when they START: a day key
`2026-10-12` reads as 2026-10-12T00:00, an hour `2026-10-12T08` as
08:00, a minute as itself, a gap by the minute it started.

Invariant I-3 (docs/brainstorms/gateway-insights.md): whatever the cap
removes is a PREFIX of that global age order - it never prunes a newer row
while an older one, in any table, survives.

The byte measure is replaced by a row count here, so the property is
checked on the selection logic over many shapes; the real-file mechanism
(vacuum, checkpoint, WAL) is exercised in test_stats_rollup.py.
"""

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from app.store import stats as stats_store
from app.store.stats import maintain
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

NOW = datetime(2026, 10, 15, 12, 0, tzinfo=UTC)
CAP_MB = 1
_PAD = "0000-00-00T00:00"


def _age(entry, key):
    """The (start, tie rank, list position) a row of a cap entry sorts by."""
    name, _table, _col, length, rank = entry
    start = key[:length] + _PAD[length:]
    return (start, rank, [e[0] for e in stats_store._CAP_TIERS].index(name))


def _key(entry, moment):
    _name, _table, col, length, _rank = entry
    if col in ("started", "tested_at"):
        return moment.strftime("%Y-%m-%dT%H:%M:%SZ")
    return moment.strftime("%Y-%m-%dT%H:%M")[:length]


def _insert(conn, entry, key, device):
    _name, table, col, _length, _rank = entry
    if col == "started":
        conn.execute("INSERT INTO stats_gap (started, ended, reason) "
                     "VALUES (?, ?, 'test')", (key, key))
        return
    if col == "tested_at":
        conn.execute("INSERT OR IGNORE INTO stats_node_delay (tested_at, grp, "
                     "node, delay_ms) VALUES (?, 'Auto', ?, 1)", (key, device))
        return
    cols = {r["name"]: r for r in conn.execute(f"PRAGMA table_info({table})")}
    names, vals = ["bucket"], [key]
    if "device" in cols:
        names.append("device")
        vals.append(device)
    for name, info in cols.items():
        if name in names or info["dflt_value"] is not None:
            continue
        names.append(name)
        vals.append(1 if name in ("up", "down") else "x")
    conn.execute(f"INSERT OR IGNORE INTO {table} ({', '.join(names)}) "
                 f"VALUES ({', '.join('?' * len(vals))})", vals)


def _rows(conn):
    """(entry, key) per stored row, across every capped table."""
    out = []
    for entry in stats_store._CAP_TIERS:
        _name, table, col, _length, _rank = entry
        out.extend((entry, r[0]) for r in conn.execute(
            f"SELECT {col} FROM {table}"))
    return out


def _measure_rows(monkeypatch, conn, keep):
    """Over the cap until at most KEEP rows remain."""
    def fake(_path):
        return (CAP_MB * 1024 * 1024 + 1) if len(_rows(conn)) > keep else 0
    monkeypatch.setattr(maintain, "_db_bytes", fake)


@pytest.fixture()
def one_group(monkeypatch):
    """One age group per batch, so a test sees the order rows go in."""
    monkeypatch.setattr(maintain, "_CAP_BATCH", 1)


@pytest.fixture()
def sconn(panel_env):
    conn = stats_store.open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


def _entry(name):
    return next(e for e in stats_store._CAP_TIERS if e[0] == name)


# --- examples -----------------------------------------------------------------

def test_an_older_dimension_row_goes_before_a_newer_device_day(sconn,
                                                              monkeypatch,
                                                              one_group):
    _insert(sconn, _entry("exit_day"), "2024-01-01", "192.0.2.20")
    for day in ("2025-01-01", "2025-01-02", "2025-01-03"):
        _insert(sconn, _entry("day"), day, "192.0.2.20")
    _measure_rows(monkeypatch, sconn, keep=3)
    pruned = stats_store.enforce_cap(sconn, "unused", CAP_MB)
    assert pruned["exit_day"] == 1
    assert pruned["day"] == 0
    assert sconn.execute("SELECT COUNT(*) FROM stats_day").fetchone()[0] == 3


def test_a_device_day_goes_before_a_newer_dimension_day(sconn, monkeypatch,
                                                         one_group):
    # the old fixed order drained `day` first; age now decides both ways
    _insert(sconn, _entry("day"), "2024-01-01", "192.0.2.20")
    _insert(sconn, _entry("country_day"), "2025-01-01", "192.0.2.20")
    _measure_rows(monkeypatch, sconn, keep=1)
    pruned = stats_store.enforce_cap(sconn, "unused", CAP_MB)
    assert (pruned["day"], pruned["country_day"]) == (1, 0)


def test_on_a_tie_the_seven_day_class_goes_first(sconn, monkeypatch,
                                                  one_group):
    _insert(sconn, _entry("hour"), "2026-10-10T08", "192.0.2.20")
    _insert(sconn, _entry("domain"), "2026-10-10T08", "192.0.2.20")
    _measure_rows(monkeypatch, sconn, keep=1)
    pruned = stats_store.enforce_cap(sconn, "unused", CAP_MB)
    assert (pruned["domain"], pruned["hour"]) == (1, 0)


def test_a_day_starts_before_the_hours_of_that_day(sconn, monkeypatch,
                                                   one_group):
    _insert(sconn, _entry("domain"), "2026-10-10T00", "192.0.2.20")
    _insert(sconn, _entry("day"), "2026-10-10", "192.0.2.20")
    _measure_rows(monkeypatch, sconn, keep=1)
    # both start 2026-10-10T00:00: a tie, and the seven-day row goes first
    pruned = stats_store.enforce_cap(sconn, "unused", CAP_MB)
    assert (pruned["domain"], pruned["day"]) == (1, 0)


def test_a_batch_spans_tables_in_age_order(sconn, monkeypatch):
    # day holds 2024-01-01..2024-01-30; an hour row sits at 2024-01-05T10.
    # One batch is the 20 oldest age groups across BOTH tables: the days up
    # to 01-19 and the hour between them - never a day past the hour first
    for d in range(1, 31):
        _insert(sconn, _entry("day"), f"2024-01-{d:02d}", "192.0.2.20")
    _insert(sconn, _entry("hour"), "2024-01-05T10", "192.0.2.20")
    _measure_rows(monkeypatch, sconn, keep=25)
    pruned = stats_store.enforce_cap(sconn, "unused", CAP_MB)
    assert pruned == {**dict.fromkeys(pruned, 0), "day": 19, "hour": 1}
    assert sconn.execute(
        "SELECT MIN(bucket) FROM stats_day").fetchone()[0] == "2024-01-20"


def test_aligned_tables_lose_the_same_buckets_together(sconn, monkeypatch,
                                                       one_group):
    # the device tier and its dimensions are written on the same buckets;
    # a batch takes a bucket from all of them, never from some
    for bucket in ("2026-07-01T08", "2026-07-01T09"):
        for name in ("hour", "exit_hour", "rule_hour", "category_hour",
                     "country_hour"):
            _insert(sconn, _entry(name), bucket, "192.0.2.20")
    _measure_rows(monkeypatch, sconn, keep=9)
    pruned = stats_store.enforce_cap(sconn, "unused", CAP_MB)
    assert {k: v for k, v in pruned.items() if v} == {
        "hour": 1, "exit_hour": 1, "rule_hour": 1, "category_hour": 1,
        "country_hour": 1}


def test_a_batch_costs_one_checkpoint_not_one_per_table(sconn, monkeypatch):
    for bucket in ("2026-07-01T08", "2026-07-01T09"):
        for name in ("hour", "exit_hour", "rule_hour", "category_hour",
                     "country_hour"):
            _insert(sconn, _entry(name), bucket, "192.0.2.20")
    checkpoints = []
    real = maintain._checkpoint
    monkeypatch.setattr(maintain, "_checkpoint",
                        lambda c: checkpoints.append(1) or real(c))
    _measure_rows(monkeypatch, sconn, keep=0)
    stats_store.enforce_cap(sconn, "unused", CAP_MB)
    # the opening checkpoint plus one per batch: ten rows, one batch
    assert len(checkpoints) == 2


def test_gap_rows_ride_a_batch_instead_of_splitting_it(sconn, monkeypatch):
    # forty gaps, several sharing a minute, among twenty days: one batch of
    # the twenty day groups takes every gap older than its cutoff along
    for i in range(40):
        moment = f"2024-01-01T00:{i // 3:02d}:{(i % 3) * 8:02d}Z"
        sconn.execute("INSERT INTO stats_gap (started, ended, reason) "
                      "VALUES (?, ?, 'test')", (moment, moment))
    for d in range(1, 21):
        _insert(sconn, _entry("day"), f"2024-02-{d:02d}", "192.0.2.20")
    checkpoints = []
    real = maintain._checkpoint
    monkeypatch.setattr(maintain, "_checkpoint",
                        lambda c: checkpoints.append(1) or real(c))
    _measure_rows(monkeypatch, sconn, keep=0)
    pruned = stats_store.enforce_cap(sconn, "unused", CAP_MB)
    assert (pruned["gap"], pruned["day"]) == (40, 20)
    assert len(checkpoints) == 2  # the opening one and ONE batch


def test_a_store_of_gaps_alone_is_still_capped(sconn, monkeypatch, one_group):
    for minute in range(3):
        for second in (0, 30):
            moment = f"2024-01-01T00:{minute:02d}:{second:02d}Z"
            sconn.execute("INSERT INTO stats_gap (started, ended, reason) "
                          "VALUES (?, ?, 'test')", (moment, moment))
    _measure_rows(monkeypatch, sconn, keep=4)
    pruned = stats_store.enforce_cap(sconn, "unused", CAP_MB)
    # one minute's group: both of its rows, nothing newer
    assert pruned["gap"] == 2
    assert sconn.execute("SELECT MIN(started) FROM stats_gap").fetchone()[0] \
        == "2024-01-01T00:01:00Z"


def test_every_capped_table_is_reported(sconn):
    pruned = stats_store.enforce_cap(sconn, "unused", 0)
    assert set(pruned) == {e[0] for e in stats_store._CAP_TIERS}


# --- I-3 ----------------------------------------------------------------------

_row = st.tuples(st.integers(min_value=0, max_value=len(stats_store._CAP_TIERS) - 1),
                 st.integers(min_value=0, max_value=800 * 24 * 60),
                 st.sampled_from(["192.0.2.20", "192.0.2.21"]))


@settings(max_examples=60, deadline=None,
          suppress_health_check=[HealthCheck.function_scoped_fixture])
@given(rows=st.lists(_row, min_size=1, max_size=60),
       keep_share=st.floats(min_value=0, max_value=1),
       batch=st.integers(min_value=1, max_value=20))
def test_I3_the_cap_prunes_a_prefix_of_the_global_age_order(
        panel_env, monkeypatch, rows, keep_share, batch):
    monkeypatch.setattr(maintain, "_CAP_BATCH", batch)
    path = panel_env["data"] / "state" / f"i3-{uuid4().hex}.db"
    conn = stats_store.open_stats_db(path)
    try:
        for index, back, device in rows:
            entry = stats_store._CAP_TIERS[index]
            _insert(conn, entry, _key(entry, NOW - timedelta(minutes=back)),
                    device)
        before = _rows(conn)
        keep = int(len(before) * keep_share)
        _measure_rows(monkeypatch, conn, keep)
        stats_store.enforce_cap(conn, path, CAP_MB)
        after = _rows(conn)
        assert len(after) <= keep
        survivors = {(e[0], k) for e, k in after}
        removed = [(e, k) for e, k in before if (e[0], k) not in survivors]
        if removed and after:
            newest_removed = max(_age(e, k) for e, k in removed)
            oldest_kept = min(_age(e, k) for e, k in after)
            assert newest_removed < oldest_kept, (newest_removed, oldest_kept)
    finally:
        conn.close()
