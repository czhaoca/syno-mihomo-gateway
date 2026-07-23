"""policy.db open/migrate discipline.

WAL + synchronous=NORMAL + busy_timeout, owner-only files (umask 077),
`PRAGMA user_version` migrations at startup, and a refusal to run WAL on a
network filesystem (WAL's shared-memory index silently corrupts over
NFS/CIFS). The connection is shared across FastAPI's threadpool, so callers
serialize mutations through the Store lock in policy.py.
"""

import os
import sqlite3
from pathlib import Path

# Filesystems where SQLite WAL is known-unsafe (shm mapping over the wire).
NETWORK_FS = {
    "nfs", "nfs4", "cifs", "smb", "smb2", "smbfs", "fuse.sshfs", "9p",
    "afpfs", "webdav", "davfs",
}


class StoreError(RuntimeError):
    """The policy store is unavailable or refused to open."""


def _mounts() -> list:
    """(mountpoint, fstype) pairs from /proc/self/mounts; empty where /proc
    does not exist (macOS dev) — the WAL round-trip assert still guards."""
    mounts = []
    try:
        with open("/proc/self/mounts", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 3:
                    mounts.append((parts[1], parts[2]))
    except OSError:
        pass
    return mounts


def _refuse_network_fs(path: Path) -> None:
    resolved = str(path.resolve())
    best = ("", "")
    for mountpoint, fstype in _mounts():
        if resolved.startswith(mountpoint.rstrip("/") + "/") or resolved == mountpoint:
            if len(mountpoint) > len(best[0]):
                best = (mountpoint, fstype)
    if best[1].lower() in NETWORK_FS:
        raise StoreError(
            f"policy.db sits on a network filesystem ({best[1]}) - WAL is "
            f"unsafe there; keep GATEWAY_DATA_DIR on local storage")


MIGRATIONS = [
    # v1 - initial schema: devices (one mode per canonical CIDR) + the
    # append-only audit trail.
    (1, """
    CREATE TABLE devices (
        id INTEGER PRIMARY KEY,
        cidr TEXT NOT NULL UNIQUE,
        mode TEXT NOT NULL CHECK (mode IN ('full-direct', 'full-tunnel')),
        name TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE TABLE audit (
        id INTEGER PRIMARY KEY,
        ts TEXT NOT NULL,
        action TEXT NOT NULL,
        cidr TEXT NOT NULL DEFAULT '',
        mode TEXT NOT NULL DEFAULT '',
        requester TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        details TEXT NOT NULL DEFAULT ''
    );
    """),
]


def open_db(path: Path) -> sqlite3.Connection:
    """Open (creating/migrating as needed) with the frozen pragmas. Raises
    StoreError when the store cannot be opened safely."""
    path = Path(path)
    _refuse_network_fs(path.parent if path.parent.exists() else path)
    old_umask = os.umask(0o077)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(path.parent, 0o700)
        conn = sqlite3.connect(path, check_same_thread=False)
    except (OSError, sqlite3.Error) as exc:
        raise StoreError(f"cannot open policy.db: {exc}") from exc
    finally:
        os.umask(old_umask)
    try:
        conn.row_factory = sqlite3.Row
        conn.isolation_level = None  # autocommit; mutations BEGIN explicitly
        conn.execute("PRAGMA busy_timeout = 5000")
        mode = conn.execute("PRAGMA journal_mode = WAL").fetchone()[0]
        if mode != "wal":
            raise StoreError(
                f"WAL journal mode unavailable (got {mode!r}) - is the data "
                f"dir on a network filesystem?")
        conn.execute("PRAGMA synchronous = NORMAL")
        conn.execute("PRAGMA foreign_keys = ON")
        os.chmod(path, 0o600)
        _migrate(conn)
    except StoreError:
        conn.close()
        raise
    except (OSError, sqlite3.Error) as exc:
        conn.close()
        raise StoreError(f"policy.db failed to initialize: {exc}") from exc
    return conn


def _migrate(conn: sqlite3.Connection) -> None:
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    for version, sql in MIGRATIONS:
        if version <= current:
            continue
        conn.execute("BEGIN IMMEDIATE")
        try:
            # executescript() would auto-COMMIT first; run statements
            # individually so the migration stays one transaction.
            for stmt in (s.strip() for s in sql.split(";")):
                if stmt:
                    conn.execute(stmt)
            conn.execute(f"PRAGMA user_version = {version}")
            conn.execute("COMMIT")
        except sqlite3.Error:
            conn.execute("ROLLBACK")
            raise
