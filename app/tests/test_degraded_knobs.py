"""Degraded-knob resilience (the fail-static promise under config damage):
a malformed or blank URL knob must DEGRADE — webhook returns False, client
raises MihomoError onto the loud path, a raising notifier never kills
_fail — and the app must boot and serve /health with parity=failed rather
than crash its lifespan."""

import pytest
from app import config
from app.main import create_app
from app.mihomo_client.client import MihomoClient, MihomoError
from app.notify import webhook_notify
from app.reconciler.core import Reconciler
from fastapi.testclient import TestClient


@pytest.mark.parametrize("bad_url", [
    "not-a-valid-url-missing-scheme",
    "http//typo.invalid",
    # a space/control char in the HOST passes Request() construction and
    # explodes inside urlopen as http.client.InvalidURL - the sibling
    # exception class the first fix round missed
    "http://127.0.0.1 :9090/hook",
])
def test_webhook_never_raises_on_garbage_url(monkeypatch, bad_url):
    monkeypatch.setenv("NOTIFY_WEBHOOK_URL", bad_url)
    assert webhook_notify("t", "b") is False


def test_blank_mihomo_url_env_falls_back_to_default(monkeypatch):
    monkeypatch.setenv("PANEL_MIHOMO_URL", "")
    assert config.mihomo_url() == "http://127.0.0.1:9090"


@pytest.mark.parametrize("base", [
    "",
    "no-scheme-at-all",
    "http://exa mple.invalid",   # InvalidURL out of urlopen, not Request()
    "http://127.0.0.1 :9090",
])
def test_client_wraps_malformed_base_url_as_mihomo_error(base):
    client = MihomoClient(base, "")
    with pytest.raises(MihomoError):
        client.refresh_provider("dyn-full-direct")
    with pytest.raises(MihomoError):
        client.provider_rule_counts()


def test_apply_survives_an_unwrapped_client_exception(panel_env, notifier):
    """Last-resort net: even an exception class the client failed to wrap
    must degrade to loud fail-static, never escape apply()."""

    class ExplodingClient:
        def refresh_provider(self, name):
            raise RuntimeError("unclassified client defect")

        def provider_rule_counts(self):
            return {}

    marker = panel_env["data"] / "state" / "panel-apply-failed"
    rec = Reconciler(client=ExplodingClient(),
                     providers_dir=panel_env["providers"],
                     marker_path=marker, notifier=notifier)
    ok = rec.apply({"full-direct": [], "full-tunnel": []})
    assert ok is False
    assert rec.status["parity"] == "failed"
    assert "RuntimeError" in rec.status["last_error"]
    assert marker.exists()


def test_raising_notifier_never_kills_failstatic(panel_env, fake_client):
    def exploding_notifier(title, body):
        raise RuntimeError("webhook stack is broken")

    marker = panel_env["data"] / "state" / "panel-apply-failed"
    fake_client.fail_puts = True
    rec = Reconciler(client=fake_client, providers_dir=panel_env["providers"],
                     marker_path=marker, notifier=exploding_notifier)
    ok = rec.apply({"full-direct": ["192.0.2.5/32"], "full-tunnel": []})
    assert ok is False  # degraded, not crashed
    assert rec.status["parity"] == "failed"
    assert marker.exists()


@pytest.mark.parametrize("bad_controller_url", [
    "http://127.0.0.1:9",         # unreachable port (connection refused)
    "http://127.0.0.1 :9090",     # control-char host (InvalidURL in urlopen)
])
def test_app_boots_with_broken_controller_and_garbage_webhook(
        panel_env, monkeypatch, bad_controller_url):
    # REAL client + REAL notifier paths (no fakes). The lifespan must
    # complete, /health must serve with parity=failed, and reads must
    # answer - whatever exception class the broken knob produces.
    monkeypatch.setenv("PANEL_MIHOMO_URL", bad_controller_url)
    monkeypatch.setenv("NOTIFY_WEBHOOK_URL", "not-a-valid-url")
    app = create_app()
    with TestClient(app) as c:
        health = c.get("/health").json()
        assert health["db_ok"] is True
        assert health["parity"] == "failed"
        assert health["marker"] is True
        assert c.get("/v1/devices").status_code == 200
