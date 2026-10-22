"""Minimal mihomo external-controller client (stdlib urllib — the runtime
dependency set is fastapi + uvicorn only, by constraint).

The reconciler's two calls (refresh one rule provider, read back the
provider table for count-parity), the collector's /connections snapshot,
the version and memory reads its telemetry samples (#96), and since #102
the /traffic stream the live relay forwards plus the group, proxy history
and proxy provider reads the sampler takes. The controller secret rides
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
# /traffic streams a frame a second: a read that waits this long for the
# next one means the stream is dead, not slow
TRAFFIC_TIMEOUT_S = 5

# a version string is shown by the doctor's flat sed extractor and the
# release validator: keep it to characters neither can mistake for syntax
_VERSION_OK = re.compile(r"[^A-Za-z0-9._+-]")


class MihomoError(RuntimeError):
    """Controller call failed; the message never carries the secret.
    `status` is the HTTP status when the controller answered one."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


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
                f"{method} {path} -> HTTP {exc.code}", status=exc.code) from None
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

    def traffic_frames(self):
        """mihomo's aggregate throughput from the GET /traffic STREAM: one
        (up, down) bytes-per-second pair a second, until the stream ends or
        the caller stops iterating (the response is closed either way).

        Without a WebSocket upgrade mihomo writes the frames as JSON lines,
        exactly as it does for /memory; each line read is bounded in size and
        in time (TRAFFIC_TIMEOUT_S). A line that is not two non-negative
        numbers yields None - never a zero frame, but still a tick, so a
        caller can stop on a stream whose every line is unreadable."""
        url = f"{self.base_url}/traffic"
        try:
            req = urllib.request.Request(url, method="GET")
            if self._secret:
                req.add_header("Authorization", f"Bearer {self._secret}")
            resp = urllib.request.urlopen(req, timeout=TRAFFIC_TIMEOUT_S)
        except urllib.error.HTTPError as exc:
            raise MihomoError(f"GET /traffic -> HTTP {exc.code}") from None
        except (urllib.error.URLError, OSError, TimeoutError, ValueError,
                http.client.HTTPException) as exc:
            reason = getattr(exc, "reason", exc)
            raise MihomoError(f"GET /traffic failed: {reason}") from None
        try:
            while True:
                try:
                    line = resp.readline(_FRAME_BYTES)
                except (OSError, TimeoutError, ValueError,
                        http.client.HTTPException) as exc:
                    raise MihomoError(f"GET /traffic stream broke: {exc}") from None
                if not line:
                    return
                yield _rate_pair(line)
        finally:
            resp.close()

    def groups(self) -> list:
        """Every proxy group from GET /group - name, type and the member it
        has selected now (`now`)."""
        doc = self._json("/group", timeout=TELEMETRY_TIMEOUT_S)
        groups = doc.get("proxies") if isinstance(doc, dict) else None
        return [g for g in groups if isinstance(g, dict)] if isinstance(
            groups, list) else []

    def proxy_history(self, name: str) -> list:
        """The delay history mihomo keeps for one proxy (or group), from
        GET /proxies/<name> - its own health-check results, oldest first.
        A provider's node is not a /proxies entry (404): it has no history
        here, which is not a failure - its history is in proxy_providers()."""
        try:
            doc = self._json(f"/proxies/{urllib.parse.quote(name, safe='')}",
                             timeout=TELEMETRY_TIMEOUT_S)
        except MihomoError as exc:
            if exc.status == 404:
                return []
            raise
        history = doc.get("history") if isinstance(doc, dict) else None
        return [h for h in history if isinstance(h, dict)] if isinstance(
            history, list) else []

    def proxy_providers(self) -> dict:
        """name -> entry from GET /providers/proxies. An entry carries the
        provider's whole node list as well as its subscriptionInfo: callers
        copy the fields they need and keep nothing else."""
        doc = self._json("/providers/proxies", timeout=TELEMETRY_TIMEOUT_S)
        providers = doc.get("providers") if isinstance(doc, dict) else None
        return {k: v for k, v in providers.items() if isinstance(v, dict)} if (
            isinstance(providers, dict)) else {}

    def _json(self, path: str, timeout: float):
        raw = self._request("GET", path, timeout=timeout)
        try:
            return json.loads(raw)
        except ValueError as exc:
            raise MihomoError(f"GET {path} returned unparseable JSON") from exc


def _rate_pair(line: bytes):
    """(up, down) from one /traffic line, or None when it is not a frame."""
    if not line.strip():
        return None
    try:
        doc = json.loads(line)
    except ValueError:
        return None
    if not isinstance(doc, dict):
        return None
    pair = []
    for key in ("up", "down"):
        value = doc.get(key)
        # NaN and infinity parse as JSON numbers; neither is a rate
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not (
                0 <= value < float("inf")):
            return None
        pair.append(int(value))
    return pair[0], pair[1]
