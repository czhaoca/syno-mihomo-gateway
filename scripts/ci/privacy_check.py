#!/usr/bin/env python3
"""Fail closed when tracked repository content contains private operations data.

The check intentionally permits public project/GitHub references and public
Alibaba Shenzhen registry examples. It reports only a path and rule name, never
the matched value. Runtime secrets remain protected primarily by the tracked-path
gate and .gitignore; content checks add defense in depth.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qsl, urlparse

REPO = Path(__file__).resolve().parents[2]
PRIVATE_SITE = "yvr" + "lab"
PRIVATE_SITE_RE = re.compile(r"yvr[-_ ]?(?:mac)?lab", re.IGNORECASE)
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
URL_RE = re.compile(r"https?://[^\s<>\"'()\[\]]+")
PRIVATE_KEY_RE = re.compile(
    "-----BEGIN " + r"(?:[A-Z0-9]+ )*PRIVATE KEY-----", re.IGNORECASE
)
SECRET_KEYS = {
    "ACR_PASSWORD",
    "CF_TUNNEL_TOKEN",
    "CONTROLLER_SECRET",
    "NOTIFY_WEBHOOK_URL",
}
ALLOWED_EMAIL_DOMAINS = {
    "example.com",
    "example.org",
    "example.net",
    "github.com",  # git@github.com repository locator, not a personal email
    "users.noreply.github.com",
}
PLACEHOLDER_SECRETS = {"abc", "xyz", "replace_me", "example", "placeholder"}


def git(*args: str, text: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(REPO), *args], capture_output=True, text=text, check=False
    )


def fail(path: str, rule: str) -> None:
    print(f"PRIVACY FAIL: {path}: {rule}", file=sys.stderr)
    raise SystemExit(1)


def candidate_paths() -> list[str]:
    # Include tracked files plus new, non-ignored files in the current change so
    # the local gate is meaningful before those files are committed.
    result = git("ls-files", "--cached", "--others", "--exclude-standard", "-z", text=False)
    if result.returncode:
        print("PRIVACY FAIL: could not enumerate repository files", file=sys.stderr)
        raise SystemExit(1)
    return [p.decode("utf-8", "surrogateescape") for p in result.stdout.split(b"\0") if p]


def is_example_host(host: str | None) -> bool:
    if not host:
        return False
    host = host.lower().rstrip(".")
    return host in {"example.com", "example.org", "example.net"} or \
        ".example." in host or host.endswith(".example")


def is_secret_path(path: str) -> bool:
    lowered_path = path.lower()
    return (
        (
            lowered_path == ".env"
            or lowered_path.startswith(".env.")
        )
        and lowered_path != ".env.example"
    ) or (
        (
            lowered_path.startswith("config/subscription.txt")
            and lowered_path != "config/subscription.txt.example"
        )
        or lowered_path.startswith("config/config.yaml")
        or lowered_path.startswith("config/providers/")
        or lowered_path.startswith("state/")
        or lowered_path.endswith(".db")
        or ".sqlite" in lowered_path
        or lowered_path.startswith("logs/")
    )


def scan_text(path: str, text: str, *, history: bool = False) -> None:
    lowered = text.lower()
    if PRIVATE_SITE in lowered or PRIVATE_SITE_RE.search(text):
        fail(path, "private lab/host identifier")
    if PRIVATE_KEY_RE.search(text):
        fail(path, "private-key material")

    for match in EMAIL_RE.finditer(text):
        if match.group(1).lower() not in ALLOWED_EMAIL_DOMAINS:
            fail(path, "non-example email address")

    for raw_url in URL_RE.findall(text):
        parsed = urlparse(raw_url.rstrip(".,);]`"))
        sensitive = any(
            key.lower() in {"token", "key", "secret", "password"}
            and value
            and len(value) > 3
            and value.lower() not in PLACEHOLDER_SECRETS
            for key, value in parse_qsl(parsed.query, keep_blank_values=True)
        )
        if sensitive and not is_example_host(parsed.hostname):
            fail(path, "credential-bearing non-example URL")

    if not history and path == ".env.example":
        for line in text.splitlines():
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            key, value = line.split("=", 1)
            if key in SECRET_KEYS and value.strip().strip("\"'"):
                fail(path, f"non-empty example secret: {key}")


def scan_worktree(paths: list[str]) -> None:
    for path in paths:
        if is_secret_path(path):
            fail(path, "runtime secret path is tracked")
        file_path = REPO / path
        if file_path.is_symlink():
            scan_text(path, str(file_path.readlink()))
            continue
        if not file_path.exists():
            # A tracked deletion in a pre-commit worktree has no content to scan.
            continue
        try:
            data = file_path.read_bytes()
        except OSError:
            fail(path, "tracked file is unreadable")
        if b"\0" in data:
            continue
        scan_text(path, data.decode("utf-8", "replace"))


def scan_history() -> None:
    objects = git("rev-list", "--objects", "--all")
    if objects.returncode:
        fail(".git", "could not enumerate reachable objects")
    seen: set[str] = set()
    for line in objects.stdout.splitlines():
        oid, _, hint = line.partition(" ")
        if not oid or oid in seen:
            continue
        seen.add(oid)
        kind = git("cat-file", "-t", oid)
        if kind.returncode or kind.stdout.strip() != "blob":
            continue
        blob = git("cat-file", "blob", oid, text=False)
        if blob.returncode or b"\0" in blob.stdout:
            continue
        scan_text(hint or f"blob:{oid[:12]}", blob.stdout.decode("utf-8", "replace"), history=True)


def main() -> None:
    paths = candidate_paths()
    scan_worktree(paths)
    scan_history()
    print(
        "OK: tracked files/history contain no private operations identifiers; "
        "runtime secret paths and non-example credentials are absent."
    )


if __name__ == "__main__":
    main()
