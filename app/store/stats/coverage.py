"""Attribution coverage (#77): what share of bytes carried a hostname."""

from app.store.stats.schema import (
    COVERAGE_CLASSES,
    DOMAIN_RETENTION_DAYS,
    KLASS_IP_ONLY,
)


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


def coverage_report(conn, since: str = "", until: str = "") -> dict:
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
        share = round(100.0 * (row["up"] + row["down"]) / total, 6) if total else 0.0
        classes.append({"klass": klass, "up": row["up"], "down": row["down"],
                        "share": share})
    # Attribution lives ONLY here, under the forced 7-day cap - the 90/730
    # day byte tiers carry no klass or rule column at all. So a caller
    # asking for 30 days gets a percentage computed over at most 7, and
    # saying so is the difference between a measurement and a number.
    # DEC-6 exists to stop a blocking decision resting on quiet inaccuracy;
    # a silently truncated window would be exactly that.
    return {"total": {"up": total_up, "down": total_down},
            "classes": classes,
            "rules": coverage_rules(conn, since, until),
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
