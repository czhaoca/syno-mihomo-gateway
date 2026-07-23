#!/usr/bin/env python3
"""Hermetic panel e2e: the REAL app (uvicorn subprocess) against a fake
mihomo controller + webhook sink, all on loopback in one CI step — no
docker, no network beyond 127.0.0.1.

The fake controller is honest where it matters: GET /providers/rules
counts payload lines from the ACTUAL provider files the app wrote, so the
reconciler's count-parity verification loop is exercised end to end, not
stubbed. Drives: startup re-sync -> auth-gated add -> flip -> audit ->
forced refresh-failure (marker + webhook + parity=failed) -> recovery via
/v1/apply -> remove. Readiness poll + hard timeout + app-log capture on
failure. Exit non-zero on any failure.
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEADLINE_S = 120
SECRET = "e2e-fixture-secret"

PROVIDER_FILES = {
    "dyn-full-direct": "dyn-full-direct.txt",
    "dyn-full-tunnel": "dyn-full-tunnel.txt",
}

_state = {"fail_puts": False, "webhooks": [], "providers_dir": None}


class FakeController(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep CI output clean
        pass

    def _reply(self, code: int, body: bytes = b""):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_PUT(self):
        if self.path.startswith("/providers/rules/"):
            if _state["fail_puts"]:
                self._reply(500, b'{"message":"forced failure (fixture)"}')
            else:
                self._reply(204)
            return
        self._reply(404)

    def do_GET(self):
        if self.path == "/providers/rules":
            providers = {}
            for name, filename in PROVIDER_FILES.items():
                path = _state["providers_dir"] / filename
                count = 0
                if path.exists():
                    count = len([ln for ln in path.read_text().splitlines()
                                 if ln.strip() and not ln.startswith("#")])
                providers[name] = {"name": name, "ruleCount": count,
                                   "type": "File", "vehicleType": "File"}
            self._reply(200, json.dumps({"providers": providers}).encode())
            return
        self._reply(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.path == "/_webhook":
            try:
                _state["webhooks"].append(json.loads(body))
            except ValueError:
                _state["webhooks"].append({"raw": body.decode(errors="replace")})
            self._reply(200)
            return
        if self.path == "/_control/fail_puts/on":
            _state["fail_puts"] = True
            self._reply(200)
            return
        if self.path == "/_control/fail_puts/off":
            _state["fail_puts"] = False
            self._reply(200)
            return
        self._reply(404)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def api(method: str, port: int, path: str, body=None, token=None,
        expect_error: bool = False):
    """Returns (status, parsed-json-or-None)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}",
                                 data=data, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as exc:
        payload = exc.read()
        try:
            return exc.code, json.loads(payload)
        except ValueError:
            return exc.code, {"raw": payload.decode(errors="replace")}


class E2EFailure(AssertionError):
    pass


def expect(cond: bool, msg: str):
    if not cond:
        raise E2EFailure(msg)


def run_scenario(app_port: int, providers: Path, marker: Path,
                 ctl_port: int) -> None:
    direct = providers / PROVIDER_FILES["dyn-full-direct"]
    tunnel = providers / PROVIDER_FILES["dyn-full-tunnel"]

    # 1) startup re-sync produced both files (empty) + green health
    status, health = api("GET", app_port, "/health")
    expect(status == 200 and health["db_ok"] is True, f"health: {health}")
    expect(health["parity"] == "ok", f"startup parity: {health}")
    expect(direct.exists() and tunnel.exists(),
           "startup re-sync must write both provider files")

    # 2) auth: mutation without a token is refused, token never echoed
    status, body = api("POST", app_port, "/v1/devices",
                       {"address": "198.51.100.7", "mode": "full-tunnel"})
    expect(status == 403, f"unauthenticated add: {status} {body}")
    status, body = api("POST", app_port, "/v1/devices",
                       {"address": "198.51.100.7", "mode": "full-tunnel"},
                       token="wrong-token-sniff")
    expect(status == 403, f"wrong-token add: {status}")
    expect("wrong-token-sniff" not in json.dumps(body),
           "the presented token must never be echoed")

    # 3) authenticated add -> file content + verified parity
    status, body = api("POST", app_port, "/v1/devices",
                       {"address": "198.51.100.7", "mode": "full-tunnel",
                        "name": "e2e-tv"}, token=SECRET)
    expect(status == 201, f"add: {status} {body}")
    dev1 = body["device"]
    expect(body["applied"] is True and body["parity"] == "ok",
           f"add apply: {body}")
    expect(tunnel.read_text() == "SRC-IP-CIDR,198.51.100.7/32\n",
           f"tunnel payload: {tunnel.read_text()!r}")

    # 4) validation + conflict classes over the API
    status, body = api("POST", app_port, "/v1/devices",
                       {"address": "not-an-ip", "mode": "full-tunnel"},
                       token=SECRET)
    expect(status == 422, f"invalid address must 422: {status}")
    status, body = api("POST", app_port, "/v1/devices",
                       {"address": "198.51.100.7/32", "mode": "full-direct"},
                       token=SECRET)
    expect(status == 409, f"duplicate must 409: {status} {body}")

    # 5) flip -> files swap sides
    status, body = api("PATCH", app_port, f"/v1/devices/{dev1['id']}",
                       {"mode": "full-direct"}, token=SECRET)
    expect(status == 200 and body["applied"] is True, f"flip: {status} {body}")
    expect(tunnel.read_text() == "" and
           direct.read_text() == "SRC-IP-CIDR,198.51.100.7/32\n",
           "flip must move the entry between provider files")

    # 6) audit carries the trail with requester IPs
    status, body = api("GET", app_port, "/v1/audit")
    expect(status == 200, f"audit read: {status}")
    actions = [e["action"] for e in body["entries"]]
    expect("add" in actions and "flip" in actions, f"audit actions: {actions}")
    expect(all(e["requester"] for e in body["entries"]),
           "audit entries must carry the requester IP")

    # 7) forced refresh failure: applied=false, parity=failed, marker,
    #    webhook ({title, body} contract) - and the mutation still landed
    api("POST", ctl_port, "/_control/fail_puts/on")
    status, body = api("POST", app_port, "/v1/devices",
                       {"address": "192.0.2.40", "mode": "full-tunnel"},
                       token=SECRET)
    expect(status == 201 and body["applied"] is False, f"failed add: {body}")
    status, health = api("GET", app_port, "/health")
    expect(health["parity"] == "failed" and health["marker"] is True,
           f"failed health: {health}")
    expect(marker.exists(), "apply failure must write the persistent marker")
    deadline = time.monotonic() + 5
    while not _state["webhooks"] and time.monotonic() < deadline:
        time.sleep(0.1)
    expect(len(_state["webhooks"]) >= 1, "apply failure must fire the webhook")
    hook = _state["webhooks"][0]
    expect("title" in hook and "body" in hook,
           f"webhook must follow the notify.sh {{title,body}} contract: {hook}")

    # 8) recovery via POST /v1/apply clears the loud state
    api("POST", ctl_port, "/_control/fail_puts/off")
    status, body = api("POST", app_port, "/v1/apply", token=SECRET)
    expect(status == 200 and body["applied"] is True, f"re-apply: {body}")
    status, health = api("GET", app_port, "/health")
    expect(health["parity"] == "ok" and health["marker"] is False,
           f"recovered health: {health}")
    expect(tunnel.read_text() == "SRC-IP-CIDR,192.0.2.40/32\n",
           f"recovered tunnel payload: {tunnel.read_text()!r}")

    # 9) remove -> file drains, audit records it
    status, body = api("DELETE", app_port, f"/v1/devices/{dev1['id']}",
                       token=SECRET)
    expect(status == 200 and body["applied"] is True, f"remove: {body}")
    expect(direct.read_text() == "", "removed entry must leave the file")
    status, body = api("GET", app_port, "/v1/audit")
    expect("remove" in [e["action"] for e in body["entries"]],
           "audit must record the removal")


def main() -> int:
    started = time.monotonic()
    with tempfile.TemporaryDirectory() as td:
        data = Path(td) / "data"
        providers = data / "config" / "providers"
        marker = data / "state" / "panel-apply-failed"
        _state["providers_dir"] = providers

        ctl_port = free_port()
        server = ThreadingHTTPServer(("127.0.0.1", ctl_port), FakeController)
        threading.Thread(target=server.serve_forever, daemon=True).start()

        app_port = free_port()
        log_path = Path(td) / "app.log"
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "GATEWAY_DATA_DIR": str(data),
            "PANEL_PROVIDERS_DIR": str(providers),
            "PANEL_SECRET": SECRET,
            "PANEL_MIHOMO_URL": f"http://127.0.0.1:{ctl_port}",
            "NOTIFY_WEBHOOK_URL": f"http://127.0.0.1:{ctl_port}/_webhook",
        }
        with log_path.open("wb") as log:
            proc = subprocess.Popen(
                [sys.executable, "-m", "uvicorn", "app.main:app",
                 "--host", "127.0.0.1", "--port", str(app_port),
                 "--log-level", "warning"],
                cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                while True:
                    if time.monotonic() - started > 30:
                        raise E2EFailure("app did not become ready in 30s")
                    if proc.poll() is not None:
                        raise E2EFailure(
                            f"uvicorn exited early ({proc.returncode})")
                    try:
                        status, _ = api("GET", app_port, "/health")
                        if status == 200:
                            break
                    except OSError:
                        pass
                    time.sleep(0.25)
                run_scenario(app_port, providers, marker, ctl_port)
                if time.monotonic() - started > DEADLINE_S:
                    raise E2EFailure(f"scenario exceeded {DEADLINE_S}s")
            except E2EFailure as exc:
                print(f"FAIL: {exc}", file=sys.stderr)
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                tail = log_path.read_text(errors="replace").splitlines()[-40:]
                print("--- app log tail ---", file=sys.stderr)
                for line in tail:
                    print(f"  {line}", file=sys.stderr)
                return 1
            finally:
                server.shutdown()
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
    print("OK: panel e2e - real uvicorn app vs fake controller: startup "
          "re-sync seeds both provider files, bearer-gated mutations "
          "(403 unauthenticated, token never echoed), add/flip/remove drive "
          "exact provider payloads with verified count-parity, invalid "
          "addresses 422 and duplicates 409, a forced refresh failure "
          "surfaces as applied=false + parity=failed + persistent marker + "
          "{title,body} webhook while the store keeps the mutation, and "
          "/v1/apply recovers to green; audit carries add/flip/remove with "
          "requester IPs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
