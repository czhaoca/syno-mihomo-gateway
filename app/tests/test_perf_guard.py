"""A loose wall-clock guard on the collector's flush (#94).

Not a benchmark: CI agents are shared and noisy, so the budget is ~10x what
the flush costs locally (3000 connections x 30 polls measured 0.28 s on an
Apple-silicon dev machine, JSON parse included). It catches a gross
regression - an O(N^2) shape, or a per-poll cost an order of magnitude up.
It does NOT catch a return to per-connection SQL: that pre-#94 flush is
O(N) indexed lookups and runs the same loop in ~0.5 s. The bounded
statement count is guarded by
`test_flush_bound.py::test_statement_count_does_not_grow_with_the_connection_count`.
Exact numbers come from the local-only `scripts/ci/panel_bench.py`.
"""

import json
import time
from datetime import UTC, datetime, timedelta

from app.store.stats import flush_poll, open_stats_db

CONNS = 3000
SNAPSHOTS = 30
BUDGET_S = 3.0


def _body(step):
    return json.dumps({"connections": [
        {"id": f"c{i}", "upload": 1000 * step + i, "download": 5000 * step + i,
         "metadata": {"sourceIP": f"192.0.2.{i % 50}",
                      "host": f"h{i % 300}.example.com", "sniffHost": ""},
         "chains": ["JP 01", "Routing Mode"], "rule": "GeoSite",
         "rulePayload": "example"} for i in range(CONNS)]})


def test_3000_connections_x_30_polls_stay_inside_the_budget(panel_env):
    conn = open_stats_db(panel_env["data"] / "state" / "stats.db")
    bodies = [_body(s + 1) for s in range(SNAPSHOTS)]  # built outside the clock
    t0 = datetime(2026, 10, 15, 12, tzinfo=UTC)
    try:
        start = time.perf_counter()
        for s, body in enumerate(bodies):
            now = (t0 + timedelta(seconds=2 * s)).strftime("%Y-%m-%dT%H:%M:%SZ")
            flush_poll(conn, json.loads(body)["connections"], now,
                       domains_enabled=False, gap_threshold_s=6, interval_s=2)
        elapsed = time.perf_counter() - start
        rows = conn.execute("SELECT COUNT(*) FROM conn_baseline").fetchone()[0]
    finally:
        conn.close()
    assert rows == CONNS
    assert elapsed < BUDGET_S, (
        f"{CONNS} connections x {SNAPSHOTS} polls took {elapsed:.2f}s "
        f"(budget {BUDGET_S}s) - has the flush gone back to per-connection SQL?")
