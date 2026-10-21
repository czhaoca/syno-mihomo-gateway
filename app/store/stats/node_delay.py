"""The selected node's delay per policy group, and the subscription quota
(#102) - the two things the panel samples from mihomo besides traffic.

Both are read PASSIVELY: the delay is the newest entry of the history mihomo
keeps from its own health checks (the panel never probes a node itself), and
the quota is the `subscriptionInfo` mihomo restores from a provider's
`subscription-userinfo` header. Nothing here is per device.

Node delay rows are keyed by the TEST's own time, so sampling a node nobody
re-tested adds no row, and a failed test (mihomo reports delay 0) is NULL -
"no answer", never "0 ms". The quota is one `stats_meta` key per provider,
holding exactly five fields, rewritten whole on every successful sample.
"""

import json
import re
from contextlib import suppress
from datetime import UTC, datetime, timedelta

from app.store.stats.schema import NODE_DELAY_TABLE
from app.store.stats.window import RANGE_SPECS

# mihomo samples cadence-free; the panel reads the newest test this often
DELAY_EVERY_S = 300
# a minute-resolution preset is served as the samples themselves; anything
# longer as hour aggregates, so a 30-day chart never ships every test
RAW_RANGES = ("24h", "48h")

QUOTA_PREFIX = "quota:"
QUOTA_FIELDS = ("upload", "download", "total", "expire", "updatedAt")

# RFC 3339 as mihomo writes it, fraction up to nanoseconds, any offset
_STAMP = re.compile(
    r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.(\d+))?"
    r"(Z|[+-]\d{2}:?\d{2})?$")
# Go's zero time (and anything before the epoch) means "never"
_EPOCH = datetime(1971, 1, 1, tzinfo=UTC)


def utc_stamp(text) -> str | None:
    """TEXT (mihomo's RFC 3339 time, with up to nanoseconds and any offset)
    as the panel's `YYYY-MM-DDTHH:MM:SSZ`, or None when it is not a time or
    is Go's zero time."""
    if not isinstance(text, str):
        return None
    m = _STAMP.match(text.strip())
    if not m:
        return None
    day, clock, fraction, zone = m.groups()
    zone = zone or "Z"
    if zone != "Z" and ":" not in zone:
        zone = f"{zone[:3]}:{zone[3:]}"
    try:
        moment = datetime.fromisoformat(
            f"{day}T{clock}{'.' + fraction[:6] if fraction else ''}"
            f"{'+00:00' if zone == 'Z' else zone}")
        if moment < _EPOCH:
            return None
        # astimezone overflows past year 9999 (a far-future stamp with a
        # negative offset): that is no time either
        return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OverflowError):
        return None


def record_delays(conn, rows) -> int:
    """ROWS (tested_at, group, node, delay_ms) into the table, one
    transaction; a test already held is ignored. Returns rows added."""
    if not rows:
        return 0
    before = conn.total_changes
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.executemany(
            f"INSERT OR IGNORE INTO {NODE_DELAY_TABLE} "
            "(tested_at, grp, node, delay_ms) VALUES (?, ?, ?, ?)", rows)
        conn.execute("COMMIT")
    except BaseException:
        with suppress(Exception):
            conn.execute("ROLLBACK")
        raise
    return conn.total_changes - before


def prune_delays_sql(now_dt: datetime, days: int) -> tuple[str, tuple]:
    """The retention DELETE for `rollup` (it runs inside its transaction)."""
    cut = (now_dt - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return f"DELETE FROM {NODE_DELAY_TABLE} WHERE tested_at < ?", (cut,)


def read_node_delay(conn, range_name: str, now: datetime,
                    retention_days: int) -> dict:
    """The delay history of every group's selected node over a range preset.

    The window is honest: it starts at the later of the preset's start and
    the retention horizon, and `truncated` says when the preset reached
    further back than anything is kept. A minute preset is served as the
    tests themselves; a longer one as hour aggregates, where a failed test is
    counted (`failed`) and never averaged in as 0 - an hour of nothing but
    failures has a null delay. `latest` is the group's newest stored test:
    the selection as of its `tested_at`, which is not necessarily now."""
    hours = RANGE_SPECS[range_name][1]
    floor = now - timedelta(days=retention_days)
    start = floor if hours is None else max(now - timedelta(hours=hours), floor)
    truncated = hours is None or now - timedelta(hours=hours) < floor
    since = start.strftime("%Y-%m-%dT%H:%M:%SZ")
    raw = range_name in RAW_RANGES
    groups: dict[str, dict] = {}

    def group(name):
        return groups.setdefault(name, {"group": name, "latest": None,
                                        "points": []})

    # the group's newest test; two at the same second (a switch within it)
    # resolve to the one written last. One pass over the table (the primary
    # key's index serves the partition): a correlated lookup per row was
    # quadratic, seconds per read at a fortnight of tests - and a long read
    # holds the WAL snapshot the maintenance checkpoint waits on under the
    # stats lock.
    for r in conn.execute(
            "SELECT grp, node, tested_at, delay_ms FROM ("
            "SELECT grp, node, tested_at, delay_ms, ROW_NUMBER() OVER ("
            "PARTITION BY grp ORDER BY tested_at DESC, rowid DESC) AS n "
            f"FROM {NODE_DELAY_TABLE}) WHERE n = 1 ORDER BY grp"):
        group(r["grp"])["latest"] = {"node": r["node"], "tested_at": r["tested_at"],
                                     "delay_ms": r["delay_ms"]}
    if raw:
        rows = conn.execute(
            f"SELECT grp, node, tested_at, delay_ms FROM {NODE_DELAY_TABLE} "
            "WHERE tested_at >= ? ORDER BY grp, tested_at, node", (since,))
        for r in rows:
            group(r["grp"])["points"].append(
                {"at": r["tested_at"], "node": r["node"], "delay_ms": r["delay_ms"]})
    else:
        rows = conn.execute(
            f"SELECT grp, node, substr(tested_at, 1, 13) AS hour, "
            "AVG(delay_ms) AS mean, MIN(delay_ms) AS low, MAX(delay_ms) AS high, "
            "COUNT(delay_ms) AS ok, COUNT(*) - COUNT(delay_ms) AS failed "
            f"FROM {NODE_DELAY_TABLE} WHERE tested_at >= ? "
            "GROUP BY grp, hour, node ORDER BY grp, hour, node", (since,))
        for r in rows:
            group(r["grp"])["points"].append({
                "at": r["hour"], "node": r["node"],
                "delay_ms": None if r["mean"] is None else round(r["mean"]),
                "min_ms": r["low"], "max_ms": r["high"],
                "tests": r["ok"], "failed": r["failed"]})
    return {"range": range_name, "resolution": "test" if raw else "hour",
            "retention_days": retention_days, "since": since,
            "truncated": truncated, "sampled_every_s": DELAY_EVERY_S,
            "groups": sorted(groups.values(), key=lambda g: g["group"])}


def _count(value, *, positive: bool = False):
    """A quota number: an int >= 0 (> 0 with POSITIVE), else None. mihomo
    zero-fills a field the provider never sent, so a zero total or expiry
    means "unknown / unlimited / never", not a real limit."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value != value or value in (float("inf"), float("-inf")):  # NaN, inf
        return None
    value = int(value)
    if value < 0 or (positive and value == 0):
        return None
    return value


def quota_entry(info) -> dict | None:
    """The five quota fields of one /providers/proxies entry - and nothing
    else of it (it also carries the provider's whole node list, and a future
    build could add a URL) - or None when it reports no subscriptionInfo."""
    if not isinstance(info, dict):
        return None
    sub = info.get("subscriptionInfo")
    if not isinstance(sub, dict):
        return None

    def pick(name, **kw):
        for key in (name.capitalize(), name):
            if key in sub:
                return _count(sub[key], **kw)
        return None

    return {"upload": pick("upload"), "download": pick("download"),
            "total": pick("total", positive=True),
            "expire": pick("expire", positive=True),
            "updatedAt": utc_stamp(info.get("updatedAt"))}


def write_quota(conn, entries: dict) -> None:
    """Replace the whole quota set with ENTRIES ({provider: five fields}) in
    one transaction - a provider no longer reported loses its key. Only the
    `quota:` keys are touched; the poll stamp and every other accounting key
    in stats_meta are matched out exactly (a prefix compare, never LIKE)."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute(delete_quota_sql(), (QUOTA_PREFIX,))
        conn.executemany(
            "INSERT INTO stats_meta (k, v) VALUES (?, ?)",
            [(QUOTA_PREFIX + name,
              json.dumps({f: entry[f] for f in QUOTA_FIELDS}, sort_keys=True))
             for name, entry in sorted(entries.items())])
        conn.execute("COMMIT")
    except BaseException:
        with suppress(Exception):
            conn.execute("ROLLBACK")
        raise


def delete_quota_sql() -> str:
    """Every quota key and no other (the bare purge runs it too)."""
    return (f"DELETE FROM stats_meta WHERE substr(k, 1, {len(QUOTA_PREFIX)}) = ?")


def read_quota(conn) -> list[dict]:
    """The stored quota, one entry per provider, by name."""
    out = []
    for r in conn.execute(
            f"SELECT k, v FROM stats_meta WHERE substr(k, 1, {len(QUOTA_PREFIX)}) = ? "
            "ORDER BY k", (QUOTA_PREFIX,)):
        try:
            doc = json.loads(r["v"])
        except ValueError:
            continue
        out.append({"provider": r["k"][len(QUOTA_PREFIX):],
                    **{f: doc.get(f) for f in QUOTA_FIELDS}})
    return out
