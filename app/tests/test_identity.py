"""Device identity: an alias without a routing policy.

The shipped `devices` table cannot express this - `mode TEXT NOT NULL
CHECK (...)` means no row exists without a policy, and relaxing it needs
SQLite's 12-step rebuild, which cannot run inside `_migrate`'s single
transaction because `PRAGMA foreign_keys` is already ON by then. So
identity lives in an IP-keyed sidecar, and the shipped table is untouched.
"""

import re
import sqlite3
from pathlib import Path

import pytest
from app.store import identity
from app.store.db import MIGRATIONS, open_db
from app.store.policy import add_device, remove_device, update_device
from app.tests.conftest import auth_headers
from app.validation import ValidationError


@pytest.fixture()
def conn(tmp_path, panel_env):
    """`panel_env` shields the reserved-address guard, which reads
    MIHOMO_IP/PANEL_IP from the ambient environment."""
    c = open_db(tmp_path / "policy.db")
    yield c
    c.close()


def test_alias_needs_no_policy_row(conn):
    """The whole point: naming a device must not force a routing decision
    on it."""
    identity.set_alias(conn, "192.0.2.50", "Living room TV", requester="t")
    assert identity.get_alias(conn, "192.0.2.50") == "Living room TV"
    # and no policy was invented on the way
    assert conn.execute("SELECT COUNT(*) FROM devices").fetchone()[0] == 0


def test_alias_survives_a_policy_arriving_later(conn):
    identity.set_alias(conn, "192.0.2.51", "Desk", requester="t")
    add_device(conn, "192.0.2.51", "full-tunnel", requester="t")
    assert identity.get_alias(conn, "192.0.2.51") == "Desk"


def test_alias_survives_the_policy_being_removed(conn):
    """Identity outliving policy is the reason it is a separate table."""
    dev = add_device(conn, "192.0.2.52", "full-direct", requester="t")
    identity.set_alias(conn, "192.0.2.52", "Printer", requester="t")
    remove_device(conn, dev["id"], requester="t")
    assert conn.execute("SELECT COUNT(*) FROM devices").fetchone()[0] == 0
    assert identity.get_alias(conn, "192.0.2.52") == "Printer"


def test_set_alias_is_an_upsert_not_a_duplicate(conn):
    identity.set_alias(conn, "192.0.2.53", "First", requester="t")
    identity.set_alias(conn, "192.0.2.53", "Second", requester="t")
    assert identity.get_alias(conn, "192.0.2.53") == "Second"
    assert len(identity.list_aliases(conn)) == 1


def test_removing_an_alias_leaves_no_row(conn):
    identity.set_alias(conn, "192.0.2.54", "Gone", requester="t")
    assert identity.remove_alias(conn, "192.0.2.54") is True
    assert identity.get_alias(conn, "192.0.2.54") == ""
    assert identity.remove_alias(conn, "192.0.2.54") is False


@pytest.mark.parametrize("bad", [
    # stats.py substitutes this literal when mihomo reports no sourceIP;
    # it must never become an aliasable pseudo-device
    "unknown",
    "",
    "192.0.2.0/28",       # a range has no single host to name
    "192.0.2.300",
    "2001:db8::1",
    "host.local",
    "192.0.2.1 ",
])
def test_identity_key_must_be_a_single_host(conn, bad):
    with pytest.raises(ValidationError):
        identity.set_alias(conn, bad, "nope", requester="t")


def test_a_32_cidr_and_its_bare_ip_are_the_same_device(conn):
    """The stats tables key on a bare `metadata.sourceIP`; the policy table
    stores canonical CIDRs. Both must land on one identity row."""
    identity.set_alias(conn, "192.0.2.55", "One", requester="t")
    identity.set_alias(conn, "192.0.2.55/32", "Same device", requester="t")
    assert len(identity.list_aliases(conn)) == 1
    assert identity.get_alias(conn, "192.0.2.55") == "Same device"


def test_alias_change_is_audited(conn):
    """`details` carries the transition and `note` stays the operator's own
    note - the convention `policy.py`'s rename already uses. Recording both
    ends is what lets a reader tell a rename from a removal and recover the
    previous name from history."""
    identity.set_alias(conn, "192.0.2.56", "Named", requester="203.0.113.9")
    rows = conn.execute(
        "SELECT action, cidr, requester, note, details FROM audit").fetchall()
    assert [r["action"] for r in rows] == ["alias"]
    assert rows[0]["cidr"] == "192.0.2.56/32"
    assert rows[0]["requester"] == "203.0.113.9"
    assert rows[0]["details"] == "'' -> 'Named' [hand-edit]"
    assert rows[0]["note"] == ""


def test_a_rename_and_a_removal_are_distinguishable_in_the_audit(conn):
    """Both write action="alias", so the transition in `details` is the only
    thing separating them - and the old name has to survive there, or an
    accidental removal is unrecoverable from history."""
    identity.set_alias(conn, "192.0.2.58", "First", requester="t")
    identity.set_alias(conn, "192.0.2.58", "Second", requester="t")
    identity.remove_alias(conn, "192.0.2.58", requester="t")
    details = [r["details"] for r in conn.execute(
        "SELECT details FROM audit WHERE action = 'alias' ORDER BY id")]
    assert details == ["'' -> 'First' [hand-edit]",
                       "'First' -> 'Second' [hand-edit]",
                       "'Second' -> '' [hand-edit]"]


def test_a_no_op_removal_manufactures_no_history(conn):
    identity.remove_alias(conn, "192.0.2.59", requester="t")
    assert conn.execute("SELECT COUNT(*) FROM audit").fetchone()[0] == 0
    # ...but a real one is recorded
    identity.set_alias(conn, "192.0.2.59", "Real", requester="t")
    assert identity.remove_alias(conn, "192.0.2.59", requester="t") is True
    actions = [r["action"] for r in conn.execute(
        "SELECT action FROM audit ORDER BY id")]
    assert actions == ["alias", "alias"]


def test_an_alias_may_be_any_text_the_owner_types(conn):
    """The repo mandates EN+zh throughout, so a Chinese alias must survive
    the round trip intact - not be stripped, transliterated or truncated
    into the blank alias that means "remove"."""
    for alias in ("客厅电视", "José's iPhone", "emoji 📺 tv",
                  "Living room Apple TV (upstairs)", "a" * 300,
                  "quote'and\"double", "semi;colon --sql"):
        identity.set_alias(conn, "192.0.2.62", alias, requester="t")
        assert identity.get_alias(conn, "192.0.2.62") == alias


def test_the_same_alias_may_name_two_hosts(conn):
    """Two phones called "iPhone" is ordinary household reality, and the
    shape #74's bulk import will load."""
    identity.set_alias(conn, "192.0.2.63", "iPhone", requester="t")
    identity.set_alias(conn, "192.0.2.64", "iPhone", requester="t")
    assert identity.get_alias(conn, "192.0.2.63") == "iPhone"
    assert identity.get_alias(conn, "192.0.2.64") == "iPhone"


def test_listing_order_is_stable_and_declared(conn):
    """`ORDER BY cidr` is a TEXT sort, so .9 follows .10. Pinning it makes
    that a reviewed choice rather than an accident, and gives #74/#80 a
    listing they can diff."""
    for ip in ("192.0.2.10", "192.0.2.9", "192.0.2.100"):
        identity.set_alias(conn, ip, f"host-{ip}", requester="t")
    assert [r["ip"] for r in identity.list_aliases(conn)] == [
        "192.0.2.10", "192.0.2.100", "192.0.2.9"]


def test_blank_alias_is_a_removal_not_an_empty_name(conn):
    identity.set_alias(conn, "192.0.2.57", "Temp", requester="t")
    identity.set_alias(conn, "192.0.2.57", "   ", requester="t")
    assert identity.get_alias(conn, "192.0.2.57") == ""
    assert identity.list_aliases(conn) == []


# --- migration safety against a populated v1.8.0 database ---------------

def _v180_db(path):
    """A database at exactly the shipped v1.8.0 schema (migration 1)."""
    return open_db(path, migrations=MIGRATIONS[:1])


def test_upgrading_a_populated_v180_database_preserves_every_row(tmp_path):
    """The gate that matters: v1.8.0 shipped, so live databases carry rows.
    Named for what it checks - full row-value and full-schema equality
    across the upgrade, not literal file bytes (WAL and page layout change
    for reasons that have nothing to do with the migration).

    The audit fixture deliberately spans SEVERAL action verbs: with only
    `add` rows present, a migration that pruned `flip`/`rename`/`remove`
    history would pass unnoticed."""
    path = tmp_path / "policy.db"
    old = _v180_db(path)
    assert old.execute("PRAGMA user_version").fetchone()[0] == 1
    dev = add_device(old, "192.0.2.10", "full-tunnel", name="Kept", note="n",
                     requester="before")
    add_device(old, "192.0.2.11/32", "full-direct", requester="before")
    update_device(old, dev["id"], mode="full-direct", requester="before")
    update_device(old, dev["id"], name="Renamed", requester="before")
    remove_device(old, dev["id"], requester="before")
    before_devices = [tuple(r) for r in old.execute(
        "SELECT * FROM devices ORDER BY id")]
    before_audit = [tuple(r) for r in old.execute(
        "SELECT * FROM audit ORDER BY id")]
    # the WHOLE schema, not just the devices row: an index or trigger added
    # or dropped behind our back is exactly the invisible change to catch
    before_schema = sorted(
        tuple(r) for r in old.execute("SELECT type, name, sql FROM sqlite_master"))
    before_actions = {r["action"] for r in old.execute(
        "SELECT action FROM audit")}
    assert before_actions >= {"add", "flip", "rename", "remove"}, (
        f"fixture must span several action verbs or a history-pruning "
        f"migration would pass unnoticed; got {sorted(before_actions)}")
    old.close()

    new = open_db(path)
    assert new.execute("PRAGMA user_version").fetchone()[0] == len(MIGRATIONS)
    assert [tuple(r) for r in new.execute(
        "SELECT * FROM devices ORDER BY id")] == before_devices
    assert [tuple(r) for r in new.execute(
        "SELECT * FROM audit ORDER BY id")] == before_audit
    after_schema = sorted(
        tuple(r) for r in new.execute("SELECT type, name, sql FROM sqlite_master"))
    added = sorted(r[1] for r in after_schema if r not in before_schema)
    # the sidecar table plus the implicit index SQLite builds for its TEXT
    # PRIMARY KEY - and nothing else
    assert added == ["device_identity", "sqlite_autoindex_device_identity_1"], (
        f"the upgrade changed more of the schema than the sidecar: {added}")
    assert all(r in after_schema for r in before_schema), \
        "the upgrade removed or rewrote part of the shipped schema"
    new.close()


def test_a_later_migration_cannot_quietly_wipe_the_sidecar(tmp_path):
    """Populate the sidecar BEFORE the upgrade path runs, so a future
    migration that clears it fails here instead of on someone's NAS."""
    path = tmp_path / "policy.db"
    first = open_db(path)
    identity.set_alias(first, "192.0.2.12", "Survivor", requester="t")
    first.close()
    again = open_db(path)
    assert identity.get_alias(again, "192.0.2.12") == "Survivor"
    again.close()


def test_the_sidecar_key_cannot_be_null(tmp_path):
    """`cidr TEXT PRIMARY KEY` alone would accept NULL - several, since
    NULLs are distinct in the implicit index - and `list_aliases` would then
    crash on a row it cannot name. The shipped `devices.cidr` is NOT NULL
    for the same reason."""
    conn = open_db(tmp_path / "policy.db")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO device_identity (cidr, alias, updated_at) "
                     "VALUES (NULL, 'orphan', 't')")
    conn.close()


class _Interleaver:
    """Passes through to a real connection, but runs `on_begin` once, just
    before the migration's BEGIN IMMEDIATE - the only window in which a
    competing process can land."""

    def __init__(self, conn, on_begin):
        self._conn = conn
        self._on_begin = on_begin
        self._fired = False

    def execute(self, sql, *args):
        if sql == "BEGIN IMMEDIATE" and not self._fired:
            self._fired = True
            self._on_begin()
        return self._conn.execute(sql, *args)


def test_a_concurrent_upgrade_does_not_abort_the_second_opener(tmp_path):
    """The panel and a CLI invocation can open the same v1.8.0 database at
    once. Both read user_version=1 outside any transaction, then serialize
    on BEGIN IMMEDIATE - so the loser must notice the upgrade already
    happened. Without the in-transaction re-read it re-runs a CREATE TABLE
    that now exists and the open fails.

    A plain "migrate an already-migrated file" test cannot catch this: the
    outer check skips the migration and the re-read is never reached. The
    interleaving has to be forced.
    """
    from app.store.db import _migrate

    path = tmp_path / "policy.db"
    conn = _v180_db(path)
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 1

    winner = sqlite3.connect(path)
    winner.execute("PRAGMA journal_mode = WAL")

    def other_process_finishes_first():
        for stmt in (s.strip() for s in MIGRATIONS[1][1].split(";")):
            if stmt:
                winner.execute(stmt)
        winner.execute("PRAGMA user_version = 2")
        winner.commit()

    # must not raise: this is the loser's migration pass
    _migrate(_Interleaver(conn, other_process_finishes_first), MIGRATIONS)
    winner.close()

    assert conn.execute("PRAGMA user_version").fetchone()[0] == len(MIGRATIONS)
    # and the connection is still usable - a left-open transaction would
    # surface here as "cannot start a transaction within a transaction"
    identity.set_alias(conn, "192.0.2.13", "After", requester="t")
    assert identity.get_alias(conn, "192.0.2.13") == "After"
    conn.close()


# The devices DDL exactly as v1.8.0 shipped it. Frozen as a literal on
# PURPOSE: deriving the expectation from MIGRATIONS (as the byte-identity
# test's fixture must) means an in-place edit to migration 1 moves the
# expectation along with the code - so new installs would silently get a
# different schema from every already-deployed database, and no test would
# notice. This literal is the only thing pinning that.
V180_DEVICES_DDL = (
    "CREATE TABLE devices (\n"
    "        id INTEGER PRIMARY KEY,\n"
    "        cidr TEXT NOT NULL UNIQUE,\n"
    "        mode TEXT NOT NULL CHECK (mode IN ('full-direct', 'full-tunnel')),\n"
    "        name TEXT NOT NULL DEFAULT '',\n"
    "        note TEXT NOT NULL DEFAULT '',\n"
    "        created_at TEXT NOT NULL,\n"
    "        updated_at TEXT NOT NULL\n"
    "    )"
)


def test_migration_one_still_creates_the_schema_v180_shipped(tmp_path):
    """Migration 1 is history, not code: it is what every live database was
    built from, so editing it in place is a schema fork, not a change."""
    conn = open_db(tmp_path / "policy.db", migrations=MIGRATIONS[:1])
    ddl = conn.execute(
        "SELECT sql FROM sqlite_master WHERE name = 'devices'").fetchone()[0]
    conn.close()
    assert ddl == V180_DEVICES_DDL, (
        "migration 1 no longer produces the shipped v1.8.0 devices schema - "
        "a new install would diverge from every deployed database")


def _normalized(sql: str) -> str:
    """Uppercased, unquoted, single-spaced - so a guard cannot be evaded by
    `ALTER TABLE "devices"`, a newline, or doubled whitespace."""
    return re.sub(r"\s+", " ", sql.upper().replace('"', "").replace("`", "")
                  .replace("[", "").replace("]", ""))


def test_no_later_migration_touches_the_shipped_tables():
    """A structural guard, not a behavioural one: the epic forbids touching
    the shipped table, and only reading the migration list can prove no
    later migration does."""
    for version, sql in MIGRATIONS[1:]:
        norm = _normalized(sql)
        for shipped in ("DEVICES", "AUDIT"):
            for verb in ("ALTER TABLE", "DROP TABLE", "CREATE TABLE",
                         "DELETE FROM", "UPDATE", "INSERT INTO",
                         "DROP INDEX", "CREATE TRIGGER"):
                assert f"{verb} {shipped}" not in norm, (
                    f"migration {version} runs `{verb}` against the shipped "
                    f"{shipped.lower()} table")
        # a rebuild usually hides behind a rename
        assert "RENAME" not in norm, (
            f"migration {version} renames a table - the 12-step rebuild this "
            f"epic forbids starts exactly there")


def test_sidecar_write_is_rolled_back_on_failure(conn, monkeypatch):
    """set_alias appends audit inside its own transaction; a failure after
    the upsert must leave neither row."""
    import app.store.identity as mod

    def boom(*a, **k):
        raise sqlite3.OperationalError("audit exploded (fixture)")

    monkeypatch.setattr(mod, "append_audit", boom)
    with pytest.raises(sqlite3.OperationalError):
        identity.set_alias(conn, "192.0.2.61", "Doomed", requester="t")
    assert identity.get_alias(conn, "192.0.2.61") == ""
    assert conn.execute("SELECT COUNT(*) FROM audit").fetchone()[0] == 0


# --- API surface -------------------------------------------------------

def test_identity_api_round_trip(client, panel_env):
    h = auth_headers(panel_env)
    assert client.get("/v1/identity").json() == {"identities": []}
    made = client.put("/v1/identity/192.0.2.70",
                      json={"alias": "Study Mac"}, headers=h)
    assert made.status_code == 200
    assert made.json()["identity"] == {"ip": "192.0.2.70",
                                       "alias": "Study Mac"}
    # the lock is surfaced where it is created, not only in the docs
    assert made.json()["source"] == "hand-edit"
    listed = client.get("/v1/identity").json()["identities"]
    assert listed == [{"ip": "192.0.2.70", "alias": "Study Mac",
                       "source": "hand-edit"}]
    gone = client.delete("/v1/identity/192.0.2.70", headers=h)
    assert gone.status_code == 200
    assert client.get("/v1/identity").json() == {"identities": []}


def test_identity_writes_are_token_gated(client, panel_env):
    r = client.put("/v1/identity/192.0.2.71", json={"alias": "nope"})
    assert r.status_code == 403
    assert "test-panel-secret" not in r.text
    assert client.delete("/v1/identity/192.0.2.71").status_code == 403
    # reads stay LAN-open, like the rest of the panel
    assert client.get("/v1/identity").status_code == 200


def test_identity_api_rejects_a_pseudo_device(client, panel_env):
    h = auth_headers(panel_env)
    for bad in ("unknown", "2001:db8::1", "192.0.2.300", "host.local"):
        r = client.put(f"/v1/identity/{bad}", json={"alias": "x"}, headers=h)
        assert r.status_code == 422, f"{bad} should be refused, got {r.status_code}"


def test_the_identity_path_cannot_express_a_range(client, panel_env):
    """`/v1/identity/{ip}` is per-host by construction: a CIDR's `/` is a
    path separator, so a range does not address any endpoint at all. That
    is the intended contract, not an oversight - the 404 is the routing
    layer agreeing that there is no such resource."""
    h = auth_headers(panel_env)
    r = client.put("/v1/identity/192.0.2.0/28", json={"alias": "x"},
                   headers=h)
    assert r.status_code == 404
    # and the store-level guard refuses it independently of any routing
    with pytest.raises(ValidationError):
        identity.host_key("192.0.2.0/28")


def test_device_rows_carry_their_alias(client, panel_env):
    """Resolution is decoration on the way out - the policy store itself
    stays free of identity."""
    h = auth_headers(panel_env)
    client.post("/v1/devices",
                json={"address": "192.0.2.80", "mode": "full-tunnel"},
                headers=h)
    client.put("/v1/identity/192.0.2.80", json={"alias": "Guest laptop"},
               headers=h)
    rows = client.get("/v1/devices").json()["devices"]
    assert [r["alias"] for r in rows] == ["Guest laptop"]
    # a device with no identity reports an empty alias, never a missing key
    client.post("/v1/devices",
                json={"address": "192.0.2.81", "mode": "full-direct"},
                headers=h)
    rows = client.get("/v1/devices").json()["devices"]
    assert {r["cidr"]: r["alias"] for r in rows} == {
        "192.0.2.80/32": "Guest laptop", "192.0.2.81/32": ""}


def test_a_range_device_row_reports_no_alias(client, panel_env):
    """A /28 has no single host, so it can carry no identity - and must not
    borrow one from an address it happens to contain."""
    h = auth_headers(panel_env)
    client.put("/v1/identity/192.0.2.98", json={"alias": "Inside"},
               headers=h)
    client.post("/v1/devices",
                json={"address": "192.0.2.96/28", "mode": "full-tunnel"},
                headers=h)
    rows = client.get("/v1/devices").json()["devices"]
    assert [(r["cidr"], r["alias"]) for r in rows] == [("192.0.2.96/28", "")]


# --- import + provenance (issue #74, DEC-A: hand-edit wins) -------------

def _v2_db(path):
    """A database at the identity-sidecar schema BEFORE provenance existed."""
    return open_db(path, migrations=MIGRATIONS[:2])


def test_migration_three_claims_authority_only_for_pre_existing_rows(tmp_path):
    """Every row written before the `source` column existed really is an
    operator's own work - nothing else could write one - so the backfill
    claims `hand-edit` for exactly those."""
    path = tmp_path / "policy.db"
    old = _v2_db(path)
    old.execute("INSERT INTO device_identity (cidr, alias, updated_at) "
                "VALUES ('192.0.2.20/32', 'Typed Long Ago', 't')")
    old.commit()
    old.close()
    new = open_db(path)
    assert new.execute("PRAGMA user_version").fetchone()[0] == len(MIGRATIONS)
    row = new.execute("SELECT alias, source FROM device_identity").fetchone()
    assert (row["alias"], row["source"]) == ("Typed Long Ago", "hand-edit")
    new.close()


def test_the_column_default_does_not_hand_out_authority(tmp_path):
    """The DEFAULT is '' on purpose. If it were 'hand-edit', any future
    writer that simply forgot the column would silently claim the one value
    that blocks every sync - indistinguishable from the backfill. '' means
    unknown provenance: the weakest precedence, always overwritable."""
    conn = open_db(tmp_path / "policy.db")
    default = [r for r in conn.execute("PRAGMA table_info(device_identity)")
               if r["name"] == "source"][0]["dflt_value"]
    assert default in ("''", '""'), (
        f"the source default must be blank, not authoritative; got {default!r}")
    # a column-omitting raw INSERT lands as unknown provenance...
    conn.execute("INSERT INTO device_identity (cidr, alias, updated_at) "
                 "VALUES ('192.0.2.21/32', 'No Provenance', 't')")
    conn.commit()
    assert conn.execute("SELECT source FROM device_identity").fetchone()[
        "source"] == ""
    # ...and an importer may therefore overwrite it, unlike a hand-edit
    report = identity.import_aliases(
        conn, [{"ip": "192.0.2.21", "alias": "From Unifi", "source": "unifi"}],
        requester="cron")
    assert report["results"][0]["outcome"] == "applied"
    conn.close()


def test_an_import_cannot_overwrite_a_name_the_operator_typed(conn):
    identity.set_alias(conn, "192.0.2.22", "Typed By Owner", requester="op")
    report = identity.import_aliases(
        conn, [{"ip": "192.0.2.22", "alias": "unifi-name", "source": "unifi"}],
        requester="cron")
    row = report["results"][0]
    assert row["outcome"] == "skipped"
    assert row["existing_alias"] == "Typed By Owner"
    assert row["existing_source"] == "hand-edit"
    assert "may not overwrite" in row["reason"]
    assert identity.get_alias(conn, "192.0.2.22") == "Typed By Owner"
    assert report["skipped"] == 1 and report["changed"] == 0


def test_a_blank_alias_from_an_import_cannot_delete_a_hand_edit(conn):
    """The trap this rule would otherwise walk into: `set_alias` treats a
    blank alias as a REMOVAL and `remove_alias` has no precedence check, so
    a vendor device with an empty name would silently destroy a typed one
    while appearing to honour the rule."""
    identity.set_alias(conn, "192.0.2.23", "Keep Me", requester="op")
    for blank in ("", "   ", None):
        report = identity.import_aliases(
            conn, [{"ip": "192.0.2.23", "alias": blank, "source": "unifi"}],
            requester="cron")
        assert report["results"][0]["outcome"] == "rejected"
        assert "may not clear a name" in report["results"][0]["reason"]
    assert identity.get_alias(conn, "192.0.2.23") == "Keep Me"


def test_an_import_may_not_claim_operator_authority(conn):
    """Only the hand-edit route may write `hand-edit`; otherwise an importer
    could promote itself above every other importer - and above the
    operator's own future edits."""
    report = identity.import_aliases(
        conn, [{"ip": "192.0.2.24", "alias": "x", "source": "hand-edit"}],
        requester="cron")
    assert report["results"][0]["outcome"] == "rejected"
    assert "reserved" in report["results"][0]["reason"]
    assert identity.list_aliases(conn) == []


def test_a_repeated_sync_is_idempotent_and_says_so(conn):
    first = identity.import_aliases(
        conn, [{"ip": "192.0.2.25", "alias": "AP-1", "source": "unifi"}],
        requester="cron")
    again = identity.import_aliases(
        conn, [{"ip": "192.0.2.25", "alias": "AP-1", "source": "unifi"}],
        requester="cron")
    renamed = identity.import_aliases(
        conn, [{"ip": "192.0.2.25", "alias": "AP-1b", "source": "unifi"}],
        requester="cron")
    assert [r["results"][0]["outcome"] for r in (first, again, renamed)] == [
        "applied", "unchanged", "applied"]
    # only real changes are audited, so an unchanged row writes no history
    assert conn.execute(
        "SELECT COUNT(*) FROM audit").fetchone()[0] == 2


def test_one_importer_cannot_steal_anothers_row(conn):
    identity.import_aliases(
        conn, [{"ip": "192.0.2.26", "alias": "unifi-name", "source": "unifi"}],
        requester="cron")
    report = identity.import_aliases(
        conn, [{"ip": "192.0.2.26", "alias": "nimbus-name",
                "source": "nimbus"}], requester="cron")
    assert report["results"][0]["outcome"] == "skipped"
    assert identity.get_alias(conn, "192.0.2.26") == "unifi-name"


def test_override_adopts_without_destroying_the_name_first(conn):
    """The attended escape hatch. Without it the only way to re-point a
    renamed host at its vendor name is to delete the name."""
    identity.set_alias(conn, "192.0.2.27", "Typed", requester="op")
    report = identity.import_aliases(
        conn, [{"ip": "192.0.2.27", "alias": "vendor", "source": "unifi"}],
        requester="op", override=True)
    assert report["results"][0]["outcome"] == "applied"
    assert identity.get_alias(conn, "192.0.2.27") == "vendor"
    # and authority moved with it, so the operator can take it back
    assert identity.list_aliases(conn)[0]["source"] == "unifi"
    identity.set_alias(conn, "192.0.2.27", "Typed Again", requester="op")
    assert identity.list_aliases(conn)[0]["source"] == "hand-edit"


def test_the_import_ledger_accounts_for_every_row(conn):
    """A batch mixes outcomes, and the totals must reconcile - an aggregate
    'N imported' would hide the skips this rule exists to produce."""
    identity.set_alias(conn, "192.0.2.30", "Typed", requester="op")
    report = identity.import_aliases(conn, [
        {"ip": "192.0.2.30", "alias": "vendor", "source": "unifi"},   # skipped
        {"ip": "192.0.2.31", "alias": "New", "source": "unifi"},      # applied
        {"ip": "192.0.2.0/28", "alias": "Range", "source": "unifi"},  # rejected
        {"ip": "unknown", "alias": "Pseudo", "source": "unifi"},      # rejected
    ], requester="cron")
    assert [r["outcome"] for r in report["results"]] == [
        "skipped", "applied", "rejected", "rejected"]
    assert (report["applied"], report["skipped"], report["rejected"],
            report["unchanged"]) == (1, 1, 2, 0)
    assert len(report["results"]) == 4


def test_an_import_records_its_provenance_in_the_audit(conn):
    identity.import_aliases(
        conn, [{"ip": "192.0.2.32", "alias": "AP", "source": "unifi"}],
        requester="cron")
    row = conn.execute("SELECT details FROM audit").fetchone()
    assert row["details"] == "'' -> 'AP' [unifi]", (
        "the audit must answer 'typed or synced'")


# --- import API --------------------------------------------------------

def test_import_endpoint_is_token_gated(client, panel_env):
    body = {"entries": [{"ip": "192.0.2.40", "alias": "x", "source": "unifi"}]}
    r = client.post("/v1/identities/import", json=body)
    assert r.status_code == 403
    assert "test-panel-secret" not in r.text


def test_import_endpoint_returns_the_ledger(client, panel_env):
    h = auth_headers(panel_env)
    client.put("/v1/identity/192.0.2.41", json={"alias": "Typed"}, headers=h)
    r = client.post("/v1/identities/import", headers=h, json={"entries": [
        {"ip": "192.0.2.41", "alias": "vendor", "source": "unifi"},
        {"ip": "192.0.2.42", "alias": "AP-2", "source": "unifi"},
    ]})
    assert r.status_code == 200
    body = r.json()
    assert [x["outcome"] for x in body["results"]] == ["skipped", "applied"]
    assert body["applied"] == 1 and body["skipped"] == 1
    # the operator's name is still there
    rows = {d["ip"]: d["alias"] for d in
            client.get("/v1/identity").json()["identities"]}
    assert rows["192.0.2.41"] == "Typed"


def test_import_endpoint_carries_no_vendor_specific_code():
    """AC1: the endpoint must serve UniFi, Nimbus and a hand-written file
    equally. Naming a vendor as an EXAMPLE label is exactly what
    vendor-agnostic looks like - `source` is a string the caller supplies.
    What must not exist is vendor LOGIC: an import, a branch on a vendor
    literal, a vendor URL, or a vendor credential."""
    app_root = Path(__file__).resolve().parents[1]
    vendors = ("unifi", "ubiquiti", "nimbus")
    offenders = []
    for path in list((app_root / "api").rglob("*.py")) + \
            list((app_root / "store").rglob("*.py")):
        text = path.read_text()
        low = text.lower()
        for vendor in vendors:
            for pattern in (f"import {vendor}", f"from {vendor}",
                            f'== "{vendor}"', f"== '{vendor}'",
                            f'!= "{vendor}"', f"{vendor}_url",
                            f"{vendor}_user", f"{vendor}_password",
                            f"{vendor}.com", f"{vendor}os"):
                if pattern in low:
                    offenders.append(f"{path.name}: {pattern}")
    assert not offenders, (
        f"the panel must hold no vendor logic or credential: {offenders}")
    # and no vendor credential may be read from the environment here
    for path in (app_root / "config.py",):
        assert "UNIFI" not in path.read_text().upper(), \
            "a vendor credential must never be a panel config knob"
