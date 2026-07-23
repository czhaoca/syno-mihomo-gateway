"""Shared fixtures for the panel test suite.

Every test runs against a throwaway GATEWAY_DATA_DIR (policy.db, providers/,
markers all live under it), a fake mihomo client whose ruleCounts come from
the REAL provider files on disk (so count-parity is exercised, not stubbed),
and a recording notifier. No network, no docker — hermetic by construction.
"""

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from app.mihomo_client.client import MihomoError  # noqa: E402
from app.reconciler.core import PROVIDER_FILES  # noqa: E402


class FakeMihomoClient:
    """Stands in for the controller: refresh records the PUT (or fails on
    demand), and rule counts are read back from the actual provider files —
    the same read-after-write loop the real controller performs."""

    def __init__(self, providers_dir: Path):
        self.providers_dir = Path(providers_dir)
        self.puts: list[str] = []
        self.fail_puts = False
        # /connections fixture state (#65): tests assign the live list;
        # fail_connections simulates a controller outage for gap testing.
        self.conns: list[dict] = []
        self.fail_connections = False

    def refresh_provider(self, name: str) -> None:
        if self.fail_puts:
            raise MihomoError("PUT /providers/rules refresh failed (fixture)")
        self.puts.append(name)

    def connections(self) -> list[dict]:
        if self.fail_connections:
            raise MihomoError("GET /connections failed (fixture)")
        return [dict(c) for c in self.conns]

    def provider_rule_counts(self) -> dict:
        counts = {}
        for provider, filename in PROVIDER_FILES.items():
            path = self.providers_dir / filename
            if not path.exists():
                continue
            lines = [
                ln for ln in path.read_text().splitlines()
                if ln.strip() and not ln.startswith("#")
            ]
            counts[provider] = len(lines)
        return counts


class RecordingNotifier:
    def __init__(self):
        self.sent: list[tuple[str, str]] = []

    def __call__(self, title: str, body: str) -> bool:
        self.sent.append((title, body))
        return True


@pytest.fixture()
def panel_env(tmp_path, monkeypatch):
    """Point every env knob at the throwaway tree; PANEL_SECRET set."""
    data = tmp_path / "data"
    providers = data / "config" / "providers"
    monkeypatch.setenv("GATEWAY_DATA_DIR", str(data))
    monkeypatch.setenv("PANEL_PROVIDERS_DIR", str(providers))
    monkeypatch.setenv("PANEL_SECRET", "test-panel-secret")
    monkeypatch.setenv("PANEL_MIHOMO_URL", "http://127.0.0.1:9")  # never dialed
    monkeypatch.delenv("CONTROLLER_SECRET", raising=False)
    monkeypatch.delenv("NOTIFY_WEBHOOK_URL", raising=False)
    monkeypatch.delenv("MIHOMO_IP", raising=False)
    monkeypatch.delenv("PANEL_IP", raising=False)
    # stats: no background thread in unit tests (0 disables the loop);
    # collection is driven explicitly via poll_once/rollup with fake clocks
    monkeypatch.setenv("PANEL_STATS_POLL_S", "0")
    monkeypatch.delenv("PANEL_STATS_DOMAINS", raising=False)
    return {"data": data, "providers": providers, "secret": "test-panel-secret"}


def conn_fixture(cid: str, source: str, up: int, down: int,
                 chain: str = "Routing Mode", host: str = "") -> dict:
    """A /connections entry in the controller's wire shape."""
    return {"id": cid, "upload": up, "download": down,
            "metadata": {"sourceIP": source, "host": host,
                         "network": "tcp", "type": "tun"},
            "chains": ["JP01", "Japan Auto", "Exit Country", chain]}


@pytest.fixture()
def fake_client(panel_env):
    return FakeMihomoClient(panel_env["providers"])


@pytest.fixture()
def notifier():
    return RecordingNotifier()


@pytest.fixture()
def client(panel_env, fake_client, notifier):
    """A TestClient over the real app wired to the fakes; lifespan runs."""
    from app.main import create_app
    from fastapi.testclient import TestClient

    app = create_app(mihomo_client=fake_client, notifier=notifier)
    with TestClient(app) as c:
        yield c


def auth_headers(panel_env) -> dict:
    return {"Authorization": f"Bearer {panel_env['secret']}"}
