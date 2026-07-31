#!/usr/bin/env python3
"""Build gate for the panel frontend (#78).

Two things can only be checked against the BUILT artifact, which is why this
is a separate script rather than a pytest:

1. The A6 release marker. `validate_release.sh:548` greps
   `data-i18n="app_title"` out of a raw `wget` with NO JavaScript running,
   during a REQUIRED release phase. It therefore has to survive `vite build`
   into `dist/index.html` - asserting it against the SOURCE template proves
   nothing about what ships, because only the built file is served.

2. The external-URL allowlist. `app/tests/test_ui.py` forbids `http(s)://`
   under the committed source and served trees (app/ui/src, app/ui/index.html,
   app/ui/public/i18n), but a React bundle carries
   inert URLs of its own (error-explainer links, XML namespaces). Those are
   never fetched - they are string constants - so the rule for the built
   tree is an explicit allowlist rather than an outright ban, and anything
   outside it fails here.

Usage: python3 scripts/ci/ui_build_check.py [--build]
  --build runs `npm ci && npm run build` first; without it an existing
  dist/ is checked (the Dockerfile builds it, and CI passes --build).
"""

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
UI = REPO / "app" / "ui"
DIST = UI / "dist"

A6_MARKER = 'data-i18n="app_title"'

# Inert by construction: never fetched, only ever compared or embedded as a
# namespace. Each entry is a PREFIX and each one needs a reason, because an
# allowlist nobody can justify is just the ban switched off.
ALLOWED_URL_PREFIXES = {
    # React and MUI both embed a link to their own error explainer in the
    # minified throw path. Both are string constants inside an exception
    # message; neither is ever requested, and both are only reachable on a
    # code path that has already failed.
    "https://react.dev/errors/": "react error-explainer text, never fetched",
    "https://mui.com/production-error/": "MUI error-explainer text, never fetched",
    # Inside a console.warn body in useMediaQuery, emitted only for a query
    # containing "print" (the audit fold asks for min-width). A console
    # message, not a request - and unreachable on the queries this app issues.
    "https://mui.com/system/display/": "MUI console.warn docs pointer, never fetched",
    # XML namespaces - identifiers, not addresses. The first two are the same
    # pair the committed static tree already allowlists.
    "http://www.w3.org/2000/svg": "SVG namespace identifier",
    "http://www.w3.org/1999/xhtml": "XHTML namespace identifier",
    "http://www.w3.org/1998/Math/MathML": "MathML namespace identifier",
    "http://www.w3.org/1999/xlink": "XLink namespace identifier",
    "http://www.w3.org/XML/1998/namespace": "XML namespace identifier",
}

URL_RE = re.compile(r"https?://[^\s\"'`)\\]+")


def _rel(path: Path) -> str:
    """A repo-relative label that never raises. `relative_to` throws when the
    path sits outside REPO, which is only reachable on an ERROR path - and a
    crash while explaining a failure is strictly worse than the failure."""
    try:
        return str(path.relative_to(REPO))
    except ValueError:
        return str(path)


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def build() -> None:
    for cmd in (["npm", "ci", "--no-audit", "--no-fund"],
                ["npm", "run", "build"]):
        proc = subprocess.run(cmd, cwd=UI, capture_output=True, text=True)
        if proc.returncode != 0:
            fail(f"{' '.join(cmd)} failed:\n{proc.stdout}\n{proc.stderr}")


def check_marker() -> None:
    index = DIST / "index.html"
    if not index.exists():
        fail(f"{_rel(index)} does not exist - run with --build")
    html = index.read_text(encoding="utf-8")
    if A6_MARKER not in html:
        fail(
            f"the built shell has lost {A6_MARKER!r}. release phase A6 greps "
            f"it from raw HTML with no JavaScript running, so a build that "
            f"drops it fails a REQUIRED release gate - put it back in "
            f"app/ui/index.html somewhere a minifier will not remove "
            f"(an attribute, not a comment)")
    # A comment is not enough: minifier settings strip comments, and the
    # marker would vanish with no test noticing.
    without_comments = re.sub(r"<!--.*?-->", "", html, flags=re.S)
    if A6_MARKER not in without_comments:
        fail("the A6 marker survives only inside an HTML comment - a "
             "minifier would drop it; it must ride a real attribute")


def check_urls() -> None:
    offenders = []
    for path in sorted(DIST.rglob("*")):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for url in URL_RE.findall(text):
            if not any(url.startswith(p) for p in ALLOWED_URL_PREFIXES):
                offenders.append(f"{path.relative_to(DIST)}: {url[:80]}")
    if offenders:
        fail(
            "the built panel carries external URL(s) outside the documented "
            "allowlist - the panel must make no external request, and a LAN "
            "gateway is exactly where a silent outbound call matters:\n  "
            + "\n  ".join(sorted(set(offenders))[:20]))


def main() -> None:
    if "--build" in sys.argv[1:]:
        build()
    check_marker()
    check_urls()
    allowed = ", ".join(sorted(ALLOWED_URL_PREFIXES))
    print(
        f"OK: built panel UI carries the A6 marker {A6_MARKER!r} outside any "
        f"comment, and every external URL is in the inert allowlist "
        f"({allowed}).")


if __name__ == "__main__":
    main()
