#!/usr/bin/env python3
r"""Validate the config renderer end-to-end by invoking the REAL renderer.

This shells out to scripts/render_config.sh (the same script the mihomo container
runs) against a temp config dir with a realistic subscription.txt fixture, so the
runtime awk/sed logic is actually exercised — earlier this check used a Python
str.replace() stand-in and therefore missed two critical rendering bugs.

Enforces:
  * the subscription URL round-trips EXACTLY, including a `Name=` prefix, `&`
    query separators, AND a literal `"` (regression guard for the rendering bugs,
    incl. the YAML double-quoted-scalar escaping — url renders inside `url: "..."`);
  * a controller secret containing `&`, `|`, `"` AND `\` renders verbatim
    (secret renders inside `secret: "..."`, so `"`/`\` must be YAML-escaped);
  * external-controller + DNS sections are present and correctly typed (lists);
  * NO hardcoded DNS server / user network address remains in the committed template
    (CLAUDE.md rule) — only the generic bind/loopback constants are allowed.

Exit non-zero on any failure.
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
TEMPLATE = REPO / "config" / "config.template.yaml"
RENDERER = REPO / "scripts" / "render_config.sh"
ALLOWED_IPS = {"0.0.0.0", "127.0.0.1"}  # bind-all / loopback are generic, not DNS/user addrs
IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")

# A deliberately nasty fixture: label prefix + multiple `&`-joined params + `=`
# inside + a literal `"`. The URL and secret both render inside YAML double-quoted
# scalars, so a `"`/`\` not escaped for that context closes the string early (or is
# read as a YAML escape) -> invalid config -> mihomo crash-loop. These exercise
# BOTH render_config.sh escaping layers: esc() (sed: \ & |) and yaml_dq() (YAML: " \).
SUB_URL = 'https://h.example.com/api/v1/subscribe?token=a&flag=1&list=clash&note="x"'
SUB_LINE = f"Default={SUB_URL}"
SECRET = 's3cr&t|"x\\y'  # & | render via esc(); " and \ render via yaml_dq()


def fail(msg: str):
    print(f"FAIL: {msg}")
    sys.exit(1)


def main() -> None:
    raw = TEMPLATE.read_text()

    # 1) No hardcoded DNS / network address literals in the committed template.
    leftover = [ip for ip in IPV4.findall(raw) if ip not in ALLOWED_IPS]
    if leftover:
        fail(f"hardcoded IP literal(s) in {TEMPLATE.name}: {sorted(set(leftover))} "
             f"(use {{placeholders}} + .env per CLAUDE.md)")

    # 2) Run the REAL renderer against a temp config dir.
    with tempfile.TemporaryDirectory() as td:
        tdp = Path(td)
        (tdp / "config.template.yaml").write_text(raw)
        (tdp / "subscription.txt").write_text(SUB_LINE + "\n")
        env = {
            **os.environ,
            "MIHOMO_CONFIG_DIR": str(tdp),
            "CONTROLLER_PORT": "9090",
            "CONTROLLER_SECRET": SECRET,
            "DNS_DEFAULT_NAMESERVER": "114.114.114.114,223.5.5.5",
            "DNS_NAMESERVER": "114.114.114.114,223.5.5.5",
            "DNS_FALLBACK": "8.8.8.8,8.8.4.4",
        }
        proc = subprocess.run(["sh", str(RENDERER)], env=env,
                              capture_output=True, text=True)
        if proc.returncode != 0:
            fail(f"render_config.sh exited {proc.returncode}: {proc.stderr.strip()}")
        rendered = (tdp / "config.yaml").read_text()

    unresolved = re.findall(r"\{\{[^}]+\}\}", rendered)
    if unresolved:
        fail(f"unresolved placeholders after render: {unresolved}")

    doc = yaml.safe_load(rendered)

    # 3) Subscription URL must round-trip EXACTLY (the critical regression).
    url = (((doc.get("proxy-providers") or {}).get("my-airport")) or {}).get("url")
    if url != SUB_URL:
        fail(f"subscription URL mangled: got {url!r}, expected {SUB_URL!r}")

    # 4) Controller + secret (secret tests &/| escaping).
    ec = doc.get("external-controller")
    if not ec or not ec.endswith(":9090"):
        fail(f"external-controller missing/wrong: {ec!r}")
    if doc.get("secret") != SECRET:
        fail(f"controller secret mangled: got {doc.get('secret')!r}, expected {SECRET!r}")

    # 5) DNS lists.
    dns = doc.get("dns") or {}
    for field in ("default-nameserver", "nameserver", "fallback"):
        servers = dns.get(field)
        if not isinstance(servers, list) or not servers:
            fail(f"dns.{field} did not parse as a non-empty list: {servers!r}")

    print("OK: real renderer round-trips the subscription URL (with Name= prefix & '&' "
          "params) and secret exactly; controller + DNS valid; no hardcoded DNS/network literals.")


if __name__ == "__main__":
    main()
