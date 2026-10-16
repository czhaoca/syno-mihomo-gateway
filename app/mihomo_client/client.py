"""Minimal mihomo external-controller client (stdlib urllib — the runtime
dependency set is fastapi + uvicorn only, by constraint).

The reconciler's two calls (refresh one rule provider, read back the
provider table for count-parity), the collector's /connections snapshot,
and the version and memory reads its telemetry samples (#96). The
controller secret rides
the Authorization header and is never logged, echoed, or embedded in
exception text.
"""

import http.client
import json
import re
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT_S = 10
# the telemetry reads (#96) are best-effort: a slow controller gets less time
TELEMETRY_TIMEOUT_S = 3

# /memory streams a frame a second and never ends; its first frame always
# reads inuse=0. Read at most this many frames looking for a real one.
_MEMORY_FRAMES = 3
_FRAME_BYTES = 4096

# a version string is shown by the doctor's flat sed extractor and the
# release validator: keep it to characters neither can mistake for syntax
_VERSION_OK = re.compile(r"[^A-Za-z0-9._+-]")


class MihomoError(RuntimeError):
    """Controller call failed; the message never carries the secret."""


class MihomoClient:
    def __init__(self, base_url: str, secret: str = ""):
        self.base_url = base_url.rstrip("/")
        self._secret = secret

    def _request(self, method: str, path: str,
                 timeout: float = TIMEOUT_S) -> bytes:
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
            with urllib.request.urlopen(req, timeout=timeout) as resp:
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

    def version(self) -> str:
        """The running build from GET /version - "" when the field is
        absent. Sanitised to a short safe token (the doctor reads it with
        a sed scalar extractor)."""
        raw = self._request("GET", "/version", timeout=TELEMETRY_TIMEOUT_S)
        try:
            doc = json.loads(raw)
        except ValueError as exc:
            raise MihomoError("GET /version returned unparseable JSON") from exc
        return _VERSION_OK.sub("", str((doc or {}).get("version") or ""))[:64]

    def memory_inuse(self) -> int | None:
        """mihomo's in-use memory, bytes, from the GET /memory STREAM.

        The endpoint never finishes a response, so it is read a bounded
        line at a time (each read bounded by TELEMETRY_TIMEOUT_S) and closed: the
        first frame always says 0, so zero frames are skipped, and after
        _MEMORY_FRAMES of them the answer is None (unknown) - never 0."""
        url = f"{self.base_url}/memory"
        try:
            req = urllib.request.Request(url, method="GET")
            if self._secret:
                req.add_header("Authorization", f"Bearer {self._secret}")
            with urllib.request.urlopen(req,
                                        timeout=TELEMETRY_TIMEOUT_S) as resp:
                for _ in range(_MEMORY_FRAMES):
                    line = resp.readline(_FRAME_BYTES)
                    if not line:
                        break
                    inuse = int((json.loads(line) or {}).get("inuse") or 0)
                    if inuse > 0:
                        return inuse
            return None
        except urllib.error.HTTPError as exc:
            raise MihomoError(f"GET /memory -> HTTP {exc.code}") from None
        except (urllib.error.URLError, OSError, TimeoutError, ValueError,
                TypeError, http.client.HTTPException) as exc:
            reason = getattr(exc, "reason", exc)
            raise MihomoError(f"GET /memory failed: {reason}") from None

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
