#!/usr/bin/env python3
"""Hermetic safeguard test for the offline release packager.

Builds a throwaway git-repo fixture (so it never touches or dirties the real
checkout), then invokes the REAL scripts/package.sh and bootstrap.sh and asserts:

  * the release archive can NEVER ship a secret - planted secrets (.env,
    config/subscription.txt, config/config.yaml, logs/) appear in NEITHER
    archive's file list NOR its decompressed bytes (the highest-stakes property);
  * the shipped templates and scripts ARE present, and checksums verify;
  * every package.sh guard fires - tracked secret, dirty tree, non-git dir;
  * bootstrap.sh seeds .env (mode 600) + subscription from the examples, restores
    the exec bit the .zip extraction drops, and is idempotent (no clobber).

Mirrors scripts/ci/render_check.py: exercise the REAL scripts (a reimplementation
would miss the very bugs this guards against), fail() -> exit 1, print OK: on pass.
Stdlib only - no third-party deps.
"""
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PACKAGER = REPO / "scripts" / "package.sh"
BOOTSTRAP = REPO / "bootstrap.sh"
GITIGNORE = REPO / ".gitignore"
PREFIX = "syno-mihomo-gateway/"

ENV_SENTINEL = "PLANTED_SECRET_DO_NOT_SHIP"
SUB_SENTINEL = "PLANTEDTOKEN"

MUST_INCLUDE = [
    PREFIX + ".env.example",
    PREFIX + "config/subscription.txt.example",
    PREFIX + "scripts/package.sh",
    PREFIX + "bootstrap.sh",
    PREFIX + "VERSION",
]
MUST_EXCLUDE = [
    PREFIX + ".env",
    PREFIX + "config/subscription.txt",
    PREFIX + "config/config.yaml",
]


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def run(cmd, cwd=None, env=None):
    return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)


def git(args, cwd):
    r = run(["git", *args], cwd=cwd)
    if r.returncode != 0:
        fail(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r


def build_fixture(root: Path):
    """A minimal but realistic repo: real scripts + .gitignore, tracked templates,
    and untracked planted secrets that must never reach the archive."""
    (root / "scripts" / "lib").mkdir(parents=True)
    (root / "config").mkdir(parents=True)
    shutil.copy(PACKAGER, root / "scripts" / "package.sh")
    shutil.copy(BOOTSTRAP, root / "bootstrap.sh")
    shutil.copy(GITIGNORE, root / ".gitignore")
    # Tracked files (must ship).
    (root / "VERSION").write_text("0.0.0-fixture\n")
    (root / ".env.example").write_text("ROUTER_IP=192.168.1.1\nCONTROLLER_SECRET=\n")
    (root / "config" / "subscription.txt.example").write_text(
        "Default=https://example.com/sub?token=REPLACE_ME\n")
    (root / "config" / "config.template.yaml").write_text("mixed-port: 7890\n")
    (root / "docker-compose.yml").write_text("services: {}\n")
    (root / "scripts" / "render_config.sh").write_text("#!/bin/sh\n:\n")
    (root / "scripts" / "lib" / "common.sh").write_text("#!/bin/sh\n:\n")
    # Untracked planted secrets (gitignored) carrying unique sentinels.
    (root / ".env").write_text(f"ACR_PASSWORD={ENV_SENTINEL}\n")
    (root / "config" / "subscription.txt").write_text(
        f"Default=https://real.example.com/sub?token={SUB_SENTINEL}\n")
    (root / "config" / "config.yaml").write_text("rendered: true\n")
    (root / "logs").mkdir()
    (root / "logs" / "auto-update.log").write_text(f"log line {ENV_SENTINEL}\n")

    git(["init", "-q"], cwd=root)
    git(["config", "user.email", "ci@example.com"], cwd=root)
    git(["config", "user.name", "ci"], cwd=root)
    git(["add", "-A"], cwd=root)  # respects .gitignore -> secrets stay untracked
    git(["commit", "-q", "-m", "fixture"], cwd=root)


def archive_names(path: Path):
    if path.name.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            return z.namelist()
    with tarfile.open(path) as t:
        return t.getnames()


def archive_blob(path: Path) -> bytes:
    """Concatenated decompressed bytes of every regular-file member."""
    blob = b""
    if path.name.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                if not n.endswith("/"):
                    blob += z.read(n)
        return blob
    with tarfile.open(path) as t:
        for m in t.getmembers():
            if m.isfile():
                f = t.extractfile(m)
                if f is not None:
                    blob += f.read()
    return blob


def check_archive_contents(path: Path):
    label = path.name
    names = archive_names(path)
    for want in MUST_INCLUDE:
        if want not in names:
            fail(f"{label}: missing required entry {want}")
    for bad in MUST_EXCLUDE:
        if bad in names:
            fail(f"{label}: SECRET LEAK - {bad} is in the archive")
    if any(n.startswith(PREFIX + "logs/") for n in names):
        fail(f"{label}: logs/ leaked into the archive")
    if any(".git/" in n for n in names):
        fail(f"{label}: .git/ leaked into the archive")
    blob = archive_blob(path)
    for sentinel in (ENV_SENTINEL, SUB_SENTINEL):
        if sentinel.encode() in blob:
            fail(f"{label}: secret sentinel {sentinel!r} found in archive bytes")


def check_checksum(art: Path):
    side = Path(str(art) + ".sha256")
    if not side.exists():
        fail(f"missing checksum sidecar for {art.name}")
    digest = hashlib.sha256(art.read_bytes()).hexdigest()
    recorded = side.read_text().split()[0]
    if digest != recorded:
        fail(f"checksum mismatch for {art.name}: sidecar {recorded} != actual {digest}")


def check_bootstrap(tar: Path, nas: Path):
    with tarfile.open(tar) as t:
        t.extractall(nas)
    app = nas / "syno-mihomo-gateway"
    r = run(["sh", "bootstrap.sh"], cwd=app)
    if r.returncode != 0:
        fail(f"bootstrap.sh exited {r.returncode}: {r.stderr.strip()}")
    envf = app / ".env"
    if not envf.exists():
        fail("bootstrap did not create .env from .env.example")
    mode = stat.S_IMODE(envf.stat().st_mode)
    if mode != 0o600:
        fail(f".env mode is {oct(mode)}, expected 0o600")
    if not (app / "config" / "subscription.txt").exists():
        fail("bootstrap did not create config/subscription.txt from the example")
    if not os.access(app / "scripts" / "render_config.sh", os.X_OK):
        fail("bootstrap did not restore +x on scripts/*.sh")
    # Idempotency: an existing .env must NOT be clobbered.
    envf.write_text("MY_EDIT=keepme\n")
    r2 = run(["sh", "bootstrap.sh"], cwd=app)
    if "keepme" not in envf.read_text():
        fail("bootstrap clobbered an already-configured .env")
    if "already exists" not in (r2.stdout + r2.stderr):
        fail("bootstrap re-run did not report the existing .env as left untouched")


def check_guards(root: Path, dist: Path, pkg: Path, ng: Path):
    # dirty tree -> refuse without --allow-dirty; accept (with -dirty suffix) with it.
    (root / "VERSION").write_text("0.0.0-fixture-edited\n")
    r = run(["sh", str(pkg), "--version", "1.2.3"])
    if r.returncode != 3:
        fail(f"dirty-tree guard: expected exit 3, got {r.returncode}")
    r = run(["sh", str(pkg), "--version", "1.2.3", "--allow-dirty"])
    if r.returncode != 0:
        fail(f"--allow-dirty: expected exit 0, got {r.returncode}: {r.stderr.strip()}")
    if not (dist / "syno-mihomo-gateway-1.2.3-dirty.tar.gz").exists():
        fail("--allow-dirty did not append -dirty to the artifact name")
    git(["checkout", "-q", "--", "VERSION"], cwd=root)

    # tracked secret -> refuse (the in-tool §1 guard).
    git(["add", "-f", ".env"], cwd=root)
    r = run(["sh", str(pkg), "--version", "1.2.3"])
    if r.returncode != 3:
        fail(f"tracked-secret guard: expected exit 3, got {r.returncode}")
    if "tracked" not in (r.stdout + r.stderr).lower():
        fail("tracked-secret guard fired but message did not mention 'tracked'")
    git(["rm", "-q", "--cached", ".env"], cwd=root)

    # non-git directory -> refuse.
    (ng / "scripts").mkdir(parents=True)
    shutil.copy(PACKAGER, ng / "scripts" / "package.sh")
    env = {**os.environ, "GIT_CEILING_DIRECTORIES": str(ng.parent)}
    r = run(["sh", str(ng / "scripts" / "package.sh")], env=env)
    if r.returncode != 3:
        fail(f"non-git guard: expected exit 3, got {r.returncode}")


def main():
    for p in (PACKAGER, BOOTSTRAP, GITIGNORE):
        if not p.exists():
            fail(f"missing repo file under test: {p}")

    with tempfile.TemporaryDirectory() as base_s:
        base = Path(base_s)
        root = base / "repo"
        root.mkdir()
        build_fixture(root)

        pkg = root / "scripts" / "package.sh"
        dist = root / "dist"
        r = run(["sh", str(pkg), "--version", "9.9.9-test"])
        if r.returncode != 0:
            fail(f"package.sh build failed (exit {r.returncode}): {r.stderr.strip()}")

        tar = dist / "syno-mihomo-gateway-9.9.9-test.tar.gz"
        zp = dist / "syno-mihomo-gateway-9.9.9-test.zip"
        for f in (tar, zp):
            if not f.exists():
                fail(f"expected artifact missing: {f.name}")

        for art in (tar, zp):
            check_archive_contents(art)
            check_checksum(art)

        nas = base / "nas"
        nas.mkdir()
        check_bootstrap(tar, nas)

        ng = base / "nongit"
        ng.mkdir()
        check_guards(root, dist, pkg, ng)

    print("OK: release archive ships templates+scripts but no secret bytes (both "
          "zip & tar.gz); checksums verify; tracked-secret/dirty/non-git guards fire; "
          "bootstrap.sh seeds config (mode 600), restores +x, and is idempotent.")


if __name__ == "__main__":
    main()
