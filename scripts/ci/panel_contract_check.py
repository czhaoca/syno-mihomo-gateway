#!/usr/bin/env python3
"""Panel API contract gate: app/openapi.json is the COMMITTED contract of
the panel's HTTP surface, regenerated only via `python -m app.export_openapi`
(or this script's --write), and docs/panel-api.md is the human-readable
reference RENDERED from it (#69) - both are generated artifacts, never
hand-edited. Clone of the cli_contract_check.py shape:

Modes:
  bare     regenerate both in memory, byte-diff against the committed
           copies, and run the live assertions below; exit non-zero on any
           drift.
  --write  regenerate app/openapi.json AND docs/panel-api.md in place (the
           only sanctioned way to change either).

Live assertions (bare mode):
  * the committed contract parses and matches a fresh export byte-for-byte;
  * docs/panel-api.md matches a fresh render byte-for-byte;
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
API_MD = REPO / "docs" / "panel-api.md"
REGEN_CMD = "python3 scripts/ci/panel_contract_check.py --write"


def fail(msg: str):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def render_api_md(doc: dict) -> str:
    """Deterministic markdown reference rendered from the openapi doc -
    the same single source the byte-gate already freezes (EN-only by
    design: generated references have no hand-written zh twin)."""
    info = doc.get("info") or {}
    lines = [
        "# Panel HTTP API (generated)",
        "",
        f"<!-- GENERATED from app/openapi.json - never hand-edit. Regenerate: {REGEN_CMD} -->",
        "",
        f"Version {info.get('version', '?')}. "
        + " ".join((info.get("description") or "").split()),
        "",
        "Reads are open on the LAN; every mutation (POST/PATCH/DELETE) requires",
        "`Authorization: Bearer <PANEL_SECRET>` and is refused when the secret is",
        "unset - fail closed. All responses are JSON. The base URL is",
        "`http://<PANEL_IP>:<PANEL_PORT>` (default port 8090); prefer",
        "`gateway.sh policy` over raw calls for the policy surface.",
        "",
    ]
    for path in sorted(doc.get("paths") or {}):
        ops = doc["paths"][path]
        for method in ("get", "post", "patch", "delete", "put"):
            if method not in ops:
                continue
            op = ops[method]
            summary = (op.get("summary")
                       or (op.get("description") or "").strip().split("\n")[0])
            lines.append(f"## `{method.upper()} {path}`")
            lines.append("")
            if summary:
                lines.append(" ".join(summary.split()))
                lines.append("")
            params = [p.get("name", "?") for p in op.get("parameters", [])]
            if params:
                lines.append("Parameters: "
                             + ", ".join(f"`{p}`" for p in params))
                lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main():
    from app.export_openapi import render_openapi

    fresh = render_openapi()
    fresh_md = render_api_md(json.loads(fresh))

    if "--write" in sys.argv[1:]:
        CONTRACT.write_text(fresh, encoding="utf-8")
        API_MD.write_text(fresh_md, encoding="utf-8")
        print(f"wrote {CONTRACT.relative_to(REPO)} + {API_MD.relative_to(REPO)}")
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
    if not API_MD.exists():
        fail(f"missing generated reference {API_MD.relative_to(REPO)} "
             f"(regenerate: {REGEN_CMD})")
    if API_MD.read_text(encoding="utf-8") != fresh_md:
        fail("docs/panel-api.md is stale - it renders from app/openapi.json "
             f"(never hand-edit; run `{REGEN_CMD}` and commit)")

    doc = json.loads(committed)
    description = (doc.get("info") or {}).get("description") or ""
    if "additive-only" not in description:
        fail("the spec's info.description must state the additive-only /v1 "
             "policy (breaking = new version prefix + owner acknowledgment)")
    for path in (doc.get("paths") or {}):
        if path != "/health" and not path.startswith("/v1/"):
            fail(f"unversioned path {path!r}: every surface except /health "
                 f"must live under /v1 (the additive-only contract)")

    print("OK: panel contract is fresh - app/openapi.json + docs/panel-api.md "
          "regenerate byte-identical, the additive-only /v1 policy is stated, "
          "and every path is /health or /v1-versioned.")


if __name__ == "__main__":
    main()
