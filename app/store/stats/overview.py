"""The landing page's whole answer in one read (#98 DEC-A): totals, the
timeline, the top values of each dimension, the gaps, the framings and the
coverage of one window, all from the caller's single read transaction.

A section the stored tables cannot answer for the asked scope is `null`,
and `unavailable` says why - never a zero that would read as "no traffic".
The dimensions are stored independently (there is no exit x category
table), so a category or host scope can say how much traffic it had, when,
and on which devices, but not its exit nodes or countries.
"""

from datetime import timedelta

from app.store.stats.breakdown import (
    DEVICE_DIM,
    Window,
    read_breakdown,
    read_dim_timeline,
    window_info,
)
from app.store.stats.coverage import coverage_report
from app.store.stats.read import read_gaps
from app.store.stats.window import read_window_timeline, window_framings, window_key

# What the panel cannot see, said every time (brief critical question 2).
# The code is stable for the UI to translate; the text is the English one.
INVISIBLE_TRAFFIC_HINT = {
    "code": "gateway_only",
    "text": ("Only traffic that passes through the gateway is counted. A "
             "device or a DNS path that bypasses it - an IPv6 route the "
             "router hands out, a DNS server outside the gateway - is not "
             "seen here."),
}

TOP_DIMS = ("device", "exit", "category", "country", "host")
TOP_DEFAULT = 10
GAPS_MAX = 100


def _independent(scope: str) -> str:
    return (f"the dimensions are stored independently, so this breakdown "
            f"cannot be cut by {scope}")


def read_overview(conn, window: Window, *, device: str = "",
                  category: str | None = None, host: str | None = None,
                  limit: int = TOP_DEFAULT,
                  domains_enabled: bool = False) -> dict:
    """The overview of WINDOW (a ranged window), scoped to at most one
    DEVICE and at most one of CATEGORY (a category dimension value) or HOST
    (a hostname, seven-day class - only with the gate on)."""
    if category is not None and host is not None:
        raise ValueError("scope to a category or to a host, not both")
    top: dict = dict.fromkeys(TOP_DIMS)
    unavailable: dict = {}
    body = {"scope": {"device": device, "category": category, "host": host},
            "totals": None, "timeline": None, "top": top,
            "unavailable": unavailable}
    if host is not None and not domains_enabled:
        reason = ("the hostname class is off (PANEL_STATS_DOMAINS), so no "
                  "per-host traffic is kept")
        for key in ("totals", "timeline", *(f"top.{d}" for d in TOP_DIMS)):
            unavailable[key] = reason
    else:
        if host is not None:
            tier, rows = read_dim_timeline(conn, "host", window, host, device)
        elif category is not None:
            tier, rows = read_dim_timeline(conn, "category", window, category,
                                           device)
        else:
            tier = window.resolution
            rows = read_window_timeline(conn, tier, device, window.since,
                                        window.frame)
        body["timeline"] = {"tier": tier, "rows": rows}
        body["totals"] = {"tier": tier,
                          "up": sum(r["up"] for r in rows),
                          "down": sum(r["down"] for r in rows)}
        if host is not None or category is not None:
            # where the scope's data starts, and for a host the seven-day
            # floor the window was cut at - said here, not only in a list a
            # device scope removes
            body["totals"]["window"] = window_info(
                conn, "host" if host is not None else "category", window)
        _tops(conn, window, top, unavailable, device=device,
              category=category, host=host, limit=limit,
              domains_enabled=domains_enabled)
    # the newest GAPS_MAX only; one more is read to know whether there are
    # more. Bounded at the tier the timeline was read at: a scoped 48-hour
    # timeline is hourly, so its first bucket starts on the hour
    tier = (body["timeline"] or {}).get("tier", window.resolution)
    gaps = read_gaps(conn, GAPS_MAX + 1, _gaps_since(window, tier))
    body["gaps"] = gaps[:GAPS_MAX]
    body["gaps_truncated"] = len(gaps) > GAPS_MAX
    if window.resolution == "day":
        body["framings"] = window_framings(conn, window.since, window.frame)
    if device or category is not None or host is not None:
        body["coverage"] = None
        unavailable["coverage"] = ("coverage is measured for the whole "
                                   "gateway only, not per scope")
    else:
        coverage_since = (window_key(window.since, "hour", window.frame)
                          if window.since is not None else "")
        body["coverage"] = coverage_report(conn, coverage_since,
                                           app_ids_kept=domains_enabled)
    body["invisible_traffic_hint"] = INVISIBLE_TRAFFIC_HINT
    return body


def _gaps_since(window: Window, tier: str) -> str:
    """The gaps lower bound: the START of the window's first bucket, not the
    window's instant - a gap ending inside that partial bucket is a hole in
    what the timeline shows. A local day's UTC start is not known here, so a
    day window reaches one day further back (an extra gap is harmless; a
    hidden one is not). Stamps compare as strings; a key is a prefix."""
    if window.since is None:
        return ""
    if tier == "day":
        return (window.since - timedelta(days=1)).strftime("%Y-%m-%dT%H")
    return window_key(window.since, tier, window.frame)


def _tops(conn, window, top, unavailable, *, device, category, host, limit,
          domains_enabled) -> None:
    common = {"sort": "total", "limit": limit, "domains_enabled":
              domains_enabled}
    if device:
        unavailable["top.device"] = "scoped to one device"
    elif host is not None:
        top["device"] = read_breakdown(conn, "host", window, by_device=True,
                                       value=("{v}", host), **common)
    elif category is not None:
        top["device"] = read_breakdown(conn, "category", window,
                                       by_device=True,
                                       value=("{v}", category), **common)
    else:
        top["device"] = read_breakdown(conn, DEVICE_DIM, window, **common)
    scope = ("one host" if host is not None
             else "one category" if category is not None else None)
    for dim in ("exit", "category", "country"):
        if scope is None:
            top[dim] = read_breakdown(conn, dim, window, device=device,
                                      **common)
        elif dim == "category" and category is not None:
            unavailable[f"top.{dim}"] = "scoped to one category"
        else:
            unavailable[f"top.{dim}"] = _independent(scope)
    if host is not None:
        unavailable["top.host"] = "scoped to one host"
    elif category is not None:
        unavailable["top.host"] = _independent("one category")
    else:
        top["host"] = read_breakdown(conn, "host", window, device=device,
                                     **common)
