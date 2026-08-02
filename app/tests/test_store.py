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


# --- migration v5: a name has exactly one home (#82) -------------------------

T0 = "2026-01-01T00:00:00Z"


def _v190_policy_db(path):
    """A policy.db as v1.9.0 shipped it: schema version 4, populated raw —
    the API-era guards (overlap, canonicalization) don't gate what an old
    database may already hold, so the fixture must not run them either."""
    conn = open_db(path, migrations=dbmod.MIGRATIONS[:4])
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 4
    return conn


def _seed_v190(conn):
    dev = ("INSERT INTO devices (cidr, mode, name, note, created_at, "
           "updated_at) VALUES (?, ?, ?, '', ?, ?)")
    ident = ("INSERT INTO device_identity (cidr, alias, source, updated_at) "
             "VALUES (?, ?, ?, ?)")
    # A: typed label, no identity row - the label must MOVE
    conn.execute(dev, ("192.0.2.10/32", "full-tunnel", "printer", T0, T0))
    # B: typed label vs an IMPORTED alias that disagrees - alias wins
    #    (owner-decided; the screen already showed it)
    conn.execute(dev, ("192.0.2.11/32", "full-tunnel", "typed-b", T0, T0))
    conn.execute(ident, ("192.0.2.11/32", "vendor-b", "unifi", T0))
    # C: typed label vs a HAND alias that disagrees - alias wins
    conn.execute(dev, ("192.0.2.12/32", "full-direct", "old-c", T0, T0))
    conn.execute(ident, ("192.0.2.12/32", "newer-c", "hand-edit", T0))
    # D: label and alias agree - silent clear, source NOT upgraded
    conn.execute(dev, ("192.0.2.13/32", "full-tunnel", "same-d", T0, T0))
    conn.execute(ident, ("192.0.2.13/32", "same-d", "unifi", T0))
    # E: nameless host - nothing to do, row must stay byte-identical
    conn.execute(dev, ("192.0.2.14/32", "full-direct", "", T0, T0))
    # R: a RANGE - no alias can exist for it, so devices.name stays its home
    conn.execute(dev, ("198.51.100.0/24", "full-direct", "lab", T0, T0))


def _display(conn):
    """The one rule the UI applies: alias wins where one exists."""
    aliases = {r["cidr"]: r["alias"] for r in conn.execute(
        "SELECT cidr, alias FROM device_identity")}
    return {r["cidr"]: aliases.get(r["cidr"]) or r["name"] or "(unnamed)"
            for r in conn.execute("SELECT cidr, name FROM devices")}


def test_a_populated_v190_database_migrates_with_every_name_intact(tmp_path):
    path = tmp_path / "state" / "policy.db"
    old = _v190_policy_db(path)
    _seed_v190(old)
    display_before = _display(old)
    audit_before = old.execute("SELECT count(*) FROM audit").fetchone()[0]
    old.close()

    conn = open_db(path)
    try:
        assert conn.execute("PRAGMA user_version").fetchone()[0] \
            == len(dbmod.MIGRATIONS)

        # THE property: the migration is display-invariant. Every device
        # shows the identical name before and after, because the only
        # surviving-name rule is the one the interface already applied.
        assert _display(conn) == display_before

        # every /32 policy label is gone; the range keeps its only name
        named_hosts = conn.execute(
            "SELECT cidr FROM devices WHERE cidr LIKE '%/32' "
            "AND name != ''").fetchall()
        assert named_hosts == [], f"hosts still carry a policy label: " \
            f"{[r['cidr'] for r in named_hosts]}"
        assert conn.execute(
            "SELECT name FROM devices WHERE cidr = '198.51.100.0/24'"
        ).fetchone()["name"] == "lab"

        # A moved: the label became a hand-edit alias
        row = conn.execute("SELECT alias, source FROM device_identity "
                           "WHERE cidr = '192.0.2.10/32'").fetchone()
        assert (row["alias"], row["source"]) == ("printer", "hand-edit")
        # B and C kept their alias; B's importer provenance is untouched,
        # so the next vendor sync still owns its row
        for cidr, alias, source in (("192.0.2.11/32", "vendor-b", "unifi"),
                                    ("192.0.2.12/32", "newer-c", "hand-edit"),
                                    ("192.0.2.13/32", "same-d", "unifi")):
            row = conn.execute(
                "SELECT alias, source, updated_at FROM device_identity "
                "WHERE cidr = ?", (cidr,)).fetchone()
            assert (row["alias"], row["source"]) == (alias, source), cidr
            assert row["updated_at"] == T0, f"{cidr}: an untouched identity " \
                f"row must not be rewritten"

        # cleared rows say when; untouched rows say nothing happened
        stamps = {r["cidr"]: r["updated_at"] for r in conn.execute(
            "SELECT cidr, updated_at FROM devices")}
        for cidr in ("192.0.2.10/32", "192.0.2.11/32", "192.0.2.12/32",
                     "192.0.2.13/32"):
            assert stamps[cidr] != T0, f"{cidr}: clearing the label is a " \
                f"mutation and must stamp updated_at"
        for cidr in ("192.0.2.14/32", "198.51.100.0/24"):
            assert stamps[cidr] == T0, f"{cidr}: nothing changed here"

        # NO NAME LOST: the two retired labels are in the audit trail in
        # the exact convention the UI's retire control wrote, and the move
        # is recorded as an alias birth. D (equal) and E/R (no-ops) add
        # nothing - a no-op must not manufacture history.
        rows = conn.execute(
            "SELECT action, cidr, mode, requester, details FROM audit "
            "ORDER BY id").fetchall()[audit_before:]
        entries = {(r["action"], r["cidr"]): r for r in rows}
        assert len(rows) == 3, [dict(r) for r in rows]
        assert all(r["requester"] == "migration" for r in rows)
        assert entries[("alias", "192.0.2.10/32")]["details"] \
            == "'' -> 'printer' [hand-edit]"
        assert entries[("rename", "192.0.2.11/32")]["details"] \
            == "'typed-b' -> ''"
        assert entries[("rename", "192.0.2.12/32")]["details"] \
            == "'old-c' -> ''"
        # the rename convention carries the mode, exactly as policy.py's does
        assert entries[("rename", "192.0.2.11/32")]["mode"] == "full-tunnel"
    finally:
        conn.close()


def test_the_v5_migration_is_a_no_op_the_second_time(tmp_path):
    path = tmp_path / "state" / "policy.db"
    old = _v190_policy_db(path)
    _seed_v190(old)
    old.close()
    first = open_db(path)
    after_first = [tuple(r) for r in first.execute(
        "SELECT cidr, name, updated_at FROM devices ORDER BY cidr")]
    audit_count = first.execute("SELECT count(*) FROM audit").fetchone()[0]
    first.close()
    again = open_db(path)
    try:
        assert [tuple(r) for r in again.execute(
            "SELECT cidr, name, updated_at FROM devices ORDER BY cidr")] \
            == after_first
        assert again.execute(
            "SELECT count(*) FROM audit").fetchone()[0] == audit_count
    finally:
        again.close()
