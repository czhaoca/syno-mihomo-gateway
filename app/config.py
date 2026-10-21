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


# --- stats knobs (PANEL_STATS_* family; .env.example rows land at
# Sequence 60). Invalid values fall back to the safe default - a stats
# knob typo must never take the panel down. ---

def _int_env(name: str, default: int, minimum: int = 0) -> int:
    raw = os.environ.get(name, "")
    try:
        return max(minimum, int(raw))
    except ValueError:
        return default


def stats_db_path() -> Path:
    return state_dir() / "stats.db"


# The collector's cadence (#94, DEC-A): 2 s, chosen by the epic's rule
# "2 s unless a poll costs more than 500 ms at the production connection
# count". The number it rests on is an ESTIMATE - a local Apple-silicon
# bench of the PRE-#94 flush (3.3 ms per poll at 573 connections, the
# measured busy count; the batched flush measures 1.8 ms there) scaled by
# an assumed 6-8x for the NAS's Celeron J4125 - until the
# collector's own poll timing (#96) is read on the NAS, which may move this
# back to 5 s before release. The one place the default lives.
STATS_POLL_DEFAULT_S = 2


def stats_poll_s() -> int:
    """0 disables the collector loop (tests drive poll_once directly)."""
    return _int_env("PANEL_STATS_POLL_S", STATS_POLL_DEFAULT_S)


def stats_minute_hours() -> int:
    return _int_env("PANEL_STATS_MINUTE_HOURS", 48, minimum=1)


def stats_hour_days() -> int:
    return _int_env("PANEL_STATS_HOUR_DAYS", 90, minimum=1)


def stats_day_days() -> int:
    return _int_env("PANEL_STATS_DAY_DAYS", 730, minimum=1)


def stats_cap_mb() -> int:
    return _int_env("PANEL_STATS_CAP_MB", 512)


# The node delay history's retention (#102 DEC-B): 14 days unless set,
# clamped to 7-30 - shorter would not show a week's pattern, longer keeps a
# history of airport node labels for no analytic gain.
NODE_DELAY_DAYS_DEFAULT = 14


def node_delay_days() -> int:
    return min(30, max(7, _int_env("PANEL_NODE_DELAY_DAYS",
                                   NODE_DELAY_DAYS_DEFAULT)))


def stats_domains() -> bool:
    """The opt-in per-domain table - OFF unless explicitly enabled."""
    return os.environ.get("PANEL_STATS_DOMAINS", "").lower() in (
        "1", "true", "yes")


def metrics() -> bool:
    """The Prometheus exposition at /metrics (#99) - OFF unless explicitly
    enabled; off, the path answers 404."""
    return os.environ.get("PANEL_METRICS", "").lower() in ("1", "true", "yes")


def full_proxy_sources() -> str:
    """The static band knob, for the UI's band_member badge. Compose wires
    it through at Sequence 60; unset (the norm until then) = no band."""
    return os.environ.get("FULL_PROXY_SOURCES", "")


def timezone_default() -> str:
    """The container's own TZ, which docker-compose already passes to the
    panel alongside mihomo and the updater (DEC-5). Deliberately NOT a zone
    written into this file: a panel that disagrees with the rest of the
    stack about what "today" means is a bug generator, and a baked-in
    default would silently be that disagreement on every install whose
    operator never opened the settings page.

    Blank falls back to UTC, which is the ABSENCE of a zone choice rather
    than a regional one - and is already what the minute and hour tiers
    store in (DEC-4), so an unconfigured panel stays self-consistent. The
    blank check matters because compose passes empty strings through for
    unset knobs, so "" must never become the effective value.
    """
    return os.environ.get("TZ", "").strip() or "UTC"


def dashboard_port() -> int:
    """MetaCubexD's published port for the UI deep-link (brief DEC-12:
    node ops stay on the dashboard). Default mirrors .env.example's
    WEB_UI_PORT; compose injects the real value at Sequence 60."""
    return _int_env("PANEL_DASHBOARD_PORT", 8080, minimum=1)
