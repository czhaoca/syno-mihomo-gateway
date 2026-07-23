"""Environment-driven configuration.

Every knob is read at call time (never cached at import) so tests and the
container entrypoint can set plain env vars. Defaults are neutral —
loopback or paths relative to GATEWAY_DATA_DIR; no real address ships in
code (CLAUDE.md rule).
"""

import os
from pathlib import Path

DEFAULT_BACKUP_KEEP = 5


def data_dir() -> Path:
    return Path(os.environ.get("GATEWAY_DATA_DIR", "./data"))


def state_dir() -> Path:
    return data_dir() / "state"


def db_path() -> Path:
    return state_dir() / "policy.db"


def marker_path() -> Path:
    return state_dir() / "panel-apply-failed"


def providers_dir() -> Path:
    override = os.environ.get("PANEL_PROVIDERS_DIR", "")
    if override:
        return Path(override)
    return data_dir() / "config" / "providers"


def panel_secret() -> str:
    return os.environ.get("PANEL_SECRET", "")


def mihomo_url() -> str:
    # blank == unset (the repo's env-knob convention: compose passes empty
    # strings through) — never let "" become a malformed request URL
    return (os.environ.get("PANEL_MIHOMO_URL", "")
            or "http://127.0.0.1:9090").rstrip("/")


def controller_secret() -> str:
    return os.environ.get("CONTROLLER_SECRET", "")


def webhook_url() -> str:
    return os.environ.get("NOTIFY_WEBHOOK_URL", "")


def backup_keep() -> int:
    raw = os.environ.get("PANEL_BACKUP_KEEP", "")
    try:
        return max(0, int(raw))
    except ValueError:
        return DEFAULT_BACKUP_KEEP


def gateway_ip() -> str:
    return os.environ.get("MIHOMO_IP", "")


def panel_ip() -> str:
    return os.environ.get("PANEL_IP", "")
