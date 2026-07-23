"""Device-policy CRUD over policy.db.

SQLite is the single source of truth. Every mutation validates first
(fail-closed), appends its audit entry in the SAME transaction, and the
API layer follows up with a VACUUM INTO backup. One mode per IP is schema
law (UNIQUE cidr); cross-mode overlap is refused here so a device can
never be simultaneously forced-direct and forced-tunneled by two ranges.
"""

import os
import sqlite3
import time
from datetime import UTC, datetime
from pathlib import Path

from app.store.audit import append_audit
from app.validation import (
    ValidationError,
    canonicalize,
    check_reserved_addresses,
    cidrs_overlap,
)

__all__ = ["StoreConflict", "ValidationError", "add_device", "backup_db",
           "desired_state", "get_device", "list_devices", "remove_device",
           "update_device", "validate_entry"]

MODES = ("full-direct", "full-tunnel")


class StoreConflict(ValueError):
    """The mutation conflicts with an existing entry (duplicate/overlap)."""


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _row_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def validate_entry(raw: str) -> str:
    """Canonicalize + panel-level guards; ValidationError on any defect."""
    canonical = canonicalize(raw)
    check_reserved_addresses(canonical)
    return canonical


def _check_overlap(conn, canonical: str, mode: str, exclude_id=None) -> None:
    query = "SELECT id, cidr, mode FROM devices"
    for row in conn.execute(query):
        if exclude_id is not None and row["id"] == exclude_id:
            continue
        if row["mode"] != mode and cidrs_overlap(canonical, row["cidr"]):
            raise StoreConflict(
                f"{canonical} ({mode}) would overlap {row['cidr']} "
                f"({row['mode']}) - a device cannot be forced both ways")


def list_devices(conn) -> list:
    rows = conn.execute("SELECT * FROM devices ORDER BY cidr").fetchall()
    return [_row_dict(r) for r in rows]


def get_device(conn, device_id: int) -> dict | None:
    row = conn.execute("SELECT * FROM devices WHERE id = ?",
                       (device_id,)).fetchone()
    return _row_dict(row) if row else None


def desired_state(conn) -> dict:
    """The reconciler's input: canonical CIDRs per mode, sorted."""
    state = {mode: [] for mode in MODES}
    for row in conn.execute("SELECT cidr, mode FROM devices ORDER BY cidr"):
        state[row["mode"]].append(row["cidr"])
    return state


def add_device(conn, raw: str, mode: str, *, name: str = "", note: str = "",
               requester: str = "") -> dict:
    if mode not in MODES:
        raise ValidationError(f"mode must be one of {MODES}")
    canonical = validate_entry(raw)
    ts = _now()
    conn.execute("BEGIN IMMEDIATE")
    try:
        _check_overlap(conn, canonical, mode)
        try:
            cur = conn.execute(
                "INSERT INTO devices (cidr, mode, name, note, created_at, "
                "updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                (canonical, mode, name, note, ts, ts))
        except sqlite3.IntegrityError as exc:
            raise StoreConflict(
                f"{canonical} already has a policy entry (one mode per IP)"
            ) from exc
        append_audit(conn, action="add", cidr=canonical, mode=mode,
                     requester=requester, note=note)
        conn.execute("COMMIT")
    except BaseException:
        _rollback(conn)
        raise
    return get_device(conn, cur.lastrowid)


def update_device(conn, device_id: int, *, cidr: str | None = None,
                  mode: str | None = None, name: str | None = None,
                  note: str | None = None, requester: str = "") -> dict:
    current = get_device(conn, device_id)
    if current is None:
        raise KeyError(device_id)
    if cidr is not None:
        new_cidr = validate_entry(cidr)
    else:
        # Re-run the reserved-address guard on the EXISTING cidr too: the
        # gateway/panel address knobs may have changed since the entry was
        # added, and a mode flip on an entry covering them must fail
        # closed, not slip past because the address field was untouched.
        new_cidr = current["cidr"]
        check_reserved_addresses(new_cidr)
    new_mode = mode if mode is not None else current["mode"]
    if new_mode not in MODES:
        raise ValidationError(f"mode must be one of {MODES}")
    ts = _now()
    conn.execute("BEGIN IMMEDIATE")
    try:
        _check_overlap(conn, new_cidr, new_mode, exclude_id=device_id)
        try:
            conn.execute(
                "UPDATE devices SET cidr = ?, mode = ?, name = ?, note = ?, "
                "updated_at = ? WHERE id = ?",
                (new_cidr, new_mode,
                 name if name is not None else current["name"],
                 note if note is not None else current["note"], ts, device_id))
        except sqlite3.IntegrityError as exc:
            raise StoreConflict(
                f"{new_cidr} already has a policy entry (one mode per IP)"
            ) from exc
        audit_note = note if note is not None else ""
        if mode is not None and mode != current["mode"]:
            append_audit(conn, action="flip", cidr=new_cidr, mode=new_mode,
                         requester=requester, note=audit_note)
        if name is not None and name != current["name"]:
            append_audit(conn, action="rename", cidr=new_cidr, mode=new_mode,
                         requester=requester, note=audit_note,
                         details=f"{current['name']!r} -> {name!r}")
        if cidr is not None and new_cidr != current["cidr"]:
            append_audit(conn, action="readdress", cidr=new_cidr,
                         mode=new_mode, requester=requester, note=audit_note,
                         details=f"{current['cidr']} -> {new_cidr}")
        conn.execute("COMMIT")
    except BaseException:
        _rollback(conn)
        raise
    return get_device(conn, device_id)


def remove_device(conn, device_id: int, *, requester: str = "",
                  note: str = "") -> dict:
    current = get_device(conn, device_id)
    if current is None:
        raise KeyError(device_id)
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute("DELETE FROM devices WHERE id = ?", (device_id,))
        append_audit(conn, action="remove", cidr=current["cidr"],
                     mode=current["mode"], requester=requester, note=note)
        conn.execute("COMMIT")
    except BaseException:
        _rollback(conn)
        raise
    return current


def _rollback(conn) -> None:
    try:
        conn.execute("ROLLBACK")
    except sqlite3.Error:
        pass


def backup_db(conn, db_path: Path, keep: int) -> Path | None:
    """Per-mutation VACUUM INTO backup (owner-only), rotating to KEEP
    newest. keep <= 0 disables. Restore = copy the backup over policy.db."""
    if keep <= 0:
        return None
    db_path = Path(db_path)
    target = db_path.parent / f"{db_path.name}.bak-{time.time_ns()}"
    old_umask = os.umask(0o077)
    try:
        conn.execute("VACUUM INTO ?", (str(target),))
    finally:
        os.umask(old_umask)
    backups = sorted(db_path.parent.glob(f"{db_path.name}.bak-*"))
    for stale in backups[:-keep]:
        stale.unlink(missing_ok=True)
    return target
