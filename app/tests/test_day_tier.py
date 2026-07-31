"""The local-time day tier (#76, DEC-4).

Minute and hour stay UTC; only the day tier is local-keyed, and every day
row stamps the `(bucket_tz, day_boundary)` that produced it. Those stamps
are part of the row identity, so changing the zone later produces a second
row for the same calendar date - a visible seam - rather than merging into
the old one and silently relabelling shipped history.

Every assertion here uses an explicit zone and a frozen clock. `panel_env`
clears `TZ`, so nothing leaks in from the machine, and each behavioural
claim is made against TWO different zones: with one zone a bug that simply
ignores the configured value passes whenever that value happens to equal
the fallback.
"""

import sqlite3

import pytest
from app.store import dayframe
from app.store import stats as stats_store
from app.store.dayframe import DayFrame
from app.store.stats import STATS_MIGRATIONS, open_stats_db

SHANGHAI = "Asia/Shanghai"   # UTC+8, no DST
DENVER = "America/Denver"    # UTC-7/-6, DST both directions


@pytest.fixture()
def sconn(tmp_path, panel_env):
    c = open_stats_db(tmp_path / "stats.db")
    yield c
    c.close()


def frame(tz=SHANGHAI, cut="03:00"):
    f = dayframe.resolve(tz, cut)
    assert f.ok, f.error
    return f


def seed_hour(conn, bucket, device="192.0.2.20", chain="X", up=1, down=10):
    conn.execute(
        "INSERT INTO stats_hour (bucket, device, chain, up, down) "
        "VALUES (?, ?, ?, ?, ?)", (bucket, device, chain, up, down))


def day_rows(conn):
    return [tuple(r) for r in conn.execute(
        "SELECT bucket, bucket_tz, day_boundary, device, chain, up, down "
        "FROM stats_day ORDER BY bucket, bucket_tz")]


# --- the cut, proven with a frozen clock and a non-UTC zone (AC1) -----------

def test_the_local_cut_splits_two_hours_into_different_days(sconn):
    """The defect the ticket exists to fix, stated as arithmetic. In
    Shanghai (UTC+8) with a 03:00 cut: 18:00Z is 02:00 local NEXT day,
    which is BEFORE the cut and so belongs to the day that started
    yesterday at 03:00; 20:00Z is 04:00 local, after the cut, a new day."""
    seed_hour(sconn, "2026-07-29T18")   # local 2026-07-30 02:00 -> day 07-29
    seed_hour(sconn, "2026-07-29T20")   # local 2026-07-30 04:00 -> day 07-30
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z", day=frame())
    buckets = [r[0] for r in day_rows(sconn)]
    assert buckets == ["2026-07-29", "2026-07-30"], buckets


def test_the_same_two_hours_land_on_ONE_day_under_utc(sconn):
    """The control. Identical input, UTC framing: both hours are the same
    UTC day, so a test that only ever ran the local case could not tell
    the local keying from no keying at all."""
    seed_hour(sconn, "2026-07-29T18")
    seed_hour(sconn, "2026-07-29T20")
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z",
                       day=frame("UTC", "00:00"))
    assert [r[0] for r in day_rows(sconn)] == ["2026-07-29"]


def test_a_second_zone_gives_a_different_split(sconn):
    """Two zones, because one zone can pass by coincidence: an
    implementation that ignored the configured zone entirely would agree
    with whichever single zone the suite happened to pick."""
    seed_hour(sconn, "2026-07-29T18")   # Denver local 12:00 -> day 07-29
    seed_hour(sconn, "2026-07-30T08")   # Denver local 02:00 -> day 07-29 too
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z", day=frame(DENVER))
    assert [r[0] for r in day_rows(sconn)] == ["2026-07-29"]


def test_the_cut_itself_is_configurable(sconn):
    """With a 00:00 cut the same Shanghai hours split the other way -
    otherwise `day_boundary` is decoration."""
    seed_hour(sconn, "2026-07-29T18")   # local 07-30 02:00
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z",
                       day=frame(SHANGHAI, "00:00"))
    assert [r[0] for r in day_rows(sconn)] == ["2026-07-30"]


@pytest.mark.parametrize("utc_hour,expected", [
    # spring forward: 2026-03-08, Denver 02:00 -> 03:00 local
    ("2026-03-08T08", "2026-03-07"),   # 01:00 local, before the 03:00 cut
    ("2026-03-08T09", "2026-03-08"),   # 03:00 local (02:00 never existed)
    # fall back: 2026-11-01, Denver 02:00 -> 01:00 local, 01:00 happens twice
    ("2026-11-01T07", "2026-10-31"),   # 01:00 MDT, first pass
    ("2026-11-01T08", "2026-10-31"),   # 01:00 MST, second pass
    ("2026-11-01T10", "2026-11-01"),   # 03:00 MST, the cut
])
def test_dst_transitions_key_correctly(sconn, utc_hour, expected):
    """A local day is 23 or 25 hours twice a year. Converting UTC->local
    is always defined and never ambiguous (`fold` cannot arise in that
    direction), which is why the arithmetic runs that way round."""
    assert dayframe.day_key(utc_hour, frame(DENVER)) == expected


# --- the migration preserves shipped history exactly (AC2) ------------------

def _v1_stats_db(path):
    """A stats.db as v1.8.0 shipped it: schema version 1, populated."""
    from app.store.db import open_db
    conn = open_db(path, migrations=STATS_MIGRATIONS[:1],
                   pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 1
    return conn


def test_a_populated_v180_database_migrates_with_every_number_intact(tmp_path,
                                                                     panel_env):
    path = tmp_path / "stats.db"
    old = _v1_stats_db(path)
    old.execute("INSERT INTO stats_day (bucket, device, chain, up, down) "
                "VALUES ('2026-07-05', '192.0.2.20', 'X', 7, 70)")
    old.execute("INSERT INTO stats_day (bucket, device, chain, up, down) "
                "VALUES ('2026-07-06', '192.0.2.21', 'Y', 8, 80)")
    old.execute("INSERT INTO stats_hour (bucket, device, chain, up, down) "
                "VALUES ('2026-07-06T05', '192.0.2.21', 'Y', 1, 2)")
    before_day = [tuple(r) for r in old.execute(
        "SELECT bucket, device, chain, up, down FROM stats_day ORDER BY bucket")]
    before_hour = [tuple(r) for r in old.execute(
        "SELECT * FROM stats_hour ORDER BY bucket")]
    old.commit()
    old.close()

    new = open_stats_db(path)
    try:
        assert new.execute("PRAGMA user_version").fetchone()[0] == 2
        # every shipped row survives with its numbers, stamped as the UTC
        # framing that actually produced it
        assert [tuple(r) for r in new.execute(
            "SELECT bucket, device, chain, up, down FROM stats_day "
            "ORDER BY bucket")] == before_day
        stamps = {(r[0], r[1]) for r in new.execute(
            "SELECT bucket_tz, day_boundary FROM stats_day")}
        assert stamps == {("UTC", "00:00")}
        # the untouched tier is untouched
        assert [tuple(r) for r in new.execute(
            "SELECT * FROM stats_hour ORDER BY bucket")] == before_hour
        # auto_vacuum must survive the rebuild or enforce_cap's
        # incremental_vacuum silently stops reclaiming pages
        assert new.execute("PRAGMA auto_vacuum").fetchone()[0] == 2
        # and no scaffolding table is left behind
        names = {r[0] for r in new.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        assert "stats_day_v2" not in names and "stats_day" in names
    finally:
        new.close()


def test_the_day_tier_is_stats_migration_two(sconn):
    versions = [v for v, _ in STATS_MIGRATIONS]
    assert versions == [1, 2], versions
    assert sconn.execute("PRAGMA user_version").fetchone()[0] == 2


def test_the_shipped_five_column_insert_idiom_still_works(sconn):
    """v1 code (and every existing test) writes stats_day without the
    stamps. The columns carry DEFAULTs so that keeps working rather than
    raising NOT NULL - a migration that broke the shipped write shape
    would be a breaking change wearing an additive costume."""
    sconn.execute("INSERT INTO stats_day (bucket, device, chain, up, down) "
                  "VALUES ('2026-07-07', '192.0.2.22', 'Z', 1, 2)")
    assert day_rows(sconn) == [
        ("2026-07-07", "UTC", "00:00", "192.0.2.22", "Z", 1, 2)]


# --- a later tz change is a visible seam, never a relabel (AC3) -------------

def test_changing_the_zone_leaves_history_on_its_original_stamp(sconn):
    """The forbidden outcome is that yesterday's numbers quietly start
    meaning something else. Two framings of the same calendar date must
    coexist as two rows."""
    seed_hour(sconn, "2026-07-29T18", up=1, down=10)
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z",
                       day=frame("UTC", "00:00"))
    seed_hour(sconn, "2026-07-29T10", up=2, down=20)  # Shanghai 18:00, 07-29
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z", day=frame(SHANGHAI))

    rows = day_rows(sconn)
    assert len(rows) == 2, rows
    assert {(r[0], r[1], r[2]) for r in rows} == {
        ("2026-07-29", "UTC", "00:00"),
        ("2026-07-29", SHANGHAI, "03:00"),
    }
    # and neither absorbed the other's numbers
    assert {(r[5], r[6]) for r in rows} == {(1, 10), (2, 20)}


def test_rolling_again_under_the_SAME_stamp_accumulates(sconn):
    """The seam must come from a CHANGED stamp, not from every pass making
    a new row - otherwise the day tier would fragment on every rollup."""
    seed_hour(sconn, "2026-07-29T19", up=1, down=10)
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z", day=frame())
    seed_hour(sconn, "2026-07-29T20", up=2, down=20)
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z", day=frame())
    rows = day_rows(sconn)
    assert len(rows) == 1, rows
    assert (rows[0][5], rows[0][6]) == (3, 30)


def test_a_day_timeline_does_not_merge_across_stamps(sconn):
    """The seam has to be visible where someone would actually look. A
    timeline that grouped on `bucket` alone would sum the two framings
    back into one row and hide it again."""
    seed_hour(sconn, "2026-07-29T18", up=1, down=10)
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z",
                       day=frame("UTC", "00:00"))
    seed_hour(sconn, "2026-07-29T10", up=2, down=20)  # Shanghai 18:00, 07-29
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z", day=frame(SHANGHAI))

    rows = stats_store.read_timeline(sconn, "day")
    assert len(rows) == 2, rows
    assert {(r["bucket_tz"], r["day_boundary"]) for r in rows} == {
        ("UTC", "00:00"), (SHANGHAI, "03:00")}
    # the untouched tiers keep their exact shape - this is additive
    seed_hour(sconn, "2026-07-30T01")
    hour_rows = stats_store.read_timeline(sconn, "hour")
    assert set(hour_rows[0]) == {"bucket", "up", "down"}


# --- an unresolvable zone degrades honestly, it never pauses (AC-adjacent) --

def test_an_unresolvable_zone_still_rolls_and_stamps_what_it_used(sconn):
    """Pausing the day tier would be worse than degrading. The hour DELETE
    is also the hour tier's only retention, so a paused roll grows
    stats_hour without bound - while enforce_cap drains the DAY tier FIRST
    under size pressure (stats.py _CAP_TIERS). A long unnoticed pause would
    therefore destroy up to 730 days of day history to make room for hours
    it refused to roll. So: keep rolling, key in UTC, and stamp UTC/00:00 -
    the framing that actually produced the row, never the one that failed.
    """
    bad = dayframe.resolve("Mars/Olympus", "03:00")
    assert not bad.ok and "Mars/Olympus" in bad.error
    seed_hour(sconn, "2026-07-29T18", up=1, down=10)
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z", day=bad)
    rows = day_rows(sconn)
    assert len(rows) == 1
    assert (rows[0][1], rows[0][2]) == ("UTC", "00:00")
    # the hour tier really was drained, so nothing accumulates
    assert sconn.execute("SELECT COUNT(*) FROM stats_hour").fetchone()[0] == 0


def test_resolve_never_raises_whatever_it_is_given(sconn):
    """settings.get() returns a stored value without re-validating, so a
    zone dropped by a tzdata upgrade arrives here intact. This runs on the
    collector thread; a raise would be a silently dead collector."""
    for tz, cut in [("Mars/Olympus", "03:00"), ("", "03:00"),
                    (SHANGHAI, "25:00"), (SHANGHAI, "3pm"),
                    (SHANGHAI, ""), ("../../etc/passwd", "03:00"),
                    # an embedded-but-valid time: the anchors are what make
                    # this a clean refusal instead of a silent truncation
                    # that stores junk and keys off the fragment
                    (SHANGHAI, "03:00 UTC"), (SHANGHAI, "at 03:00"),
                    (None, None)]:
        f = dayframe.resolve(tz, cut)
        assert isinstance(f, DayFrame)
        assert f.ok is False, (tz, cut)
        assert f.error, (tz, cut)


def test_the_utc_frame_does_not_depend_on_a_tz_database(monkeypatch):
    """Every shipped v1.8.0 row is stamped UTC, and UTC is also the
    degraded fallback - so the one framing that must always work cannot
    route through zoneinfo. `ZoneInfo("UTC")` itself raises when no tz
    database is installed."""
    import zoneinfo
    monkeypatch.setattr(zoneinfo, "available_timezones", lambda: set())

    def explode(*a, **k):
        raise zoneinfo.ZoneInfoNotFoundError("no tz database (simulated)")

    monkeypatch.setattr(dayframe, "ZoneInfo", explode)
    f = dayframe.resolve("UTC", "00:00")
    assert f.ok, f.error
    assert dayframe.day_key("2026-07-29T18", f) == "2026-07-29"
    # and the constructor used by the DEGRADE path specifically - it is a
    # separate code path from resolve(), and it is the one that runs when
    # a zone will not load, so it above all must not need the thing that
    # just failed
    u = dayframe.utc_frame()
    assert u.ok and (u.tz, u.cut) == ("UTC", "00:00")
    assert dayframe.day_key("2026-07-29T18", u) == "2026-07-29"


def test_minute_and_hour_stay_utc_whatever_the_day_framing(sconn):
    """DEC-4 is explicit: only the day tier is local-keyed. A change that
    localised the hour bucket would silently re-key the tier the API
    charts by default."""
    sconn.execute(
        "INSERT INTO stats_minute (bucket, device, chain, up, down) "
        "VALUES ('2026-07-29T18:30', '192.0.2.20', 'X', 1, 10)")
    # `now` is chosen so the minute row rolls (minute retention 48h) while
    # the hour row is still inside its own 90-day window - otherwise the
    # hour is rolled onward and deleted, and the assertion tests nothing.
    stats_store.rollup(sconn, "2026-08-05T00:00:00Z", day=frame())
    hours = [r[0] for r in sconn.execute(
        "SELECT bucket FROM stats_hour ORDER BY bucket")]
    assert hours == ["2026-07-29T18"]


def test_a_collector_with_no_timezone_source_is_degraded_not_utc(sconn,
                                                                 fake_client):
    """An unwired collector must say so, not quietly stamp UTC. Silently
    claiming a framing nobody configured is how a wiring mistake becomes
    90 days of mis-stamped history that looks deliberate."""
    from app.collector.core import Collector
    col = Collector(client=fake_client, conn=sconn)
    assert col.day_frame().ok is False
    col.maintain(now="2027-01-01T00:00:00Z")
    assert col.status["day_framing"] == "degraded"
    assert col.status["day_error"]


def test_a_raising_timezone_source_degrades_instead_of_propagating(sconn,
                                                                   fake_client):
    """`day_source` reads policy.db on the collector thread. Anything it
    can raise - a closed connection, a store error - must become a
    recorded degraded frame, because an exception escaping here kills the
    maintenance pass and, in the loop, the thread."""
    from app.collector.core import Collector

    def angry():
        raise sqlite3.ProgrammingError("connection closed (simulated)")

    col = Collector(client=fake_client, conn=sconn, day_source=angry)
    frame_now = col.day_frame()
    assert frame_now.ok is False
    assert "ProgrammingError" in frame_now.error
    col.maintain(now="2027-01-01T00:00:00Z")     # must not raise
    assert col.status["day_framing"] == "degraded"


def test_rollup_refuses_to_run_without_an_explicit_framing(sconn):
    """`day` is a REQUIRED keyword on purpose. Defaulting it would let a
    call site that forgot the framing produce UTC-keyed rows that look
    like a decision someone made; "cannot key locally" is a value
    (`DayFrame.ok is False`), not an omitted argument."""
    with pytest.raises(TypeError):
        stats_store.rollup(sconn, "2027-01-01T00:00:00Z")


def test_day_retention_keeps_a_day_of_slack_for_local_keys(sconn):
    """A local day key can sit either side of the UTC date it was rolled
    from, so comparing it against a UTC-derived horizon with no slack can
    evict the oldest day a whole day early."""
    sconn.execute(
        "INSERT INTO stats_day (bucket, device, chain, up, down) "
        "VALUES ('2024-12-31', '192.0.2.20', 'X', 1, 10)")   # exactly at the
    sconn.execute(                                           # 730d horizon -1
        "INSERT INTO stats_day (bucket, device, chain, up, down) "
        "VALUES ('2024-12-30', '192.0.2.20', 'X', 1, 10)")   # genuinely older
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z", day=frame())
    kept = [r[0] for r in sconn.execute(
        "SELECT bucket FROM stats_day ORDER BY bucket")]
    assert kept == ["2024-12-31"], kept


def test_health_reports_the_framing_the_day_tier_is_actually_using(
        client, panel_env):
    """A degraded framing keys in UTC, which is the right behaviour - but
    it must not be SILENT. /health carries it on FLAT keys because the
    doctor reads them with a sed scalar extractor, and it is separate from
    `last_error`, which every successful poll clears within 10s while
    maintenance runs only once a minute."""
    body = client.get("/health").json()
    assert {"day_tz", "day_cut", "day_framing"} <= set(body)
    # before any maintenance pass has run the honest answer is "unknown",
    # not a guess at the framing
    assert body["day_framing"] in ("unknown", "ok", "degraded")

    collector = client.app.state.collector
    collector.day_source = lambda: dayframe.resolve("Mars/Olympus", "03:00")
    collector.maintain(now="2027-01-01T00:00:00Z")
    body = client.get("/health").json()
    assert body["day_framing"] == "degraded"
    assert body["day_tz"] == "Mars/Olympus"

    collector.day_source = lambda: dayframe.resolve(SHANGHAI, "03:00")
    collector.maintain(now="2027-01-01T00:00:00Z")
    body = client.get("/health").json()
    assert body["day_framing"] == "ok"
    assert (body["day_tz"], body["day_cut"]) == (SHANGHAI, "03:00")


def test_the_production_day_source_follows_a_settings_change(client,
                                                             panel_env):
    """The setting lives in policy.db and the rollup runs against stats.db,
    so this is the wire between them. It must be re-read per pass: caching
    it at construction would make a timezone change need a panel restart."""
    from app.tests.conftest import auth_headers
    collector = client.app.state.collector
    assert collector.day_frame().tz == "UTC"          # nothing configured
    client.put("/v1/settings",
               json={"values": {"timezone": SHANGHAI, "day_boundary": "05:00"}},
               headers=auth_headers(panel_env))
    frame_now = collector.day_frame()
    assert (frame_now.tz, frame_now.cut) == (SHANGHAI, "05:00")
    assert frame_now.ok


# --- the day_boundary setting ------------------------------------------------

def test_day_boundary_is_a_setting_with_a_03_00_default(panel_env, tmp_path):
    from app.store import settings
    from app.store.db import open_db
    from app.validation import ValidationError
    conn = open_db(tmp_path / "policy.db")
    try:
        assert settings.get(conn, "day_boundary") == "03:00"
        settings.set_value(conn, "day_boundary", "05:00", requester="t")
        assert settings.get(conn, "day_boundary") == "05:00"
        for bad in ("25:00", "3pm", "5", "05:60", "-1:00",
                    # a sub-hour cut is REFUSED, not approximated: the day
                    # tier is fed hour buckets, so a boundary at 03:30 would
                    # put the whole 03:00-03:59 hour on one side of a line
                    # running through its middle - and stamp the row as if
                    # that were deliberate
                    "05:30", "23:59", "00:01"):
            with pytest.raises(ValidationError):
                settings.set_value(conn, "day_boundary", bad, requester="t")
    finally:
        conn.close()


def test_a_sub_hour_cut_is_unusable_rather_than_approximated(sconn):
    """Reachable even though the setting refuses it: a value stored before
    this rule, or written by raw SQL, still reaches the rollup. It must
    degrade visibly (UTC) rather than mis-slice the boundary hour."""
    f = dayframe.resolve(SHANGHAI, "03:30")
    assert f.ok is False and "03:30" in f.error
    seed_hour(sconn, "2026-07-29T18")
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z", day=f)
    assert [(r[1], r[2]) for r in day_rows(sconn)] == [("UTC", "00:00")]


def test_day_tier_totals_are_exact_across_a_seam_and_say_so(sconn, client,
                                                            panel_env):
    """Totals sum ACROSS framings, and that is arithmetically right - each
    hour bucket rolls exactly once, so nothing is double-counted or lost.
    What a sum cannot show is that the day BOUNDARY moved inside the
    window, so the framings present travel alongside it."""
    seed_hour(sconn, "2026-07-29T18", up=1, down=10)
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z",
                       day=frame("UTC", "00:00"))
    seed_hour(sconn, "2026-07-29T10", up=2, down=20)
    stats_store.rollup(sconn, "2027-01-01T00:00:00Z", day=frame(SHANGHAI))

    totals = stats_store.read_grouped(sconn, "day", "device")
    assert len(totals) == 1
    assert (totals[0]["up"], totals[0]["down"]) == (3, 30)   # exact, no loss
    framings = stats_store.day_framings(sconn)
    assert {(f["bucket_tz"], f["day_boundary"]) for f in framings} == {
        ("UTC", "00:00"), (SHANGHAI, "03:00")}


def test_the_stats_api_carries_framings_on_the_day_tier_only(client,
                                                             panel_env):
    """Additive, and absent where it would be meaningless: the minute and
    hour tiers have no framing at all."""
    day = client.get("/v1/stats/devices?tier=day").json()
    assert "framings" in day
    for tier in ("minute", "hour"):
        assert "framings" not in client.get(
            f"/v1/stats/devices?tier={tier}").json()
    assert "framings" in client.get("/v1/stats/chains?tier=day").json()
