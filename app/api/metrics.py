"""The Prometheus exposition at root `/metrics` (#99, brief DEC-11/12).

Served only with PANEL_METRICS on (404 otherwise), LAN-open like every
other read, rendered by hand in the text format 0.0.4 - no new dependency.
The label set is an API, fixed here before any scraper exists:
  - one counter family per dimension of the long-term class (DEC-A), its
    value in one label plus `direction` (`up`/`down`), counted since the
    panel started (DEC-B: in memory, reset by a restart);
  - the collector's own gauges, mirroring the flat `/health` keys.
No label ever carries a hostname, sniffed name, ASN, destination port or
app-level id: `render` refuses any label name outside LABELS.
"""

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response

from app import config
from app.api import routes

router = APIRouter()

CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

# Every label name the exposition may carry (the allowlist a test pins).
LABELS = frozenset({"device", "group", "exit", "rule_type", "category",
                    "country", "direction", "mihomo_version"})

# family -> (metric name, value label, help)
COUNTERS = {
    "device": ("insights_device_bytes_total", "device",
               "Bytes per LAN device (gateway = mihomo's own traffic)"),
    "group": ("insights_group_bytes_total", "group",
              "Bytes per policy group (the last chain)"),
    "exit": ("insights_exit_bytes_total", "exit",
             "Bytes per exit node (the first chain)"),
    "rule": ("insights_rule_bytes_total", "rule_type",
             "Bytes per rule type"),
    "category": ("insights_category_bytes_total", "category",
                 "Bytes per coarse category (unknown = unattributed)"),
    "country": ("insights_country_bytes_total", "country",
                "Bytes per destination country"),
}

# Prometheus reads an empty label value as the label being absent, so a
# stored "" is written as a fixed placeholder (DEC-C): the category value
# counted without a dictionary keeps the coverage report's name for it.
EMPTY = {"category": "no_dictionary"}
EMPTY_DEFAULT = "none"


def label_value(family: str, value: str) -> str:
    return value if value != "" else EMPTY.get(family, EMPTY_DEFAULT)


def _escape_label(value: str) -> str:
    return (value.replace("\\", "\\\\").replace("\n", "\\n")
            .replace('"', '\\"'))


def _escape_help(text: str) -> str:
    return text.replace("\\", "\\\\").replace("\n", "\\n")


def _number(value) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, float):
        return repr(value)
    return str(int(value))


def render(families: list) -> str:
    """The text format for FAMILIES: [(name, type, help, [(labels, value)])].
    A family with no samples is still declared, so a scraper sees every
    name; a sample whose value is None ("not measured") is left out."""
    lines = []
    for name, kind, text, samples in families:
        lines.append(f"# HELP {name} {_escape_help(text)}")
        lines.append(f"# TYPE {name} {kind}")
        for labels, value in samples:
            if value is None:
                continue
            bad = sorted(set(labels) - LABELS)
            if bad:
                raise ValueError(f"label(s) {bad} are not in the allowlist")
            body = ",".join(f'{k}="{_escape_label(str(v))}"'
                            for k, v in labels.items())
            lines.append(f"{name}{{{body}}} {_number(value)}" if body
                         else f"{name} {_number(value)}")
    return "\n".join(lines) + "\n"


def _counter_families(snapshot: dict) -> list:
    families = []
    for family, (name, label, text) in COUNTERS.items():
        # values that render alike (an empty value and a real `none`) are
        # one series: the text format allows no duplicate
        shown: dict = {}
        for value, (up, down) in snapshot.get(family, {}).items():
            acc = shown.setdefault(label_value(family, value), [0, 0])
            acc[0] += up
            acc[1] += down
        samples = []
        for value, (up, down) in sorted(shown.items()):
            samples.append(({label: value, "direction": "up"}, up))
            samples.append(({label: value, "direction": "down"}, down))
        families.append((name, "counter", text + ", since the panel started",
                         samples))
    return families


def _gauge_families(health: dict) -> list:
    """The collector's own numbers, from the very values `/health` reports
    (None = not measured: no sample), in base units (bytes, seconds)."""
    def scaled(key, factor):
        value = health.get(key)
        return None if value is None else value * factor

    def gauge(name, text, value, kind="gauge"):
        return (name, kind, text, [({}, value)])

    families = [
        gauge("insights_collector_up",
              "1 when the collector's last poll is fresh, else 0",
              health.get("collector") == "ok"),
        gauge("insights_collector_lag_seconds",
              "Seconds since the collector's last successful poll",
              health.get("collector_lag_s")),
        gauge("insights_collector_poll_seconds",
              "Mean duration of the last successful polls",
              scaled("collector_poll_ms", 0.001)),
        gauge("insights_collector_connections",
              "Connections in mihomo's last snapshot",
              health.get("collector_conns")),
        gauge("insights_collector_failed_polls_total",
              "Polls that failed since the panel started",
              health.get("collector_failed_polls"), kind="counter"),
        gauge("insights_collector_interval_seconds",
              "The poll interval the collector runs with",
              health.get("collector_interval_s")),
        gauge("insights_stats_db_bytes", "Size of stats.db with its WAL",
              health.get("stats_db_bytes")),
        gauge("insights_stats_cap_bytes", "The stats.db size cap",
              scaled("stats_cap_mb", 1024 * 1024)),
        gauge("insights_stats_db_growth_bytes_per_day",
              "stats.db growth over the last day of gauges",
              scaled("stats_db_growth_mb_day", 1024 * 1024)),
        gauge("insights_mihomo_memory_bytes",
              "mihomo's own reported memory in use (to the MiB)",
              scaled("mihomo_mem_mb", 1024 * 1024)),
    ]
    version = health.get("mihomo_version") or ""
    families.append(("insights_mihomo_info", "gauge",
                     "The running mihomo version (value always 1)",
                     [({"mihomo_version": version}, 1)] if version else []))
    return families


@router.get("/metrics", response_class=Response, responses={
    200: {"content": {"text/plain; version=0.0.4": {
        "schema": {"type": "string"}}},
        "description": "The Prometheus text exposition"},
    404: {"description": "PANEL_METRICS is off"}})
def metrics(request: Request):
    """Prometheus text exposition (format 0.0.4), only with
    `PANEL_METRICS=true` - 404 otherwise. Open on the LAN like every read:
    never expose the panel to the WAN.

    Counters, since the panel started (a restart resets them):
    `insights_device_bytes_total{device,direction}`,
    `insights_group_bytes_total{group,direction}`,
    `insights_exit_bytes_total{exit,direction}`,
    `insights_rule_bytes_total{rule_type,direction}`,
    `insights_category_bytes_total{category,direction}`,
    `insights_country_bytes_total{country,direction}` - `direction` is
    `up` or `down`. An empty value is written `no_dictionary` (category,
    bytes counted without a dictionary) or `none` (anything else, e.g. a
    flow no rule decided). Gauges mirror `/health`: `insights_collector_*`,
    `insights_stats_*`, `insights_mihomo_*`. No label carries a hostname,
    sniffed name, ASN, port or app-level id."""
    if not config.metrics():
        raise HTTPException(status_code=404,
                            detail="metrics are off: set PANEL_METRICS=true")
    collector = getattr(request.app.state, "collector", None)
    counters = getattr(collector, "counters", None)
    snapshot = counters.snapshot() if counters is not None else {}
    body = render(_counter_families(snapshot)
                  + _gauge_families(routes.health(request)))
    return Response(content=body, media_type=CONTENT_TYPE)
