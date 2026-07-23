"""Store behavior: open/migrate discipline (WAL, pragmas, umask, network-FS
refusal), CRUD with one-mode-per-IP and cross-mode overlap rejection, and the
per-mutation VACUUM INTO backup rotation."""

import os
import sqlite3
import stat
from pathlib import Path

import pytest
from app.store import db as dbmod
from app.store.db import StoreError, open_db
from app.store.policy import (
    StoreConflict,
    add_device,
    backup_db,
    get_device,
    list_devices,
    remove_device,
    update_device,
)


@pytest.fixture()
def conn(tmp_path):
    path = tmp_path / "state" / "policy.db"
    c = open_db(path)
    yield c
    c.close()


def test_open_sets_pragmas_and_migrates(tmp_path):
    path = tmp_path / "state" / "policy.db"
    c = open_db(path)
    assert c.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    assert c.execute("PRAGMA user_version").fetchone()[0] >= 1
    tables = {r[0] for r in c.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"devices", "audit"} <= tables
    c.close()


def test_db_file_is_owner_only(tmp_path):
    path = tmp_path / "state" / "policy.db"
    c = open_db(path)
    c.close()
    mode = stat.S_IMODE(os.stat(path).st_mode)
    assert mode == 0o600, f"policy.db must be 0600, got {oct(mode)}"
    dmode = stat.S_IMODE(os.stat(path.parent).st_mode)
    assert dmode == 0o700, f"state dir must be 0700, got {oct(dmode)}"


def test_network_fs_refused(tmp_path, monkeypatch):
    path = tmp_path / "state" / "policy.db"

    def fake_mounts():
        # longest-prefix mount for the db path reports NFS
        return [("/", "ext4"), (str(tmp_path), "nfs4")]

    monkeypatch.setattr(dbmod, "_mounts", fake_mounts)
    with pytest.raises(StoreError) as exc:
        open_db(path)
    assert "network filesystem" in str(exc.value)


def test_add_list_get_update_remove(conn):
    d = add_device(conn, "192.0.2.5", "full-tunnel", name="tv", note="living room",
                   requester="203.0.113.9")
    assert d["cidr"] == "192.0.2.5/32"
    assert d["mode"] == "full-tunnel"
    rows = list_devices(conn)
    assert len(rows) == 1 and rows[0]["name"] == "tv"

    flipped = update_device(conn, d["id"], mode="full-direct",
                            requester="203.0.113.9")
    assert flipped["mode"] == "full-direct"
    renamed = update_device(conn, d["id"], name="tv-2", requester="203.0.113.9")
    assert renamed["name"] == "tv-2"
    assert get_device(conn, d["id"])["name"] == "tv-2"

    remove_device(conn, d["id"], requester="203.0.113.9")
    assert list_devices(conn) == []


def test_one_mode_per_ip_unique(conn):
    add_device(conn, "192.0.2.5", "full-tunnel", requester="t")
    with pytest.raises(StoreConflict):
        add_device(conn, "192.0.2.5/32", "full-direct", requester="t")
    with pytest.raises(StoreConflict):
        add_device(conn, "192.0.2.5", "full-tunnel", requester="t")


def test_cross_mode_overlap_rejected(conn):
    add_device(conn, "192.0.2.0/28", "full-tunnel", requester="t")
    with pytest.raises(StoreConflict) as exc:
        add_device(conn, "192.0.2.5", "full-direct", requester="t")
    assert "overlap" in str(exc.value)
    # same-mode adjacency is fine
    add_device(conn, "192.0.2.16/28", "full-tunnel", requester="t")


def test_update_mode_overlap_rejected(conn):
    add_device(conn, "192.0.2.0/28", "full-tunnel", requester="t")
    other = add_device(conn, "192.0.2.16/28", "full-tunnel", requester="t")
    # flipping the second range to full-direct is fine (no overlap) ...
    update_device(conn, other["id"], mode="full-direct", requester="t")
    # ... but a flip that would overlap the other mode's range is refused
    third = add_device(conn, "192.0.2.32/28", "full-tunnel", requester="t")
    with pytest.raises(StoreConflict):
        update_device(conn, third["id"], cidr="192.0.2.17", requester="t")


def test_mode_only_update_recheks_reserved_addresses(conn, monkeypatch):
    # The gateway/panel address knobs can change AFTER an entry exists: a
    # mode-only flip on an entry now covering them must fail closed.
    d = add_device(conn, "192.168.1.0/24", "full-tunnel", requester="t")
    monkeypatch.setenv("MIHOMO_IP", "192.168.1.100")
    from app.validation import ValidationError
    with pytest.raises(ValidationError) as exc:
        update_device(conn, d["id"], mode="full-direct", requester="t")
    assert "gateway" in str(exc.value)


def test_migration_from_empty(tmp_path):
    path = tmp_path / "state" / "policy.db"
    path.parent.mkdir(parents=True)
    raw = sqlite3.connect(path)
    assert raw.execute("PRAGMA user_version").fetchone()[0] == 0
    raw.close()
    c = open_db(path)
    assert c.execute("PRAGMA user_version").fetchone()[0] >= 1
    c.close()


def test_backup_rotation_and_restorability(tmp_path, conn):
    db_path = Path(conn.execute("PRAGMA database_list").fetchone()[2])
    add_device(conn, "192.0.2.1", "full-tunnel", requester="t")
    for _i in range(4):
        backup_db(conn, db_path, keep=2)
    backups = sorted(db_path.parent.glob("policy.db.bak-*"))
    assert len(backups) == 2, f"keep=2 must retain 2 backups: {backups}"
    # a backup is a full standalone db: restore = copy it back
    check = sqlite3.connect(backups[-1])
    rows = check.execute("SELECT cidr, mode FROM devices").fetchall()
    check.close()
    assert rows == [("192.0.2.1/32", "full-tunnel")]


def test_backup_keep_zero_skips(tmp_path, conn):
    db_path = Path(conn.execute("PRAGMA database_list").fetchone()[2])
    backup_db(conn, db_path, keep=0)
    assert list(db_path.parent.glob("policy.db.bak-*")) == []
