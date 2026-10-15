#!/usr/bin/env python3
"""Every CI step image in .woodpecker.yml must be pinned by digest.

A step image named by tag alone (`python:3.12-slim`, `alpine:3.22`,
`koalaman/shellcheck-alpine:stable`) is whatever the registry serves TODAY. A
registry-side tag move can turn a green commit red - or red green - with no
diff in this repo, and nobody can reproduce "the build that was tested". The
`ui-e2e` step argued this first for its browser image (the Playwright image
pins the browser build alongside the Playwright version); this gate makes the
rule hold for every step, its own included.

Accepted form - the tag STAYS so a reviewer can read what the digest is:

    image: python:3.12-slim@sha256:<64 lowercase hex>

Three rules, each with its own failure line:

  * every step image is `<name>:<tag>@sha256:<64 hex>` - a digest-only ref
    (`alpine@sha256:...`) is a valid pull ref but hides what it is, so it is
    refused; a registry port (`host:5000/img`) is not a tag;
  * one `name:tag` maps to ONE digest across the file - a half-done bump that
    rewrote some lines but not others must not pass;
  * the file carries at least one step image - zero refs means a mis-parsed
    pipeline, never a clean one.

Resolve a digest (the multi-arch manifest-list digest - what the engine pulls
on any architecture), then bump every line that names that tag:

    docker buildx imagetools inspect <name:tag> --format '{{.Manifest.Digest}}'

Refresh procedure: docs/development.md, "Refreshing CI image digests".

Mirrors scripts/ci/compose_policy_check.py: offenders listed, exit 1; prints
OK: on pass. Parses the YAML only - no network, no docker (CI step containers
stay plain daemonless images). Needs PyYAML. An optional path argument points
the gate at another pipeline file (the test's fixtures).
"""
import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
PIPELINE = REPO / ".woodpecker.yml"

# <name[:tag]>@sha256:<64 lowercase hex>. The name part must be non-empty and
# must not contain '@' or interior whitespace, so a bare `@sha256:...` (no
# name) or a second '@' is rejected. Surrounding whitespace is trimmed first
# (a quoted YAML scalar may carry it); the tag requirement is checked
# separately by tag_of().
PINNED = re.compile(r"^[^@\s]+@sha256:[0-9a-f]{64}$")


def steps_of(doc):
    """[(step name, step spec)] for either Woodpecker `steps:` syntax.

    The real pipeline uses the list form (`- name: x`); older/fixture
    pipelines (scripts/ci/package_check.py's throwaway repo) use the mapping
    form (`x:`). Both are valid Woodpecker, so the gate reads both. Entries
    that are not mappings carry no image and are skipped, never a crash.
    """
    steps = (doc if isinstance(doc, dict) else {}).get("steps") or []
    if isinstance(steps, dict):
        return [(str(name), spec if isinstance(spec, dict) else {})
                for name, spec in steps.items()]
    if not isinstance(steps, list):
        return []
    return [(str(spec.get("name", f"#{i}")) if isinstance(spec, dict) else f"#{i}",
             spec if isinstance(spec, dict) else {})
            for i, spec in enumerate(steps)]


def tag_of(ref):
    """The `name:tag` part of a pinned ref, or None when it carries no tag.

    The tag is the ':' AFTER the last '/', so `localhost:5000/alpine@...`
    (a registry port, no tag) yields None while `host:5000/alpine:3.22@...`
    yields `host:5000/alpine:3.22`.
    """
    name = ref.split("@", 1)[0]
    return name if ":" in name.rsplit("/", 1)[-1] else None


def images_of(doc):
    """[(step name, image ref)] for every step that declares an image."""
    out = []
    for name, spec in steps_of(doc):
        img = spec.get("image")
        if img is not None:
            out.append((name, str(img).strip()))
    return out


def offenders(doc):
    """Failure lines for everything in `doc` that breaks the three rules."""
    bad = []
    images = images_of(doc)
    if not images:
        bad.append("no step images found - a pipeline with nothing to pin is a "
                   "mis-parsed pipeline, not a clean one")
        return bad
    by_tag = {}
    for name, img in images:
        if not PINNED.match(img):
            bad.append(f"step {name}: {img} is not pinned by digest - want "
                       f"<name:tag>@sha256:<64 hex>")
            continue
        tag = tag_of(img)
        if tag is None:
            bad.append(f"step {name}: {img} has no tag before the digest - keep "
                       f"<name:tag> beside @sha256 so a reviewer can read what it is")
            continue
        by_tag.setdefault(tag, {}).setdefault(img.split("@", 1)[1], []).append(name)
    for tag, digests in by_tag.items():
        if len(digests) > 1:
            where = "; ".join(f"{d[:19]}... in {', '.join(names)}"
                              for d, names in digests.items())
            bad.append(f"{tag} is pinned to {len(digests)} different digests "
                       f"({where}) - a bump must rewrite every line naming the tag")
    return bad


def check(path):
    path = Path(path)
    doc = yaml.safe_load(path.read_text())
    bad = offenders(doc)
    if bad:
        for line in bad:
            print(f"FAIL: {line} (resolve with: docker buildx imagetools inspect "
                  f"<name:tag> --format '{{{{.Manifest.Digest}}}}'; see "
                  f"docs/development.md 'Refreshing CI image digests')")
        return 1
    images = images_of(doc)
    distinct = sorted({img for _, img in images})
    print(f"OK: every CI step image in {path.name} is pinned by digest "
          f"({len(images)} image refs, {len(distinct)} distinct, one digest per "
          f"tag, tag kept beside each)")
    return 0


def main(argv):
    path = Path(argv[1]) if len(argv) > 1 else PIPELINE
    return check(path)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
