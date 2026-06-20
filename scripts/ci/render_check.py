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
  * TUN auto-redirect defaults to the DSM-safe false value, accepts an explicit
    true opt-in, and rejects non-boolean input before writing config.yaml;
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


def render(raw: str, tun_auto_redirect: str | None = None):
    """Run the real renderer in an isolated config directory."""
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
        env.pop("TUN_AUTO_REDIRECT", None)
        if tun_auto_redirect is not None:
            env["TUN_AUTO_REDIRECT"] = tun_auto_redirect
        proc = subprocess.run(["sh", str(RENDERER)], env=env,
                              capture_output=True, text=True)
        out = tdp / "config.yaml"
        return proc, out.read_text() if out.exists() else None


def main() -> None:
    raw = TEMPLATE.read_text()

    # 1) No hardcoded DNS / network address literals in the committed template.
    leftover = [ip for ip in IPV4.findall(raw) if ip not in ALLOWED_IPS]
    if leftover:
        fail(f"hardcoded IP literal(s) in {TEMPLATE.name}: {sorted(set(leftover))} "
             f"(use {{placeholders}} + .env per CLAUDE.md)")

    # 2) Run the REAL renderer with the backwards-compatible omitted-key path.
    proc, rendered = render(raw)
    if proc.returncode != 0 or rendered is None:
        fail(f"render_config.sh exited {proc.returncode}: {proc.stderr.strip()}")

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

    # 6) The advertised LAN-gateway behavior requires a real interception
    # dataplane. A mounted /dev/net/tun and an open tproxy-port are insufficient.
    tun = doc.get("tun") or {}
    required_tun = {
        "enable": True,
        "device": "mihomo-tun",
        "stack": "mixed",
        "auto-route": True,
        "auto-redirect": False,
        "auto-detect-interface": True,
    }
    for field, expected in required_tun.items():
        if tun.get(field) != expected:
            fail(f"tun.{field}={tun.get(field)!r}, expected {expected!r}")
    hijack = tun.get("dns-hijack") or []
    for required in ("any:53", "tcp://any:53"):
        if required not in hijack:
            fail(f"tun.dns-hijack missing {required!r}: {hijack!r}")

    # 7) A deliberate opt-in must render as a YAML boolean, while invalid
    # spellings fail closed without producing a config file.
    proc, opted_in = render(raw, "true")
    if proc.returncode != 0 or opted_in is None:
        fail(f"TUN auto-redirect opt-in failed: {proc.stderr.strip()}")
    if (yaml.safe_load(opted_in).get("tun") or {}).get("auto-redirect") is not True:
        fail("TUN_AUTO_REDIRECT=true did not render as YAML true")
    proc, invalid = render(raw, "yes")
    if proc.returncode == 0 or invalid is not None:
        fail("invalid TUN_AUTO_REDIRECT was accepted or wrote config.yaml")

    print("OK: renderer preserves URL/secrets; controller, DNS, and DSM-safe TUN defaults are "
          "valid; auto-redirect opt-in is strict; no hardcoded DNS/network literals.")


if __name__ == "__main__":
    main()
