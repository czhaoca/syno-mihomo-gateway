"""Reconciler behavior against the fake controller: happy path
(write -> refresh -> count-parity), refresh failure (fail-static + marker +
webhook), startup re-sync, and DB-corrupt fail-static with reads still
serving and provider files untouched."""

from app.reconciler.core import MODE_TO_PROVIDER, PROVIDER_FILES, Reconciler
from app.tests.conftest import auth_headers
from fastapi.testclient import TestClient


def _provider_path(env, mode):
    return env["providers"] / PROVIDER_FILES[MODE_TO_PROVIDER[mode]]


def test_happy_path_write_refresh_verify(panel_env, fake_client, notifier):
    marker = panel_env["data"] / "state" / "panel-apply-failed"
    rec = Reconciler(client=fake_client, providers_dir=panel_env["providers"],
                     marker_path=marker, notifier=notifier)
    ok = rec.apply({"full-direct": ["192.0.2.5/32"],
                    "full-tunnel": ["198.51.100.0/28"]})
    assert ok is True
    assert rec.status["parity"] == "ok" and rec.status["last_apply"]
    direct = _provider_path(panel_env, "full-direct").read_text()
    tunnel = _provider_path(panel_env, "full-tunnel").read_text()
    assert direct == "SRC-IP-CIDR,192.0.2.5/32\n"
    assert tunnel == "SRC-IP-CIDR,198.51.100.0/28\n"
    assert sorted(fake_client.puts) == ["dyn-full-direct", "dyn-full-tunnel"]
    assert not marker.exists()
    assert notifier.sent == []


def test_empty_sets_write_empty_files(panel_env, fake_client, notifier):
    marker = panel_env["data"] / "state" / "panel-apply-failed"
    rec = Reconciler(client=fake_client, providers_dir=panel_env["providers"],
                     marker_path=marker, notifier=notifier)
    assert rec.apply({"full-direct": [], "full-tunnel": []}) is True
    assert _provider_path(panel_env, "full-direct").read_text() == ""
    assert _provider_path(panel_env, "full-tunnel").read_text() == ""


def test_refresh_failure_is_loud_and_failstatic(panel_env, fake_client, notifier):
    marker = panel_env["data"] / "state" / "panel-apply-failed"
    fake_client.fail_puts = True
    rec = Reconciler(client=fake_client, providers_dir=panel_env["providers"],
                     marker_path=marker, notifier=notifier)
    ok = rec.apply({"full-direct": ["192.0.2.5/32"], "full-tunnel": []})
    assert ok is False
    assert rec.status["parity"] == "failed"
    assert marker.exists() and "refresh failed" in marker.read_text()
    assert len(notifier.sent) == 1
    title, body = notifier.sent[0]
    assert title and body  # the notify.sh {title,body} contract

    # recovery clears the marker
    fake_client.fail_puts = False
    assert rec.apply({"full-direct": ["192.0.2.5/32"], "full-tunnel": []}) is True
    assert not marker.exists()
    assert rec.status["parity"] == "ok"


def test_count_parity_mismatch_fails(panel_env, fake_client, notifier, monkeypatch):
    marker = panel_env["data"] / "state" / "panel-apply-failed"
    rec = Reconciler(client=fake_client, providers_dir=panel_env["providers"],
                     marker_path=marker, notifier=notifier)
    monkeypatch.setattr(fake_client, "provider_rule_counts",
                        lambda: {"dyn-full-direct": 7, "dyn-full-tunnel": 0})
    ok = rec.apply({"full-direct": ["192.0.2.5/32"], "full-tunnel": []})
    assert ok is False
    assert rec.status["parity"] == "failed"
    assert "parity" in marker.read_text()


def test_startup_resync_writes_files(panel_env, fake_client, notifier):
    # Seed the store BEFORE the app starts; startup must reconcile it to disk.
    from app.store.db import open_db
    from app.store.policy import add_device

    conn = open_db(panel_env["data"] / "state" / "policy.db")
    add_device(conn, "192.0.2.77", "full-tunnel", requester="seed")
    conn.close()

    from app.main import create_app
    app = create_app(mihomo_client=fake_client, notifier=notifier)
    with TestClient(app) as c:
        health = c.get("/health").json()
        assert health["db_ok"] is True and health["parity"] == "ok"
        tunnel = _provider_path(panel_env, "full-tunnel").read_text()
        assert tunnel == "SRC-IP-CIDR,192.0.2.77/32\n"


def test_db_corrupt_failstatic_reads_still_serve(panel_env, fake_client, notifier):
    # Make the db path unopenable (a directory), pre-write sentinel provider
    # files: they must stay byte-identical (fail-static never touches them).
    db_path = panel_env["data"] / "state" / "policy.db"
    db_path.mkdir(parents=True)
    panel_env["providers"].mkdir(parents=True)
    for mode in ("full-direct", "full-tunnel"):
        _provider_path(panel_env, mode).write_text("SRC-IP-CIDR,192.0.2.99/32\n")

    from app.main import create_app
    app = create_app(mihomo_client=fake_client, notifier=notifier)
    with TestClient(app) as c:
        health = c.get("/health")
        assert health.status_code == 200
        assert health.json()["db_ok"] is False
        # reads still serve (structured responses, the app is alive) ...
        r = c.get("/v1/devices")
        assert r.status_code == 503 and "fail-static" in r.json()["detail"]
        # ... mutations are blocked ...
        r = c.post("/v1/devices", json={"address": "192.0.2.5",
                                        "mode": "full-tunnel"},
                   headers=auth_headers(panel_env))
        assert r.status_code == 503
    # ... provider files untouched, loud channels fired
    for mode in ("full-direct", "full-tunnel"):
        assert _provider_path(panel_env, mode).read_text() == \
            "SRC-IP-CIDR,192.0.2.99/32\n"
    marker = panel_env["data"] / "state" / "panel-apply-failed"
    assert marker.exists()
    assert len(notifier.sent) == 1
    assert fake_client.puts == []  # no refresh was ever attempted
