"""Operator settings: defaults in code, the table stores only overrides.

The k/v shape mirrors `stats_meta` (stats.py:61-64), the closest existing
idiom. What it deliberately does NOT mirror is where the default lives:
`stats_meta` stores whatever the collector wrote, whereas here an unset key
must resolve through code, so that shipping a new default actually reaches
every existing install instead of being shadowed by a row written once at
first boot.

The timezone default is inherited from the container's TZ (DEC-5). A panel
that disagrees with mihomo and the updater about what "today" means is a
bug generator, and the compose file already passes the one value all three
should agree on.
"""

import ast
import sqlite3
import zoneinfo
from pathlib import Path

import pytest
from app.store import settings
from app.store.db import MIGRATIONS, open_db
from app.tests.conftest import auth_headers
from app.validation import ValidationError

APP = Path(__file__).resolve().parents[1]


@pytest.fixture()
def conn(tmp_path, panel_env):
    c = open_db(tmp_path / "policy.db")
    yield c
    c.close()


# --- defaults live in code (AC1) --------------------------------------------

def test_an_unset_setting_resolves_through_code(conn):
    """No row, no error - the default is the answer, not a KeyError."""
    assert settings.get(conn, "timezone") == settings.default("timezone")
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 0


def test_the_table_stores_only_overrides(conn, monkeypatch):
    """The point of defaults-in-code: nothing is written until an operator
    actually chooses something, so a later change to the shipped default
    reaches every install instead of being shadowed by a first-boot row."""
    monkeypatch.setenv("TZ", "Europe/Berlin")
    settings.get(conn, "timezone")
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 0

    settings.set_value(conn, "timezone", "Asia/Tokyo", requester="t")
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 1

    # reverting stores nothing either - it REMOVES the override, so "no
    # opinion" has exactly one representation (the identity module's rule)
    settings.set_value(conn, "timezone", "", requester="t")
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 0
    assert settings.get(conn, "timezone") == "Europe/Berlin"


def test_reverting_works_even_when_the_override_equals_the_current_default(
        conn, monkeypatch):
    """The shape that breaks an effective-value comparison: an operator
    pins Asia/Tokyo, the container is later redeployed with TZ=Asia/Tokyo,
    and they then ask to revert. The EFFECTIVE value does not move, so
    comparing effective values calls it a no-op and silently keeps the
    row - leaving the host pinned while GET reports it as overridden, and
    the NEXT timezone change would not reach it. Which is the entire
    reason someone reverts.

    So the no-op test has to be about the STORED state, not the resolved
    one: "there is no override" and "the override happens to equal the
    default" are different states with different futures.
    """
    monkeypatch.setenv("TZ", "Europe/Berlin")
    settings.set_value(conn, "timezone", "Asia/Tokyo", requester="t")
    monkeypatch.setenv("TZ", "Asia/Tokyo")  # the container caught up
    assert settings.set_value(conn, "timezone", "", requester="t") is True
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 0
    # and the host really is tracking the container again
    monkeypatch.setenv("TZ", "America/Denver")
    assert settings.get(conn, "timezone") == "America/Denver"


def test_pinning_the_current_default_is_a_real_override(conn, monkeypatch):
    """The mirror image: choosing the value that happens to be the default
    right now is a deliberate PIN, and must survive the container moving.
    Treating it as a no-op would silently discard the operator's choice."""
    monkeypatch.setenv("TZ", "Europe/Berlin")
    assert settings.set_value(
        conn, "timezone", "Europe/Berlin", requester="t") is True
    monkeypatch.setenv("TZ", "America/Denver")
    assert settings.get(conn, "timezone") == "Europe/Berlin"


def test_a_set_setting_round_trips_and_persists_across_a_reopen(
        tmp_path, panel_env):
    path = tmp_path / "policy.db"
    c = open_db(path)
    settings.set_value(c, "timezone", "Asia/Tokyo", requester="t")
    c.close()

    c2 = open_db(path)
    try:
        assert settings.get(c2, "timezone") == "Asia/Tokyo"
    finally:
        c2.close()


def test_an_override_outlives_a_change_to_the_container_tz(conn, monkeypatch):
    """Otherwise "overridable and persisted" is a lie: redeploying with a
    different TZ would silently revert the operator's choice."""
    monkeypatch.setenv("TZ", "Europe/Berlin")
    settings.set_value(conn, "timezone", "Asia/Tokyo", requester="t")
    monkeypatch.setenv("TZ", "America/Denver")
    assert settings.get(conn, "timezone") == "Asia/Tokyo"


# --- the timezone default is the container's TZ (AC2) ------------------------

def test_the_timezone_default_is_the_container_tz(conn, monkeypatch):
    monkeypatch.setenv("TZ", "Europe/Berlin")
    assert settings.get(conn, "timezone") == "Europe/Berlin"
    # a second value, so the test cannot pass by coincidence of one match
    monkeypatch.setenv("TZ", "America/Denver")
    assert settings.get(conn, "timezone") == "America/Denver"


def test_an_unset_tz_falls_back_to_utc(conn, monkeypatch):
    """UTC is the ABSENCE of a zone choice, not a zone choice - it is also
    what the minute/hour tiers already store in (DEC-4), so an unconfigured
    panel is consistent rather than arbitrarily regional."""
    monkeypatch.delenv("TZ", raising=False)
    assert settings.get(conn, "timezone") == "UTC"


def test_a_blank_or_whitespace_tz_is_treated_as_unset(conn, monkeypatch):
    """compose passes empty strings through for unset knobs (the repo's
    convention), so "" must not become the literal default value."""
    monkeypatch.setenv("TZ", "   ")
    assert settings.get(conn, "timezone") == "UTC"


def test_no_zone_is_hardcoded_in_the_default_path():
    """The constraint is structural, not just behavioural: assert that no
    real IANA zone appears as a string literal in the code that produces
    the default. Docstrings are excluded so the modules may still name an
    example in prose."""
    zones = zoneinfo.available_timezones() - {"UTC"}
    assert "Asia/Shanghai" in zones, "tz database missing - guard is inert"
    for module in (APP / "config.py", APP / "store" / "settings.py"):
        tree = ast.parse(module.read_text(encoding="utf-8"))
        docstrings = set()
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.FunctionDef,
                                 ast.AsyncFunctionDef, ast.ClassDef)):
                first = node.body[0] if node.body else None
                if (isinstance(first, ast.Expr)
                        and isinstance(first.value, ast.Constant)
                        and isinstance(first.value.value, str)):
                    docstrings.add(id(first.value))
        literals = {
            n.value for n in ast.walk(tree)
            if isinstance(n, ast.Constant) and isinstance(n.value, str)
            and id(n) not in docstrings
        }
        leaked = literals & zones
        assert not leaked, f"{module.name} hardcodes a timezone: {leaked}"


# --- validation --------------------------------------------------------------

def test_an_unknown_key_is_refused_and_writes_nothing(conn):
    """A typo'd key stored silently would be a lie: it would read back as
    set while changing nothing."""
    with pytest.raises(ValidationError):
        settings.set_value(conn, "timzone", "Asia/Tokyo", requester="t")
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 0


def test_an_invalid_timezone_is_refused_and_writes_nothing(conn):
    with pytest.raises(ValidationError):
        settings.set_value(conn, "timezone", "Mars/Olympus", requester="t")
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 0


def test_the_timezone_validator_says_WHY_a_blank_value_is_wrong():
    """The blank guard does not change WHETHER a blank is rejected - an
    empty string fails the not-in-database check anyway, and fails the
    shape check in the no-tzdata fallback. What it changes is the message,
    and that is the whole reason to keep it: "unknown timezone ''" reads
    like a lookup failure, when the real answer is that nothing was
    supplied. So the assertion is on the two messages staying distinct,
    not on rejection - anything else here would pass with the guard
    deleted."""
    with pytest.raises(ValidationError, match="must name an IANA zone"):
        settings._check_timezone("")
    with pytest.raises(ValidationError, match="must name an IANA zone"):
        settings._check_timezone("   ")
    with pytest.raises(ValidationError, match="unknown timezone"):
        settings._check_timezone("Mars/Olympus")


def test_get_of_an_unknown_key_raises_rather_than_inventing_a_default(conn):
    with pytest.raises(ValidationError):
        settings.get(conn, "timzone")


# --- the landing stats range (#80 DEC-A) ------------------------------------

def test_the_stats_range_default_is_seven_days(conn):
    """The landing view's range is an operator preference, not a constant in
    the UI. It lives here for the same reason every other default does: a
    value baked into the bundle can only be changed by shipping a new
    bundle."""
    assert settings.default("stats_default_range") == "7d"
    assert settings.get(conn, "stats_default_range") == "7d"


def test_the_stats_range_accepts_exactly_what_the_ui_can_show(conn):
    """The setting and the view's selector are ONE list. A default naming a
    range the UI cannot render would land the operator on a blank tab with
    nothing saying why - the setting would look honoured and be unusable."""
    assert settings.STATS_RANGES == ("48h", "7d", "30d", "daily")
    for value in settings.STATS_RANGES:
        settings.set_value(conn, "stats_default_range", value, requester="t")
        assert settings.get(conn, "stats_default_range") == value


def test_an_unknown_stats_range_is_refused_and_names_the_alternatives(conn):
    """Rejecting is not enough on its own: a validator that says only "no"
    leaves the operator guessing at a closed vocabulary they cannot see."""
    with pytest.raises(ValidationError, match="48h, 7d, 30d, daily"):
        settings.set_value(conn, "stats_default_range", "90d", requester="t")
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 0


def test_a_blank_stats_range_reverts_rather_than_storing_emptiness(conn):
    settings.set_value(conn, "stats_default_range", "30d", requester="t")
    settings.set_value(conn, "stats_default_range", "", requester="t")
    assert settings.get(conn, "stats_default_range") == "7d"
    assert conn.execute(
        "SELECT COUNT(*) FROM settings WHERE k = 'stats_default_range'"
    ).fetchone()[0] == 0


def test_the_new_key_did_not_disturb_the_shipped_ones(conn):
    """Adding a SPEC entry must be additive. `effective()` is generic over
    SPEC, so a key that changed the shape of the others would surface as a
    settings page that stops round-tripping the ones it already had."""
    eff = settings.effective(conn)
    assert set(eff) == {"timezone", "day_boundary", "stats_default_range"}
    for key, row in eff.items():
        assert set(row) == {"value", "default", "overridden"}, key
        assert row["overridden"] is False


def test_a_failed_write_partway_through_a_batch_rolls_the_whole_batch_back(
        conn, monkeypatch):
    """Up-front validation only rules out VALIDATION failures. A disk error
    or a constraint on the second key would otherwise leave the first key
    committed and audited while the caller saw an exception - the exact
    half-applied state an operator cannot diagnose, and the reason the
    batch needs one transaction rather than one per key."""
    monkeypatch.setitem(settings.SPEC, "second", settings._Setting(
        default=lambda: "a", check=lambda v: v, description="test-only"))
    real = settings._apply_one
    calls = []

    def exploding(conn_, key, checked, ts, **kw):
        calls.append(key)
        if len(calls) > 1:
            raise sqlite3.OperationalError("disk I/O error (injected)")
        return real(conn_, key, checked, ts, **kw)

    monkeypatch.setattr(settings, "_apply_one", exploding)
    with pytest.raises(sqlite3.OperationalError):
        settings.apply_values(conn, {"timezone": "Asia/Tokyo", "second": "b"},
                              requester="t")
    assert len(calls) > 1, "the injected failure never fired - test is inert"
    # nothing survived: not the row, not the audit entry
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM audit").fetchone()[0] == 0


def test_a_batch_applies_every_key_in_one_transaction(conn, monkeypatch):
    monkeypatch.setitem(settings.SPEC, "second", settings._Setting(
        default=lambda: "a", check=lambda v: v, description="test-only"))
    changed = settings.apply_values(
        conn, {"timezone": "Asia/Tokyo", "second": "b"}, requester="t")
    assert sorted(changed) == ["second", "timezone"]
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 2
    assert conn.execute("SELECT COUNT(*) FROM audit").fetchone()[0] == 2


def test_the_shape_fallback_rejects_path_traversal(conn, monkeypatch):
    """The fallback's own comment promises it rejects traversal. Nothing
    resolves a zone against the filesystem today, so this is defence in
    depth - but a guarantee stated in a comment has to be real, or the next
    reader builds on it."""
    monkeypatch.setattr(zoneinfo, "available_timezones", lambda: set())
    for bogus in ("Zone/..", "X/../..", "Foo/../Bar", ".", "..",
                  # deeper than any real zone: IANA names stop at three
                  # segments (America/Argentina/Buenos_Aires is the deepest
                  # shape), so anything longer is not a zone being validated
                  # leniently - it is a path
                  "A/B/C/D", "Etc/../../etc/passwd"):
        with pytest.raises(ValidationError):
            settings.set_value(conn, "timezone", bogus, requester="t")
    assert conn.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 0
    # ...while the deepest REAL shape still passes: a bound that also
    # rejected valid zones would be a different bug
    settings.set_value(conn, "timezone", "America/Argentina/Buenos_Aires",
                       requester="t")
    assert settings.get(conn, "timezone") == "America/Argentina/Buenos_Aires"


def test_effective_does_not_leak_untranslated_prose_into_the_api(conn):
    """Every user-facing string goes through the i18n dictionaries. A
    hardcoded English description in the payload would be a label no
    bilingual gate watches."""
    for row in settings.effective(conn).values():
        assert set(row) == {"value", "default", "overridden"}


def test_a_missing_tz_database_does_not_reject_every_zone(conn, monkeypatch):
    """A container image without tzdata would otherwise make EVERY zone
    invalid, locking the operator out of a setting the panel demands. With
    no database to check against, fall back to validating the shape."""
    monkeypatch.setattr(zoneinfo, "available_timezones", lambda: set())
    settings.set_value(conn, "timezone", "Asia/Tokyo", requester="t")
    assert settings.get(conn, "timezone") == "Asia/Tokyo"
    # shape validation still bites - it is a fallback, not an amnesty
    with pytest.raises(ValidationError):
        settings.set_value(conn, "timezone", "not a zone!", requester="t")


# --- every mutation is audited (AC3) -----------------------------------------

def test_every_settings_mutation_is_audited(conn, monkeypatch):
    monkeypatch.setenv("TZ", "Europe/Berlin")
    settings.set_value(conn, "timezone", "Asia/Tokyo", requester="192.0.2.9",
                       note="dst")
    rows = conn.execute(
        "SELECT action, cidr, requester, note, details FROM audit").fetchall()
    assert len(rows) == 1
    assert rows[0]["action"] == settings.AUDIT_ACTION
    assert rows[0]["requester"] == "192.0.2.9"
    assert rows[0]["note"] == "dst"
    # both ends recorded, so a reader can tell what it was before and
    # recover it - the convention policy.py's rename already follows
    assert "Europe/Berlin" in rows[0]["details"]
    assert "Asia/Tokyo" in rows[0]["details"]
    assert "timezone" in rows[0]["details"]


def test_reverting_to_the_default_is_audited_too(conn):
    settings.set_value(conn, "timezone", "Asia/Tokyo", requester="t")
    settings.set_value(conn, "timezone", "", requester="t")
    rows = conn.execute("SELECT details FROM audit ORDER BY id").fetchall()
    assert len(rows) == 2
    assert "Asia/Tokyo" in rows[1]["details"]


def test_the_audit_distinguishes_an_absent_override_from_a_pin(
        conn, monkeypatch):
    """Pinning the current default and reverting to a default that equals
    the pin are the two states the resolved value cannot tell apart - the
    same conflation that silently dropped a revert. An audit line printing
    only resolved values renders both as "X -> X", i.e. unreadable exactly
    where the trail matters most."""
    monkeypatch.setenv("TZ", "Europe/Berlin")
    settings.set_value(conn, "timezone", "Europe/Berlin", requester="t")
    settings.set_value(conn, "timezone", "", requester="t")
    rows = [r["details"] for r in
            conn.execute("SELECT details FROM audit ORDER BY id")]
    assert rows == [
        "timezone: default('Europe/Berlin') -> 'Europe/Berlin'",
        "timezone: 'Europe/Berlin' -> default('Europe/Berlin')",
    ]


def test_a_no_op_write_does_not_manufacture_history(conn):
    """Auditing a write that changed nothing would make the trail lie about
    how often an operator touched the setting."""
    settings.set_value(conn, "timezone", "Asia/Tokyo", requester="t")
    settings.set_value(conn, "timezone", "Asia/Tokyo", requester="t")
    assert conn.execute("SELECT COUNT(*) FROM audit").fetchone()[0] == 1


def test_a_refused_write_is_not_audited(conn):
    with pytest.raises(ValidationError):
        settings.set_value(conn, "timezone", "Mars/Olympus", requester="t")
    assert conn.execute("SELECT COUNT(*) FROM audit").fetchone()[0] == 0


# --- the migration ------------------------------------------------------------

def test_settings_is_migration_four_appended_not_edited(conn):
    versions = [v for v, _ in MIGRATIONS]
    assert versions == sorted(set(versions)), "migration versions must be unique and ordered"
    # Appended-not-edited means slot 4 IS the settings table, forever - the
    # tail moving past it (v5, #82) is exactly what appending looks like.
    assert MIGRATIONS[3][0] == 4 and "CREATE TABLE settings" in MIGRATIONS[3][1], (
        "the settings table is migration 4, byte-where-it-was")
    assert conn.execute("PRAGMA user_version").fetchone()[0] == len(MIGRATIONS)


def test_the_migration_leaves_every_shipped_table_untouched(conn):
    """Forward-only and non-destructive against a populated v1.8.0 db: the
    shipped DDL must be byte-identical, not merely present."""
    for table in ("devices", "audit", "device_identity"):
        ddl = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
            (table,)).fetchone()
        assert ddl is not None, f"{table} vanished"
    devices_ddl = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='devices'"
    ).fetchone()["sql"]
    assert "mode TEXT NOT NULL CHECK" in devices_ddl
    assert "cidr TEXT NOT NULL UNIQUE" in devices_ddl


def test_the_settings_key_cannot_be_null(conn):
    """`k TEXT PRIMARY KEY` alone is a rowid-table key and SQLite accepts
    NULL there - several of them, since NULLs are distinct in the implicit
    index. The same trap device_identity.cidr had to name explicitly."""
    import sqlite3
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO settings (k, v, updated_at) VALUES (NULL, 'x', 'y')")


# --- the API surface ----------------------------------------------------------

def test_get_settings_reports_value_default_and_whether_it_is_overridden(
        client, panel_env, monkeypatch):
    monkeypatch.setenv("TZ", "Europe/Berlin")
    body = client.get("/v1/settings").json()["settings"]
    assert body["timezone"]["value"] == "Europe/Berlin"
    assert body["timezone"]["default"] == "Europe/Berlin"
    assert body["timezone"]["overridden"] is False

    r = client.put("/v1/settings", json={"values": {"timezone": "Asia/Tokyo"}},
                   headers=auth_headers(panel_env))
    assert r.status_code == 200
    body = r.json()["settings"]
    assert body["timezone"]["value"] == "Asia/Tokyo"
    assert body["timezone"]["default"] == "Europe/Berlin"
    assert body["timezone"]["overridden"] is True


def test_put_settings_reports_which_keys_actually_changed(client, panel_env):
    r = client.put("/v1/settings", json={"values": {"timezone": "Asia/Tokyo"}},
                   headers=auth_headers(panel_env))
    assert r.json()["changed"] == ["timezone"]
    # a second identical write changed nothing, and says so
    r = client.put("/v1/settings", json={"values": {"timezone": "Asia/Tokyo"}},
                   headers=auth_headers(panel_env))
    assert r.json()["changed"] == []


def test_put_settings_refuses_an_unknown_key_atomically(client, panel_env):
    """One bad key must not leave a partial write behind - the operator
    would have no way to tell which half applied."""
    r = client.put("/v1/settings",
                   json={"values": {"timezone": "Asia/Tokyo",
                                    "timzone": "Asia/Tokyo"}},
                   headers=auth_headers(panel_env))
    assert r.status_code == 422
    assert client.get("/v1/settings").json()["settings"]["timezone"][
        "overridden"] is False


def test_put_settings_refuses_an_invalid_value(client, panel_env):
    r = client.put("/v1/settings",
                   json={"values": {"timezone": "Mars/Olympus"}},
                   headers=auth_headers(panel_env))
    assert r.status_code == 422


def test_settings_mutation_reaches_the_audit_endpoint(client, panel_env):
    client.put("/v1/settings", json={"values": {"timezone": "Asia/Tokyo"}},
               headers=auth_headers(panel_env))
    entries = client.get("/v1/audit").json()["entries"]
    assert any(e["action"] == settings.AUDIT_ACTION for e in entries)
