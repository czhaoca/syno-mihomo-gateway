#!/usr/bin/env python3
"""Enforce the gateway's image-reference policy on the two committed files.

The gateway pulls its container images from a registry chosen by REGISTRY_MODE in
.env:  acr (the operator's private Alibaba ACR mirror — the default, required in
mainland China where Docker Hub / ghcr.io are blocked) or docker (upstream public
images, for a NAS with unfiltered internet). REGISTRY_MODE and the resolved image
refs live in the gitignored, per-host .env, which this check never inspects.

What it DOES enforce on the committed files:

  * docker-compose.yml — every service `image:` must be a single env reference,
    exactly `${VAR}` or `${VAR:?msg}` — never a default-value fallback
    (`${VAR:-ref}` / `${VAR:=ref}`) and never a hardcoded ref. An unset var then
    FAILS the deploy loudly instead of silently pulling something unexpected. This
    is orthogonal to acr-vs-docker and stays enforced regardless of REGISTRY_MODE.
  * .env.example — MIHOMO_IMAGE / METACUBEXD_IMAGE must be defined and non-empty
    (their value is an illustrative default; the installer rewrites it from
    REGISTRY_MODE), and REGISTRY_MODE must be present and SHIP as `acr` so a fresh
    copy defaults to the safe China path (operators opt into `docker` explicitly).
  * container names — a frozen operator contract (owner mandate 2026-07-13): every
    compose service pins `container_name:` (compose's default <project>-<service>-1
    naming broke every `docker logs mihomo` runbook once already), the two core
    services pin EXACTLY `mihomo` / `mihomo-ui`, and scripts/lib/compose.sh's
    MIHOMO_CONTAINER / METACUBEXD_CONTAINER defaults mirror the same literals so
    the script side can never drift from what compose actually creates.

Mirrors scripts/ci/render_check.py: fail() -> exit 1, print OK: on pass. Needs PyYAML.
"""
import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
COMPOSE = REPO / "docker-compose.yml"
ENV_EXAMPLE = REPO / ".env.example"
COMPOSE_SH = REPO / "scripts" / "lib" / "compose.sh"

# The frozen container-name contract: compose service -> container_name literal,
# plus the compose.sh shell default that must mirror it. A rename here is a
# breaking operator-contract change and needs explicit owner sign-off.
FROZEN_NAMES = {"mihomo": "mihomo", "metacubexd": "mihomo-ui"}
FROZEN_SH_DEFAULTS = (("MIHOMO_CONTAINER", "mihomo"), ("METACUBEXD_CONTAINER", "mihomo-ui"))

# The ONLY accepted compose image forms: a single env ref, optionally with a `:?`
# required-guard (which fails closed). Defaults (:- / :=) and hardcoded refs are
# rejected so an unset var can never silently pull an unexpected image.
ALLOWED_IMAGE = re.compile(r"^\$\{[A-Za-z_][A-Za-z0-9_]*(:\?[^}]*)?\}$")
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
                 f"drop it so an unset var FAILS instead of pulling silently (use ${{VAR:?message}})")
        if not ALLOWED_IMAGE.match(img):
            fail(f"{COMPOSE.name}: service '{name}' image {img!r} must be a bare env ref "
                 f"(${{VAR}} or ${{VAR:?msg}}) - no hardcoded registry, no fallback")
    return seen


def check_container_names():
    doc = yaml.safe_load(COMPOSE.read_text()) or {}
    services = doc.get("services") or {}
    for svc in FROZEN_NAMES:
        if svc not in services:
            fail(f"{COMPOSE.name}: core service '{svc}' is missing")
    for name, spec in services.items():
        cn = (spec or {}).get("container_name")
        if not cn:
            fail(f"{COMPOSE.name}: service '{name}' has no container_name: - compose would "
                 f"assign a project-prefixed random name and break every script and runbook "
                 f"that addresses the container by name")
        if name in FROZEN_NAMES and cn != FROZEN_NAMES[name]:
            fail(f"{COMPOSE.name}: service '{name}' pins container_name {cn!r}; the frozen "
                 f"operator contract requires {FROZEN_NAMES[name]!r} (a rename needs explicit "
                 f"owner sign-off)")
    sh = COMPOSE_SH.read_text()
    for var, frozen in FROZEN_SH_DEFAULTS:
        m = re.search(rf'^{var}="([^"]*)"', sh, re.MULTILINE)
        if not m:
            fail(f"{COMPOSE_SH.name}: {var} default assignment not found (expected "
                 f'{var}="{frozen}" at the top of the file)')
        if m.group(1) != frozen:
            fail(f"{COMPOSE_SH.name}: {var} defaults to {m.group(1)!r} but the frozen "
                 f"container-name contract requires {frozen!r} - compose and the scripts "
                 f"must always agree")


def env_values():
    """Parse KEY=VALUE assignments from .env.example (one layer of quotes stripped)."""
    found = {}
    for m in re.finditer(r"^([A-Z0-9_]+)=(.*)$", ENV_EXAMPLE.read_text(), re.MULTILINE):
        found[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return found


def check_env_example():
    found = env_values()
    for req in REQUIRED_VARS:
        if req not in found:
            fail(f"{ENV_EXAMPLE.name}: {req} is not defined")
        if not found[req]:
            fail(f"{ENV_EXAMPLE.name}: {req} is empty - give it an illustrative default ref")
    mode = found.get("REGISTRY_MODE")
    if mode is None:
        fail(f"{ENV_EXAMPLE.name}: REGISTRY_MODE is not defined (it must ship defaulting to 'acr')")
    if mode != "acr":
        fail(f"{ENV_EXAMPLE.name}: REGISTRY_MODE ships as {mode!r}; it must ship as 'acr' "
             f"(the safe mainland-China default - operators opt into 'docker' explicitly)")


def main():
    imgs = check_compose()
    check_container_names()
    check_env_example()
    print("OK: docker-compose images are fail-closed env refs "
          f"({', '.join(imgs)}); container names frozen (mihomo / mihomo-ui, every "
          "service pinned, compose.sh mirrors them); .env.example defines "
          "MIHOMO_IMAGE/METACUBEXD_IMAGE and REGISTRY_MODE ships as 'acr'.")


if __name__ == "__main__":
    main()
