"""Minimal mihomo external-controller client (stdlib urllib — the runtime
dependency set is fastapi + uvicorn only, by constraint).

Only the two calls the reconciler needs: refresh one rule provider and
read back the provider table for count-parity. The controller secret rides
the Authorization header and is never logged, echoed, or embedded in
exception text.
"""

import http.client
import json
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT_S = 10


class MihomoError(RuntimeError):
    """Controller call failed; the message never carries the secret."""


class MihomoClient:
    def __init__(self, base_url: str, secret: str = ""):
        self.base_url = base_url.rstrip("/")
        self._secret = secret

    def _request(self, method: str, path: str) -> bytes:
        url = f"{self.base_url}{path}"
        try:
            # Request construction raises ValueError on a malformed base
            # URL (e.g. a blank/garbage PANEL_MIHOMO_URL) — it must be
            # inside the guard so every defect surfaces as MihomoError and
            # rides the reconciler's loud fail path instead of crashing
            # the app.
            req = urllib.request.Request(url, method=method)
            if self._secret:
                req.add_header("Authorization", f"Bearer {self._secret}")
            with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            raise MihomoError(
                f"{method} {path} -> HTTP {exc.code}") from None
        except (urllib.error.URLError, OSError, TimeoutError, ValueError,
                http.client.HTTPException) as exc:
            # http.client.HTTPException covers InvalidURL (a control char /
            # space in the host passes Request() but explodes in urlopen)
            # and protocol-level garbage like BadStatusLine — all of it is
            # a controller-call failure, never an app crash.
            reason = getattr(exc, "reason", exc)
            raise MihomoError(
                f"{method} {path} failed: {reason}") from None

    def refresh_provider(self, name: str) -> None:
        """PUT /providers/rules/:name — tell mihomo to re-read the file."""
        self._request("PUT", f"/providers/rules/{urllib.parse.quote(name)}")

    def provider_rule_counts(self) -> dict:
        """name -> ruleCount from GET /providers/rules."""
        raw = self._request("GET", "/providers/rules")
        try:
            doc = json.loads(raw)
        except ValueError as exc:
            raise MihomoError(
                "GET /providers/rules returned unparseable JSON") from exc
        counts = {}
        for name, info in (doc.get("providers") or {}).items():
            if isinstance(info, dict) and "ruleCount" in info:
                counts[name] = info["ruleCount"]
        return counts

    def connections(self) -> list:
        """The raw connections array from GET /connections (per-connection
        cumulative upload/download + metadata); the collector parses it."""
        raw = self._request("GET", "/connections")
        try:
            doc = json.loads(raw)
        except ValueError as exc:
            raise MihomoError(
                "GET /connections returned unparseable JSON") from exc
        conns = doc.get("connections")
        return conns if isinstance(conns, list) else []
