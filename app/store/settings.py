"""Operator settings - defaults in code, the table holds only overrides.

The storage shape mirrors `stats_meta` (stats.py:61-64), the existing k/v
idiom in this codebase. The RESOLUTION does not: `stats_meta` answers with
whatever was written, whereas an unset key here resolves through
`SPEC[key].default()`. That difference is the whole design. If first boot
seeded a row per key, every later change to a shipped default would be
shadowed on every existing install, and the only way to pick the new
default up would be to know it had changed and re-enter it by hand.

Each key names its own default source and its own validator, so adding a
setting is one SPEC entry rather than a new endpoint.
"""

import re
import sqlite3
import zoneinfo
from datetime import UTC, datetime

from app import config
from app.store import dayframe
from app.store.audit import append_audit
from app.validation import ValidationError

# The audit action for every settings mutation. The bilingual gate in
# app/tests/test_static_ui.py sweeps every literal append_audit(action=...)
# in app/ and demands a matching `action_<name>` key in BOTH i18n
# dictionaries, so this string and app/static/i18n/{en,zh}.json move
# together.
AUDIT_ACTION = "setting"

# One segment of a plausible IANA zone name, used ONLY when there is no tz
# database to check against (see `_check_timezone`). Not an attempt to
# enumerate the real list - just to reject what is clearly not a zone.
_ZONE_SEGMENT = re.compile(r"^[A-Za-z0-9+_-][A-Za-z0-9+_.-]*$")


def _zone_shape_ok(value: str) -> bool:
    """Whether VALUE could be an IANA zone name at all.

    Path traversal is excluded BY CONSTRUCTION rather than by a separate
    check: every segment must START with an alphanumeric, so `.` and `..`
    cannot form one. An explicit `part in (".", "..")` guard on top of that
    is unfalsifiable - deleting it changes no behaviour - and a guard no
    test can distinguish from its own absence is worse than none, because
    it reads as the protection while the real one sits elsewhere. The
    leading character class IS the protection, and it is tested in both
    directions.

    Nothing resolves a zone against the filesystem today; this is defence
    in depth for whoever wires one up.
    """
    parts = value.split("/")
    if not value[:1].isalpha() or not 1 <= len(parts) <= 3:
        return False
    return all(_ZONE_SEGMENT.match(part) for part in parts)


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _check_timezone(raw: str) -> str:
    """A zone the panel can actually resolve.

    Validated against the real tz database when one is present. When it is
    absent, `available_timezones()` is empty and EVERY name would look
    invalid - which would lock the operator out of a setting the panel
    demands rather than protect them - so fall back to validating the
    shape. That is a narrower promise, and it is the honest one.
    """
    value = (raw or "").strip()
    if not value:
        raise ValidationError("timezone must name an IANA zone, e.g. the one "
                              "the container already runs in")
    known = zoneinfo.available_timezones()
    if known:
        if value not in known:
            raise ValidationError(
                f"unknown timezone {value!r} - use an IANA name such as the "
                f"zone the container already runs in")
        return value
    if not _zone_shape_ok(value):
        raise ValidationError(
            f"{value!r} is not a usable timezone name (no tz database is "
            f"installed here, so only the name shape could be checked)")
    return value


# 03:00 rather than midnight: a session that starts at 01:00 belongs to the
# day it began, not to the one that just started while nobody was awake.
# Existing v1.8.0 day rows keep their own 00:00 stamp - this default applies
# only to rows rolled from here on (#76).
DEFAULT_DAY_BOUNDARY = "03:00"


def _check_day_boundary(raw: str) -> str:
    """A 24-hour HH:MM local time. Anchored deliberately: "3pm" or "25:00"
    silently truncated into something plausible would mis-file every day
    row from then on, and the stamp would make the wrong answer look
    deliberate."""
    value = (raw or "").strip()
    if not dayframe.BOUNDARY_RE.match(value):
        raise ValidationError(
            f"day_boundary {value!r} must be a whole hour on a 24-hour "
            f"clock, e.g. {DEFAULT_DAY_BOUNDARY} - the day tier rolls hour "
            f"buckets, so a boundary inside an hour cannot be honoured")
    return value


class _Setting:
    __slots__ = ("default", "check", "description")

    def __init__(self, default, check, description):
        self.default = default
        self.check = check
        self.description = description


# The registry. `default` is a CALLABLE, not a value: it is read at call
# time so the container's environment stays authoritative and nothing is
# frozen at import (the convention app/config.py already follows).
SPEC = {
    "timezone": _Setting(
        default=config.timezone_default,
        check=_check_timezone,
        description="IANA zone for day-tier rollups and displayed times; "
                    "defaults to the container's own TZ"),
    "day_boundary": _Setting(
        default=lambda: DEFAULT_DAY_BOUNDARY,
        check=_check_day_boundary,
        description="Local time at which a stats day starts (HH:MM). 03:00 "
                    "keeps a late-night session on the day it began"),
}


def _spec(key: str) -> _Setting:
    entry = SPEC.get(key)
    if entry is None:
        raise ValidationError(
            f"unknown setting {key!r} - known settings: "
            f"{', '.join(sorted(SPEC))}")
    return entry


def default(key: str) -> str:
    """The code default for KEY, resolved now."""
    return _spec(key).default()


def get(conn, key: str) -> str:
    """The effective value: the stored override, else the code default.

    Raises for an unknown key rather than inventing a default - a typo
    that answered with something plausible would be worse than an error.
    """
    entry = _spec(key)
    row = conn.execute("SELECT v FROM settings WHERE k = ?",
                       (key,)).fetchone()
    return row["v"] if row else entry.default()


def effective(conn) -> dict:
    """Every known setting: what it resolves to, what it would resolve to
    with no override, and whether one is in force. Reporting all three is
    what lets the UI show "inherited from the container" honestly instead
    of presenting an inherited value as a stored choice.

    `description` is deliberately NOT part of the payload: it is hardcoded
    English, and every user-facing string in this app goes through
    app/static/i18n/{en,zh}.json. Returning it would hand a future settings
    page an untranslated label that no bilingual gate watches, which is how
    English leaks into the Chinese UI. It stays next to the key it
    documents, for whoever reads SPEC.
    """
    stored = {r["k"]: r["v"] for r in conn.execute("SELECT k, v FROM settings")}
    out = {}
    for key, entry in SPEC.items():
        fallback = entry.default()
        out[key] = {
            "value": stored.get(key, fallback),
            "default": fallback,
            "overridden": key in stored,
        }
    return out


def _transition(key: str, current, desired, fallback: str) -> str:
    """`details` in the shipped convention - policy.py's rename writes
    `'old' -> 'new'` and keeps `note` for the operator's own note. The key
    is included because one audit stream carries every setting.

    An absent override renders as `default('X')` rather than just `'X'`, so
    the trail distinguishes the two states a bare value cannot: pinning the
    value that is currently the default, and reverting to a default that
    currently equals the pin, both move between states whose resolved value
    is identical. Printing only the resolved value would make each look
    like a change from something to itself.
    """
    def show(value):
        return repr(value) if value is not None else f"default({fallback!r})"

    return f"{key}: {show(current)} -> {show(desired)}"


def _apply_one(conn, key: str, checked: str, ts: str, *, requester: str,
               note: str) -> bool:
    """One key, INSIDE an already-open transaction. Returns whether the
    stored OVERRIDE changed - which is not the same as whether the resolved
    value moved, and the difference is load-bearing (see the comparison
    below).

    The `before` read lives here, not in the caller, so it is serialized
    against the write by the same `BEGIN IMMEDIATE`. Reading it outside
    would be the identical race `_migrate` was hardened against (db.py) and
    the one `import_aliases` avoids by deciding precedence in SQL: the
    in-process mutex does not serialize against a CLI process holding the
    same file, so a read-then-decide check can record a `before` value that
    was already stale by the time the row was written.
    """
    entry = SPEC[key]
    row = conn.execute("SELECT v FROM settings WHERE k = ?", (key,)).fetchone()
    # The comparison is on the STORED state - the override itself - not on
    # the resolved value. "No override" and "an override that happens to
    # equal today's default" resolve identically but have different futures:
    # the first tracks the container, the second is pinned. Comparing
    # resolved values conflates them, and then a revert requested while the
    # two agree is silently dropped, leaving the host pinned forever.
    current = row["v"] if row else None
    desired = checked or None
    if current == desired:
        # A genuine no-op. Auditing it would make the trail lie about how
        # often this setting was actually touched.
        return False
    fallback = entry.default()
    if checked:
        conn.execute(
            "INSERT INTO settings (k, v, updated_at) VALUES (?, ?, ?) "
            "ON CONFLICT(k) DO UPDATE SET v = excluded.v, "
            "updated_at = excluded.updated_at", (key, checked, ts))
    else:
        conn.execute("DELETE FROM settings WHERE k = ?", (key,))
    append_audit(conn, action=AUDIT_ACTION, requester=requester, note=note,
                 details=_transition(key, current, desired, fallback))
    return True


def apply_values(conn, values: dict, *, requester: str = "",
                 note: str = "") -> list:
    """Apply a batch atomically, returning the keys whose stored OVERRIDE
    changed.

    Deliberately not "whose resolved value changed": pinning the value that
    currently happens to be the default, and reverting a pin that currently
    equals the default, both leave the resolved value untouched while
    changing what happens on the next container redeploy. Reporting those
    as unchanged is what silently dropped a revert.

    Two separate guarantees, and both are needed. Every key and value is
    validated BEFORE the transaction opens, so a refused write leaves no
    row and no audit entry - the trail records changes, not attempts. Then
    every write lands in ONE transaction, so a failure partway through
    rolls back the keys that already succeeded along with their audit rows.
    Validating up front alone would not give that: a non-validation failure
    (a disk error, a constraint) on the second key would otherwise leave the
    first committed and audited while the caller saw an exception, which is
    precisely the half-applied state the operator cannot diagnose.

    Unlike `identity.import_aliases`, whose per-row ledger is the honest
    answer because its rows are independent hosts, a settings write is a
    single operator intent.
    """
    checked = {}
    for key, value in values.items():
        entry = _spec(key)
        raw = (value or "").strip()
        checked[key] = entry.check(raw) if raw else ""

    ts = _now()
    changed = []
    conn.execute("BEGIN IMMEDIATE")
    try:
        for key, value in checked.items():
            if _apply_one(conn, key, value, ts, requester=requester,
                          note=note):
                changed.append(key)
        conn.execute("COMMIT")
    except BaseException:
        try:
            conn.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise
    return changed


def set_value(conn, key: str, value: str, *, requester: str = "",
              note: str = "") -> bool:
    """Override KEY, or REVERT it when VALUE is blank. Returns whether the
    stored override actually changed.

    A blank value removes the row rather than storing an empty string, so
    "no opinion" has exactly one representation - the same rule the identity
    sidecar follows for a cleared alias. A one-key batch, so the atomicity
    and ordering rules live in exactly one place.
    """
    return bool(apply_values(conn, {key: value}, requester=requester,
                             note=note))
