"""Device identity - a human alias for a host, independent of policy.

Deliberately NOT part of `policy.py`: the shipped `devices` table requires
a routing mode on every row, so naming a device there would force a policy
decision onto it. This module owns the `device_identity` sidecar
(migration 2) and never reads or writes `devices`, which keeps
`desired_state` - the reconciler's input - free of identity entirely.

Keyed on the canonical /32 so that a bare `metadata.sourceIP` from the
stats collector and a `/32` CIDR from the policy store resolve to the same
device. A range carries no identity: there is no single host to name, and
borrowing an alias from a contained address would attribute one device's
name to a whole subnet.
"""

import sqlite3
from datetime import UTC, datetime

from app.store.audit import append_audit
from app.validation import ValidationError, canonicalize

# The provenance an operator's own edit carries. Only the hand-edit path
# may claim it, and it outranks every importer (issue #74 DEC-A).
HAND = "hand-edit"
# Written by migration 3's backfill only for rows whose provenance predates
# the column; the weakest precedence, always overwritable.
UNKNOWN = ""


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def check_source(raw: str) -> str:
    """A non-blank provenance label. Blank is reserved for migration 3's
    backfill and must be unreachable through any API, or a caller could
    write the weakest precedence and then be unable to explain why its
    aliases keep getting overwritten."""
    source = (raw or "").strip()
    if not source:
        raise ValidationError("source must name where the alias came from")
    if len(source) > 32 or any(ch.isspace() for ch in source):
        raise ValidationError(
            "source must be a short single-word label (e.g. unifi, nimbus)")
    return source


def host_key(raw: str) -> str:
    """The canonical /32 for RAW, or ValidationError.

    Rejects everything that is not a single host - including the literal
    `"unknown"` that `stats.py` substitutes when mihomo reports no source
    IP, which must never become an aliasable pseudo-device.
    """
    canonical = canonicalize(raw)
    if not canonical.endswith("/32"):
        raise ValidationError(
            f"{canonical} covers more than one host - an alias names a "
            f"single device, so identity keys on a /32")
    return canonical


def get_alias(conn, raw: str) -> str:
    """The alias for RAW, or "" when there is none. Never raises for an
    unnameable address: a caller resolving a range simply gets nothing."""
    try:
        key = host_key(raw)
    except ValidationError:
        return ""
    row = conn.execute("SELECT alias FROM device_identity WHERE cidr = ?",
                       (key,)).fetchone()
    return row["alias"] if row else ""


def list_aliases(conn) -> list:
    return [{"ip": r["cidr"].removesuffix("/32"), "alias": r["alias"],
             "source": r["source"]}
            for r in conn.execute(
                "SELECT cidr, alias, source FROM device_identity "
                "ORDER BY cidr")]


def resolve(conn) -> dict:
    """Every alias as {canonical /32: alias} - one query for a whole
    listing, rather than a lookup per row.

    The keys are /32 CIDRs, matching `devices.cidr`. They do NOT match the
    stats tables, which key on the bare `metadata.sourceIP` (stats.py:120);
    a stats-side join must normalize through `host_key` first. Handing back
    the raw column rather than a bare IP keeps that mismatch visible at the
    call site instead of producing silent misses.
    """
    return {r["cidr"]: r["alias"] for r in conn.execute(
        "SELECT cidr, alias FROM device_identity")}


def _transition(before: str, after: str, source: str = HAND) -> str:
    """`details` payload in the shipped convention - `policy.py`'s rename
    writes `'old' -> 'new'` there and keeps `note` for the operator's own
    note. Recording both ends is what lets a reader tell a rename from a
    removal, and recovers the previous name from history; the trailing
    source answers "typed or synced", which a precedence skip cannot
    (a skip changes nothing, so it writes no audit row at all)."""
    return f"{before!r} -> {after!r} [{source}]"


def set_alias(conn, raw: str, alias: str, *, requester: str = "",
              note: str = "") -> dict:
    """Upsert the alias for RAW. A blank alias REMOVES the row rather than
    storing an empty name, so "no alias" has exactly one representation.

    The delegation to `remove_alias` happens BEFORE this function opens a
    transaction - nesting BEGIN IMMEDIATE inside an open one would abort
    and poison the shared long-lived connection.
    """
    key = host_key(raw)
    alias = (alias or "").strip()
    if not alias:
        removed = remove_alias(conn, key, requester=requester, note=note)
        return {"ip": key.removesuffix("/32"), "alias": "",
                "removed": removed}
    ts = _now()
    conn.execute("BEGIN IMMEDIATE")
    try:
        before = conn.execute(
            "SELECT alias FROM device_identity WHERE cidr = ?",
            (key,)).fetchone()
        # An operator edit always WINS and always claims HAND: this is the
        # only writer permitted to set that source, which is what makes
        # "hand-edit wins" enforceable against every importer.
        conn.execute(
            "INSERT INTO device_identity (cidr, alias, source, updated_at) "
            "VALUES (?, ?, ?, ?) ON CONFLICT(cidr) DO UPDATE SET "
            "alias = excluded.alias, source = excluded.source, "
            "updated_at = excluded.updated_at",
            (key, alias, HAND, ts))
        append_audit(conn, action="alias", cidr=key, requester=requester,
                     note=note,
                     details=_transition(before["alias"] if before else "",
                                         alias, HAND))
        conn.execute("COMMIT")
    except BaseException:
        try:
            conn.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise
    return {"ip": key.removesuffix("/32"), "alias": alias, "source": HAND}


def import_aliases(conn, entries, *, requester: str = "",
                   override: bool = False) -> dict:
    """Bulk-import aliases from any source, honouring DEC-A: an alias a
    human typed outranks every importer.

    Vendor-agnostic by construction - `source` is just a label the caller
    supplies, so UniFi, Nimbus and a hand-written file all use this one
    path and no vendor code lives in the panel.

    Returns a LEDGER, not a count. A skip is a designed refusal, and the
    caller has to be able to see WHICH hosts kept their typed name - an
    aggregate total would hide exactly the case the precedence rule exists
    to protect, which is the same silent-success lie this epic removed from
    the UI elsewhere.

    `override` is the attended escape hatch: it lets an operator re-point a
    renamed host at its vendor name without first destroying the name. The
    scheduled sync never sets it.
    """
    results = []
    changed = 0
    for raw_entry in entries:
        entry = dict(raw_entry or {})
        ip_raw = str(entry.get("ip", ""))
        alias = str(entry.get("alias", "") or "").strip()
        try:
            key = host_key(ip_raw)
            source = check_source(str(entry.get("source", "")))
            if source == HAND:
                raise ValidationError(
                    f"{HAND!r} is reserved for an operator's own edit - an "
                    f"import must name its real origin")
            # A blank alias must NEVER reach set_alias: there a blank means
            # REMOVE, and removal has no precedence check - so an unnamed
            # vendor device would silently delete a hand-edited name,
            # defeating this rule while appearing to honour it.
            if not alias:
                raise ValidationError(
                    "alias is empty - an import may not clear a name "
                    "(removal is a separate, deliberate act)")
        except ValidationError as exc:
            results.append({"ip": ip_raw, "outcome": "rejected",
                            "reason": str(exc)})
            continue

        ts = _now()
        conn.execute("BEGIN IMMEDIATE")
        try:
            # Read first, for the LEDGER only. The WHERE clause below is
            # what actually enforces precedence: the in-process mutex does
            # not serialize against a CLI process holding the same file, so
            # a read-then-decide check would be a race.
            before = conn.execute(
                "SELECT alias, source FROM device_identity WHERE cidr = ?",
                (key,)).fetchone()
            sql = ("INSERT INTO device_identity (cidr, alias, source, "
                   "updated_at) VALUES (?, ?, ?, ?) "
                   "ON CONFLICT(cidr) DO UPDATE SET alias = excluded.alias, "
                   "source = excluded.source, "
                   "updated_at = excluded.updated_at")
            if not override:
                # Only a row this same source already owns may be updated;
                # a hand-edit (or another importer's row) is left alone.
                # UNKNOWN is the exception and must stay one: it can only
                # come from raw SQL that omitted the column, so it carries
                # no authority and any importer may claim it. Leaving it
                # unclaimable would let an un-provenanced write block every
                # future sync for that host.
                sql += (" WHERE device_identity.source = excluded.source"
                        " OR device_identity.source = ''")
            cur = conn.execute(sql, (key, alias, source, ts))
            wrote = cur.rowcount > 0
            if wrote and before is not None and before["alias"] == alias \
                    and before["source"] == source:
                outcome = "unchanged"
            elif wrote:
                outcome = "applied"
            else:
                outcome = "skipped"
            if wrote and outcome == "applied":
                append_audit(
                    conn, action="alias", cidr=key, requester=requester,
                    details=_transition(before["alias"] if before else "",
                                        alias, source))
            conn.execute("COMMIT")
        except BaseException:
            try:
                conn.execute("ROLLBACK")
            except sqlite3.Error:
                pass
            raise

        row = {"ip": key.removesuffix("/32"), "outcome": outcome,
               "alias": alias, "source": source}
        if before is not None:
            row["existing_alias"] = before["alias"]
            row["existing_source"] = before["source"]
        if outcome == "skipped":
            row["reason"] = (
                f"{before['source'] or 'unknown-provenance'!r} owns this "
                f"alias; {source!r} may not overwrite it")
        results.append(row)
        if outcome == "applied":
            changed += 1

    return {
        "results": results,
        "changed": changed,
        "applied": sum(1 for r in results if r["outcome"] == "applied"),
        "unchanged": sum(1 for r in results if r["outcome"] == "unchanged"),
        "skipped": sum(1 for r in results if r["outcome"] == "skipped"),
        "rejected": sum(1 for r in results if r["outcome"] == "rejected"),
    }


def remove_alias(conn, raw: str, *, requester: str = "",
                 note: str = "") -> bool:
    """True when a row was removed. Audits only a real removal, so a
    no-op delete does not manufacture history."""
    key = host_key(raw)
    conn.execute("BEGIN IMMEDIATE")
    try:
        before = conn.execute(
            "SELECT alias, source FROM device_identity WHERE cidr = ?",
            (key,)).fetchone()
        cur = conn.execute("DELETE FROM device_identity WHERE cidr = ?",
                           (key,))
        removed = cur.rowcount > 0
        if removed:
            append_audit(conn, action="alias", cidr=key, requester=requester,
                         note=note,
                         details=_transition(before["alias"], "",
                                             before["source"]))
        conn.execute("COMMIT")
    except BaseException:
        try:
            conn.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise
    return removed
