"""Rollup cascade, per-tier retention, the hard size cap and the purge -
the store's maintenance path."""

import json
from contextlib import suppress
from datetime import timedelta
from pathlib import Path

from app import config
from app.store import dayframe
from app.store.stats.schema import (
    CLASS_TABLES,
    DIMENSIONS,
    DOMAIN_RETENTION_DAYS,
    MINUTE_TABLE,
    PURGE_TABLES,
    SELF_TABLE,
    _db_bytes,
    _parse_ts,
)

# hour table -> day table it rolls into, the key column beside bucket and
# device, and whether it carries #94's per-bucket facts
_DAY_ROLLS = (("stats_hour", "stats_day", "chain", True),
              *((f"stats_{dim}_hour", f"stats_{dim}_day", "value", False)
                for dim in DIMENSIONS))

# the tables under the FORCED seven-day horizon (brief DEC-8 rider, #77 DEC-A,
# and #96's own gauges)
_SEVEN_DAY_TABLES = ("stats_domain", "stats_coverage", *CLASS_TABLES,
                     SELF_TABLE)

# tables with no device column: a device-scoped purge leaves them alone
_NO_DEVICE_TABLES = ("stats_gap", SELF_TABLE)


def _roll_days(conn, hour_table, day_table, key_col, facts, hours, frame):
    """Sum the hour rows of HOURS into local days of FRAME - one statement:
    the hour -> day key mapping travels as one JSON parameter, because
    SQLite cannot do timezone maths but can still do every summation."""
    sums = ("SUM(h.samples), SUM(h.conns), MAX(h.peak_up), MAX(h.peak_down), "
            if facts else "")
    cols = "samples, conns, peak_up, peak_down, " if facts else ""
    merge = (", samples = samples + excluded.samples, "
             "conns = conns + excluded.conns, "
             "peak_up = max(peak_up, excluded.peak_up), "
             "peak_down = max(peak_down, excluded.peak_down)" if facts else "")
    conn.execute(
        f"INSERT INTO {day_table} (bucket, device, {key_col}, up, down, {cols}"
        f"bucket_tz, day_boundary) "
        f"SELECT m.day, h.device, h.{key_col}, SUM(h.up), SUM(h.down), {sums}"
        f"?, ? FROM {hour_table} AS h JOIN (SELECT "
        f"json_extract(j.value, '$[0]') AS hour, "
        f"json_extract(j.value, '$[1]') AS day FROM json_each(?) AS j) AS m "
        f"ON h.bucket = m.hour WHERE true GROUP BY m.day, h.device, h.{key_col} "
        f"ON CONFLICT(bucket, device, {key_col}, bucket_tz, day_boundary) "
        f"DO UPDATE SET up = up + excluded.up, down = down + excluded.down"
        f"{merge}",
        (frame.tz, frame.cut, hours))


def rollup(conn, now: str, *, day) -> None:
    """Cascade + retention in one transaction: minute rows older than the
    minute window expire, hours older than the hour window aggregate into
    local days, days expire; the seven-day tables prune at their FORCED
    horizon.

    Since #95 the collector writes the hour tier at ingest, beside the
    minute tier, so minute -> hour is retention only: every minute byte is
    already in its hour. Hour -> day still MOVES rows, for the device tier
    and every dimension alike.

    DAY is a `dayframe.DayFrame` and is REQUIRED, deliberately. Defaulting
    it would let a call site that forgot the framing produce UTC-keyed rows
    that look like a decision; "cannot key locally" is a value
    (`DayFrame.ok is False`), not an omitted argument, so it has exactly
    one representation. An unusable frame degrades to UTC here rather than
    skipping the roll: the hour DELETE below is also the hour tier's ONLY
    retention, so a paused roll would grow the hour tables without bound
    while the cap destroyed older history to make room for them.
    """
    now_dt = _parse_ts(now)
    minute_cut = (now_dt - timedelta(
        hours=config.stats_minute_hours())).strftime("%Y-%m-%dT%H:%M")
    hour_cut = (now_dt - timedelta(
        days=config.stats_hour_days())).strftime("%Y-%m-%dT%H")
    day_slack = (now_dt - timedelta(
        days=config.stats_day_days() + 1)).strftime("%Y-%m-%d")
    domain_cut = (now_dt - timedelta(
        days=DOMAIN_RETENTION_DAYS)).strftime("%Y-%m-%dT%H")
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute(f"DELETE FROM {MINUTE_TABLE} WHERE bucket < ?",
                     (minute_cut,))
        # The day tier is LOCAL-keyed: the key is computed once per distinct
        # hour bucket in Python, and every table rolls in one statement.
        # `frame` supplies both the mapping and the stamp written into the
        # row's identity. Counts sum and peaks keep the largest (#94).
        frame = day if day.ok else dayframe.utc_frame()
        hours = sorted({r[0] for hour_table, *_ in _DAY_ROLLS
                        for r in conn.execute(
                            f"SELECT DISTINCT bucket FROM {hour_table} "
                            f"WHERE bucket < ?", (hour_cut,))})
        if hours:
            mapping = json.dumps([[h, dayframe.day_key(h, frame)]
                                  for h in hours])
            for hour_table, day_table, key_col, facts in _DAY_ROLLS:
                _roll_days(conn, hour_table, day_table, key_col, facts,
                           mapping, frame)
                conn.execute(f"DELETE FROM {hour_table} WHERE bucket < ?",
                             (hour_cut,))
        # Retention stays UTC-derived with a day of slack: a local day key
        # can sit either side of the UTC date it was rolled from, so
        # comparing it against a UTC-derived horizon could otherwise evict
        # a day the operator has not yet finished accumulating.
        for _hour_table, day_table, _key, _facts in _DAY_ROLLS:
            conn.execute(f"DELETE FROM {day_table} WHERE bucket < ?",
                         (day_slack,))
        # DEC-A (#77, panel-confirmed): coverage inherits the domain table's
        # FORCED horizon rather than gaining a knob of its own, and so does
        # every seven-day class table (#95) - the rejected option would
        # have extended retention of hostname-adjacent data past a
        # documented, deliberately non-configurable promise.
        for table in _SEVEN_DAY_TABLES:
            conn.execute(f"DELETE FROM {table} WHERE bucket < ?",
                         (domain_cut,))
        # gap history ages out with the oldest data tier: a gap older than
        # any retained measurement explains nothing (and an unbounded gap
        # table could otherwise defeat the hard size cap)
        conn.execute("DELETE FROM stats_gap WHERE ended < ?", (day_slack,))
        conn.execute("COMMIT")
    except BaseException:
        with suppress(Exception):
            conn.execute("ROLLBACK")
        raise


# --- the hard size cap (#95, DEC-C: by data age across every table) ------------
#
# (name, table, age column, key length, tie rank). A row's age is when its
# bucket STARTS: the key padded to minute precision, so a day `2026-10-12`
# reads as 2026-10-12T00:00 and an hour `2026-10-12T08` as 08:00. A local
# day key is compared by its date - the approximation every day read makes:
# a local day really starts at its date plus the day boundary minus the
# zone's UTC offset, so where the day and hour tiers meet (the hour retention
# horizon) the order can be off by that much. On an exact tie the lower rank
# goes first: the seven-day class (it expires within the week anyway), then
# the minute tiers (finer copies of the hour tier since #95), then the
# long-term tables, then the gap history.
_KEY_PAD = "0000-00-00T00:00"
_CAP_TIERS = (("domain", "stats_domain", "bucket", 13, 0),
              ("coverage", "stats_coverage", "bucket", 13, 0),
              *((t.removeprefix("stats_"), t, "bucket", 13, 0)
                for t in CLASS_TABLES),
              ("self", SELF_TABLE, "bucket", 16, 0),
              ("minute", MINUTE_TABLE, "bucket", 16, 1),
              ("legacy_minute", "stats_minute", "bucket", 16, 1),
              ("hour", "stats_hour", "bucket", 13, 2),
              ("day", "stats_day", "bucket", 10, 2),
              *((f"{dim}_{tier}", f"stats_{dim}_{tier}", "bucket",
                 13 if tier == "hour" else 10, 2)
                for dim in DIMENSIONS for tier in ("hour", "day")),
              ("gap", "stats_gap", "started", 16, 3))
# age groups - distinct (start, rank) - removed per cap batch
_CAP_BATCH = 20


def _start(key: str, length: int) -> str:
    key = key[:length]
    return key + _KEY_PAD[len(key):]


def _age_clause(col: str, length: int, moment: str, *,
                inclusive: bool) -> tuple[str, str]:
    """(SQL condition, parameter) selecting the rows of a table whose keys
    are LENGTH characters long and whose bucket starts before MOMENT (a
    padded minute key) - or at it too, with INCLUSIVE. In the table's own
    key format: `key <= moment[:length]` covers "starts at or before"; for
    "strictly before" a bucket that straddles an unaligned moment still
    starts before it, so it is `<` only when MOMENT is aligned to the
    table's granularity."""
    expr = col if col == "bucket" else f"substr({col}, 1, {length})"
    aligned = moment[length:] == _KEY_PAD[length:]
    strict = not inclusive and aligned
    return f"{expr} {'<' if strict else '<='} ?", moment[:length]


def _cap_groups(conn, entries) -> set:
    """Each entry's _CAP_BATCH oldest age groups. That is enough to find the
    global _CAP_BATCH oldest: an entry's later groups are each preceded by
    that many of its own."""
    groups = set()
    for _name, table, col, length, rank in entries:
        expr = col if col == "bucket" else f"substr({col}, 1, {length})"
        groups.update((_start(r[0], length), rank) for r in conn.execute(
            f"SELECT DISTINCT {expr} FROM {table} ORDER BY 1 LIMIT ?",
            (_CAP_BATCH,)))
    return groups


def _cap_cutoff(conn):
    """The (start, rank) of the newest age group in the next cap batch - the
    _CAP_BATCH oldest distinct groups of the BUCKETED tables - or None when
    every table is empty. Deleting every row, in every table, up to and
    including this group removes a PREFIX of the global age order
    (invariant I-3), and tables written on the same buckets (the device tier
    and its dimensions) lose the same buckets together.

    Gap rows ride along - every gap older than the cutoff goes in the same
    batch - rather than counting as groups of their own: each is a one-row
    group, so a store with many collection gaps would otherwise need a batch
    (and a checkpoint, under the writer lock) for every few of them while
    freeing almost nothing. Only a store holding nothing but gaps cuts by
    gap rows."""
    bucketed = [e for e in _CAP_TIERS if e[2] == "bucket"]
    groups = _cap_groups(conn, bucketed) or _cap_groups(
        conn, [e for e in _CAP_TIERS if e[2] != "bucket"])
    return sorted(groups)[:_CAP_BATCH][-1] if groups else None


def _checkpoint(conn) -> bool:
    """A TRUNCATE checkpoint; True when it completed.

    Since #93 the stats API reads through its own read-only connections,
    and a TRUNCATE checkpoint has to wait for every reader still using the
    WAL. It does wait - through `busy_timeout` (5 s), far longer than any
    request's read - but a snapshot held past that leaves the WAL in place
    and the checkpoint answers busy=1 instead of raising.
    """
    busy, _log, _done = conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    return busy == 0


def enforce_cap(conn, path: Path, cap_mb: int) -> dict:
    """Hard size cap: while over, delete the oldest age groups - by data age
    across every table (see _CAP_TIERS) - in one transaction, then vacuum +
    checkpoint once and re-measure. Returns rows pruned per table name.

    The size measured includes the WAL, so a pass whose checkpoint came
    back busy stops where it is: measuring a WAL a reader still pins would
    count bytes that are about to go, and keep deleting history to pay for
    them. The next maintenance pass retries. Without readers the checkpoint
    is never busy and the pass runs until the store is under the cap.
    """
    pruned = {name: 0 for name, *_ in _CAP_TIERS}
    if cap_mb <= 0:
        return pruned
    cap = cap_mb * 1024 * 1024
    if not _checkpoint(conn):
        return pruned
    while _db_bytes(path) > cap:
        cutoff = _cap_cutoff(conn)
        if cutoff is None:
            break
        moment, last_rank = cutoff
        deleted = 0
        conn.execute("BEGIN IMMEDIATE")
        try:
            for name, table, col, length, rank in _CAP_TIERS:
                clause, param = _age_clause(col, length, moment,
                                            inclusive=rank <= last_rank)
                count = conn.execute(f"DELETE FROM {table} WHERE {clause}",
                                     (param,)).rowcount
                pruned[name] += count
                deleted += count
            conn.execute("COMMIT")
        except BaseException:
            with suppress(Exception):
                conn.execute("ROLLBACK")
            raise
        if deleted <= 0:
            break
        conn.execute("PRAGMA incremental_vacuum").fetchall()
        if not _checkpoint(conn):
            break
    return pruned


# --- the purge -------------------------------------------------------------------

def _purge_where(table: str, device: str, before: str) -> tuple[str, list]:
    """The row filter of a scoped purge on TABLE (empty = every row).

    BEFORE is a UTC bucket-vocabulary moment; a row goes when its bucket
    STARTS before it, so a bucket straddling the moment goes too and
    nothing older survives (a day row is compared by its local date).
    """
    where, params = [], []
    if device:
        where.append("device = ?")
        params.append(device)
    if before:
        _name, _table, col, length, _rank = next(e for e in _CAP_TIERS
                                                 if e[1] == table)
        clause, param = _age_clause(col, length, _start(before, 16),
                                    inclusive=False)
        where.append(clause)
        params.append(param)
    return (f" WHERE {' AND '.join(where)}" if where else ""), params


def purge_stats(conn, *, device: str = "", tables=None,
                before: str = "") -> dict:
    """The token-gated purge: every VISIBLE stats surface goes - the tiers,
    the dimension and seven-day tables, gap history - or, scoped (#95), the
    rows of one DEVICE, of some TABLES, or whose bucket starts BEFORE a
    moment, in any combination. Returns rows deleted per table.

    conn_baseline and the poll stamp are ACCOUNTING STATE, not stats, and
    deliberately survive every form: dropping a baseline would make every
    still-open connection re-contribute its entire pre-purge cumulative on
    the very next poll - the exact double-count the delta model exists to
    prevent. The gap history and the collector's gauges have no device, so
    a device scope leaves them.
    The POLICY audit lives in policy.db and is untouched by construction.
    """
    # PURGE_TABLES is the single list, so a table added later cannot
    # quietly survive the one operation whose promise is that none does.
    chosen = [t for t in PURGE_TABLES if tables is None or t in tables]
    if device:
        chosen = [t for t in chosen if t not in _NO_DEVICE_TABLES]
    deleted = {}
    conn.execute("BEGIN IMMEDIATE")
    try:
        for table in chosen:
            clause, params = _purge_where(table, device, before)
            deleted[table] = conn.execute(f"DELETE FROM {table}{clause}",
                                          params).rowcount
        conn.execute("COMMIT")
    except BaseException:
        with suppress(Exception):
            conn.execute("ROLLBACK")
        raise
    conn.execute("PRAGMA incremental_vacuum").fetchall()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
    return deleted
