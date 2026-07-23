"""SQLite -> provider-file -> controller reconciliation.

The #63 write contract: providers/dyn-full-direct.txt + dyn-full-tunnel.txt
(classical text, one `SRC-IP-CIDR,<cidr>` line per device). Every apply
re-writes both files atomically (tmp + rename in the same directory — this
is also what guarantees the files EXIST: mihomo treats an absent file as
empty without creating it), refreshes both providers over the controller
API, and verifies count-parity by reading the provider table back. Any
failure is LOUD: parity=failed in /health, a persistent marker in the data
dir, and one webhook notification (the scripts/lib/notify.sh {title,body}
contract) — never a silent drift.
"""

import os
from datetime import UTC, datetime
from pathlib import Path

from app.mihomo_client.client import MihomoError

# provider name -> file name (the #63 contract; never rename)
PROVIDER_FILES = {
    "dyn-full-direct": "dyn-full-direct.txt",
    "dyn-full-tunnel": "dyn-full-tunnel.txt",
}
# store mode -> provider name
MODE_TO_PROVIDER = {
    "full-direct": "dyn-full-direct",
    "full-tunnel": "dyn-full-tunnel",
}


def render_payload(cidrs: list) -> str:
    """Classical-text payload from CANONICAL cidrs only (the validation
    layer is the sole producer of these strings — no raw input ever)."""
    return "".join(f"SRC-IP-CIDR,{cidr}\n" for cidr in cidrs)


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


class Reconciler:
    def __init__(self, *, client, providers_dir: Path, marker_path: Path,
                 notifier=None):
        self.client = client
        self.providers_dir = Path(providers_dir)
        self.marker_path = Path(marker_path)
        self.notifier = notifier
        self.status = {"parity": "unknown", "last_apply": None,
                       "last_error": None}

    # -- loud-failure plumbing ------------------------------------------------
    def _fail(self, reason: str) -> None:
        self.status["parity"] = "failed"
        self.status["last_error"] = reason
        try:
            self.marker_path.parent.mkdir(parents=True, exist_ok=True)
            self.marker_path.write_text(f"time: {_now()}\nreason: {reason}\n")
        except OSError:
            pass  # the marker is best-effort; /health still carries the state
        if self.notifier is not None:
            try:
                self.notifier("Gateway panel: policy apply FAILED",
                              f"{reason} - device policy on the gateway may "
                              f"be stale; see /health and the "
                              f"panel-apply-failed marker in the data dir")
            except Exception:  # noqa: BLE001 - best-effort loud channel:
                pass  # a broken notifier must never kill fail-static

    def _clear_marker(self) -> None:
        try:
            self.marker_path.unlink(missing_ok=True)
        except OSError:
            pass

    # -- the apply loop -------------------------------------------------------
    def _write_provider(self, filename: str, content: str) -> None:
        self.providers_dir.mkdir(parents=True, exist_ok=True)
        tmp = self.providers_dir / f".{filename}.tmp"
        tmp.write_text(content)
        os.replace(tmp, self.providers_dir / filename)

    def apply(self, desired: dict) -> bool:
        """DESIRED: mode -> [canonical cidr]. Returns True on verified
        parity; False (loud) on any write/refresh/parity failure."""
        expected = {}
        try:
            for mode, provider in MODE_TO_PROVIDER.items():
                cidrs = desired.get(mode) or []
                self._write_provider(PROVIDER_FILES[provider],
                                     render_payload(cidrs))
                expected[provider] = len(cidrs)
        except OSError as exc:
            self._fail(f"provider file write failed: {exc}")
            return False
        try:
            for provider in MODE_TO_PROVIDER.values():
                self.client.refresh_provider(provider)
        except MihomoError as exc:
            self._fail(f"controller refresh failed: {exc}")
            return False
        except Exception as exc:  # noqa: BLE001 - last-resort net: apply()
            # is called unguarded at every boot and mutation; an exception
            # class the client failed to wrap must still degrade to the
            # loud fail-static path, never crash the lifespan.
            self._fail(f"controller refresh failed "
                       f"({exc.__class__.__name__}): {exc}")
            return False
        try:
            counts = self.client.provider_rule_counts()
        except MihomoError as exc:
            self._fail(f"controller read-back failed: {exc}")
            return False
        except Exception as exc:  # noqa: BLE001 - same last-resort net
            self._fail(f"controller read-back failed "
                       f"({exc.__class__.__name__}): {exc}")
            return False
        for provider, want in expected.items():
            got = counts.get(provider)
            if got != want:
                self._fail(
                    f"count parity failed for {provider}: mihomo loaded "
                    f"{got!r}, expected {want}")
                return False
        self.status["parity"] = "ok"
        self.status["last_apply"] = _now()
        self.status["last_error"] = None
        self._clear_marker()
        return True
