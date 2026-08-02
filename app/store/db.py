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
    # v2 - device identity, separate from policy. `devices.mode` is NOT
    # NULL with a CHECK, so no row there can exist without a routing
    # decision; naming a device must not force one. Relaxing that column
    # would need SQLite's 12-step rebuild, which cannot run here - by the
    # time _migrate opens its transaction PRAGMA foreign_keys is already
    # ON, and pragmas cannot be toggled mid-transaction. A pure CREATE
    # TABLE sidecar leaves every shipped row and the devices DDL itself
    # byte-identical on a populated v1.8.0 database.
    #
    # Keyed on the canonical /32, matching `devices.cidr`, because the only
    # consumer today is the /v1/devices listing. NOTE the stats tables key
    # on the BARE `metadata.sourceIP` (stats.py:120), so a stats-side join
    # must normalize - `identity.host_key()` is the single place that
    # conversion lives, and `identity.resolve()` returns /32 keys.
    #
    # NOT NULL is explicit: `cidr TEXT PRIMARY KEY` alone is a rowid-table
    # key, and SQLite accepts NULL there - several of them, since NULLs are
    # distinct in the implicit index. The shipped `devices.cidr` is
    # `TEXT NOT NULL UNIQUE` for the same reason.
    (2, """
    CREATE TABLE device_identity (
        cidr TEXT PRIMARY KEY NOT NULL,
        alias TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    """),
    # v3 - provenance, so an unattended import cannot overwrite a name a
    # human typed (issue #74 DEC-A: hand-edit wins).
    #
    # The DEFAULT is deliberately EMPTY, not 'hand-edit'. Every row that
    # predates this column really is an operator's own work - nothing else
    # could write one - so the UPDATE below claims that authority for them
    # explicitly, inside this same migration transaction. Making the
    # DEFAULT itself authoritative would be indistinguishable from a future
    # writer that simply forgot the column, and would hand that writer the
    # one value which blocks every subsequent sync. '' therefore means
    # "provenance unknown": the weakest precedence, always overwritable,
    # and unreachable through the API (which rejects a blank source).
    (3, """
    ALTER TABLE device_identity ADD COLUMN source TEXT NOT NULL DEFAULT '';
    UPDATE device_identity SET source = 'hand-edit';
    """),
    # v4 - operator settings. The k/v shape mirrors `stats_meta`
    # (stats.py:61-64), the existing idiom; what it does NOT mirror is
    # where the default lives. This table stores ONLY overrides: an unset
    # key resolves through code, so shipping a new default actually
    # reaches every existing install instead of being shadowed forever by
    # a row written once at first boot.
    #
    # NOT NULL on `k` is explicit for the same reason it is on
    # `device_identity.cidr`: `k TEXT PRIMARY KEY` alone is a rowid-table
    # key and SQLite accepts NULL there - several of them, since NULLs are
    # distinct in the implicit index.
    (4, """
    CREATE TABLE settings (
        k TEXT PRIMARY KEY NOT NULL,
        v TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    """),
    # v5 - a name has exactly one home (#82). Until now a /32 could carry
    # BOTH a policy label (devices.name) and an identity alias, and the UI
    # shipped an affordance whose only job was to explain the discrepancy.
    # After this migration a host's name lives in device_identity ONLY;
    # devices.name stays as the one possible home for a RANGE (identity
    # keys on a /32, so a wider CIDR cannot carry an alias at all). The
    # column is NOT dropped: that needs SQLite's 12-step rebuild, which
    # cannot run here (PRAGMA foreign_keys is ON and pragmas cannot be
    # toggled mid-transaction) - the same collision that produced the
    # sidecar in the first place (v2 above).
    #
    # DISPLAY-INVARIANT by construction (owner decision, #82): the only
    # surviving-name rule is the one the interface already applies - the
    # alias wins wherever one exists. So a label with no identity row MOVES
    # (it becomes a hand-edit alias: only the panel's own form ever wrote
    # devices.name, so hand provenance is honest), a label an alias had
    # displaced is RETIRED into the audit trail in the exact convention the
    # UI's retire control used (`rename 'old' -> ''`, recoverable), an
    # equal pair clears silently (nothing is lost; the importer's `source`
    # is deliberately NOT upgraded, so the next vendor sync still owns its
    # row), and no device shows a different name after the upgrade. #74
    # DEC-A is untouched: it governs writes WITHIN the identity layer.
    #
    # Audit rows are written FIRST (they quote the pre-state), inside the
    # same transaction. details strings are built with SQLite's quote(),
    # which matches Python's repr for quote-free names and diverges only
    # on embedded apostrophes ('it''s' vs "it's") - informational text,
    # not a parsed format. The clear stamps updated_at because it is a
    # real mutation; untouched rows (nameless hosts, every range) keep
    # their stamps byte-identical.
    (5, """
    INSERT INTO audit (ts, action, cidr, mode, requester, note, details)
    SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'alias', d.cidr, '',
           'migration', '',
           quote('') || ' -> ' || quote(d.name) || ' [hand-edit]'
      FROM devices d
     WHERE d.cidr LIKE '%/32' AND d.name != ''
       AND NOT EXISTS (SELECT 1 FROM device_identity i WHERE i.cidr = d.cidr);
    INSERT INTO audit (ts, action, cidr, mode, requester, note, details)
    SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'rename', d.cidr, d.mode,
           'migration', '',
           quote(d.name) || ' -> ' || quote('')
      FROM devices d JOIN device_identity i ON i.cidr = d.cidr
     WHERE d.cidr LIKE '%/32' AND d.name != '' AND i.alias != d.name;
    INSERT INTO device_identity (cidr, alias, source, updated_at)
    SELECT d.cidr, d.name, 'hand-edit', strftime('%Y-%m-%dT%H:%M:%SZ','now')
      FROM devices d
     WHERE d.cidr LIKE '%/32' AND d.name != ''
       AND NOT EXISTS (SELECT 1 FROM device_identity i WHERE i.cidr = d.cidr);
    UPDATE devices SET name = '',
           updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
     WHERE cidr LIKE '%/32' AND name != '';
    """),
]


def open_db(path: Path, *, migrations=None, pre_migrate=()) -> sqlite3.Connection:
    """Open (creating/migrating as needed) with the frozen pragmas. Raises
    StoreError when the store cannot be opened safely. MIGRATIONS defaults
    to the policy schema; stats.db passes its own list (same discipline,
    separate file — brief DEC-8). PRE_MIGRATE pragmas run before the first
    table exists (e.g. auto_vacuum, which cannot be set later without a
    full VACUUM)."""
    path = Path(path)
    _refuse_network_fs(path.parent if path.parent.exists() else path)
    old_umask = os.umask(0o077)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(path.parent, 0o700)
        conn = sqlite3.connect(path, check_same_thread=False)
    except (OSError, sqlite3.Error) as exc:
        raise StoreError(f"cannot open {path.name}: {exc}") from exc
    finally:
        os.umask(old_umask)
    try:
        conn.row_factory = sqlite3.Row
        conn.isolation_level = None  # autocommit; mutations BEGIN explicitly
        conn.execute("PRAGMA busy_timeout = 5000")
        # pre_migrate pragmas MUST run before journal_mode initializes the
        # database header: auto_vacuum is frozen once page 1 exists, and
        # setting it later silently no-ops without a full VACUUM.
        for pragma in pre_migrate:
            conn.execute(pragma)
        mode = conn.execute("PRAGMA journal_mode = WAL").fetchone()[0]
        if mode != "wal":
            raise StoreError(
                f"WAL journal mode unavailable (got {mode!r}) - is the data "
                f"dir on a network filesystem?")
        conn.execute("PRAGMA synchronous = NORMAL")
        conn.execute("PRAGMA foreign_keys = ON")
        os.chmod(path, 0o600)
        _migrate(conn, migrations if migrations is not None else MIGRATIONS)
    except StoreError:
        conn.close()
        raise
    except (OSError, sqlite3.Error) as exc:
        conn.close()
        raise StoreError(f"{path.name} failed to initialize: {exc}") from exc
    return conn


def _migrate(conn: sqlite3.Connection, migrations) -> None:
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    for version, sql in migrations:
        if version <= current:
            continue
        conn.execute("BEGIN IMMEDIATE")
        try:
            # Re-read INSIDE the transaction. The check above raced: two
            # processes opening the same database (the panel and a CLI
            # invocation) both see the old version, both queue on
            # BEGIN IMMEDIATE, and the loser would then re-run a
            # CREATE TABLE that already exists and abort the open. Only
            # this read is serialized against the winner's COMMIT.
            applied = conn.execute("PRAGMA user_version").fetchone()[0]
            if version <= applied:
                conn.execute("COMMIT")
                continue
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
