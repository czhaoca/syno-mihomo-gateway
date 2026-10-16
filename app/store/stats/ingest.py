"""One poll's delta flush into the minute and hour tiers, the dimension
tables, and the hour-keyed coverage and opt-in seven-day class tables - the
collector's write path."""

import json
from contextlib import suppress

from app.store.stats.schema import (
    CLASS_TABLES,
    DIMENSIONS,
    GATEWAY_DEVICE,
    KLASS_HOSTNAME,
    KLASS_IP_ONLY,
    MINUTE_TABLE,
    UNATTRIBUTED,
    UNKNOWN,
    _parse_ts,
    meta_get,
)

# The rule types whose payload names a routing CATEGORY (brief DEC-4): a
# geosite or geoip list, a rule-set, the final match, a LAN source range.
# Every other type's payload is blanked before it is stored - Domain,
# DomainSuffix and DomainKeyword carry a hostname (the airport's own, from
# the template's direct rule), and a type this list does not know, including
# one a future mihomo adds, fails closed.
PAYLOAD_RULES = frozenset({"GeoSite", "GeoIP", "RuleSet", "Match",
                           "SrcIPCIDR"})

# The upserts below take a whole poll's rows as ONE JSON array parameter
# (`json_each`), so the number of SQL statements a poll issues does not grow
# with the number of open connections (#94). `WHERE true` is SQLite's
# required disambiguation for an upsert whose source is a SELECT.

def _tier_upsert(table: str) -> str:
    return (
        f"INSERT INTO {table} (bucket, device, chain, up, down, samples, "
        "conns, peak_up, peak_down) "
        "SELECT ?, json_extract(value, '$[0]'), json_extract(value, '$[1]'), "
        "json_extract(value, '$[2]'), json_extract(value, '$[3]'), 1, "
        "json_extract(value, '$[4]'), json_extract(value, '$[5]'), "
        "json_extract(value, '$[6]') FROM json_each(?) WHERE true "
        "ON CONFLICT(bucket, device, chain) DO UPDATE SET "
        "up = up + excluded.up, down = down + excluded.down, "
        "samples = samples + excluded.samples, conns = conns + excluded.conns, "
        "peak_up = max(peak_up, excluded.peak_up), "
        "peak_down = max(peak_down, excluded.peak_down)")


def _value_upsert(table: str) -> str:
    # json_each's own column is also called `value`; the alias keeps the
    # two apart
    return (
        f"INSERT INTO {table} (bucket, device, value, up, down) "
        "SELECT ?, json_extract(j.value, '$[0]'), "
        "json_extract(j.value, '$[1]'), json_extract(j.value, '$[2]'), "
        "json_extract(j.value, '$[3]') FROM json_each(?) AS j WHERE true "
        "ON CONFLICT(bucket, device, value) DO UPDATE SET "
        "up = up + excluded.up, down = down + excluded.down")


# The minute tier and, since #95, the hour tier: one poll writes both with
# the same facts, so the hour tier is complete at ingest. (The minute tier
# is MINUTE_TABLE, not the shipped stats_minute - schema.py says why.)
_MINUTE_UPSERT = _tier_upsert(MINUTE_TABLE)
_HOUR_UPSERT = _tier_upsert("stats_hour")
_DIMENSION_UPSERTS = {dim: _value_upsert(f"stats_{dim}_hour")
                      for dim in DIMENSIONS}
_CLASS_UPSERTS = {table: _value_upsert(table) for table in CLASS_TABLES}

_COVERAGE_UPSERT = (
    "INSERT INTO stats_coverage (bucket, device, klass, rule, rule_payload, "
    "sniff_host, up, down) "
    "SELECT ?, json_extract(value, '$[0]'), json_extract(value, '$[1]'), "
    "json_extract(value, '$[2]'), json_extract(value, '$[3]'), "
    "json_extract(value, '$[4]'), json_extract(value, '$[5]'), "
    "json_extract(value, '$[6]') FROM json_each(?) WHERE true "
    "ON CONFLICT(bucket, device, klass, rule, rule_payload, sniff_host) "
    "DO UPDATE SET up = up + excluded.up, down = down + excluded.down")

_DOMAIN_UPSERT = (
    "INSERT INTO stats_domain (bucket, device, domain, up, down) "
    "SELECT ?, json_extract(value, '$[0]'), json_extract(value, '$[1]'), "
    "json_extract(value, '$[2]'), json_extract(value, '$[3]') "
    "FROM json_each(?) WHERE true "
    "ON CONFLICT(bucket, device, domain) DO UPDATE SET "
    "up = up + excluded.up, down = down + excluded.down")

_BASELINE_UPSERT = (
    "INSERT INTO conn_baseline (conn_id, up, down, last_seen) "
    "SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]'), "
    "json_extract(value, '$[2]'), ? FROM json_each(?) WHERE true "
    "ON CONFLICT(conn_id) DO UPDATE SET up = excluded.up, "
    "down = excluded.down, last_seen = excluded.last_seen")


def _rows(table: dict) -> str:
    return json.dumps([[*key, *vals] for key, vals in table.items()])


def _add(table: dict, key, up: int, down: int) -> None:
    acc = table.setdefault(key, [0, 0])
    acc[0] += up
    acc[1] += down


def _country(meta: dict) -> str:
    """`metadata.dstGeoIP`, probed on EVERY snapshot (DEC-A): the image is
    `:latest`, so the field can appear - or vanish - between two polls. A
    list of codes on the builds that send it; the first names the country.
    Upper-cased so one country keeps one spelling across mihomo versions."""
    geo = meta.get("dstGeoIP")
    if isinstance(geo, list):
        geo = geo[0] if geo else ""
    code = str(geo or "").strip().upper()
    return code or UNKNOWN


def _device(meta: dict) -> str:
    """The LAN source; mihomo's own traffic (`type: Inner` - provider pulls,
    health checks) has none and belongs to the gateway, not to `unknown`."""
    if meta.get("type") == "Inner":
        return GATEWAY_DEVICE
    return str(meta.get("sourceIP") or "") or UNKNOWN


def flush_poll(conn, raw_conns: list, now: str, *, domains_enabled: bool,
               gap_threshold_s: int, interval_s: int | None = None) -> None:
    """One poll's delta flush - a single transaction covering the minute
    and hour upserts, the dimension upserts, the (hourly) coverage and
    seven-day class upserts, the baseline update, the closed-connection
    reap, gap detection, and the poll stamps.

    Since #95 the HOUR tier is written here too, with exactly the minute
    rows' facts, so it is complete at ingest and rollup only expires minute
    rows. Each long-term dimension (exit node, rule type, category, country)
    gets one row per device and value that MOVED bytes - a new connection
    with no bytes yet adds to the tier's `conns` but writes no dimension
    row. The seven-day class (hostname, sniffHost, ASN, port) is written
    only with DOMAINS_ENABLED.

    The work is done in Python and written with a bounded number of
    statements (#94): the baseline set is read ONCE, each table is written
    by one statement over the whole poll, and only connections whose
    counters MOVED rewrite their baseline - an idle connection rewrites no
    baseline row. `conn_baseline.last_seen` therefore records when a
    connection last moved (nothing reads it).

    Each minute row also accumulates, per device and chain:
      samples   +1 for every poll in which the row had activity (bytes
                moved, or a connection appeared)
      conns     connection ids first seen - or seen again after a counter
                reset, which is a new connection to mihomo - in the poll
      peak_*    the largest single-poll delta. A poll counts as following
                a normal interval when the previous one is at most the gap
                threshold (GAP_FACTOR intervals) ago, so a peak is bytes per
                one poll - usually one interval, at most GAP_FACTOR of them
    INTERVAL_S, when given, is recorded as `stats_meta.poll_interval_s`, so
    a peak is interpretable against the cadence that produced it.

    A poll that does NOT follow a normal interval - the store's first poll
    ever, the first after a hole wider than the gap threshold, or one whose
    previous poll is stamped in the future (a clock stepped back) - still
    adds its bytes, samples and connections, but writes no peak: its delta
    covers the whole hole (or the lifetime counters of connections the
    store never saw), so calling it "bytes per interval" would plant a
    false maximum that every rollup would then keep for two years. The
    gap row says why that poll's peak is missing.
    """
    minute_bucket = now[:16]
    hour_bucket = now[:13]
    conn.execute("BEGIN IMMEDIATE")
    try:
        last = meta_get(conn, "last_poll_ts")
        hole_s = ((_parse_ts(now) - _parse_ts(last)).total_seconds()
                  if last is not None else None)
        # a peak is only recorded when the previous poll was a normal
        # interval ago - at most the gap threshold, and never in the future
        # (a clock stepped backwards proves nothing about the interval)
        measured = hole_s is not None and 0 <= hole_s <= gap_threshold_s
        base = {r["conn_id"]: (r["up"], r["down"]) for r in conn.execute(
            "SELECT conn_id, up, down FROM conn_baseline")}
        rows: dict = {}      # (device, chain) -> [up, down, conns]
        cover: dict = {}     # (device, klass, rule, payload, sniff) -> [up, down]
        domains: dict = {}   # (device, host) -> [up, down]
        dims: dict = {dim: {} for dim in DIMENSIONS}  # (device, value) -> ...
        klass_rows: dict = {table: {} for table in CLASS_TABLES}
        moved = []           # [conn_id, up, down] baselines to write
        seen = set()
        for rc in raw_conns:
            cid = str(rc.get("id") or "")
            if not cid or cid in seen:
                continue
            seen.add(cid)
            up = int(rc.get("upload") or 0)
            down = int(rc.get("download") or 0)
            meta = rc.get("metadata") or {}
            device = _device(meta)
            chains = rc.get("chains") or []
            chain = str(chains[-1]) if chains else "DIRECT"
            host = str(meta.get("host") or "")
            # #77: the classification signal already on the wire, previously
            # discarded. `sniffHost` is what the sniffer recovered when the
            # DNS path gave no name - so for CLASSIFYING a flow it counts
            # exactly like `host`, but as a hostname it is stored only where
            # hostnames already live (the opt-in domain table below).
            sniff = str(meta.get("sniffHost") or "")
            rule = str(rc.get("rule") or "")
            payload = (str(rc.get("rulePayload") or "")
                       if rule in PAYLOAD_RULES else "")
            prev = base.get(cid)
            # first sighting, or a counter reset (id reuse after a mihomo
            # restart): the full cumulative counts, and it is a new connection
            new = prev is None or up < prev[0] or down < prev[1]
            d_up, d_down = (up, down) if new else (up - prev[0], down - prev[1])
            if new or d_up or d_down:
                acc = rows.setdefault((device, chain), [0, 0, 0])
                acc[0] += d_up
                acc[1] += d_down
                acc[2] += 1 if new else 0
            if d_up or d_down:
                klass = KLASS_HOSTNAME if (host or sniff) else KLASS_IP_ONLY
                # the raw hostname ONLY behind the opt-in gate; empty in the
                # default configuration, so the column adds no cardinality
                # and no privacy surface there
                key = (device, klass, rule, payload,
                       sniff if domains_enabled else "")
                _add(cover, key, d_up, d_down)
                exit_node = str(chains[0]) if chains else "DIRECT"
                _add(dims["exit"], (device, exit_node), d_up, d_down)
                _add(dims["rule"], (device, rule), d_up, d_down)
                _add(dims["category"], (device, UNATTRIBUTED), d_up, d_down)
                _add(dims["country"], (device, _country(meta)), d_up, d_down)
                if domains_enabled:
                    if host:
                        _add(domains, (device, host), d_up, d_down)
                    if sniff:
                        _add(klass_rows["stats_sniff"], (device, sniff),
                             d_up, d_down)
                    asn = str(meta.get("dstIPASN") or "").strip() or UNKNOWN
                    _add(klass_rows["stats_asn"], (device, asn), d_up, d_down)
                    port = str(meta.get("destinationPort") or "") or UNKNOWN
                    _add(klass_rows["stats_port"], (device, port), d_up,
                         d_down)
            if new or (up, down) != prev:
                moved.append([cid, up, down])
        if rows:
            payload = json.dumps([
                [device, chain, up, down, conns,
                 up if measured else 0, down if measured else 0]
                for (device, chain), (up, down, conns) in rows.items()])
            conn.execute(_MINUTE_UPSERT, (minute_bucket, payload))
            conn.execute(_HOUR_UPSERT, (hour_bucket, payload))
        for dim, table in dims.items():
            if table:
                conn.execute(_DIMENSION_UPSERTS[dim],
                             (hour_bucket, _rows(table)))
        if cover:
            conn.execute(_COVERAGE_UPSERT, (hour_bucket, _rows(cover)))
        if domains:
            conn.execute(_DOMAIN_UPSERT, (hour_bucket, _rows(domains)))
        for name, table in klass_rows.items():
            if table:
                conn.execute(_CLASS_UPSERTS[name], (hour_bucket, _rows(table)))
        if moved:
            conn.execute(_BASELINE_UPSERT, (now, json.dumps(moved)))
        # reap baselines for closed connections (their growth since the
        # last poll is lost - the documented <= one-interval bound)
        reaped = [cid for cid in base if cid not in seen]
        if reaped:
            conn.execute("DELETE FROM conn_baseline WHERE conn_id IN "
                         "(SELECT value FROM json_each(?))",
                         (json.dumps(reaped),))
        # honest gap accounting: a hole wider than the threshold becomes an
        # explicit row - never interpolated, never backfilled
        if hole_s is not None and hole_s > gap_threshold_s:
            conn.execute(
                "INSERT INTO stats_gap (started, ended, reason) "
                "VALUES (?, ?, ?)",
                (last, now, f"no poll for {int(hole_s)}s"))
        stamps = [("last_poll_ts", now)]
        if interval_s is not None:
            stamps.append(("poll_interval_s", str(int(interval_s))))
        conn.execute(
            "INSERT INTO stats_meta (k, v) "
            "SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]') "
            "FROM json_each(?) WHERE true "
            "ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            (json.dumps(stamps),))
        conn.execute("COMMIT")
    except BaseException:
        with suppress(Exception):
            conn.execute("ROLLBACK")
        raise
