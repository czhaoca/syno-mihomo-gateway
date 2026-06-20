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
import re
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

# --- enduser profile (curated, self-contained, identity-free distribution) ----
# Forbidden substrings mirror scripts/package.sh's leak-gate (case-insensitive).
FORBIDDEN_SUBSTRINGS = [
    "github", "gitlab", "bitbucket", "gitea", "git@",
    "czhaoca", "chao.zhao", "nimbus", "docker-china-sync",
    "woodpecker", "aliyun_name_space", "yvr" + "lab",
]
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

ENDUSER_MUST_INCLUDE = [
    PREFIX + "install.sh",
    PREFIX + "scripts/installer/ui.sh",
    PREFIX + "scripts/installer/i18n.sh",
    PREFIX + "scripts/installer/flow_redeploy.sh",
    PREFIX + "scripts/installer/preprocess.sh",
    PREFIX + "scripts/lib/network.sh",
    PREFIX + "scripts/lib/common.sh",
    PREFIX + "scripts/lib/lifecycle.sh",
    PREFIX + "scripts/lib/scheduler.sh",
    PREFIX + "scripts/doctor.sh",
    PREFIX + "docs/README.txt",
    PREFIX + ".env.example",
    PREFIX + "docker-compose.yml",
    PREFIX + "bootstrap.sh",
    PREFIX + "VERSION",
]
ENDUSER_MUST_EXCLUDE = [
    PREFIX + "README.md",
    PREFIX + "AGENTS.md",
    PREFIX + "CLAUDE.md",
    PREFIX + ".woodpecker.yml",
    PREFIX + ".gitignore",
    PREFIX + "docs/installation.md",
    PREFIX + "docs/zh/installation.md",
    PREFIX + "scripts/ci/check.py",
    PREFIX + "scripts/package.sh",
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
    r = run(["sh", str(pkg), "--profile", "dev", "--version", "1.2.3"])
    if r.returncode != 3:
        fail(f"dirty-tree guard: expected exit 3, got {r.returncode}")
    r = run(["sh", str(pkg), "--profile", "dev", "--version", "1.2.3", "--allow-dirty"])
    if r.returncode != 0:
        fail(f"--allow-dirty: expected exit 0, got {r.returncode}: {r.stderr.strip()}")
    if not (dist / "syno-mihomo-gateway-1.2.3-dirty.tar.gz").exists():
        fail("--allow-dirty did not append -dirty to the artifact name")
    git(["checkout", "-q", "--", "VERSION"], cwd=root)

    # tracked secret -> refuse (the in-tool §1 guard).
    git(["add", "-f", ".env"], cwd=root)
    r = run(["sh", str(pkg), "--profile", "dev", "--version", "1.2.3"])
    if r.returncode != 3:
        fail(f"tracked-secret guard: expected exit 3, got {r.returncode}")
    if "tracked" not in (r.stdout + r.stderr).lower():
        fail("tracked-secret guard fired but message did not mention 'tracked'")
    git(["rm", "-q", "--cached", ".env"], cwd=root)

    # non-git directory -> refuse.
    (ng / "scripts").mkdir(parents=True)
    shutil.copy(PACKAGER, ng / "scripts" / "package.sh")
    env = {**os.environ, "GIT_CEILING_DIRECTORIES": str(ng.parent)}
    r = run(["sh", str(ng / "scripts" / "package.sh"), "--profile", "dev"], env=env)
    if r.returncode != 3:
        fail(f"non-git guard: expected exit 3, got {r.returncode}")


def build_enduser_fixture(root: Path):
    """A realistic repo for the enduser profile: identity-CLEAN runtime files +
    the installer + .txt guides that must ship, alongside developer/identity decoy
    files (README.md/AGENTS.md/CLAUDE.md/.woodpecker.yml/docs/*.md/scripts/ci) that
    must be pruned, plus the usual untracked planted secrets."""
    (root / "scripts" / "lib").mkdir(parents=True)
    (root / "scripts" / "installer").mkdir(parents=True)
    (root / "scripts" / "ci").mkdir(parents=True)
    (root / "config").mkdir(parents=True)
    (root / "docs" / "zh").mkdir(parents=True)
    shutil.copy(PACKAGER, root / "scripts" / "package.sh")
    shutil.copy(GITIGNORE, root / ".gitignore")

    # --- KEPT runtime files (must be identity-clean for the leak-gate) ---
    (root / "VERSION").write_text("0.0.0-eu\n")
    (root / "install.sh").write_text("#!/bin/sh\n# guided installer\n:\n")
    (root / "bootstrap.sh").write_text("#!/bin/sh\n# seeds .env; run: sh ./install.sh\n:\n")
    (root / "docker-compose.yml").write_text(
        "services:\n  mihomo:\n    image: ${MIHOMO_IMAGE:?set in .env - run ./install.sh}\n")
    (root / ".env.example").write_text(
        "REGISTRY_MODE=acr\n"
        "MIHOMO_IMAGE=registry.example.com/ns/mihomo:latest\n"
        "METACUBEXD_IMAGE=registry.example.com/ns/metacubexd:latest\n"
        "DOCKER_REGISTRY=\nACR_NAMESPACE=\n")
    (root / "config" / "config.template.yaml").write_text("mixed-port: 7894\n")
    (root / "config" / "subscription.txt.example").write_text(
        "Default=https://example.com/sub?token=REPLACE_ME\n")
    for s in ("ui.sh", "i18n.sh", "flow_redeploy.sh", "flow_deploy.sh", "preprocess.sh"):
        (root / "scripts" / "installer" / s).write_text("#!/bin/sh\n:\n")
    for s in ("common.sh", "network.sh", "registry.sh", "compose.sh", "scheduler.sh", "lifecycle.sh"):
        (root / "scripts" / "lib" / s).write_text("#!/bin/sh\n:\n")
    for s in ("auto_update.sh", "render_config.sh", "install_scheduler.sh", "setup_network.sh"):
        (root / "scripts" / s).write_text("#!/bin/sh\n:\n")
    (root / "scripts" / "doctor.sh").write_text("#!/bin/sh\n:\n")
    (root / "docs" / "README.txt").write_text("Mihomo Gateway - start here.\nRun: sh ./install.sh\n")
    (root / "docs" / "INSTALL.txt").write_text("Move this folder into the Docker shared folder.\n")

    # --- EXCLUDED developer/identity files (decoys: pruned AND must not leak) ---
    (root / "README.md").write_text("See https://github.com/czhaoca/syno-mihomo-gateway\n")
    (root / "AGENTS.md").write_text("Registered in Nimbus. Repo git@github.com:czhaoca/x.git\n")
    (root / "CLAUDE.md").write_text("Registered in Nimbus registry.\n")
    (root / ".woodpecker.yml").write_text("steps:\n  test:\n    image: alpine\n")
    (root / "docs" / "installation.md").write_text("git clone https://github.com/czhaoca/x.git\n")
    (root / "docs" / "zh" / "installation.md").write_text("clone https://github.com/czhaoca/x\n")
    (root / "scripts" / "ci" / "check.py").write_text("# woodpecker ci helper\n")

    # --- untracked planted secrets (gitignored -> must never ship) ---
    (root / ".env").write_text(f"ACR_PASSWORD={ENV_SENTINEL}\n")
    (root / "config" / "subscription.txt").write_text(
        f"Default=https://real.example.com/sub?token={SUB_SENTINEL}\n")

    git(["init", "-q"], cwd=root)
    git(["config", "user.email", "ci@example.com"], cwd=root)
    git(["config", "user.name", "ci"], cwd=root)
    git(["add", "-A"], cwd=root)  # respects .gitignore -> secrets stay untracked
    git(["commit", "-q", "-m", "fixture"], cwd=root)


def check_enduser_archive(path: Path):
    label = path.name
    names = archive_names(path)
    for want in ENDUSER_MUST_INCLUDE:
        if want not in names:
            fail(f"{label}: enduser bundle missing required entry {want}")
    for bad in ENDUSER_MUST_EXCLUDE:
        if bad in names:
            fail(f"{label}: enduser bundle shipped an excluded file {bad}")
    for n in names:
        if n.endswith(".md"):
            fail(f"{label}: enduser bundle ships a .md doc: {n}")
        if n.startswith(PREFIX + "scripts/ci/"):
            fail(f"{label}: enduser bundle ships scripts/ci: {n}")
        if n.startswith(PREFIX + "docs/zh/"):
            fail(f"{label}: enduser bundle ships docs/zh: {n}")
    blob = archive_blob(path)
    for sentinel in (ENV_SENTINEL, SUB_SENTINEL):
        if sentinel.encode() in blob:
            fail(f"{label}: SECRET LEAK - sentinel {sentinel!r} in the enduser bundle")
    text = blob.decode("utf-8", "ignore")
    low = text.lower()
    for s in FORBIDDEN_SUBSTRINGS:
        if s in low:
            fail(f"{label}: enduser bundle contains forbidden identity string {s!r}")
    m = EMAIL_RE.search(text)
    if m:
        fail(f"{label}: enduser bundle contains an email-like string {m.group(0)!r}")


def check_enduser(base: Path):
    """Build the enduser bundle in its own fixture and assert prune + no-leak, then
    prove the leak-gate FIRES (exit 3, no artifact) when a kept file carries an
    identity string."""
    eu = base / "enduser"
    eu.mkdir()
    build_enduser_fixture(eu)
    pkg = eu / "scripts" / "package.sh"
    dist = eu / "dist"

    r = run(["sh", str(pkg), "--version", "9.9.9-eu"])
    if r.returncode != 0:
        fail(f"enduser build failed (exit {r.returncode}): {r.stderr.strip()}")
    tar = dist / "syno-mihomo-gateway-9.9.9-eu.tar.gz"
    zp = dist / "syno-mihomo-gateway-9.9.9-eu.zip"
    for f in (tar, zp):
        if not f.exists():
            fail(f"enduser artifact missing: {f.name}")
    for art in (tar, zp):
        check_enduser_archive(art)
        check_checksum(art)

    # Leak-gate must FIRE: inject a forbidden string into a KEPT, tracked file.
    cmp_path = eu / "docker-compose.yml"
    cmp_path.write_text(cmp_path.read_text() + "# mirror via docker-china-sync\n")
    git(["commit", "-aqm", "inject leak"], cwd=eu)
    r2 = run(["sh", str(pkg), "--version", "9.9.9-leak"])
    if r2.returncode != 3:
        fail(f"leak-gate: expected exit 3 on an injected leak, got {r2.returncode}")
    if (dist / "syno-mihomo-gateway-9.9.9-leak.tar.gz").exists() or \
       (dist / "syno-mihomo-gateway-9.9.9-leak.zip").exists():
        fail("leak-gate fired but still wrote an artifact")
    if "docker-china-sync" not in (r2.stdout + r2.stderr):
        fail("leak-gate fired but did not name the offending string")


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
        r = run(["sh", str(pkg), "--profile", "dev", "--version", "9.9.9-test"])
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

        # enduser profile: curated, identity-free distribution.
        check_enduser(base)

    print("OK: dev archive ships templates+scripts but no secret bytes (zip & tar.gz); "
          "checksums verify; tracked-secret/dirty/non-git guards fire; bootstrap.sh seeds "
          "config (mode 600), restores +x, is idempotent. enduser profile prunes all "
          "developer/.md/CI files, ships the installer + .txt guides, leaks no identity "
          "string or secret, and its leak-gate fails closed on an injected leak.")


if __name__ == "__main__":
    main()
