"""Attribution coverage (#77): what share of bytes carried a hostname, and
(#97) what share the category dictionary could name."""

from app.store import categories
from app.store.stats.schema import (
    APP_TABLE,
    COVERAGE_CLASSES,
    DICTIONARY_CLASSES,
    DOMAIN_RETENTION_DAYS,
    KLASS_IP_ONLY,
    NO_DICTIONARY,
    UNATTRIBUTED,
)


def _share(part: int, total: int) -> float:
    return round(100.0 * part / total, 6) if total else 0.0


def read_coverage(conn, since: str = "", until: str = "") -> list:
    """Bytes per attribution class over a window.

    The classes are the whole point of #77: `hostname` means the flow
    carried a name an app dictionary could eventually match, `ip_only`
    means it did not. Routing signals never promote a flow (DEC-B) - the
    release gate already refuses to read GeoSite/cn as proof of anything.
    """
    where, params = [], []
    if since:
        where.append("bucket >= ?")
        params.append(since)
    if until:
        where.append("bucket <= ?")
        params.append(until)
    clause = f"WHERE {' AND '.join(where)}" if where else ""
    rows = conn.execute(
        f"SELECT klass, SUM(up) AS up, SUM(down) AS down "
        f"FROM stats_coverage {clause} GROUP BY klass ORDER BY klass",
        params).fetchall()
    return [dict(r) for r in rows]


def coverage_rules(conn, since: str = "", until: str = "") -> list:
    """Unattributable bytes, broken down by the rule that routed them.

    AC2 asks for a "deliberately excluded" share. This does not produce
    one, for a reason worth stating precisely rather than confidently.

    VERIFIED here: the template's skip-domain list lives entirely inside
    the `sniffer:` block and no `rules:` entry references it, so it
    changes sniffing rather than routing.

    NOT verified here, and deliberately not asserted: whether mihomo still
    reports `metadata.sniffHost` for a flow whose sniffing was skipped.
    This repo vendors no mihomo source and captures no fixture of such a
    flow. If it DOES report one, that flow carries a name and is
    attributable under DEC-B - correctly counted, just not visible as an
    exclusion. If it does NOT, the flow is indistinguishable from ordinary
    IP-only residue. Either way, separating exclusions out would require
    hardcoding the exclusion list, which CLAUDE.md forbids outright.

    So what is reported is what is observable: which rule routed each
    unattributable byte. An operator can read a designed exclusion off its
    own rule name where one exists, without the panel guessing on their
    behalf - and which of the two cases actually holds is precisely the
    sort of thing this ticket's own output is meant to reveal.
    """
    where = ["klass = ?"]
    params = [KLASS_IP_ONLY]
    if since:
        where.append("bucket >= ?")
        params.append(since)
    if until:
        where.append("bucket <= ?")
        params.append(until)
    clause = "WHERE " + " AND ".join(where)
    rows = conn.execute(
        f"SELECT rule, rule_payload, SUM(up) AS up, SUM(down) AS down "
        f"FROM stats_coverage {clause} GROUP BY rule, rule_payload "
        f"ORDER BY SUM(up) + SUM(down) DESC, rule, rule_payload",
        params).fetchall()
    return [dict(r) for r in rows]


def dictionary_report(conn, start: str, until: str = "",
                      app_ids_kept: bool | None = None) -> dict:
    """What the category dictionary named, over the coverage window (#97,
    DEC-D): the buckets from START - the coverage window's first bucket, ""
    when the coverage table holds none - up to UNTIL, so this partition and
    the hostname/ip_only one cover the same hours. The category dimension
    keeps 90 days and `stats_app` seven; reading either beyond the window
    would file app bytes that aged out of `stats_app` under `coarse`.

    Every byte falls in exactly one class, and every class is listed even
    at zero:
      app            classified, and its app-level id is kept (stats_app,
                     only with PANEL_STATS_DOMAINS on)
      coarse         classified, and only its coarse category is kept
      unattributed   the dictionary had no answer: no hostname, or one it
                     does not know
      no_dictionary  counted without a dictionary: before v1.12, or by an
                     older image after a rollback
    `total` is this partition's own, over the hours the category dimension
    still holds at HOUR resolution: a window reaching back before v1.11 (no
    category dimension yet), or past PANEL_STATS_HOUR_DAYS when that is
    under seven days (older hours are in the day tier, which a UTC hour
    window cannot be cut from), holds coverage bytes it never saw.
    `oldest_bucket` is the first hour it counted.

    `app` is matched per hour and device: in each, the app bytes kept can
    be at most the classified bytes of that hour and device. Without that,
    app ids kept in one hour could pass for classified bytes of another -
    after a purge of one table, or when the two tables hold different hours.
    APP_IDS_KEPT says whether app ids are being kept NOW: a zero `app`
    share then reads as "not kept", not as "none seen", while ids kept
    before the gate was switched off still count until their seven days
    are up."""
    sums = {klass: [0, 0] for klass in DICTIONARY_CLASSES}
    oldest = ""
    if start:
        where, params = ["bucket >= ?"], [start]
        if until:
            where.append("bucket <= ?")
            params.append(until)
        clause = " AND ".join(where)
        row = conn.execute(
            f"""WITH cat AS (
                SELECT bucket, device,
                    SUM(CASE WHEN value = ? THEN up ELSE 0 END) AS nd_up,
                    SUM(CASE WHEN value = ? THEN down ELSE 0 END) AS nd_down,
                    SUM(CASE WHEN value = ? THEN up ELSE 0 END) AS un_up,
                    SUM(CASE WHEN value = ? THEN down ELSE 0 END) AS un_down,
                    SUM(CASE WHEN value NOT IN (?, ?) THEN up ELSE 0 END)
                        AS cl_up,
                    SUM(CASE WHEN value NOT IN (?, ?) THEN down ELSE 0 END)
                        AS cl_down
                FROM stats_category_hour WHERE {clause}
                GROUP BY bucket, device),
            app AS (
                SELECT bucket, device, SUM(up) AS up, SUM(down) AS down
                FROM {APP_TABLE} WHERE {clause} GROUP BY bucket, device)
            SELECT MIN(cat.bucket) AS oldest,
                COALESCE(SUM(nd_up), 0), COALESCE(SUM(nd_down), 0),
                COALESCE(SUM(un_up), 0), COALESCE(SUM(un_down), 0),
                COALESCE(SUM(cl_up), 0), COALESCE(SUM(cl_down), 0),
                COALESCE(SUM(MIN(cl_up, COALESCE(app.up, 0))), 0),
                COALESCE(SUM(MIN(cl_down, COALESCE(app.down, 0))), 0)
            FROM cat LEFT JOIN app USING (bucket, device)""",
            [NO_DICTIONARY, NO_DICTIONARY, UNATTRIBUTED, UNATTRIBUTED,
             NO_DICTIONARY, UNATTRIBUTED, NO_DICTIONARY, UNATTRIBUTED,
             *params, *params]).fetchone()
        oldest = row[0] or ""
        nd_up, nd_down, un_up, un_down, cl_up, cl_down, app_up, app_down = (
            row[1:])
        sums = {"app": [app_up, app_down],
                "coarse": [cl_up - app_up, cl_down - app_down],
                "unattributed": [un_up, un_down],
                "no_dictionary": [nd_up, nd_down]}
    total_up = sum(v[0] for v in sums.values())
    total_down = sum(v[1] for v in sums.values())
    total = total_up + total_down
    dictionary = categories.active()
    return {"version": dictionary.version if dictionary else None,
            "error": categories.load_error(),
            "app_ids_kept": app_ids_kept,
            "oldest_bucket": oldest,
            "total": {"up": total_up, "down": total_down},
            "classes": [{"klass": klass, "up": up, "down": down,
                         "share": _share(up + down, total)}
                        for klass, (up, down) in sums.items()]}


def coverage_report(conn, since: str = "", until: str = "",
                    app_ids_kept: bool | None = None) -> dict:
    """The measurement DEC-6 asks for: what share of bytes is attributable.

    EVERY known class is listed even at zero, so a consumer never has to
    guess whether a missing class means "none" or means "not measured" -
    the same honesty rule the apply badge and the import ledger follow.
    Shares are of total bytes (up + down) and sum to 100 by construction,
    or to 0 on an empty window rather than dividing by it.
    """
    counted = {r["klass"]: r for r in read_coverage(conn, since, until)}
    oldest = conn.execute(
        "SELECT MIN(bucket) FROM stats_coverage").fetchone()[0]
    total_up = sum(r["up"] for r in counted.values())
    total_down = sum(r["down"] for r in counted.values())
    total = total_up + total_down
    classes = []
    for klass in COVERAGE_CLASSES:
        row = counted.get(klass) or {"up": 0, "down": 0}
        classes.append({"klass": klass, "up": row["up"], "down": row["down"],
                        "share": _share(row["up"] + row["down"], total)})
    # Attribution lives ONLY here, under the forced 7-day cap - the 90/730
    # day byte tiers carry no klass or rule column at all. So a caller
    # asking for 30 days gets a percentage computed over at most 7, and
    # saying so is the difference between a measurement and a number.
    # DEC-6 exists to stop a blocking decision resting on quiet inaccuracy;
    # a silently truncated window would be exactly that.
    return {"total": {"up": total_up, "down": total_down},
            "classes": classes,
            "rules": coverage_rules(conn, since, until),
            # the dictionary's own partition (#97 DEC-D), beside `classes`
            # rather than in it: `classes` sums to 100 on its own
            "dictionary": dictionary_report(
                conn, max(since, oldest) if oldest else "", until,
                app_ids_kept),
            "window": {
                "requested_since": since,
                "requested_until": until,
                "oldest_bucket": oldest or "",
                "retention_days": DOMAIN_RETENTION_DAYS,
                # True when the requested range starts before the oldest
                # row held: the answer is correct for what it covers but
                # does not answer the question asked. Deliberately does NOT
                # distinguish retention pruning from a young install - the
                # consequence for the caller is identical, and guessing
                # which it was would be the panel inventing a story.
                "truncated": bool(since and oldest and since < oldest),
            }}
