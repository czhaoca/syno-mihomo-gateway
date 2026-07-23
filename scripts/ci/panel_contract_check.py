#!/usr/bin/env python3
"""Panel API contract gate: app/openapi.json is the COMMITTED contract of
the panel's HTTP surface, regenerated only via `python -m app.export_openapi`
(or this script's --write). Clone of the cli_contract_check.py shape:

Modes:
  bare     regenerate in memory, byte-diff against the committed copy, and
           run the live assertions below; exit non-zero on any drift.
  --write  regenerate app/openapi.json in place (the only sanctioned way
           to change it; never hand-edit).

Live assertions (bare mode):
  * the committed contract parses and matches a fresh export byte-for-byte;
  * the additive-only /v1 policy is stated in the spec's info.description
    (breaking = new version prefix + explicit owner acknowledgment);
  * every path is /health or versioned under /v1 — an unversioned surface
    could never honor the additive-only promise.
"""

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

CONTRACT = REPO / "app" / "openapi.json"
REGEN_CMD = "python3 scripts/ci/panel_contract_check.py --write"


def fail(msg: str):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    from app.export_openapi import render_openapi

    fresh = render_openapi()

    if "--write" in sys.argv[1:]:
        CONTRACT.write_text(fresh, encoding="utf-8")
        print(f"wrote {CONTRACT.relative_to(REPO)}")
        return

    if not CONTRACT.exists():
        fail(f"missing committed contract {CONTRACT.relative_to(REPO)} "
             f"(regenerate: {REGEN_CMD})")
    committed = CONTRACT.read_text(encoding="utf-8")
    if committed != fresh:
        fail("app/openapi.json is stale - the committed contract differs "
             f"from a fresh export (never hand-edit; run `{REGEN_CMD}` and "
             "commit; a REMOVED or renamed /v1 field is a breaking change "
             "needing a new version prefix + explicit owner sign-off)")

    doc = json.loads(committed)
    description = (doc.get("info") or {}).get("description") or ""
    if "additive-only" not in description:
        fail("the spec's info.description must state the additive-only /v1 "
             "policy (breaking = new version prefix + owner acknowledgment)")
    for path in (doc.get("paths") or {}):
        if path != "/health" and not path.startswith("/v1/"):
            fail(f"unversioned path {path!r}: every surface except /health "
                 f"must live under /v1 (the additive-only contract)")

    print("OK: panel contract is fresh - app/openapi.json regenerates "
          "byte-identical, states the additive-only /v1 policy, and every "
          "path is /health or /v1-versioned.")


if __name__ == "__main__":
    main()
