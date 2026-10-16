"""One poll's delta flush into the minute tier (and the hour-keyed
coverage and opt-in domain tables) - the collector's write path."""

from contextlib import suppress

from app.store.stats.schema import (
    KLASS_HOSTNAME,
    KLASS_IP_ONLY,
    _parse_ts,
    meta_get,
)


def flush_poll(conn, raw_conns: list, now: str, *, domains_enabled: bool,
               gap_threshold_s: int) -> None:
    """One poll's delta flush - a single transaction covering the minute
    upserts, the (hourly) domain upserts, the baseline replacement, the
    closed-connection reap, gap detection, and the last-poll stamp."""
    minute_bucket = now[:16]
    hour_bucket = now[:13]
    conn.execute("BEGIN IMMEDIATE")
    try:
        seen = set()
        for rc in raw_conns:
            cid = str(rc.get("id") or "")
            if not cid:
                continue
            up = int(rc.get("upload") or 0)
            down = int(rc.get("download") or 0)
            meta = rc.get("metadata") or {}
            device = str(meta.get("sourceIP") or "") or "unknown"
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
            payload = str(rc.get("rulePayload") or "")
            named = host or sniff
            base = conn.execute(
                "SELECT up, down FROM conn_baseline WHERE conn_id = ?",
                (cid,)).fetchone()
            if base is None or up < base["up"] or down < base["down"]:
                # first sighting, or a counter reset (id reuse after a
                # mihomo restart): the full cumulative counts
                d_up, d_down = up, down
            else:
                d_up, d_down = up - base["up"], down - base["down"]
            if d_up or d_down:
                conn.execute(
                    "INSERT INTO stats_minute (bucket, device, chain, up, down) "
                    "VALUES (?, ?, ?, ?, ?) "
                    "ON CONFLICT(bucket, device, chain) DO UPDATE SET "
                    "up = up + excluded.up, down = down + excluded.down",
                    (minute_bucket, device, chain, d_up, d_down))
                conn.execute(
                    "INSERT INTO stats_coverage (bucket, device, klass, "
                    "rule, rule_payload, sniff_host, up, down) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
                    "ON CONFLICT(bucket, device, klass, rule, rule_payload, "
                    "sniff_host) "
                    "DO UPDATE SET up = up + excluded.up, "
                    "down = down + excluded.down",
                    (hour_bucket, device,
                     KLASS_HOSTNAME if named else KLASS_IP_ONLY,
                     rule, payload,
                     # the raw hostname ONLY behind the opt-in gate; empty
                     # in the default configuration, so the column adds no
                     # cardinality and no privacy surface there
                     sniff if domains_enabled else "",
                     d_up, d_down))
                if domains_enabled and host:
                    conn.execute(
                        "INSERT INTO stats_domain "
                        "(bucket, device, domain, up, down) "
                        "VALUES (?, ?, ?, ?, ?) "
                        "ON CONFLICT(bucket, device, domain) DO UPDATE SET "
                        "up = up + excluded.up, down = down + excluded.down",
                        (hour_bucket, device, host, d_up, d_down))
            conn.execute(
                "INSERT INTO conn_baseline (conn_id, up, down, last_seen) "
                "VALUES (?, ?, ?, ?) ON CONFLICT(conn_id) DO UPDATE SET "
                "up = excluded.up, down = excluded.down, "
                "last_seen = excluded.last_seen",
                (cid, up, down, now))
            seen.add(cid)
        # reap baselines for closed connections (their growth since the
        # last poll is lost - the documented <= one-interval bound)
        for row in conn.execute("SELECT conn_id FROM conn_baseline"):
            if row["conn_id"] not in seen:
                conn.execute("DELETE FROM conn_baseline WHERE conn_id = ?",
                             (row["conn_id"],))
        # honest gap accounting: a hole wider than the threshold becomes an
        # explicit row - never interpolated, never backfilled
        last = meta_get(conn, "last_poll_ts")
        if last is not None:
            hole_s = (_parse_ts(now) - _parse_ts(last)).total_seconds()
            if hole_s > gap_threshold_s:
                conn.execute(
                    "INSERT INTO stats_gap (started, ended, reason) "
                    "VALUES (?, ?, ?)",
                    (last, now, f"no poll for {int(hole_s)}s"))
        conn.execute(
            "INSERT INTO stats_meta (k, v) VALUES ('last_poll_ts', ?) "
            "ON CONFLICT(k) DO UPDATE SET v = excluded.v", (now,))
        conn.execute("COMMIT")
    except BaseException:
        with suppress(Exception):
            conn.execute("ROLLBACK")
        raise
