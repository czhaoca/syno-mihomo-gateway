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
  * external-controller + DNS sections round-trip the injected lists EXACTLY,
    including DoH (https://) / DoT (tls://) URL entries and '#PROXY' proxy-group
    fragments in the fallback list (the China-safe .env defaults ship exactly
    that shape);
  * the split-horizon DNSPOLICY fence: knobs-unset renders byte-identical to a
    fence-stripped template (pre-1.3.8 .env compat, mirroring the EXTUI proof),
    both-knobs-set renders the exact nameserver-policy mapping with '#PROXY'
    fragments preserved while default-nameserver / proxy-server-nameserver stay
    UNPROXIED plain lists (the cold-start invariant from the 2026-07 incident),
    exactly-one-set fails loud naming the missing var, and DNS_GEOIP_NO_RESOLVE
    renders ',no-resolve' / bare / fails closed on garbage;
  * geox-url mirrors point at hosts reachable from mainland China — never the
    blocked upstream Git host or the flaky primary jsDelivr domain;
  * TUN is ON by default (transparent gateway): the DEFAULT render INCLUDES the tun block
    with stack: system (which does NOT hijack the controller reply path), allow-lan true,
    and dns enhanced-mode fake-ip; TUN_ENABLE=false OMITS the block (plain proxy);
    auto-redirect defaults to the DSM-safe false, and non-boolean TUN_* fail closed;
  * NO hardcoded DNS server / user network address remains in the committed template
    (CLAUDE.md rule) — only the generic bind/loopback constants are allowed;
  * template semantic invariants: every rules[] target is a proxy-group or a
    builtin and NEVER a proxy-provider (the `MATCH,my-airport` crash-loop
    class), group use:/proxies: references resolve, fence markers pair exactly
    once without overlap (an unpaired {{TUN_END}} otherwise makes the
    renderer's range-delete silently eat to end-of-file on the TUN-off
    render), and the template's {{TOKEN}} set equals the renderer's sed
    mapping set in BOTH directions (no unrendered token, no dead mapping);
  * EVERY rendered variant (default, TUN-off, TUN-on, auto-redirect, EXTUI) is
    scanned for unresolved {{...}} placeholders, not just the default one.

Exit non-zero on any failure.
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

import yaml

REPO = Path(__file__).resolve().parents[2]
TEMPLATE = REPO / "config" / "config.template.yaml"
RENDERER = REPO / "scripts" / "render_config.sh"
ALLOWED_IPS = {"0.0.0.0", "127.0.0.1", "198.18.0.1"}  # bind-all/loopback + fake-ip benchmark range (RFC 2544); generic, not DNS/user addrs
IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")

# A deliberately nasty fixture: label prefix + multiple `&`-joined params + `=`
# inside + a literal `"`. The URL and secret both render inside YAML double-quoted
# scalars, so a `"`/`\` not escaped for that context closes the string early (or is
# read as a YAML escape) -> invalid config -> mihomo crash-loop. These exercise
# BOTH render_config.sh escaping layers: esc() (sed: \ & |) and yaml_dq() (YAML: " \).
SUB_URL = 'https://h.example.com/api/v1/subscribe?token=a&flag=1&list=clash&note="x"'
SUB_LINE = f"Default={SUB_URL}"
SECRET = 's3cr&t|"x\\y'  # & | render via esc(); " and \ render via yaml_dq()

# DNS fixtures mirror the shipped .env.example shape: a plain-IP bootstrap
# list, DoH-on-IP domestic lists, and '#PROXY'-fragment (proxy-group-tunneled)
# foreign/fallback entries. The URLs must survive esc() (sed) and parse as YAML
# flow-sequence STRING scalars — '#' preceded by a non-space is NOT a YAML
# comment, and the exact-equality assertions prove the fragments survive.
# All six lists are pairwise DISTINCT so ANY swapped {{DNS_*}} substitution
# fails the round-trip assertions.
DNS_DEFAULT = ["223.6.6.6", "119.29.29.29"]
DNS_NS = ["https://223.5.5.5/dns-query", "https://120.53.53.53/dns-query"]
DNS_FB = ["https://1.1.1.1/dns-query#PROXY", "tls://8.8.8.8:853#PROXY"]
DNS_CN = ["https://223.4.4.4/dns-query", "https://120.53.53.102/dns-query"]
DNS_FOREIGN = ["https://1.0.0.1/dns-query#PROXY", "https://8.8.4.4/dns-query#PROXY"]

# geox-url mirror hosts that are unreachable (or too flaky to ship) from
# mainland China: the upstream Git host pair mihomo defaults to, and the
# primary jsDelivr domain (ICP-revoked; the *.jsdelivr.net CDN alternates the
# template uses instead are fine). CI-side blocklist only — scripts/ci is
# excluded from the enduser bundle, so naming them here cannot trip the
# release leak gate.
BLOCKED_GEOX_HOSTS = {
    "github.com",
    "raw.githubusercontent.com",
    "objects.githubusercontent.com",
    "cdn.jsdelivr.net",
}


def fail(msg: str):
    print(f"FAIL: {msg}")
    sys.exit(1)


def render(raw: str, tun_auto_redirect: str | None = None,
           tun_enable: str | None = None,
           external_ui_dir: str | None = None,
           dns_cn: str | None = None,
           dns_foreign: str | None = None,
           geoip_no_resolve: str | None = None):
    """Run the real renderer in an isolated config directory."""
    with tempfile.TemporaryDirectory() as td:
        tdp = Path(td)
        (tdp / "config.template.yaml").write_text(raw)
        (tdp / "subscription.txt").write_text(SUB_LINE + "\n")
        # Minimal env, NOT **os.environ: the checker itself must not inherit
        # dev/CI shell variables (a stray MIHOMO_TEMPLATE or TUN_ENABLE would
        # silently redirect or skew the render under test) — the same
        # env-bleed class that once masked a source-time-default bug in the
        # shell harnesses. Only PATH passes through (sh/sed/awk locations).
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "MIHOMO_CONFIG_DIR": str(tdp),
            "CONTROLLER_PORT": "9090",
            "CONTROLLER_SECRET": SECRET,
            "DNS_DEFAULT_NAMESERVER": ",".join(DNS_DEFAULT),
            "DNS_NAMESERVER": ",".join(DNS_NS),
            "DNS_FALLBACK": ",".join(DNS_FB),
        }
        if tun_auto_redirect is not None:
            env["TUN_AUTO_REDIRECT"] = tun_auto_redirect
        if tun_enable is not None:
            env["TUN_ENABLE"] = tun_enable
        if external_ui_dir is not None:
            env["EXTERNAL_UI_DIR"] = external_ui_dir
        # Split-horizon knobs stay ABSENT unless a case opts in, so every
        # pre-existing render in this suite doubles as the legacy-path
        # (pre-1.3.8 .env) regression.
        if dns_cn is not None:
            env["DNS_CN_NAMESERVER"] = dns_cn
        if dns_foreign is not None:
            env["DNS_FOREIGN_NAMESERVER"] = dns_foreign
        if geoip_no_resolve is not None:
            env["DNS_GEOIP_NO_RESOLVE"] = geoip_no_resolve
        proc = subprocess.run(["sh", str(RENDERER)], env=env,
                              capture_output=True, text=True)
        out = tdp / "config.yaml"
        return proc, out.read_text() if out.exists() else None


def strip_fence(raw: str, name: str) -> str:
    """Delete the {{NAME_BEGIN}}..{{NAME_END}} range, like the renderer's sed."""
    out, skipping = [], False
    for line in raw.splitlines(keepends=True):
        if f"{{{{{name}_BEGIN}}}}" in line:
            skipping = True
            continue
        if f"{{{{{name}_END}}}}" in line:
            skipping = False
            continue
        if not skipping:
            out.append(line)
    return "".join(out)


TOKEN = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
FENCE = re.compile(r"\{\{([A-Z0-9_]+)_(BEGIN|END)\}\}")


def assert_resolved(variant: str, rendered: str):
    """No {{...}} may survive into any rendered variant."""
    unresolved = re.findall(r"\{\{[^}]+\}\}", rendered)
    if unresolved:
        fail(f"[{variant}] unresolved placeholders after render: {unresolved}")


def check_fences(raw: str):
    """Fence markers pair exactly once, BEGIN before END, ranges disjoint.

    The renderer deletes a disabled fence with `sed /BEGIN/,/END/d`: with the
    END marker missing, sed's range runs to end-of-file and silently deletes
    the rest of the template — every downstream assertion on that variant
    still passes because both sides of the byte-identity compare are mangled
    the same way. This is the structural guard.
    """
    names = {m.group(1) for m in FENCE.finditer(raw)}
    spans = []
    for name in sorted(names):
        begins = [m.start() for m in re.finditer(re.escape(f"{{{{{name}_BEGIN}}}}"), raw)]
        ends = [m.start() for m in re.finditer(re.escape(f"{{{{{name}_END}}}}"), raw)]
        if len(begins) != 1 or len(ends) != 1:
            fail(f"fence {name}: {len(begins)}x BEGIN / {len(ends)}x END "
                 f"(need exactly one pair; an unpaired marker makes the renderer's "
                 f"range-delete eat to end-of-file)")
        if begins[0] >= ends[0]:
            fail(f"fence {name}: BEGIN marker appears after END")
        spans.append((begins[0], ends[0], name))
    spans.sort()
    for (_, e1, n1), (b2, _, n2) in zip(spans, spans[1:]):
        if b2 < e1:
            fail(f"fences {n1} and {n2} overlap — range-deletes would interleave")


def check_token_mapping(raw: str):
    """Template {{TOKEN}} set == renderer token set, both directions.

    A template token with no renderer mapping survives into config.yaml (an
    unresolved placeholder mihomo chokes on); a renderer mapping with no
    template site is a dead or typo'd sed rule. Both directions are compared
    against the literal {{TOKEN}} strings in scripts/render_config.sh (fence
    markers included — the renderer names those in its sed ranges too).
    """
    template_tokens = {m.group(1) for m in TOKEN.finditer(raw)}
    # Template comments COUNT (fence markers live on '# {{X_BEGIN}}' lines);
    # renderer comments do not (its prose mentions generic {{X_BEGIN}} names) —
    # only the renderer's code lines carry real sed patterns.
    renderer_code = "\n".join(
        line for line in RENDERER.read_text().splitlines()
        if not line.lstrip().startswith("#"))
    renderer_tokens = {m.group(1) for m in TOKEN.finditer(renderer_code)}
    missing = template_tokens - renderer_tokens
    if missing:
        fail(f"template token(s) with no renderer mapping (would survive into "
             f"config.yaml): {sorted(missing)}")
    dead = renderer_tokens - template_tokens
    if dead:
        fail(f"renderer mapping(s) with no template site (dead/typo'd sed rule): "
             f"{sorted(dead)}")


def check_rule_targets(doc):
    """Every rule/group reference resolves; a rule may NEVER target a provider.

    `MATCH,my-airport` (a proxy-provider target) crash-looped mihomo in
    production — rules can only target a proxy-group or a builtin. Groups'
    use:/proxies: references are held to the same standard.
    """
    groups = [g.get("name") for g in doc.get("proxy-groups") or [] if isinstance(g, dict)]
    providers = set((doc.get("proxy-providers") or {}).keys())
    builtins = {"DIRECT", "REJECT", "REJECT-DROP", "PASS"}
    valid = set(groups) | builtins
    if len(set(groups)) != len(groups):
        fail(f"duplicate proxy-group names: {groups}")
    for rule in doc.get("rules") or []:
        parts = [p.strip() for p in str(rule).split(",")]
        if len(parts) < 2:
            fail(f"malformed rule: {rule!r}")
        target = parts[1] if parts[0] == "MATCH" else (parts[2] if len(parts) >= 3 else None)
        if target is None:
            fail(f"rule has no target: {rule!r}")
        if target in providers and target not in valid:
            fail(f"rule {rule!r} targets proxy-provider {target!r}: rules may only "
                 f"target a group or builtin (a provider target crash-loops mihomo)")
        if target not in valid:
            fail(f"rule {rule!r} targets unknown {target!r} "
                 f"(groups: {sorted(set(groups))}, builtins: {sorted(builtins)})")
    for g in doc.get("proxy-groups") or []:
        for u in g.get("use") or []:
            if u not in providers:
                fail(f"group {g.get('name')!r} uses unknown provider {u!r}")
        for p in g.get("proxies") or []:
            if p not in valid:
                fail(f"group {g.get('name')!r} references unknown proxy/group {p!r}")


def main() -> None:
    raw = TEMPLATE.read_text()

    # 1) No hardcoded DNS / network address literals in the committed template.
    leftover = [ip for ip in IPV4.findall(raw) if ip not in ALLOWED_IPS]
    if leftover:
        fail(f"hardcoded IP literal(s) in {TEMPLATE.name}: {sorted(set(leftover))} "
             f"(use {{placeholders}} + .env per CLAUDE.md)")

    # 1b) Static semantic invariants: fence pairing + bidirectional token map.
    check_fences(raw)
    check_token_mapping(raw)

    # 2) Run the REAL renderer with the backwards-compatible omitted-key path.
    proc, rendered = render(raw)
    if proc.returncode != 0 or rendered is None:
        fail(f"render_config.sh exited {proc.returncode}: {proc.stderr.strip()}")

    assert_resolved("default", rendered)

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

    # 4b) CORS must permit a self-hosted dashboard origin. mihomo's default allow-list
    # excludes arbitrary LAN addresses, so a NAS-hosted MetaCubeXD on a different
    # host:port is otherwise rejected by the browser ("cannot connect to backend").
    cors = doc.get("external-controller-cors") or {}
    if "*" not in (cors.get("allow-origins") or []):
        fail(f"external-controller-cors.allow-origins must allow '*': {cors.get('allow-origins')!r}")
    if cors.get("allow-private-network") is not True:
        fail("external-controller-cors.allow-private-network must be true (Chrome PNA preflight)")

    # 5) DNS lists must round-trip EXACTLY: the comma list splits into flow-seq
    # items, and DoH/DoT URL entries stay STRING scalars (a YAML mis-parse would
    # surface here as a dict or a mangled token). proxy-server-nameserver reuses
    # the domestic list so node hostnames resolve without the fallback-filter
    # (the filtered-network chicken-and-egg observed in production).
    dns = doc.get("dns") or {}
    for field, expected in (("default-nameserver", DNS_DEFAULT),
                            ("nameserver", DNS_NS),
                            ("proxy-server-nameserver", DNS_NS),
                            ("fallback", DNS_FB)):
        servers = dns.get(field)
        if servers != expected:
            fail(f"dns.{field} did not round-trip: got {servers!r}, expected {expected!r}")

    # 5b) Rule / group / provider reference integrity (the MATCH,my-airport
    # crash-loop class) on the fully rendered document.
    check_rule_targets(doc)

    # 5c) geox-url mirrors must be pinned and reachable from mainland China.
    # mihomo's compiled-in default source is the blocked upstream Git host, so
    # a first start with no cached geodata would hang forever behind the GFW —
    # the template must keep pointing every entry at a reachable CDN mirror.
    geox = doc.get("geox-url") or {}
    for key in ("geoip", "geosite", "mmdb"):
        u = geox.get(key)
        if not u:
            fail(f"geox-url.{key} missing: the template must pin a geodata mirror "
                 f"(mihomo's default source is blocked in mainland China)")
        host = urlparse(str(u)).hostname or ""
        if host in BLOCKED_GEOX_HOSTS:
            fail(f"geox-url.{key} points at {host!r}, which is unreachable/flaky "
                 f"from mainland China — use a reachable CDN mirror")
        if not str(u).startswith("https://"):
            fail(f"geox-url.{key} must be https:// (got {u!r})")

    # 6) DEFAULT render is TUN-ON (this is a transparent gateway). The tun block MUST be
    # present with stack: system, which (unlike mixed/gvisor) does NOT hijack the
    # external-controller reply path (mihomo #1493) - the VERIFIED working config.
    dtun = doc.get("tun")
    if not isinstance(dtun, dict) or dtun.get("enable") is not True:
        fail(f"default render must INCLUDE an enabled tun block (TUN on by default); got {dtun!r}")
    if dtun.get("stack") != "system":
        fail(f"tun.stack must be 'system' to keep the controller reachable; got {dtun.get('stack')!r}")
    # allow-lan lets LAN devices also use mihomo as an explicit proxy; fake-ip is the
    # standard DNS mode for a clean TUN gateway.
    if doc.get("allow-lan") is not True:
        fail(f"allow-lan must be true for LAN clients; got {doc.get('allow-lan')!r}")
    if (doc.get("dns") or {}).get("enhanced-mode") != "fake-ip":
        fail(f"dns.enhanced-mode must be 'fake-ip' for the TUN gateway; got {(doc.get('dns') or {}).get('enhanced-mode')!r}")
    for port_field, expected in (("redir-port", 7892), ("tproxy-port", 7893)):
        if doc.get(port_field) != expected:
            fail(f"{port_field}={doc.get(port_field)!r}, expected {expected!r}")
    # The toggle still works: TUN_ENABLE=false OMITS the block (plain-proxy mode).
    proc_off, off = render(raw, tun_enable="false")
    if proc_off.returncode != 0 or off is None:
        fail(f"TUN_ENABLE=false render failed: {proc_off.stderr.strip()}")
    assert_resolved("TUN-off", off)
    if yaml.safe_load(off).get("tun") is not None:
        fail("TUN_ENABLE=false must OMIT the tun block (plain-proxy mode)")

    # 7) TUN_ENABLE=true renders the full transparent-gateway block (auto-redirect
    # defaults to the DSM-safe false). A mounted /dev/net/tun alone is insufficient.
    proc, tun_on = render(raw, tun_enable="true")
    if proc.returncode != 0 or tun_on is None:
        fail(f"TUN_ENABLE=true render failed: {proc.stderr.strip()}")
    assert_resolved("TUN-on", tun_on)
    tun = (yaml.safe_load(tun_on).get("tun") or {})
    required_tun = {
        "enable": True,
        "device": "mihomo-tun",
        "stack": "system",
        "auto-route": True,
        "auto-redirect": False,
        "auto-detect-interface": True,
    }
    for field, expected in required_tun.items():
        if tun.get(field) != expected:
            fail(f"[TUN on] tun.{field}={tun.get(field)!r}, expected {expected!r}")
    hijack = tun.get("dns-hijack") or []
    for required in ("any:53", "tcp://any:53"):
        if required not in hijack:
            fail(f"[TUN on] tun.dns-hijack missing {required!r}: {hijack!r}")

    # 8) auto-redirect opt-in must render as a YAML boolean (only meaningful with TUN
    # on); invalid TUN_AUTO_REDIRECT / TUN_ENABLE fail closed without writing config.yaml.
    proc, opted_in = render(raw, tun_auto_redirect="true", tun_enable="true")
    if proc.returncode != 0 or opted_in is None:
        fail(f"TUN auto-redirect opt-in failed: {proc.stderr.strip()}")
    assert_resolved("TUN-on+auto-redirect", opted_in)
    if (yaml.safe_load(opted_in).get("tun") or {}).get("auto-redirect") is not True:
        fail("TUN_AUTO_REDIRECT=true did not render as YAML true")
    proc, invalid = render(raw, tun_auto_redirect="yes")
    if proc.returncode == 0 or invalid is not None:
        fail("invalid TUN_AUTO_REDIRECT was accepted or wrote config.yaml")
    proc, invalid_te = render(raw, tun_enable="maybe")
    if proc.returncode == 0 or invalid_te is not None:
        fail("invalid TUN_ENABLE was accepted or wrote config.yaml")

    # 9) external-ui fence (Pi bare-metal mode). The DSM compose path never sets
    # EXTERNAL_UI_DIR, so the default render must carry no external-ui key and be
    # byte-identical to rendering a template with the fenced range stripped —
    # the mechanical proof the fence is inert for every existing deployment.
    if "{{EXTUI_BEGIN}}" not in raw or "{{EXTUI_END}}" not in raw:
        fail("template must carry the {{EXTUI_BEGIN}}/{{EXTUI_END}} fence")
    if "external-ui" in (yaml.safe_load(rendered) or {}):
        fail("default render must NOT contain external-ui (EXTERNAL_UI_DIR unset)")
    proc_s, stripped_render = render(strip_fence(raw, "EXTUI"))
    if proc_s.returncode != 0 or stripped_render is None:
        fail(f"fence-stripped render failed: {proc_s.stderr.strip()}")
    if stripped_render != rendered:
        fail("default render is not byte-identical to a fence-less template render")
    if "\n\n\n" in rendered:
        fail("default render contains doubled blank lines — the fence must sit flush "
             "against its neighbor so range-deletion leaves the original spacing")
    # TUN-off + EXTUI-unset is the most common alternate DSM config; the
    # inertness guarantee must hold on that permutation too (`off` is the
    # TUN_ENABLE=false render from section 6).
    proc_so, stripped_off = render(strip_fence(raw, "EXTUI"), tun_enable="false")
    if proc_so.returncode != 0 or stripped_off is None:
        fail(f"fence-stripped TUN-off render failed: {proc_so.stderr.strip()}")
    if stripped_off != off:
        fail("TUN-off default render is not byte-identical to a fence-less template render")
    if "\n\n\n" in off:
        fail("TUN-off default render contains doubled blank lines")
    ui_dir = "/data/u i/metacubexd"  # space exercises the YAML double-quoted path
    proc_e, extui = render(raw, external_ui_dir=ui_dir)
    if proc_e.returncode != 0 or extui is None:
        fail(f"EXTERNAL_UI_DIR render failed: {proc_e.stderr.strip()}")
    assert_resolved("EXTUI", extui)
    if yaml.safe_load(extui).get("external-ui") != ui_dir:
        fail(f"external-ui did not round-trip: {yaml.safe_load(extui).get('external-ui')!r}")

    # 10) Split-horizon DNS policy fence (privacy hardening). Knobs UNSET —
    # which is every render above — must be INERT: no nameserver-policy key,
    # the bare GEOIP rule, and byte-identity against a template with the
    # DNSPOLICY fence stripped and the {{GEOIP_NO_RESOLVE}} token removed.
    # That is the mechanical proof a pre-1.3.8 .env renders exactly as before.
    if "{{DNSPOLICY_BEGIN}}" not in raw or "{{DNSPOLICY_END}}" not in raw:
        fail("template must carry the {{DNSPOLICY_BEGIN}}/{{DNSPOLICY_END}} fence")
    if "{{GEOIP_NO_RESOLVE}}" not in raw:
        fail("template must carry the {{GEOIP_NO_RESOLVE}} token on the GEOIP,CN rule")
    if "nameserver-policy" in (doc.get("dns") or {}):
        fail("default render must NOT contain nameserver-policy (knobs unset)")
    if doc.get("rules") != ["GEOSITE,CN,DIRECT", "GEOIP,CN,DIRECT", "MATCH,PROXY"]:
        fail(f"default rules must be the bare legacy triple in order: {doc.get('rules')!r}")
    legacy_raw = strip_fence(raw, "DNSPOLICY").replace("{{GEOIP_NO_RESOLVE}}", "")
    proc_l, legacy = render(legacy_raw)
    if proc_l.returncode != 0 or legacy is None:
        fail(f"DNSPOLICY-stripped render failed: {proc_l.stderr.strip()}")
    if legacy != rendered:
        fail("knobs-unset render is not byte-identical to a DNSPOLICY-less "
             "template render — the fence/token are not inert for existing .env files")
    # EMPTY-STRING knobs must behave exactly like unset ones: docker-compose
    # passes '${DNS_CN_NAMESERVER:-}' through as an empty env var for every
    # pre-1.3.8 .env, so empty==off is the interop contract with the compose
    # environment allowlist (the renderer's ':=' colon-form normalizes null).
    proc_es, empty_set = render(raw, dns_cn="", dns_foreign="", geoip_no_resolve="")
    if proc_es.returncode != 0 or empty_set != rendered:
        fail("empty-string knobs must render byte-identical to unset knobs "
             "(the compose ':-' pass-through contract)")

    # Both knobs set: the policy block renders with the exact mapping, and the
    # '#PROXY' proxy-group fragments survive into the parsed YAML values. The
    # cold-start invariants hold on THIS variant too: default-nameserver and
    # proxy-server-nameserver keep their plain domestic lists with NO '#'
    # fragment (proxied bootstrap = the 2026-07 incident chicken-and-egg).
    proc_p, pol = render(raw, dns_cn=",".join(DNS_CN), dns_foreign=",".join(DNS_FOREIGN))
    if proc_p.returncode != 0 or pol is None:
        fail(f"split-horizon render failed: {proc_p.stderr.strip()}")
    assert_resolved("DNSPOLICY", pol)
    if "\n\n\n" in pol:
        fail("split-horizon render contains doubled blank lines — the fence must "
             "sit flush against its neighbors")
    pdoc = yaml.safe_load(pol)
    policy = (pdoc.get("dns") or {}).get("nameserver-policy")
    expected_policy = {"geosite:cn": DNS_CN, "geosite:geolocation-!cn": DNS_FOREIGN}
    if policy != expected_policy:
        fail(f"nameserver-policy did not round-trip: got {policy!r}, "
             f"expected {expected_policy!r}")
    for field, expected in (("default-nameserver", DNS_DEFAULT),
                            ("nameserver", DNS_NS),
                            ("proxy-server-nameserver", DNS_NS),
                            ("fallback", DNS_FB)):
        if (pdoc.get("dns") or {}).get(field) != expected:
            fail(f"[DNSPOLICY] dns.{field} did not round-trip: "
                 f"{(pdoc.get('dns') or {}).get(field)!r}")
    for field in ("default-nameserver", "proxy-server-nameserver"):
        tunneled = [e for e in (pdoc.get("dns") or {}).get(field) or [] if "#" in str(e)]
        if tunneled:
            fail(f"dns.{field} must stay UNPROXIED — no '#group' fragments "
                 f"(cold-start invariant): {tunneled}")
    check_rule_targets(pdoc)

    # Exactly ONE knob set is a broken half-configuration: fail loud, write
    # nothing, and NAME the missing variable in the error.
    for kwargs, missing in (({"dns_cn": "223.5.5.5"}, "DNS_FOREIGN_NAMESERVER"),
                            ({"dns_foreign": "https://1.0.0.1/dns-query#PROXY"},
                             "DNS_CN_NAMESERVER")):
        proc_h, half = render(raw, **kwargs)
        if proc_h.returncode == 0 or half is not None:
            fail(f"half-configured split-horizon ({list(kwargs)[0]} only) was "
                 f"accepted or wrote config.yaml")
        if missing not in proc_h.stderr:
            fail(f"half-configured error must name the missing {missing}: "
                 f"{proc_h.stderr.strip()!r}")

    # 11) DNS_GEOIP_NO_RESOLVE opt-in, independent of the policy knobs:
    # true appends ',no-resolve' to the GEOIP rule (and ONLY that rule),
    # false is byte-identical to unset, garbage fails closed.
    proc_nr, nr = render(raw, geoip_no_resolve="true")
    if proc_nr.returncode != 0 or nr is None:
        fail(f"DNS_GEOIP_NO_RESOLVE=true render failed: {proc_nr.stderr.strip()}")
    assert_resolved("no-resolve", nr)
    nrdoc = yaml.safe_load(nr)
    if nrdoc.get("rules") != ["GEOSITE,CN,DIRECT", "GEOIP,CN,DIRECT,no-resolve",
                              "MATCH,PROXY"]:
        fail(f"DNS_GEOIP_NO_RESOLVE=true rules wrong: {nrdoc.get('rules')!r}")
    check_rule_targets(nrdoc)  # the trailing flag must not confuse target resolution
    proc_nf, nf = render(raw, geoip_no_resolve="false")
    if proc_nf.returncode != 0 or nf != rendered:
        fail("DNS_GEOIP_NO_RESOLVE=false must render byte-identical to unset")
    proc_nb, nb = render(raw, geoip_no_resolve="yes")
    if proc_nb.returncode == 0 or nb is not None:
        fail("invalid DNS_GEOIP_NO_RESOLVE was accepted or wrote config.yaml")

    print("OK: renderer preserves URL/secrets; controller, DNS, CORS valid; TUN is ON by "
          "default (stack: system keeps the controller reachable, allow-lan + fake-ip set; "
          "TUN_ENABLE=false omits the block); auto-redirect/enable opt-ins are strict; "
          "external-ui + split-horizon DNSPOLICY fences inert when unset (byte-identical "
          "legacy render); policy-on round-trips nameserver-policy with #PROXY fragments "
          "while default/proxy-server-nameserver stay unproxied; half-config fails loud; "
          "GEOIP no-resolve knob strict; geox-url hosts China-reachable; no hardcoded "
          "literals; fences pair, tokens map bidirectionally, rule/group targets resolve "
          "(never a provider), and every variant renders placeholder-free.")


if __name__ == "__main__":
    main()
