"""Breakdown reads (#98): per-value totals of one dimension over a window,
sorted and paged, with the honesty facts a top-N chart needs - where the
dimension's data starts, and how many device bytes it never recorded."""

from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta

from app.store.stats.read import _TIER_TABLES, MOVED, dimension_tables
from app.store.stats.schema import (
    APP_TABLE,
    DIMENSIONS,
    DOMAIN_RETENTION_DAYS,
    NO_DICTIONARY,
    UNATTRIBUTED,
)
from app.store.stats.window import (
    _usable,
    _window_plan,
    read_window_timeline,
    window_key,
)

# The long-term dimensions partition the device tier: every byte the device
# tier holds since v1.11 has exactly one value in each, so the shortfall
# against it is bytes the dimension never recorded (#95).
PARTITION_DIMS = DIMENSIONS
# The policy group is the device tier's own `chain` column.
GROUP_DIM = "group"
# The seven-day class (hostname, app id): opt-in, forced 7 days, and NOT a
# partition - only flows that carried a name (or matched the dictionary)
# with the gate on have rows. (table, value column)
CLASS_DIMS = {"host": ("stats_domain", "domain"), "app": (APP_TABLE, "value")}
BREAKDOWN_DIMS = ("exit", GROUP_DIM, "rule", "category", "country", "host",
                  "app")
# the overview's top devices: the device tier grouped by device (internal)
DEVICE_DIM = "device"

SORTS = ("total", "up", "down")
LIMIT_MAX = 200

# What a category value means (#97): a coarse id, or one of the two values
# that are not a category at all.
CATEGORY_CLASSES = {UNATTRIBUTED: "unattributed", NO_DICTIONARY: "no_dictionary"}


def category_class(value: str) -> str:
    return CATEGORY_CLASSES.get(value, "coarse")


@dataclass(frozen=True)
class Window:
    """A read window. RANGED: a `range=` preset - SINCE (None = everything
    held) under FRAME, read window-complete across tiers. Otherwise a single
    tier read between the SINCE_KEY and UNTIL_KEY strings. RESOLUTION is the
    one asked for; a dimension without that tier reads the nearest it has.
    NOW floors the seven-day class."""

    resolution: str
    ranged: bool
    now: datetime
    since: datetime | None = None
    frame: object = None
    since_key: str = ""
    until_key: str = ""


def _tiers(dim: str) -> dict:
    """{tier: (table, value column)} for DIM."""
    if dim in (GROUP_DIM, DEVICE_DIM):
        col = "chain" if dim == GROUP_DIM else "device"
        return {tier: (table, col) for tier, table in _TIER_TABLES.items()}
    if dim in CLASS_DIMS:
        return {"hour": CLASS_DIMS[dim]}
    return {tier: (table, "value")
            for tier, table in dimension_tables(dim).items()}


def resolution_for(dim: str, resolution: str) -> str:
    """The tier DIM is read at for a requested RESOLUTION: the dimensions
    have no minute tier (an hour read stands in), and the seven-day class
    holds hours only."""
    tiers = _tiers(dim)
    if resolution in tiers:
        return resolution
    return "hour"


def class_floor(now: datetime) -> str:
    """The seven-day class's lower bound, an hour key: enforced in the query,
    not left to pruning - an older image after a rollback never prunes a
    table it does not know."""
    return (now - timedelta(days=DOMAIN_RETENTION_DAYS)).astimezone(
        UTC).strftime("%Y-%m-%dT%H")


_KEY_LEN = {"minute": 16, "hour": 13, "day": 10}


def _fit(window: Window, resolution: str) -> Window:
    """A single-tier WINDOW read at another tier than it asked for, its
    since/until keys fitted to the read tier, so the bucket a bound falls in
    is kept. Read COARSER (a dimension has no minute tier) the keys are cut
    to the tier's length - as a string, a minute key sorts after its own
    hour. Read FINER (the seven-day class holds hours, a day was asked) the
    `until` key is extended past every finer key it prefixes - as a string,
    `2026-10-15` sorts before every hour of that day."""
    if window.ranged or window.resolution == resolution:
        return window
    size = _KEY_LEN[resolution]
    if size < _KEY_LEN.get(window.resolution, size):
        return replace(window, since_key=window.since_key[:size],
                       until_key=window.until_key[:size])
    return replace(window, until_key=window.until_key + "~"
                   if window.until_key else "")


def _sources(conn, dim: str, window: Window) -> tuple[str, list]:
    """(resolution read, [(table, value column, lower bound or None)])."""
    tiers = _tiers(dim)
    resolution = resolution_for(dim, window.resolution)
    if dim in CLASS_DIMS:
        table, col = tiers["hour"]
        floor = class_floor(window.now)
        if window.ranged and window.since is not None:
            floor = max(floor, window_key(window.since, "hour", window.frame))
        return resolution, [(table, col, floor)]
    if not window.ranged:
        table, col = tiers[resolution]
        return resolution, [(table, col, None)]
    plan = _window_plan(conn, resolution, window.since, _usable(window.frame),
                        {tier: table for tier, (table, _c) in tiers.items()})
    cols = {table: col for table, col in tiers.values()}
    return resolution, [(table, cols[table], bound) for table, bound in plan]


def _select(sources, columns: str, window: Window, device: str = "",
            value: tuple | None = None) -> tuple[str, list]:
    """One UNION ALL over SOURCES; COLUMNS may name `{v}`, the source's value
    column. Tier-mode windows add the since/until string bounds."""
    selects, params = [], []
    for table, col, bound in sources:
        where = []
        if device:
            where.append("device = ?")
            params.append(device)
        if value is not None:
            where.append(f"{value[0].format(v=col)} = ?")
            params.append(value[1])
        if bound is not None:
            where.append("bucket >= ?")
            params.append(bound)
        if not window.ranged:
            if window.since_key:
                where.append("bucket >= ?")
                params.append(window.since_key)
            if window.until_key:
                where.append("bucket <= ?")
                params.append(window.until_key)
        clause = f" WHERE {' AND '.join(where)}" if where else ""
        selects.append(f"SELECT {columns.format(v=col)} FROM {table}{clause}")
    return " UNION ALL ".join(selects), params


def _totals(conn, sources, window, device="", value=None) -> tuple[int, int]:
    union, params = _select(sources, "up, down", window, device, value)
    up, down = conn.execute(
        f"SELECT COALESCE(SUM(up), 0), COALESCE(SUM(down), 0) FROM ({union})",
        params).fetchone()
    return up, down


def _key_start(key: str) -> datetime | None:
    """The UTC moment a bucket key starts at; a local day key reads as its
    UTC date (the truncation flag is day-granular there)."""
    for fmt, size in (("%Y-%m-%dT%H:%M", 16), ("%Y-%m-%dT%H", 13),
                      ("%Y-%m-%d", 10)):
        if len(key) == size:
            try:
                return datetime.strptime(key, fmt).replace(tzinfo=UTC)
            except ValueError:
                return None
    return None


def _oldest(conn, sources, floor: str = "") -> str:
    """The earliest bucket any source table holds (global: no device or
    window filter), in that table's own key format - at or after FLOOR when
    given: a seven-day class row below its floor is a leftover an older
    image never pruned, which no read returns."""
    found = []
    for table, _col, _bound in sources:
        clause, params = (" WHERE bucket >= ?", [floor]) if floor else ("", [])
        key = conn.execute(f"SELECT MIN(bucket) FROM {table}{clause}",
                           params).fetchone()[0]
        start = _key_start(key) if key else None
        if start is not None:
            found.append((start, key))
    return min(found)[1] if found else ""


def _window_block(conn, dim, sources, window, unrecorded) -> dict:
    oldest = _oldest(conn, sources,
                     class_floor(window.now) if dim in CLASS_DIMS else "")
    block = {"oldest_bucket": oldest}
    if dim in CLASS_DIMS:
        start = sources[0][2]
        asked = (window_key(window.since, "hour", window.frame)
                 if window.ranged and window.since is not None
                 else window.since_key if not window.ranged else "")
        block["retention_days"] = DOMAIN_RETENTION_DAYS
        # one key format (hours): a day key names the day's first hour
        asked_hour = (asked[:13] if len(asked) >= 13
                      else f"{asked}T00" if asked else "")
        block["since"] = max(start, asked_hour) if asked else start
        # the window was cut at the seven-day floor, or starts before the
        # first row held
        clamped = not asked or asked < class_floor(window.now)
        block["truncated"] = bool(
            clamped or (oldest and block["since"] < oldest))
        return block
    if not window.ranged:
        # one table, one key format: compared as strings, as the read is
        since = window.since_key
        if not since and dim in PARTITION_DIMS:
            # an unbounded read starts where the device tier does
            since = _oldest(conn, _device_sources(conn, sources, window))
        block["truncated"] = bool(since and oldest and since < oldest) or (
            not oldest and bool(unrecorded and any(unrecorded.values())))
        return block
    start = window.since
    if start is None and dim in PARTITION_DIMS:
        # an unbounded window starts where the device tier does
        start = _key_start(
            _oldest(conn, _device_sources(conn, sources, window)) or "")
    oldest_start = _key_start(oldest) if oldest else None
    if oldest_start is None:
        block["truncated"] = bool(unrecorded and any(unrecorded.values()))
    else:
        block["truncated"] = bool(start is not None and start < oldest_start)
    return block


def _device_sources(conn, sources, window):
    """The device tier over the same window, at the resolution the
    dimension was read at - its own plan (the first held hour of a local day
    is found in the device tier's own hours)."""
    resolution = "day" if any(t.endswith("_day") for t, _c, _b in sources) \
        else "hour"
    if not window.ranged:
        return [(_TIER_TABLES[resolution], "chain", None)]
    plan = _window_plan(conn, resolution, window.since, _usable(window.frame))
    return [(table, "chain", bound) for table, bound in plan]


def read_breakdown(conn, dim: str, window: Window, *, device: str = "",
                   sort: str = "total", limit: int = 50, offset: int = 0,
                   domains_enabled: bool = False,
                   value: tuple | None = None,
                   by_device: bool = False) -> dict:
    """Per-value totals of DIM over WINDOW, largest first by SORT, the page
    OFFSET..OFFSET+LIMIT (LIMIT clamped to 1..200).

    `total` and `total_rows` are the whole window's, not the page's. A value
    that moved no bytes is never listed (MOVED). A long-term dimension also
    reports `unrecorded`: the device tier's bytes over the same window minus
    the dimension's - bytes from before v1.11, from a time an older image
    ran, or left by a one-table purge, which a chart must show as a hole and
    never as less traffic. A seven-day class dimension with the gate off
    answers `enabled: false` and no rows, whatever is still stored. VALUE,
    a (column, value) pair - `{v}` names the value column - keeps one
    value's rows, and BY_DEVICE groups them by device instead (the
    overview's scoped reads: the devices behind one category)."""
    if sort not in SORTS:
        raise ValueError(f"unknown sort {sort!r}")
    limit = max(1, min(int(limit), LIMIT_MAX))
    offset = max(0, int(offset))
    resolution, sources = _sources(conn, dim, window)
    window = _fit(window, resolution)
    body = {"dim": DEVICE_DIM if by_device else dim, "tier": resolution,
            "sort": sort, "limit": limit, "offset": offset}
    if by_device:
        # the devices behind one value of DIM
        body["within"] = {"dim": dim, "value": value[1] if value else None}
    if dim in CLASS_DIMS:
        body["enabled"] = bool(domains_enabled)
        if not domains_enabled:
            body.update(total_rows=0, total={"up": 0, "down": 0}, rows=[],
                        window={"retention_days": DOMAIN_RETENTION_DAYS})
            return body
    columns = "device AS value, up, down" if by_device else \
        "{v} AS value, up, down"
    union, params = _select(sources, columns, window, device, value)
    rows = [dict(r) for r in conn.execute(
        f"SELECT value, SUM(up) AS up, SUM(down) AS down FROM ({union}) "
        f"GROUP BY value {MOVED}", params)]
    key = {"total": lambda r: r["up"] + r["down"], "up": lambda r: r["up"],
           "down": lambda r: r["down"]}[sort]
    rows.sort(key=lambda r: (-key(r), r["value"]))
    total_up = sum(r["up"] for r in rows)
    total_down = sum(r["down"] for r in rows)
    page = rows[offset:offset + limit]
    if dim == "category" and value is None and not by_device:
        for r in page:
            r["class"] = category_class(r["value"])
    unrecorded = None
    if dim in PARTITION_DIMS and value is None and not by_device:
        dev_up, dev_down = _totals(conn, _device_sources(conn, sources, window),
                                   window, device)
        unrecorded = {"up": max(0, dev_up - total_up),
                      "down": max(0, dev_down - total_down)}
        body["unrecorded"] = unrecorded
    body.update(total_rows=len(rows), total={"up": total_up, "down": total_down},
                rows=page,
                window=_window_block(conn, dim, sources, window, unrecorded))
    return body


def window_info(conn, dim: str, window: Window) -> dict:
    """The `window` block of DIM over WINDOW alone - where its data starts,
    whether the window reaches before it, and for the seven-day class the
    floor it was cut at (the overview's scoped totals carry it)."""
    resolution, sources = _sources(conn, dim, window)
    window = _fit(window, resolution)
    device_bytes = None
    if dim in PARTITION_DIMS:
        # where the dimension holds nothing at all, the window is still
        # incomplete if the device tier moved bytes in it (pre-v1.11 hours,
        # a one-table purge): the block's no-data branch reads this
        up, down = _totals(conn, _device_sources(conn, sources, window),
                           window)
        device_bytes = {"up": up, "down": down}
    return _window_block(conn, dim, sources, window, device_bytes)


def read_dim_timeline(conn, dim: str, window: Window, value: str,
                      device: str = "") -> tuple[str, list]:
    """(resolution, bucket rows) of ONE value of a long-term or class
    dimension over a RANGED window - the overview's category and host
    scopes. Only buckets that moved bytes; a class dimension reads hours
    from its seven-day floor."""
    resolution, sources = _sources(conn, dim, window)
    if dim in PARTITION_DIMS:
        rows = read_window_timeline(conn, resolution, device, window.since,
                                    window.frame, dimension_tables(dim),
                                    ("value", value))
        return resolution, rows
    union, params = _select(sources, "bucket, up, down", window, device,
                            ("{v}", value))
    rows = [dict(r) for r in conn.execute(
        f"SELECT bucket, SUM(up) AS up, SUM(down) AS down FROM ({union}) "
        f"GROUP BY bucket {MOVED} ORDER BY bucket", params)]
    return resolution, rows
