"""Append-only audit trail.

Callers append inside their own mutation transaction; there is no update
or delete function here ON PURPOSE, and the API exposes no route that
could remove an entry — append-only is enforced by construction.
"""

from datetime import UTC, datetime


def append_audit(conn, *, action: str, cidr: str = "", mode: str = "",
                 requester: str = "", note: str = "", details: str = "") -> None:
    conn.execute(
        "INSERT INTO audit (ts, action, cidr, mode, requester, note, details) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
         action, cidr, mode, requester, note, details))


def list_audit(conn, *, limit: int = 200, offset: int = 0) -> list:
    limit = max(1, min(int(limit), 1000))
    offset = max(0, int(offset))
    rows = conn.execute(
        "SELECT * FROM audit ORDER BY id DESC LIMIT ? OFFSET ?",
        (limit, offset)).fetchall()
    return [dict(r) for r in rows]
