"""stats.db - the persistent traffic store (brief DEC-8: a separate file
from policy.db, same PRAGMA discipline via the shared opener).

Delta accounting: per-connection cumulative counters diffed against the
persisted conn_baseline; the baseline update, the minute-bucket upserts,
the meta last-poll stamp, and any gap row land in ONE transaction, so a
collector restart can never double-count and a crash mid-flush loses the
whole poll, never half of it. Tiers roll minute -> hour -> day with
per-tier retention, a hard size cap prunes oldest-tier-first (batched
deletes + incremental vacuum + WAL checkpoint), and the opt-in per-domain
table carries a FORCED 7-day retention no knob can extend. Collector
downtime becomes explicit stats_gap rows - never interpolated (the
auto_update.sh counts-header honesty style).
"""

# A package since #93: the one 860-line module became schema / ingest /
# maintain / read / window / coverage. Every name callers used is re-exported
# here, so `from app.store import stats as stats_store` keeps working, and so
# does patching a name a CALLER looks up on this package at call time (e.g.
# `monkeypatch.setattr(collector_core.stats_store, "rollup", ...)`). A patch
# here does NOT reach calls made between the submodules - they bind each
# other's names directly - so patch the submodule that makes the call.

from app.store.stats.breakdown import (
    BREAKDOWN_DIMS,
    CLASS_DIMS,
    LIMIT_MAX,
    SORTS,
    Window,
    category_class,
    read_breakdown,
)
from app.store.stats.coverage import (
    coverage_report,
    coverage_rules,
    dictionary_report,
    read_coverage,
)
from app.store.stats.ingest import PAYLOAD_RULES, flush_poll
from app.store.stats.maintain import _CAP_TIERS, enforce_cap, purge_stats, rollup
from app.store.stats.overview import INVISIBLE_TRAFFIC_HINT, read_overview
from app.store.stats.read import (
    _TIER_TABLES,
    day_framings,
    dimension_tables,
    read_dimension,
    read_domains,
    read_gaps,
    read_grouped,
    read_timeline,
)
from app.store.stats.schema import (
    APP_TABLE,
    CLASS_TABLES,
    COVERAGE_CLASSES,
    DICTIONARY_CLASSES,
    DIMENSION_TABLES,
    DIMENSIONS,
    DOMAIN_RETENTION_DAYS,
    GATEWAY_DEVICE,
    KLASS_HOSTNAME,
    KLASS_IP_ONLY,
    MINUTE_TABLE,
    NO_DICTIONARY,
    PURGE_TABLES,
    SELF_TABLE,
    STATS_MIGRATIONS,
    UNATTRIBUTED,
    UNKNOWN,
    _db_bytes,
    _fmt_ts,
    _parse_ts,
    fold_legacy_minutes,
    meta_get,
    open_stats_db,
)
from app.store.stats.self import read_self, record_self, self_growth_mb_day
from app.store.stats.window import (
    RANGE_SPECS,
    range_window,
    read_window_dimension,
    read_window_grouped,
    read_window_timeline,
    window_framings,
    window_key,
)

__all__ = [
    "APP_TABLE",
    "BREAKDOWN_DIMS",
    "CLASS_DIMS",
    "CLASS_TABLES",
    "COVERAGE_CLASSES",
    "DICTIONARY_CLASSES",
    "DIMENSIONS",
    "DIMENSION_TABLES",
    "DOMAIN_RETENTION_DAYS",
    "GATEWAY_DEVICE",
    "INVISIBLE_TRAFFIC_HINT",
    "KLASS_HOSTNAME",
    "KLASS_IP_ONLY",
    "LIMIT_MAX",
    "MINUTE_TABLE",
    "NO_DICTIONARY",
    "PAYLOAD_RULES",
    "PURGE_TABLES",
    "RANGE_SPECS",
    "SELF_TABLE",
    "SORTS",
    "STATS_MIGRATIONS",
    "UNATTRIBUTED",
    "UNKNOWN",
    "_CAP_TIERS",
    "_TIER_TABLES",
    "Window",
    "_db_bytes",
    "_fmt_ts",
    "_parse_ts",
    "category_class",
    "coverage_report",
    "coverage_rules",
    "day_framings",
    "dictionary_report",
    "dimension_tables",
    "enforce_cap",
    "flush_poll",
    "fold_legacy_minutes",
    "meta_get",
    "open_stats_db",
    "purge_stats",
    "range_window",
    "read_breakdown",
    "read_coverage",
    "read_dimension",
    "read_domains",
    "read_gaps",
    "read_grouped",
    "read_overview",
    "read_self",
    "read_timeline",
    "read_window_dimension",
    "read_window_grouped",
    "read_window_timeline",
    "record_self",
    "rollup",
    "self_growth_mb_day",
    "window_framings",
    "window_key",
]
