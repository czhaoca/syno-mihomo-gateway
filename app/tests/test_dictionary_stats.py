"""The dictionary in the store (#97): migration v7's `stats_app`, and the
coverage report's `dictionary` partition (DEC-D).

The partition sorts each byte of the coverage window into exactly one class
- `app` (its app-level id kept), `coarse` (only its coarse category kept),
`unattributed` (no answer) or `no_dictionary` (counted without one) - and
sits BESIDE the hostname/ip_only `classes`, which keep summing to 100 on
their own. Synthesised flows only (TEST-NET, example.* names).
"""

import pytest
from app.store import categories
from app.store import stats as stats_store
from app.store.db import open_db
from app.store.stats import STATS_MIGRATIONS, flush_poll, open_stats_db
from app.tests.conftest import auth_headers, example_dictionary, geo_conn

A, B = "192.0.2.20", "192.0.2.21"
NOW = "2026-10-15T12:00:00Z"
DICT = example_dictionary()


@pytest.fixture()
def sconn(panel_env):
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    yield conn
    conn.close()


def push(conn, frames, now=NOW, domains=False, dictionary=DICT):
    flush_poll(conn, frames, now, domains_enabled=domains, gap_threshold_s=6,
               interval_s=2, dictionary=dictionary)


def classes(report):
    return {c["klass"]: (c["up"], c["down"])
            for c in report["dictionary"]["classes"]}


# --- migration v7 ----------------------------------------------------------------

def test_v7_adds_the_app_table_with_its_device_index(sconn):
    # the newest migration, whichever later ticket appended it (#102: v8)
    assert sconn.execute("PRAGMA user_version").fetchone()[0] == len(
        STATS_MIGRATIONS)
    names = {r[0] for r in sconn.execute(
        "SELECT name FROM sqlite_master WHERE tbl_name = 'stats_app'")}
    assert names >= {"stats_app", "stats_app_device"}
    assert stats_store.APP_TABLE in stats_store.CLASS_TABLES
    assert stats_store.APP_TABLE in stats_store.PURGE_TABLES


def test_a_v6_store_migrates_to_v7_and_keeps_its_rows(panel_env):
    path = panel_env["data"] / "state" / "stats.db"
    older = open_db(path, migrations=STATS_MIGRATIONS[:6],
                    pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    older.execute("INSERT INTO stats_category_hour (bucket, device, value, "
                  "up, down) VALUES ('2026-10-15T11', ?, '', 3, 4)", (A,))
    older.commit()
    older.close()
    conn = open_stats_db(path)
    try:
        assert conn.execute("PRAGMA user_version").fetchone()[0] == len(
            STATS_MIGRATIONS)
        assert tuple(conn.execute(
            "SELECT value, up, down FROM stats_category_hour").fetchone()
        ) == ("", 3, 4)
        assert conn.execute("SELECT COUNT(*) FROM stats_app").fetchone()[0] == 0
    finally:
        conn.close()


def test_an_older_image_opens_a_v7_store_and_leaves_the_app_table(panel_env):
    path = panel_env["data"] / "state" / "stats.db"
    conn = open_stats_db(path)
    push(conn, [geo_conn("c1", A, 10, 100, host="video.example.com")],
         domains=True)
    conn.close()
    older = open_db(path, migrations=STATS_MIGRATIONS[:6],
                    pre_migrate=("PRAGMA auto_vacuum = INCREMENTAL",))
    try:
        # an older image leaves the newer store's version as it found it
        assert older.execute("PRAGMA user_version").fetchone()[0] == len(
            STATS_MIGRATIONS)
        assert tuple(older.execute(
            "SELECT value, up, down FROM stats_app").fetchone()
        ) == ("example-video", 10, 100)
    finally:
        older.close()


# --- the coverage partition ------------------------------------------------------

def test_every_class_is_listed_even_on_an_empty_store(sconn):
    report = stats_store.coverage_report(sconn)
    assert [c["klass"] for c in report["dictionary"]["classes"]] == [
        "app", "coarse", "unattributed", "no_dictionary"]
    assert all(c["share"] == 0.0 for c in report["dictionary"]["classes"])
    assert report["dictionary"]["total"] == {"up": 0, "down": 0}


def test_classified_bytes_are_coarse_unless_their_app_id_is_kept(sconn):
    frames = [geo_conn("c1", A, 10, 100, host="video.example.com"),
              geo_conn("c2", A, 5, 5, host="unlisted.example.net"),
              geo_conn("c3", B, 35, 340)]
    push(sconn, frames)
    report = stats_store.coverage_report(sconn, app_ids_kept=False)
    assert classes(report) == {"app": (0, 0), "coarse": (10, 100),
                               "unattributed": (40, 345),
                               "no_dictionary": (0, 0)}
    assert report["dictionary"]["app_ids_kept"] is False
    moved = [dict(f, upload=f["upload"] * 2, download=f["download"] * 2)
             for f in frames]
    push(sconn, moved, now="2026-10-15T12:00:02Z", domains=True)
    report = stats_store.coverage_report(sconn, app_ids_kept=True)
    assert classes(report) == {"app": (10, 100), "coarse": (10, 100),
                               "unattributed": (80, 690),
                               "no_dictionary": (0, 0)}
    shares = [c["share"] for c in report["dictionary"]["classes"]]
    assert round(sum(shares), 6) == 100.0


def test_the_hostname_partition_is_untouched(sconn):
    push(sconn, [geo_conn("c1", A, 60, 600, host="video.example.com"),
                 geo_conn("c2", A, 40, 400)])
    report = stats_store.coverage_report(sconn)
    assert {c["klass"]: c["share"] for c in report["classes"]} == {
        "hostname": 60.0, "ip_only": 40.0}
    assert report["dictionary"]["total"] == report["total"]


def test_an_older_image_row_after_the_dictionary_reads_as_no_dictionary(sconn):
    """The unattended rollback path: v1.12 classified, the updater rolled
    back to v1.11, which writes every category as "" - those bytes must
    read as counted without a dictionary, not as the dictionary's miss.
    (`dictionary=None` writes exactly what v1.11's ingest writes.)"""
    push(sconn, [geo_conn("c1", A, 10, 100, host="video.example.com")])
    push(sconn, [geo_conn("c1", A, 30, 300, host="video.example.com"),
                 geo_conn("c2", B, 7, 7)],
         now="2026-10-15T13:00:00Z", dictionary=None)
    push(sconn, [geo_conn("c1", A, 31, 301, host="video.example.com")],
         now="2026-10-15T14:00:00Z")
    assert classes(stats_store.coverage_report(sconn)) == {
        "app": (0, 0), "coarse": (11, 101), "unattributed": (0, 0),
        "no_dictionary": (27, 207)}


def test_the_partition_is_clamped_to_the_coverage_window(sconn):
    # a category row older than the coverage table's first bucket is
    # outside the window `classes` answers for, so it is not counted here
    sconn.execute("INSERT INTO stats_category_hour (bucket, device, value, "
                  "up, down) VALUES ('2026-09-01T00', ?, 'video', 9, 9)", (A,))
    sconn.execute("INSERT INTO stats_app (bucket, device, value, up, down) "
                  "VALUES ('2026-09-01T00', ?, 'example-video', 9, 9)", (A,))
    sconn.commit()
    push(sconn, [geo_conn("c1", A, 10, 100, host="video.example.com")])
    report = stats_store.coverage_report(sconn, since="2026-08-01")
    assert classes(report)["coarse"] == (10, 100)
    assert classes(report)["app"] == (0, 0)
    assert report["dictionary"]["total"] == {"up": 10, "down": 100}


def put(conn, table, bucket, value, up, down, device=A):
    conn.execute(f"INSERT INTO {table} (bucket, device, value, up, down) "
                 f"VALUES (?, ?, ?, ?, ?)", (bucket, device, value, up, down))


def cover(conn, bucket, up, down, device=A):
    conn.execute("INSERT INTO stats_coverage (bucket, device, klass, up, "
                 "down) VALUES (?, ?, 'hostname', ?, ?)",
                 (bucket, device, up, down))


def test_purging_the_app_table_alone_files_its_bytes_as_coarse(sconn):
    push(sconn, [geo_conn("c1", A, 10, 100, host="video.example.com")],
         domains=True)
    sconn.execute("DELETE FROM stats_app")
    sconn.commit()
    assert classes(stats_store.coverage_report(sconn))["coarse"] == (10, 100)
    assert classes(stats_store.coverage_report(sconn))["app"] == (0, 0)


def test_app_bytes_never_exceed_the_classified_bytes_left(sconn):
    push(sconn, [geo_conn("c1", A, 10, 100, host="video.example.com")],
         domains=True)
    sconn.execute("DELETE FROM stats_category_hour")
    sconn.commit()
    assert classes(stats_store.coverage_report(sconn))["app"] == (0, 0)


def test_app_ids_kept_in_one_hour_never_pass_for_another(sconn):
    """The app/coarse split is matched per hour and device. Here the app
    table holds an hour the category dimension no longer holds at hour
    resolution (PANEL_STATS_HOUR_DAYS under seven days rolls it into days),
    and a device it never classified - neither may turn the classified
    bytes of the hours that remain into `app`."""
    cover(sconn, "2026-10-11T08", 50, 50)
    cover(sconn, "2026-10-15T12", 10, 100)
    put(sconn, "stats_app", "2026-10-11T08", "example-video", 50, 50)
    put(sconn, "stats_app", "2026-10-15T12", "example-video", 4, 4, device=B)
    put(sconn, "stats_category_hour", "2026-10-15T12", "video", 10, 100)
    sconn.commit()
    report = stats_store.coverage_report(sconn)
    assert classes(report) == {"app": (0, 0), "coarse": (10, 100),
                               "unattributed": (0, 0),
                               "no_dictionary": (0, 0)}
    assert report["dictionary"]["oldest_bucket"] == "2026-10-15T12"
    # the hostname partition still answers for the whole coverage window
    assert report["total"] == {"up": 60, "down": 150}


def test_app_ids_kept_before_the_gate_closed_still_count(sconn):
    push(sconn, [geo_conn("c1", A, 10, 100, host="video.example.com")],
         domains=True)
    report = stats_store.coverage_report(sconn, app_ids_kept=False)
    # the ids ARE still held (until their seven days are up); the flag says
    # only that no new ones are being kept
    assert classes(report)["app"] == (10, 100)
    assert report["dictionary"]["app_ids_kept"] is False


def test_the_report_names_the_dictionary_and_any_load_error(sconn,
                                                            monkeypatch):
    monkeypatch.setattr(categories, "_ACTIVE", {"dictionary": DICT,
                                                "error": None})
    dictionary = stats_store.coverage_report(sconn)["dictionary"]
    assert (dictionary["version"], dictionary["error"]) == ("test", None)
    monkeypatch.setattr(categories, "_ACTIVE", {"dictionary": None,
                                                "error": "broken"})
    dictionary = stats_store.coverage_report(sconn)["dictionary"]
    assert (dictionary["version"], dictionary["error"]) == (None, "broken")


@pytest.mark.parametrize("knob, kept", [("", False), ("true", True)])
def test_the_endpoint_reports_whether_app_ids_are_kept(client, monkeypatch,
                                                       knob, kept):
    monkeypatch.setenv("PANEL_STATS_DOMAINS", knob)
    body = client.get("/v1/stats/coverage").json()
    assert body["dictionary"]["app_ids_kept"] is kept
    assert [c["klass"] for c in body["dictionary"]["classes"]] == list(
        stats_store.DICTIONARY_CLASSES)
    assert {c["klass"] for c in body["classes"]} == {"hostname", "ip_only"}


def test_the_purge_clears_the_app_table(client, panel_env):
    push(client.app.state.stats_conn,
         [geo_conn("c1", A, 10, 100, host="video.example.com")], domains=True)
    r = client.post("/v1/stats/purge", json={"tables": ["stats_app"]},
                    headers=auth_headers(panel_env))
    assert r.status_code == 200, r.text
    assert client.app.state.stats_conn.execute(
        "SELECT COUNT(*) FROM stats_app").fetchone()[0] == 0
