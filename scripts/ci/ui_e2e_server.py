#!/usr/bin/env python3
"""The app under test for the Playwright gate (#79).

Reuses `panel_e2e_check.py`'s FakeController rather than growing a second
fake: two fakes of one controller drift, and the moment they disagree the
browser suite starts asserting against behaviour the API suite never sees.

Runs in the foreground and stays up until killed - Playwright's `webServer`
owns the lifecycle. It prints the base URL on stdout as soon as /health
answers, so the config can wait for a real readiness signal rather than a
sleep.

Deliberately binds 127.0.0.1: the panel is LAN-only by design, and a CI
harness that listened on 0.0.0.0 would be the one place in this repo that
forgets it.
"""

import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts" / "ci"))

from panel_e2e_check import (  # noqa: E402
    SECRET,
    FakeController,
    _state,
    api,
    free_port,
)

READY_TIMEOUT_S = 40


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        data = Path(td) / "data"
        providers = data / "config" / "providers"
        providers.mkdir(parents=True, exist_ok=True)
        _state["providers_dir"] = providers

        ctl_port = free_port()
        controller = ThreadingHTTPServer(("127.0.0.1", ctl_port),
                                         FakeController)
        threading.Thread(target=controller.serve_forever, daemon=True).start()

        app_port = int(os.environ.get("PANEL_E2E_PORT", "0")) or free_port()
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "GATEWAY_DATA_DIR": str(data),
            "PANEL_PROVIDERS_DIR": str(providers),
            "PANEL_SECRET": SECRET,
            "PANEL_MIHOMO_URL": f"http://127.0.0.1:{ctl_port}",
            # The collector loop is OFF: a browser suite must not race a
            # background writer, and nothing here asserts on collection.
            "PANEL_STATS_POLL_S": "0",
        }
        proc = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "app.main:app",
             "--host", "127.0.0.1", "--port", str(app_port),
             "--log-level", "warning"],
            cwd=REPO, env=env)
        started = time.monotonic()
        try:
            while True:
                if time.monotonic() - started > READY_TIMEOUT_S:
                    proc.terminate()
                    print(f"FAIL: app not ready in {READY_TIMEOUT_S}s",
                          file=sys.stderr)
                    return 1
                if proc.poll() is not None:
                    print(f"FAIL: uvicorn exited early ({proc.returncode})",
                          file=sys.stderr)
                    return 1
                try:
                    status, _ = api("GET", app_port, "/health")
                    if status == 200:
                        break
                except OSError:
                    pass
                time.sleep(0.2)
            print(f"PANEL_E2E_URL=http://127.0.0.1:{app_port}", flush=True)
            proc.wait()
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
            controller.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
