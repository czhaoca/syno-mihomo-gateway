"""Gateway Insights reads (#98): the per-dimension breakdown and the
landing-page overview. LAN-open like every stats read - which is why the
panel must never be exposed to the WAN (docs/panel.md, Security)."""

from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Query, Request

from app import config
from app.api import csv_export, routes
from app.store import settings
from app.store import stats as stats_store

router = APIRouter()

Dim = Literal["exit", "group", "rule", "category", "country", "host", "app"]
Sort = Literal["total", "up", "down"]


def _window(request: Request, range_, tier: str, since: str,
            until: str) -> stats_store.Window:
    """A ranged window for `range=`, else a single-tier one."""
    now = routes._utcnow()
    if range_ is not None:
        resolution, start, frame = routes._range_args(request, range_, tier)
        return stats_store.Window(resolution=resolution, ranged=True, now=now,
                                  since=start, frame=frame)
    return stats_store.Window(resolution=tier, ranged=False, now=now,
                              since_key=since, until_key=until)


@router.get("/v1/stats/breakdown", responses=csv_export.CSV_RESPONSES)
def stats_breakdown(
        request: Request,
        dim: Annotated[Dim, Query(description=(
            "The dimension: `exit` (exit node), `group` (policy group), "
            "`rule` (rule type), `category`, `country` - long-term - or "
            "`host` / `app` (hostname / app-level category id), the "
            "seven-day class, answered only with PANEL_STATS_DOMAINS on"))],
        tier: routes.Tier = "hour", since: str = "", until: str = "",
        device: str = "",
        sort: Annotated[Sort, Query(description=(
            "Largest first by `total` (up + down), `up` or `down`"))] = "total",
        limit: Annotated[int, Query(description=(
            "Rows per page, clamped to 1-200"))] = 50,
        offset: Annotated[int, Query(ge=0)] = 0,
        range_: routes.RangeParam = None,
        fmt: csv_export.FormatParam = "json"):
    """One dimension's values over a window, largest first, one page.

    `tier` is the resolution actually read: the dimensions have no minute
    tier (a 48-hour read is hourly) and the seven-day class holds hours
    only. `total` and `total_rows` cover the whole window, not the page; a
    value that moved no bytes is never listed. A long-term dimension
    reports `unrecorded` - device bytes in the window it has no record of
    (before v1.11, a time an older panel ran, a one-table purge) - and
    `window.oldest_bucket` / `window.truncated` say where its data starts.
    `category` rows carry `class`: `coarse`, `unattributed` (`unknown`, no
    answer) or `no_dictionary` (`""`, counted without a dictionary). `host`
    and `app` answer `enabled: false` and no rows with the gate off, and
    never reach back more than seven days (`window.since`, an hour key). A
    single-tier read at another tier than asked fits `since`/`until` to the
    tier read, so the bucket a bound falls in is kept: a minute bound on an
    hourly dimension is cut to its hour, and a day `until` on the hourly
    seven-day class takes every hour of that day.

    `format=csv` columns: `kind,value,up,down`, plus `class` for
    `dim=category`. `kind` is `value` for a dimension value and `unrecorded`
    for the one row (empty `value`) carrying the device bytes the dimension
    has no record of - a whole-window figure, so only on the first page
    (`offset=0`). A seven-day class export with the gate off is the header
    row alone."""
    window = _window(request, range_, tier, since, until)
    with routes._stats_reader(request) as conn:
        body = stats_store.read_breakdown(
            conn, dim, window, device=device, sort=sort, limit=limit,
            offset=offset, domains_enabled=config.stats_domains())
    body["device"] = device
    if range_ is not None:
        body["range"] = range_
    if fmt == "csv":
        return _breakdown_csv(body, range_ or tier)
    return body


def _breakdown_csv(body: dict, span: str):
    """`kind` marks each row: `value` for a dimension value, `unrecorded`
    for the device bytes the dimension has no record of (first page only -
    it is a whole-window figure). A category export adds `class`."""
    category = body["dim"] == "category"
    header = ["kind", "value", "up", "down"] + (["class"] if category else [])
    rows = [["value", r["value"], r["up"], r["down"]]
            + ([r["class"]] if category else []) for r in body["rows"]]
    missing = body.get("unrecorded")
    if missing is not None and body["offset"] == 0:
        rows.append(["unrecorded", "", missing["up"], missing["down"]]
                    + ([""] if category else []))
    return csv_export.response(header, rows,
                               f"stats-breakdown-{body['dim']}-{span}.csv")


@router.get("/v1/stats/overview")
def stats_overview(
        request: Request,
        range_: Annotated[routes.StatsRange, Query(
            alias="range", description=(
                "The window preset, as on the other stats reads"))
        ] = settings.DEFAULT_STATS_RANGE,
        device: str = "",
        category: Annotated[str | None, Query(description=(
            "Scope to one category value (a coarse id, `unknown`, or empty "
            "for bytes counted without a dictionary)"))] = None,
        host: Annotated[str | None, Query(min_length=1, description=(
            "Scope to one hostname (the seven-day class: only with "
            "PANEL_STATS_DOMAINS on)"))] = None,
        limit: Annotated[int, Query(description=(
            "Values per top list, clamped to 1-200"))] = 10) -> dict:
    """The landing page in one read: `totals`, `timeline`, `top` lists per
    dimension (the breakdown's shape), window-scoped `gaps`, `framings` at
    day resolution, the `coverage` report and `invisible_traffic_hint`, all
    from one read transaction, so every section describes the same moment.

    Scoped to a `category` or a `host` (not both), a section the stored
    tables cannot answer - the dimensions are stored independently, so a
    category has no exit nodes - is `null` and `unavailable` says why;
    nothing unknown is ever shown as zero. A scoped `totals` carries the
    scope's `window` (where its data starts; a host's seven-day floor), a
    scoped `top.device` names the scope in `within`, and `coverage` is
    `null` under any scope: it is measured for the whole gateway only.
    `gaps` lists the newest 100 overlapping the window, from the start of
    its first bucket; `gaps_truncated` says when there may be more."""
    if category is not None and host is not None:
        raise HTTPException(status_code=422,
                            detail="scope to a category or to a host, not both")
    # the preset's own resolution: the overview declares no `tier`, so one
    # sent anyway must not change what it reads
    resolution, start, frame = routes._range_args(
        request, range_, stats_store.RANGE_SPECS[range_][0])
    window = stats_store.Window(resolution=resolution, ranged=True,
                                now=routes._utcnow(), since=start, frame=frame)
    with routes._stats_reader(request) as conn:
        body = stats_store.read_overview(
            conn, window, device=device, category=category, host=host,
            limit=limit, domains_enabled=config.stats_domains())
    return {"range": range_, **body}
