#!/usr/bin/env python3
"""Enforce the ACR-only image policy.

The gateway must ALWAYS pull its container images from the operator's Alibaba ACR
(private) mirror, NEVER directly from a public registry (Docker Hub / ghcr.io / etc.),
which are blocked or unreliable in mainland China. Two committed files are gated:

  * docker-compose.yml - parsed structurally (YAML, so inline-map services and
    comments can't hide a bad image). Every service `image:` must be a single env
    reference, exactly `${VAR}` or `${VAR:?msg}` - never a default-value fallback
    (`${VAR:-ref}` / `${VAR:=ref}`) and never a hardcoded ref. An unset var then
    FAILS the deploy instead of silently pulling a direct image.
  * .env.example - every `*IMAGE*` assignment with a literal value (not a ${...}
    composition) must be a PRIVATE-registry ref: a real registry host that is not a
    known public registry. MIHOMO_IMAGE / METACUBEXD_IMAGE are required + non-empty;
    CF_IMAGE and others may be blank.

Mirrors scripts/ci/render_check.py: fail() -> exit 1, print OK: on pass. Needs PyYAML.
"""
import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
COMPOSE = REPO / "docker-compose.yml"
ENV_EXAMPLE = REPO / ".env.example"

# The ONLY accepted compose image forms: a single env ref, optionally with a `:?`
# required-guard (which fails closed). Defaults (:- / :=), concatenations, and
# hardcoded refs are rejected.
ALLOWED_IMAGE = re.compile(r"^\$\{[A-Za-z_][A-Za-z0-9_]*(:\?[^}]*)?\}$")

# Known PUBLIC registries (lowercased hosts). A gateway image ref must NOT live here.
PUBLIC_HOSTS = {
    "docker.io", "index.docker.io", "registry-1.docker.io", "registry.hub.docker.com",
    "ghcr.io", "quay.io", "gcr.io", "k8s.gcr.io", "registry.k8s.io",
    "public.ecr.aws", "mcr.microsoft.com",
}
REQUIRED_VARS = ("MIHOMO_IMAGE", "METACUBEXD_IMAGE")


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def check_compose():
    doc = yaml.safe_load(COMPOSE.read_text()) or {}
    services = doc.get("services") or {}
    if not services:
        fail(f"{COMPOSE.name}: no services found (unexpected)")
    seen = []
    for name, spec in services.items():
        img = (spec or {}).get("image")
        if img is None:
            fail(f"{COMPOSE.name}: service '{name}' has no image:")
        img = str(img).strip()
        seen.append(img)
        if ":-" in img or ":=" in img:
            fail(f"{COMPOSE.name}: service '{name}' image {img!r} has a default-value fallback - "
                 f"drop it so an unset var FAILS instead of pulling direct (use ${{VAR:?message}})")
        if not ALLOWED_IMAGE.match(img):
            fail(f"{COMPOSE.name}: service '{name}' image {img!r} must be a bare env ref "
                 f"(${{VAR}} or ${{VAR:?msg}}) resolving to your ACR mirror - no hardcoded registry")
    return seen


def classify_ref(val):
    """Docker-reference registry detection. Returns (ok, reason).

    A ref carries a registry host only if it contains a '/' AND the first path
    segment looks like a host (has a '.', a ':port', or is 'localhost'). Otherwise
    it is a Docker Hub ref (direct). A real registry host must not be a public one.
    """
    first = val.split("/", 1)[0]
    has_registry = ("/" in val) and ("." in first or ":" in first or first == "localhost")
    if not has_registry:
        return False, "bare Docker Hub ref (no registry host)"
    host = first.lower()
    host_noport = host.split(":", 1)[0]
    if host in PUBLIC_HOSTS or host_noport in PUBLIC_HOSTS:
        return False, f"public/direct registry '{host}'"
    return True, None


def check_env_example():
    text = ENV_EXAMPLE.read_text()
    found = {}
    for m in re.finditer(r"^([A-Z0-9_]*IMAGE[A-Z0-9_]*)=(.*)$", text, re.MULTILINE):
        found[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    for req in REQUIRED_VARS:
        if req not in found:
            fail(f"{ENV_EXAMPLE.name}: {req} is not defined")
        if not found[req]:
            fail(f"{ENV_EXAMPLE.name}: {req} is empty - it must be set to your ACR ref")
    for var, val in found.items():
        if not val or "${" in val:
            continue  # blank (optional, e.g. CF_IMAGE) or a ${...} composition (UPDATE_IMAGES)
        ok, reason = classify_ref(val)
        if not ok:
            fail(f"{ENV_EXAMPLE.name}: {var}={val!r} is a {reason} - use your Alibaba ACR ref, "
                 f"e.g. registry.cn-...aliyuncs.com/<namespace>/<image>:latest")


def main():
    imgs = check_compose()
    check_env_example()
    print("OK: docker-compose images are ACR-only env refs with no direct fallback "
          f"({', '.join(imgs)}); every .env.example *IMAGE* literal targets a private registry.")


if __name__ == "__main__":
    main()
