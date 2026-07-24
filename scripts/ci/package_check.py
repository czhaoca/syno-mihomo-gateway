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
    the exec bit the .zip extraction drops, and is idempotent (no clobber);
  * the linux profile ships the enduser set PLUS the generic-Linux port - both
    entry points (install-pi.sh + install-linux.sh) with their script trees
    (DEC-2, issue #49, carrying DEC-R4/#31): its IDENTITY gate still fails
    closed, while the FORGE hostnames the port's upstream download URLs need
    are tolerated there - and only there, never in the enduser bundle; and
    --profile pi is a warned deprecated alias producing the identical -linux
    artifacts (DEC-A, #49).

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
COMMON = REPO / "scripts" / "lib" / "common.sh"
GITIGNORE = REPO / ".gitignore"
ENVEDIT = REPO / "scripts" / "installer" / "envedit.sh"
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
    PREFIX + "state/stats.db",
    PREFIX + "state/policy.sqlite3",
    PREFIX + "config/providers/dyn-full-tunnel.txt",
]

# --- enduser profile (curated, self-contained, identity-free distribution) ----
# Forbidden substrings mirror scripts/package.sh's leak-gate (case-insensitive).
# DEC-R3 (issue #31): IDENTITY strings are forbidden in EVERY gated profile;
# FORGE hostnames are additionally forbidden in the enduser bundle only (the
# linux bundle legitimately carries upstream release-download URLs).
IDENTITY_SUBSTRINGS = [
    "czhaoca", "chao.zhao", "nimbus", "docker-china-sync",
    "woodpecker", "aliyun_name_space", "yvr" + "lab",
]
FORGE_SUBSTRINGS = ["github", "gitlab", "bitbucket", "gitea", "git@"]
FORBIDDEN_SUBSTRINGS = FORGE_SUBSTRINGS + IDENTITY_SUBSTRINGS
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

ENDUSER_MUST_INCLUDE = [
    PREFIX + "install.sh",
    PREFIX + "scripts/gateway.sh",
    PREFIX + "scripts/lib/help.sh",
    PREFIX + "docs/CLI.txt",
    PREFIX + "docs/CLI.zh.txt",
    PREFIX + "scripts/installer/ui.sh",
    PREFIX + "scripts/installer/i18n.sh",
    PREFIX + "scripts/installer/flow_redeploy.sh",
    PREFIX + "scripts/installer/preprocess.sh",
    PREFIX + "scripts/installer/envedit.sh",
    PREFIX + "scripts/lib/network.sh",
    PREFIX + "scripts/lib/common.sh",
    PREFIX + "scripts/lib/lifecycle.sh",
    PREFIX + "scripts/lib/scheduler.sh",
    PREFIX + "scripts/doctor.sh",
    PREFIX + "scripts/seed_provider.sh",
    PREFIX + "scripts/lib/geodata.sh",
    PREFIX + "scripts/lib/checks.sh",
    PREFIX + "docs/README.txt",
    PREFIX + ".env.example",
    PREFIX + "docker-compose.yml",
    PREFIX + "bootstrap.sh",
    PREFIX + "VERSION",
    PREFIX + "scripts/validate_release.sh",
]
ENDUSER_MUST_EXCLUDE = [
    PREFIX + "install-pi.sh",
    PREFIX + "scripts/pi/lite.sh",
    PREFIX + "docs/INSTALL-LINUX.txt",
    PREFIX + "docs/INSTALL-LINUX.zh.txt",
    PREFIX + "scripts/pi/detect.sh",
    PREFIX + "install-linux.sh",
    PREFIX + "scripts/linux/preflight_linux.sh",
    PREFIX + "scripts/linux/i18n_linux.sh",
    PREFIX + "scripts/cli/spec.yaml",
    PREFIX + "docs/cli.md",
    PREFIX + "README.md",
    PREFIX + "AGENTS.md",
    PREFIX + "CLAUDE.md",
    PREFIX + ".woodpecker.yml",
    PREFIX + ".gitignore",
    PREFIX + "docs/installation.md",
    PREFIX + "docs/zh/installation.md",
    PREFIX + "scripts/ci/check.py",
    PREFIX + "scripts/package.sh",
    PREFIX + "app/main.py",
    PREFIX + "app/Dockerfile",
]

# --- linux profile (the enduser set PLUS the generic-Linux port; DEC-2, #49) ---
# Derived, not copied: the linux lists differ from the enduser lists by exactly
# the generic-port paths, mirroring package.sh's LINUX_EXCLUDES derivation.
# Both port dirs carry TWO fixture files each so a narrowed (single-file)
# exclude pathspec regression cannot slip past the membership checks.
LINUX_EXTRA_INCLUDE = [
    PREFIX + "install-pi.sh",
    PREFIX + "scripts/pi/lite.sh",
    PREFIX + "scripts/pi/detect.sh",
    PREFIX + "docs/INSTALL-LINUX.txt",
    PREFIX + "docs/INSTALL-LINUX.zh.txt",
    PREFIX + "install-linux.sh",
    PREFIX + "scripts/linux/preflight_linux.sh",
    PREFIX + "scripts/linux/i18n_linux.sh",
]
LINUX_MUST_INCLUDE = ENDUSER_MUST_INCLUDE + LINUX_EXTRA_INCLUDE
LINUX_MUST_EXCLUDE = [p for p in ENDUSER_MUST_EXCLUDE if p not in LINUX_EXTRA_INCLUDE]


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
    shutil.copy(COMMON, root / "scripts" / "lib" / "common.sh")
    # Untracked planted secrets (gitignored) carrying unique sentinels.
    (root / ".env").write_text(f"ACR_PASSWORD={ENV_SENTINEL}\n")
    (root / "config" / "subscription.txt").write_text(
        f"Default=https://real.example.com/sub?token={SUB_SENTINEL}\n")
    (root / "config" / "config.yaml").write_text("rendered: true\n")
    (root / "logs").mkdir()
    (root / "logs" / "auto-update.log").write_text(f"log line {ENV_SENTINEL}\n")
    # Panel runtime state (#68): stray in-tree DBs / dynamic provider files are
    # gitignored, and check_guards proves the tracked-refusal for each class.
    (root / "state").mkdir()
    (root / "state" / "stats.db").write_bytes(f"SQLite format 3\x00{ENV_SENTINEL}".encode())
    (root / "state" / "policy.sqlite3").write_bytes(f"SQLite format 3\x00{ENV_SENTINEL}".encode())
    (root / "state" / "panel-apply-failed").write_text(f"apply failed {ENV_SENTINEL}\n")
    (root / "config" / "providers").mkdir()
    (root / "config" / "providers" / "dyn-full-tunnel.txt").write_text(
        f"payload:\n  # {SUB_SENTINEL}\n  - SRC-IP-CIDR,203.0.113.36/32\n")

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
    for n in names:
        if n.startswith((PREFIX + "state/", PREFIX + "config/providers/")):
            fail(f"{label}: panel runtime state leaked into the archive: {n}")
        if n.endswith(".db") or ".sqlite" in n:
            fail(f"{label}: database file leaked into the archive: {n}")
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
    parts = side.read_text().split()
    recorded = parts[0]
    if digest != recorded:
        fail(f"checksum mismatch for {art.name}: sidecar {recorded} != actual {digest}")
    # BusyBox `sha256sum -c` needs the recorded name to be the artifact
    # basename (emit_sha256's cd-subshell contract); a build-host absolute
    # path here would break the NAS-side verify and the documented operator
    # command. Coreutils binary mode may prefix the name with '*'.
    if len(parts) < 2 or parts[1].lstrip("*") != art.name:
        fail(f"checksum sidecar for {art.name} records the wrong filename: "
             f"{parts[1:] or ['<missing>']} (sha256sum -c would fail)")


def check_leak_list_parity():
    """package.sh's hand-maintained leak lists are the gate's single source
    (its leak_scan comment demands this file stays in sync), but the
    injection proofs below fire only one representative per class - so pin
    the exact list lines here: a silent edit to either list or to the email
    catch-all fails this suite instead of shipping a weakened gate."""
    text = PACKAGER.read_text()
    private_assign = "_private_site=" + "'yvr'" + "'lab'"
    if private_assign not in text:
        fail("package.sh leak_scan: obfuscated private-site assignment missing or changed")
    identity_line = ('set -- czhaoca chao.zhao Nimbus docker-china-sync '
                     'woodpecker ALIYUN_NAME_SPACE "$_private_site"')
    if identity_line not in text:
        fail("package.sh leak_scan IDENTITY list changed - update "
             "IDENTITY_SUBSTRINGS and this suite's pins in the same change")
    forge_line = 'set -- "$@" github gitlab bitbucket gitea git@'
    if forge_line not in text:
        fail("package.sh leak_scan FORGE list changed - update "
             "FORGE_SUBSTRINGS and this suite's pins in the same change")
    email_grep = r"grep -rInE -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+'"
    if email_grep not in text:
        fail("package.sh leak_scan email catch-all changed or removed - "
             "update EMAIL_RE and this pin in the same change")
    tracked_line = ("ls-files -- .env config/subscription.txt config/config.yaml "
                    "'logs/*' '*.db' '*.sqlite*' 'config/providers/*' 'state/*'")
    if tracked_line not in text:
        fail("package.sh tracked-secrets refusal list changed - update the "
             "check_guards injections and this pin in the same change")


def check_bootstrap(tar: Path, nas: Path):
    with tarfile.open(tar) as t:
        t.extractall(nas)
    app = nas / "syno-mihomo-gateway"
    r = run(["sh", "bootstrap.sh"], cwd=app)
    if r.returncode != 0:
        fail(f"bootstrap.sh exited {r.returncode}: {r.stderr.strip()}")
    data = nas / "syno-mihomo-gateway-data"
    envf = data / ".env"
    if not envf.exists():
        fail("bootstrap did not create .env from .env.example")
    mode = stat.S_IMODE(envf.stat().st_mode)
    if mode != 0o600:
        fail(f".env mode is {oct(mode)}, expected 0o600")
    if not (data / "config" / "subscription.txt").exists():
        fail("bootstrap did not create persistent config/subscription.txt from the example")
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

    # tracked panel runtime state -> refuse; one injection per guard-list
    # class ('*.db', '*.sqlite*', 'config/providers/*', and the extensionless
    # marker proving 'state/*' bites independently of the suffix rules),
    # pinned in full by check_leak_list_parity.
    for planted in ("state/stats.db", "state/policy.sqlite3",
                    "state/panel-apply-failed",
                    "config/providers/dyn-full-tunnel.txt"):
        git(["add", "-f", planted], cwd=root)
        r = run(["sh", str(pkg), "--profile", "dev", "--version", "1.2.3"])
        if r.returncode != 3:
            fail(f"tracked {planted} guard: expected exit 3, got {r.returncode}")
        if planted not in (r.stdout + r.stderr):
            fail(f"tracked {planted} guard fired without naming the offending path")
        git(["rm", "-q", "--cached", planted], cwd=root)

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
    # envedit.sh ships as the REAL file, not a placeholder: it embeds the
    # registry-ref derivation (upstream paths), which is exactly the class of
    # installer content an identity string could sneak into - packaging the
    # real file makes the fixture's leak-gate scan cover it (the #68 QA catch:
    # a hardcoded owner GHCR namespace would fail the release cut here).
    shutil.copy(ENVEDIT, root / "scripts" / "installer" / "envedit.sh")
    for s in ("common.sh", "network.sh", "registry.sh", "compose.sh", "scheduler.sh", "lifecycle.sh",
              "resolve.sh"):
        (root / "scripts" / "lib" / s).write_text("#!/bin/sh\n:\n")
    # The generated runtime help + the CLI entry point ship; the spec does not.
    (root / "scripts" / "lib" / "help.sh").write_text(
        "#!/bin/sh\n# help.sh - generated runtime help\nusage() { :; }\ngw_help() { usage; }\n")
    (root / "scripts" / "gateway.sh").write_text("#!/bin/sh\n# non-interactive CLI\n:\n")
    (root / "docs" / "CLI.txt").write_text("Command-line reference for gateway.sh.\n")
    (root / "docs" / "CLI.zh.txt").write_text("gateway.sh command line reference (zh).\n")
    for s in ("auto_update.sh", "render_config.sh", "install_scheduler.sh", "setup_network.sh",
              "validate_release.sh", "seed_provider.sh"):
        (root / "scripts" / s).write_text("#!/bin/sh\n:\n")
    (root / "scripts" / "lib" / "geodata.sh").write_text("#!/bin/sh\n:\n")
    (root / "scripts" / "lib" / "checks.sh").write_text("#!/bin/sh\n:\n")
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
    # Deliberately identity-FREE subdirectory .md decoys: only the recursive
    # ':(exclude)docs/*.md' pathspec (non-FNM_PATHNAME wildmatch) prunes them,
    # never the leak-gate - so a maintenance edit that narrows the token to
    # top-level-only matching fails the .md blanket scans below instead of
    # silently shipping internal docs in the forge-tolerant linux bundle.
    (root / "docs" / "brainstorms").mkdir(parents=True)
    (root / "docs" / "brainstorms" / "notes.md").write_text("internal design notes - never ships\n")
    (root / "docs" / "release-notes").mkdir(parents=True)
    (root / "docs" / "release-notes" / "v0.0.0.md").write_text("internal release notes - never ships\n")
    (root / "scripts" / "ci" / "check.py").write_text("# woodpecker ci helper\n")
    # The Pi port carries FUNCTIONAL upstream download URLs that the leak-gate
    # forbids in shipped files; the enduser profile must prune it entirely, or
    # the build fails on these decoys.
    (root / "install-pi.sh").write_text("#!/bin/sh\n# Pi installer; downloads from GitHub\n:\n")
    (root / "scripts" / "pi").mkdir(parents=True)
    (root / "scripts" / "pi" / "lite.sh").write_text(
        "#!/bin/sh\nURL=https://github.com/MetaCubeX/mihomo/releases\n:\n")
    (root / "scripts" / "pi" / "detect.sh").write_text("#!/bin/sh\n:\n")
    # The generic-Linux guides (#51: the INSTALL-PI pair renamed) ship with the
    # linux profile, not the DSM bundle (their installers are pruned above; a
    # guide for absent installers is noise).
    (root / "docs" / "INSTALL-LINUX.txt").write_text("Generic Linux / Raspberry Pi install guide.\n")
    (root / "docs" / "INSTALL-LINUX.zh.txt").write_text("Generic Linux / Raspberry Pi install guide (zh).\n")
    # The generic-Linux entry drives the same engine; it ships via the linux
    # profile only. Its forge-URL decoy makes an unpruned DSM bundle FAIL the
    # leak-gate rather than ship it silently.
    (root / "install-linux.sh").write_text("#!/bin/sh\n# generic Linux installer over the pi engine\n:\n")
    (root / "scripts" / "linux").mkdir(parents=True)
    (root / "scripts" / "linux" / "preflight_linux.sh").write_text(
        "#!/bin/sh\n# macvlan guard; engine downloads from https://github.com/MetaCubeX\n:\n")
    (root / "scripts" / "linux" / "i18n_linux.sh").write_text("#!/bin/sh\n:\n")
    (root / "scripts" / "cli").mkdir(parents=True)
    (root / "scripts" / "cli" / "spec.yaml").write_text(
        "# CLI contract spec - dev-only; see github.com/czhaoca upstream\n")
    (root / "docs" / "cli.md").write_text("# CLI reference (generated) - github.com/czhaoca\n")
    (root / "docs" / "zh" / "cli.md").write_text("# CLI reference zh - github.com/czhaoca\n")
    # The panel app source is image-delivered (#68): the bundle ships the
    # compose ref, never the tree. Forge-URL decoys make an unpruned DSM
    # bundle FAIL the leak-gate instead of shipping it silently, and both
    # files trip the membership + blanket app/ scans in either profile.
    (root / "app").mkdir(parents=True)
    (root / "app" / "main.py").write_text(
        "# gateway panel app - image-delivered; github.com/czhaoca/mihomo-panel\n")
    (root / "app" / "Dockerfile").write_text("FROM python:3.12-alpine\n# github.com/czhaoca\n")

    # --- untracked planted secrets (gitignored -> must never ship) ---
    (root / ".env").write_text(f"ACR_PASSWORD={ENV_SENTINEL}\n")
    (root / "config" / "subscription.txt").write_text(
        f"Default=https://real.example.com/sub?token={SUB_SENTINEL}\n")
    (root / "state").mkdir()
    (root / "state" / "stats.db").write_bytes(f"SQLite format 3\x00{ENV_SENTINEL}".encode())
    (root / "config" / "providers").mkdir()
    (root / "config" / "providers" / "dyn-full-tunnel.txt").write_text(
        f"payload:\n  # {SUB_SENTINEL}\n  - SRC-IP-CIDR,203.0.113.36/32\n")

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
        if n.startswith(PREFIX + "scripts/cli/"):
            fail(f"{label}: enduser bundle ships the CLI spec dir scripts/cli: {n}")
        if n.startswith(PREFIX + "docs/zh/"):
            fail(f"{label}: enduser bundle ships docs/zh: {n}")
        if n.startswith(PREFIX + "app/"):
            fail(f"{label}: enduser bundle ships the panel app source: {n}")
        if n.startswith((PREFIX + "state/", PREFIX + "config/providers/")) \
                or n.endswith(".db") or ".sqlite" in n:
            fail(f"{label}: enduser bundle ships panel runtime state: {n}")
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


def check_linux_archive(path: Path):
    label = path.name
    names = archive_names(path)
    for want in LINUX_MUST_INCLUDE:
        if want not in names:
            fail(f"{label}: linux bundle missing required entry {want}")
    for bad in LINUX_MUST_EXCLUDE:
        if bad in names:
            fail(f"{label}: linux bundle shipped an excluded file {bad}")
    for n in names:
        if n.endswith(".md"):
            fail(f"{label}: linux bundle ships a .md doc: {n}")
        if n.startswith(PREFIX + "scripts/ci/"):
            fail(f"{label}: linux bundle ships scripts/ci: {n}")
        if n.startswith(PREFIX + "scripts/cli/"):
            fail(f"{label}: linux bundle ships the CLI spec dir scripts/cli: {n}")
        if n.startswith(PREFIX + "docs/zh/"):
            fail(f"{label}: linux bundle ships docs/zh: {n}")
        if n.startswith(PREFIX + "app/"):
            fail(f"{label}: linux bundle ships the panel app source: {n}")
        if n.startswith((PREFIX + "state/", PREFIX + "config/providers/")) \
                or n.endswith(".db") or ".sqlite" in n:
            fail(f"{label}: linux bundle ships panel runtime state: {n}")
    blob = archive_blob(path)
    for sentinel in (ENV_SENTINEL, SUB_SENTINEL):
        if sentinel.encode() in blob:
            fail(f"{label}: SECRET LEAK - sentinel {sentinel!r} in the linux bundle")
    text = blob.decode("utf-8", "ignore")
    low = text.lower()
    for s in IDENTITY_SUBSTRINGS:
        if s in low:
            fail(f"{label}: linux bundle contains forbidden identity string {s!r}")
    if "https://github.com/" not in text:
        fail(f"{label}: linux bundle lost its functional upstream download URL")
    m = EMAIL_RE.search(text)
    if m:
        fail(f"{label}: linux bundle contains an email-like string {m.group(0)!r}")


def check_enduser(base: Path):
    """Build the enduser bundle in its own fixture and assert prune + no-leak, then
    prove the leak-gate FIRES (exit 3, no artifact) when a kept file carries a
    forge hostname (which the linux profile must tolerate on the same tree) or
    an identity string."""
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

    # FORGE direction of the split (criterion 3, #49): a forge hostname in a
    # KEPT, tracked file must abort the enduser build, while the linux profile
    # tolerates the very same tree. This is what proves leak_scan's FORGE
    # branch exists - the built-archive scans above are trivially forge-free.
    cmp_path = eu / "docker-compose.yml"
    cmp_path.write_text(cmp_path.read_text() + "# upstream: https://github.com/example/thing\n")
    git(["commit", "-aqm", "inject forge ref"], cwd=eu)
    rf = run(["sh", str(pkg), "--version", "9.9.9-forge"])
    if rf.returncode != 3:
        fail(f"enduser forge-gate: expected exit 3 on an injected forge hostname, got {rf.returncode}")
    if (dist / "syno-mihomo-gateway-9.9.9-forge.tar.gz").exists() or \
       (dist / "syno-mihomo-gateway-9.9.9-forge.zip").exists():
        fail("enduser forge-gate fired but still wrote an artifact")
    if "github" not in (rf.stdout + rf.stderr).lower():
        fail("enduser forge-gate fired but did not name the offending string")
    rl = run(["sh", str(pkg), "--profile", "linux", "--version", "9.9.9-forge-lx"])
    if rl.returncode != 0:
        fail(f"linux profile rejected the forge hostname the split should tolerate "
             f"(exit {rl.returncode}): {rl.stderr.strip()}")

    # IDENTITY leak-gate must FIRE on top of the tolerated forge ref.
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

    # EMAIL catch-all (the regex path, distinct from the fixed strings): an
    # address in a kept file must be caught too. The tree still carries the
    # earlier injections, so the discriminating assert is the [email] label
    # only leak_scan's regex grep produces.
    cmp_path.write_text(cmp_path.read_text() + "# contact: ops@example.com\n")
    git(["commit", "-aqm", "inject email"], cwd=eu)
    r5 = run(["sh", str(pkg), "--version", "9.9.9-mail"])
    if r5.returncode != 3:
        fail(f"email-gate: expected exit 3 on an injected email address, got {r5.returncode}")
    if (dist / "syno-mihomo-gateway-9.9.9-mail.tar.gz").exists() or \
       (dist / "syno-mihomo-gateway-9.9.9-mail.zip").exists():
        fail("email-gate fired but still wrote an artifact")
    if "LEAK [email]" not in (r5.stdout + r5.stderr):
        fail("email-gate did not label the [email] hit")


def check_linux(base: Path):
    """Build the linux bundle (the enduser superset carrying both generic
    entries; DEC-2, #49) from the same fixture tree - its port decoys become
    shipped content - and assert the port files ship, the forge URL the runtime
    needs survives (the gate tolerates it), --profile pi is a warned alias
    producing the identical -linux artifacts (DEC-A), and an injected IDENTITY
    string still fails the build closed."""
    lx = base / "linux"
    lx.mkdir()
    build_enduser_fixture(lx)
    pkg = lx / "scripts" / "package.sh"
    dist = lx / "dist"

    r = run(["sh", str(pkg), "--profile", "linux", "--version", "9.9.9-lx"])
    if r.returncode != 0:
        fail(f"linux build failed (exit {r.returncode}): {r.stderr.strip()}")
    tar = dist / "syno-mihomo-gateway-linux-9.9.9-lx.tar.gz"
    zp = dist / "syno-mihomo-gateway-linux-9.9.9-lx.zip"
    for f in (tar, zp):
        if not f.exists():
            fail(f"linux artifact missing: {f.name}")
    for art in (tar, zp):
        check_linux_archive(art)
        check_checksum(art)

    # DEC-A (#49): --profile pi is a deprecated alias - it must warn, produce
    # -linux artifacts (never -pi), and rebuild the byte-identical bundle: the
    # alias rerun uses the SAME version, so git archive of the same commit must
    # overwrite each artifact with exactly the same bytes.
    saved = {a.name: a.read_bytes() for a in (tar, zp)}
    r2 = run(["sh", str(pkg), "--profile", "pi", "--version", "9.9.9-lx"])
    if r2.returncode != 0:
        fail(f"--profile pi alias build failed (exit {r2.returncode}): {r2.stderr.strip()}")
    if "deprecated" not in (r2.stdout + r2.stderr).lower():
        fail("--profile pi alias did not warn about deprecation")
    if (dist / "syno-mihomo-gateway-pi-9.9.9-lx.tar.gz").exists() or \
       (dist / "syno-mihomo-gateway-pi-9.9.9-lx.zip").exists():
        fail("--profile pi alias wrote a -pi artifact")
    for a in (tar, zp):
        if not a.exists():
            fail(f"--profile pi alias artifact missing: {a.name}")
        if a.read_bytes() != saved[a.name]:
            fail(f"--profile pi alias rebuild of {a.name} is not byte-identical")
        check_checksum(a)  # the rebuild rewrote the .sha256 sidecars too

    # The --profile=pi equals-form spelling must take the same alias path.
    r3 = run(["sh", str(pkg), "--profile=pi", "--version", "9.9.9-alias-eq", "--no-tar"])
    if r3.returncode != 0:
        fail(f"--profile=pi (equals form) build failed (exit {r3.returncode}): {r3.stderr.strip()}")
    if "deprecated" not in (r3.stdout + r3.stderr).lower():
        fail("--profile=pi (equals form) did not warn about deprecation")
    if (dist / "syno-mihomo-gateway-pi-9.9.9-alias-eq.zip").exists():
        fail("--profile=pi (equals form) wrote a -pi artifact")
    eq_zip = dist / "syno-mihomo-gateway-linux-9.9.9-alias-eq.zip"
    if not eq_zip.exists():
        fail("--profile=pi (equals form) did not produce a -linux zip artifact")
    check_checksum(eq_zip)

    # The IDENTITY gate must still FIRE for the linux profile: inject an identity
    # string into a kept, tracked file -> exit 3, no artifact, string named.
    cmp_path = lx / "docker-compose.yml"
    cmp_path.write_text(cmp_path.read_text() + "# mirror via docker-china-sync\n")
    git(["commit", "-aqm", "inject identity leak"], cwd=lx)
    r3 = run(["sh", str(pkg), "--profile", "linux", "--version", "9.9.9-lxleak"])
    if r3.returncode != 3:
        fail(f"linux leak-gate: expected exit 3 on an injected identity leak, got {r3.returncode}")
    if (dist / "syno-mihomo-gateway-linux-9.9.9-lxleak.tar.gz").exists() or \
       (dist / "syno-mihomo-gateway-linux-9.9.9-lxleak.zip").exists():
        fail("linux leak-gate fired but still wrote an artifact")
    if "docker-china-sync" not in (r3.stdout + r3.stderr):
        fail("linux leak-gate fired but did not name the offending string")


def main():
    for p in (PACKAGER, BOOTSTRAP, GITIGNORE):
        if not p.exists():
            fail(f"missing repo file under test: {p}")
    check_leak_list_parity()

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

        # linux profile: the enduser superset that carries both generic entries.
        check_linux(base)

    print("OK: dev archive ships templates+scripts but no secret bytes (zip & tar.gz); "
          "checksums verify; tracked-secret/dirty/non-git guards fire; bootstrap.sh seeds "
          "config (mode 600), restores +x, is idempotent. enduser profile prunes all "
          "developer/.md/CI files (incl. both generic-Linux entries), ships the installer "
          "+ .txt guides, leaks no identity string or secret, and its leak-gate fails "
          "closed on an injected leak. linux profile ships the Pi + generic-Linux ports "
          "on top of the enduser set, keeps the identity gate fail-closed, tolerates the "
          "upstream forge URLs the runtime needs, and accepts --profile pi as a warned "
          "alias building the identical -linux bundle.")


if __name__ == "__main__":
    main()
