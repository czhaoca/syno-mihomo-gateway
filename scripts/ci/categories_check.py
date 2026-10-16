#!/usr/bin/env python3
"""Category dictionary gate (#97): the committed files under
app/store/categories/ are exactly what scripts/ci/categories_regen.py
generates, and they stay within DEC-C's bounds. Offline - CI never fetches
the upstream geosite source.

What it proves, and what it cannot:
  * coarse.json is byte-identical to the regen script's render of its
    curated table - a full regeneration, no upstream needed;
  * suffixes.json is in the committed serialization, its header names the
    pinned upstream ref, licence and curated table, and its payload digest
    matches - so a hand edit fails unless the digest is forged too;
  * UPSTREAM-LICENSE matches the digest the header recorded;
  * bounds: at most MAX_IDS ids, MAX_RULES rules, MAX_BYTES bytes;
  * totality: every id is curated, has a coarse id inside the enum, and owns
    at least one rule; every coarse id is used; the enum holds neither
    sentinel ("" = no dictionary, "unknown" = no answer); every name is a
    hostname held by exactly one id.
Re-deriving suffixes.json byte for byte needs the upstream tree, so it is a
development-time step: `python3 scripts/ci/categories_regen.py`.
"""

import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import categories_regen as regen

SENTINELS = ("", "unknown")


def problems(directory: Path = regen.OUT_DIR) -> list:
    """Every way the files in DIRECTORY fall short; [] when they pass."""
    directory = Path(directory)
    found = []
    try:
        coarse_text = (directory / "coarse.json").read_text(encoding="utf-8")
        suffix_text = (directory / "suffixes.json").read_text(encoding="utf-8")
        license_text = (directory / "UPSTREAM-LICENSE").read_text(
            encoding="utf-8")
        doc = json.loads(suffix_text)
        header, ids = doc["header"], doc["ids"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return [f"unreadable: {exc.__class__.__name__}: {exc}"]
    if coarse_text != regen.render_coarse():
        found.append("coarse.json differs from the regen script's curated "
                     "table")
    if suffix_text != regen.render(doc):
        found.append("suffixes.json is not in the committed serialization")
    expected = {"upstream": regen.UPSTREAM,
                "upstream_ref": regen.UPSTREAM_REF,
                "upstream_license": regen.UPSTREAM_LICENSE,
                "curated_sha256": regen.curated_digest()}
    for key, value in expected.items():
        if header.get(key) != value:
            found.append(f"suffixes.json header {key} is not {value!r}")
    if header.get("payload_sha256") != regen.digest(ids):
        found.append("suffixes.json payload does not match its digest "
                     "(hand-edited?)")
    if header.get("upstream_license_sha256") != hashlib.sha256(
            license_text.encode()).hexdigest():
        found.append("UPSTREAM-LICENSE does not match the recorded digest")
    rules = sum(len(v) for entry in ids.values() for v in entry.values())
    if header.get("ids") != len(ids) or header.get("rules") != rules:
        found.append("suffixes.json header counts disagree with its payload")
    if len(ids) > regen.MAX_IDS:
        found.append(f"{len(ids)} ids, over the bound of {regen.MAX_IDS}")
    if rules > regen.MAX_RULES:
        found.append(f"{rules} rules, over the bound of {regen.MAX_RULES}")
    size = len(suffix_text.encode())
    if size > regen.MAX_BYTES:
        found.append(f"suffixes.json is {size} bytes, over the bound of "
                     f"{regen.MAX_BYTES}")
    if set(ids) != set(regen.CURATED):
        found.append("suffixes.json ids differ from the curated table")
    if len(set(regen.COARSE)) != len(regen.COARSE):
        found.append("the coarse enum repeats an id")
    for sentinel in SENTINELS:
        if sentinel in regen.COARSE:
            found.append(f"the coarse enum holds the sentinel {sentinel!r}")
    unknown = sorted(c for c in regen.CURATED.values()
                     if c not in regen.COARSE)
    if unknown:
        found.append(f"coarse ids outside the enum: {unknown}")
    unused = sorted(set(regen.COARSE) - set(regen.CURATED.values()))
    if unused:
        found.append(f"coarse ids no geosite id maps to: {unused}")
    owner: dict = {}
    for app, kinds in ids.items():
        if set(kinds) != set(regen.KINDS):
            found.append(f"{app!r} entry kinds are {sorted(kinds)}")
            continue
        if not any(kinds.values()):
            found.append(f"{app!r} owns no rule")
        for kind, names in kinds.items():
            if names != sorted(set(names)):
                found.append(f"{app!r} {kind} names are not sorted and "
                             f"unique")
            for name in names:
                if not regen.is_hostname(name):
                    found.append(f"{app!r} {kind} entry is not a hostname")
                if owner.setdefault((kind, name), app) != app:
                    found.append(f"{kind} name held by both {app!r} and "
                                 f"{owner[(kind, name)]!r}")
    return found


def main() -> int:
    found = problems()
    for problem in found:
        print(f"FAIL: {problem}", file=sys.stderr)
    if found:
        print(f"regenerate with {regen.REGEN_CMD} (never hand-edit)",
              file=sys.stderr)
        return 1
    print("categories: dictionary files match the regen script and its "
          "bounds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
