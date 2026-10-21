#!/usr/bin/env python3
"""Local-only flush benchmark for the panel's stats collector (#94).

NOT a CI step: wall-clock numbers on a shared CI agent are noise. CI runs a
loose pytest guard instead (app/tests/test_perf_guard.py, 10x headroom); this
script prints the exact numbers on the machine you run it on.

It drives the real `flush_poll` (one SQLite transaction per poll, the same
code the collector runs) against a throwaway stats.db with a synthetic
/connections payload - TEST-NET addresses and example.com hosts only - and
reports per-poll time including the JSON parse of the payload, which is what
the collector pays for every poll after the HTTP fetch.

Usage (from the repo root, in the panel's venv - see docs/development.md):
    python3 scripts/ci/panel_bench.py --conns 3000 --snapshots 30
    python3 scripts/ci/panel_bench.py --conns 573 --idle 0.8   # 80% idle flows
"""

import argparse
import json
import sys
import tempfile
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from app.store.stats import flush_poll, open_stats_db


def payload(n: int, step: int, idle: float) -> str:
    """A /connections body; the first `idle` share of flows never move."""
    frozen = int(n * idle)
    conns = []
    for i in range(n):
        grow = 0 if i < frozen else step
        conns.append({
            "id": f"c{i}", "upload": 1000 * grow + i, "download": 5000 * grow + i,
            "metadata": {"sourceIP": f"192.0.2.{i % 50}",
                         "host": f"h{i % 300}.example.com", "sniffHost": "",
                         "network": "tcp", "type": "Tun"},
            "chains": ["JP 01", "Routing Mode"], "rule": "GeoSite",
            "rulePayload": "example"})
    return json.dumps({"connections": conns})


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--conns", type=int, default=3000)
    ap.add_argument("--snapshots", type=int, default=30)
    ap.add_argument("--idle", type=float, default=0.0,
                    help="share of flows whose counters never move (0..1)")
    ap.add_argument("--interval", type=int, default=2)
    args = ap.parse_args(argv)
    with tempfile.TemporaryDirectory() as td:
        conn = open_stats_db(Path(td) / "bench.db")
        t0 = datetime(2026, 10, 15, 12, tzinfo=UTC)
        times = []
        for s in range(args.snapshots):
            body = payload(args.conns, s + 1, args.idle)
            now = (t0 + timedelta(seconds=args.interval * s)).strftime(
                "%Y-%m-%dT%H:%M:%SZ")
            start = time.perf_counter()
            flush_poll(conn, json.loads(body)["connections"], now,
                       domains_enabled=False,
                       gap_threshold_s=3 * args.interval,
                       interval_s=args.interval)
            times.append(time.perf_counter() - start)
        wal = Path(td) / "bench.db-wal"
        wal_bytes = wal.stat().st_size if wal.exists() else 0
        conn.close()
    times.sort()
    ms = [1000 * t for t in times]
    print(f"conns={args.conns} snapshots={args.snapshots} idle={args.idle:.0%}: "
          f"median {ms[len(ms) // 2]:.1f} ms, p90 {ms[int(len(ms) * 0.9)]:.1f} ms, "
          f"max {ms[-1]:.1f} ms per poll (JSON parse + flush); "
          f"total {sum(ms):.0f} ms; WAL {wal_bytes / 1024:.0f} KiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
