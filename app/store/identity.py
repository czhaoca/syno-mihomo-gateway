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


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


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
    return [{"ip": r["cidr"].removesuffix("/32"), "alias": r["alias"]}
            for r in conn.execute(
                "SELECT cidr, alias FROM device_identity ORDER BY cidr")]


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


def _transition(before: str, after: str) -> str:
    """`details` payload in the shipped convention - `policy.py`'s rename
    writes `'old' -> 'new'` there and keeps `note` for the operator's own
    note. Recording both ends is what lets a reader tell a rename from a
    removal, and recovers the previous name from history."""
    return f"{before!r} -> {after!r}"


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
        conn.execute(
            "INSERT INTO device_identity (cidr, alias, updated_at) "
            "VALUES (?, ?, ?) ON CONFLICT(cidr) DO UPDATE SET "
            "alias = excluded.alias, updated_at = excluded.updated_at",
            (key, alias, ts))
        append_audit(conn, action="alias", cidr=key, requester=requester,
                     note=note,
                     details=_transition(before["alias"] if before else "",
                                         alias))
        conn.execute("COMMIT")
    except BaseException:
        try:
            conn.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise
    return {"ip": key.removesuffix("/32"), "alias": alias}


def remove_alias(conn, raw: str, *, requester: str = "",
                 note: str = "") -> bool:
    """True when a row was removed. Audits only a real removal, so a
    no-op delete does not manufacture history."""
    key = host_key(raw)
    conn.execute("BEGIN IMMEDIATE")
    try:
        before = conn.execute(
            "SELECT alias FROM device_identity WHERE cidr = ?",
            (key,)).fetchone()
        cur = conn.execute("DELETE FROM device_identity WHERE cidr = ?",
                           (key,))
        removed = cur.rowcount > 0
        if removed:
            append_audit(conn, action="alias", cidr=key, requester=requester,
                         note=note,
                         details=_transition(before["alias"] if before else "",
                                             ""))
        conn.execute("COMMIT")
    except BaseException:
        try:
            conn.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise
    return removed
