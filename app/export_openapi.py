"""Export the committed OpenAPI contract.

    python -m app.export_openapi [target]

Writes app/openapi.json (deterministic dump: sorted keys, 2-space indent,
trailing newline). This is the ONLY sanctioned way to change the committed
contract; scripts/ci/panel_contract_check.py fails on any drift.
"""

import json
import sys
from pathlib import Path

from app.main import create_app

DEFAULT_TARGET = Path(__file__).resolve().parent / "openapi.json"


def render_openapi() -> str:
    schema = create_app().openapi()
    return json.dumps(schema, indent=2, sort_keys=True,
                      ensure_ascii=False) + "\n"


def export(target: Path) -> None:
    target.write_text(render_openapi(), encoding="utf-8")


if __name__ == "__main__":
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_TARGET
    export(target)
    print(f"wrote {target}")
