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
    including DoH (https://) / DoT (tls://) URL entries and '#auto' detour
    fragments (route-this-resolver-through-the-auto-group; the China-safe
    .env defaults ship exactly that shape);
  * split-horizon v2 (foreign-by-default) is the ONLY DNS profile (the
    2026-07-14 purge, issue #43): DNS_CN_NAMESERVER + DNS_FOREIGN_NAMESERVER
    are REQUIRED — missing or empty fails loud NAMING the variable, writing
    nothing — and every render carries the exact nameserver-policy mapping
    with dns.nameserver = the tunneled foreign list while
    fallback/fallback-filter are ABSENT (the dual-query copy channel to
    domestic resolvers is gone; a dead tunnel fails closed);
    default-nameserver / proxy-server-nameserver stay UNPROXIED plain lists
    (the cold-start invariant from the 2026-07 incident); the template
    carries NO legacy DNS fence markers and no {{DNS_FALLBACK}} token; and
    DNS_GEOIP_NO_RESOLVE renders ',no-resolve' / bare / fails closed on
    garbage;
  * the bootstrap DNS pins (2026-07-12 provider outage): EVERY variant pins the
    geodata mirror, the health-check host (www.gstatic.com — delay probes and
    the COMPATIBLE placeholder dial DIRECT and must resolve tunnel-free), AND
    the airport-panel host (derived from subscription.txt) to the domestic
    nameserver list via nameserver-policy, lists mirror+panel in
    fake-ip-filter, and gives the provider the stable cache path
    ./proxies/my-airport.yaml; an IP-literal subscription host renders the
    panel pins as comments (no DNS needed) while the mirror+gstatic pins remain;
  * the rule chain is exact (LAN-direct with no-resolve first —
    private/link-local destinations never ride the tunnel — then the
    streaming service rules: NETFLIX plus the four audio services
    SPOTIFY/TIDAL/DEEZER/SOUNDCLOUD -> Streaming Sites, all before CN-direct
    before GEOLOCATION-!CN->Proxy Mode before the GEOIP fallthrough), the
    Streaming Sites select group defaults to Proxy Mode
    (day-one behavior unchanged until an unlock node is pinned), and every
    '#group' detour fragment on a DNS server entry names a real proxy-group;
  * the SNIFFER fence: unset/false renders WITHOUT the block byte-identically
    (upgrade compat); true renders SNI/HTTP/QUIC sniffing with
    parse-pure-ip + override-destination (restores domain routing for
    LAN clients that resolve DNS outside the gateway — the v1.3.10
    raw-IP-flows incident); garbage fails closed;
  * the group-model-streamline graph (vNEXT): the selectors render FIRST
    (dashboard order = config order) — Proxy Mode (the rule target:
    Country Pick, DIRECT, REJECT + raw provider nodes), Streaming Sites
    (Proxy Mode first + the country splice + DIRECT + raw nodes), Country
    Pick (the country splice ONLY — no DIRECT/REJECT, no raw nodes) — then
    the generated '<Country> Auto' groups, then All Nodes LAST as a
    hidden: true full-pool url-test kept solely as the DNS detour anchor
    (the '#All Nodes' fragments in every deployed .env keep working, and
    LAN-wide resolution never depends on a dashboard pick);
  * the Priority Nodes category is PURGED (vNEXT): no PRIORITY fences or
    tokens survive in the template, .env.example ships no PRIORITY_* line,
    and a stale .env still setting PRIORITY_INCLUDE_FILTER /
    PRIORITY_EXCLUDE_FILTER (or the older AUTO_EXCLUDE_FILTER) refuses to
    render with a removal-instruction error (the owner-ratified fail-loud
    tripwire pattern — never a silent route-default change);
  * the COUNTRY_GROUPS generation markers: the 'NAME=regex;NAME=regex' spec
    is REQUIRED (Country Pick's members ARE the generated groups — a
    missing or empty spec refuses to render, naming the variable and
    pointing at the .env.example default); each entry generates one
    url-test group (filter, empty-fallback REJECT, tolerance, NO own
    url:/interval:) spliced into the Country Pick and Streaming Sites
    selectors, a multi-country regex being one combined group; the group
    inventory assertions are SPEC-DERIVED, never a hardcoded country list;
    every malformed-spec class (backtick, no '=', empty name/regex/entry,
    duplicate or reserved-colliding or whitespace-bearing name) refuses to
    render, with BOTH the new selector names and the retired legacy names
    reserved;
  * DNS detour fragments are validated at RENDER time too: a '#group'
    fragment in any DNS_* list that names no rendered group (e.g. a stale
    '#Priority Nodes' in a pre-vNEXT .env) refuses to render loudly — the
    runtime failure mode is silent dead resolvers, so the renderer owns
    the loud gate — and the .env.example's REAL DNS values are themselves
    rendered and detour-checked (the fragment can never drift from the
    rendered inventory again);
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
# list, DoH-on-IP domestic lists, and '#All Nodes'-fragment foreign entries
# (detoured through the hidden full-pool url-test anchor — NOT '#Proxy Mode',
# so a dashboard DIRECT pin or an empty country pick cannot kill or leak
# long-tail resolution). The URLs must
# survive esc() (sed) and parse as YAML flow-sequence STRING scalars — '#'
# preceded by a non-space is NOT a YAML comment, and the exact-equality
# assertions prove the fragments survive.
# All five lists are pairwise DISTINCT so ANY swapped {{DNS_*}} substitution
# fails the round-trip assertions.
DNS_DEFAULT = ["223.6.6.6", "119.29.29.29"]
DNS_NS = ["https://223.5.5.5/dns-query", "https://120.53.53.53/dns-query"]
DNS_CN = ["https://223.4.4.4/dns-query", "https://120.53.53.102/dns-query"]
DNS_FOREIGN = ["https://1.0.0.1/dns-query#All Nodes", "https://8.8.4.4/dns-query#All Nodes"]

# COUNTRY_GROUPS is REQUIRED (Country Pick's members ARE the generated
# groups), so every render in this suite carries a spec. The default fixture
# exercises a spaced Latin name AND a CJK name; failure cases pass
# country_groups=None (absent) / "" (the compose ':-' passthrough of a stale
# pre-country .env) explicitly.
DEFAULT_CG = 'Japan Auto=日本|JP\\d|^JP;美国=美国|US\\d'

# The full rule chain. Order is semantic: LAN first (raw-IP flows
# to private/link-local destinations go DIRECT before anything else — the
# production incident where Windows Delivery Optimization peers at foreign
# RFC1918 addresses rode the tunnel; 'lan' is HARDCODED in mihomo and needs
# no geo database, and no-resolve is mandatory so the top-of-chain GEOIP
# never forces a lookup of domain flows), the streaming service rules —
# NETFLIX + the audio services (proxy-groups-v2 #41) — before
# GEOLOCATION-!CN (each service is a subset — a later rule would never
# match), and both GEOSITE foreign rules before the GEOIP,CN fallthrough
# so listed domains never force a local lookup just for routing.
RULES_BASE = [
    "GEOIP,LAN,DIRECT,no-resolve",
    "GEOSITE,NETFLIX,Streaming Sites",
    "GEOSITE,SPOTIFY,Streaming Sites",
    "GEOSITE,TIDAL,Streaming Sites",
    "GEOSITE,DEEZER,Streaming Sites",
    "GEOSITE,SOUNDCLOUD,Streaming Sites",
    "GEOSITE,CN,DIRECT",
    "GEOSITE,GEOLOCATION-!CN,Proxy Mode",
    "GEOIP,CN,DIRECT",
    "MATCH,Proxy Mode",
]
RULES_NO_RESOLVE = [r + ",no-resolve" if r == "GEOIP,CN,DIRECT" else r
                    for r in RULES_BASE]

# Bootstrap DNS pins (2026-07-12 provider outage): mihomo must be able to
# resolve the geodata mirror and the airport panel BEFORE any node is up, so
# the template pins both to the domestic list via nameserver-policy and lists
# both in fake-ip-filter. The panel host derives from the SUB_URL fixture.
# www.gstatic.com joins the policy pins (v1.3.10): under foreign-by-default
# DNS the health-check host would otherwise resolve through the tunnel, yet
# the COMPATIBLE placeholder and the doctor/validate delay probes dial it
# DIRECT — pin it domestic like the mirror. It does NOT join fake-ip-filter:
# mihomo-internal ResolveIP never sees fake-ip, and LAN clients should keep
# fake-ip routing for a Google host.
PIN_MIRROR = "testingcf.jsdelivr.net"
PIN_GSTATIC = "www.gstatic.com"
PANEL_HOST = "h.example.com"
BOOTSTRAP_PINS = {PIN_MIRROR: DNS_NS, PIN_GSTATIC: DNS_NS, PANEL_HOST: DNS_NS}
# v2 is the only DNS profile: every render carries the bootstrap pins PLUS
# the split-horizon policy entries (geosite:cn domestic, everything-foreign
# tunneled) — there is no knobs-off variant anymore (issue #43).
EXPECTED_POLICY = {**BOOTSTRAP_PINS,
                   "geosite:cn": DNS_CN, "geosite:geolocation-!cn": DNS_FOREIGN}
FAKEIP_FILTER = [PIN_MIRROR, PANEL_HOST]
PROVIDER_PATH = "./proxies/my-airport.yaml"
# An IP-literal subscription host needs no DNS pin at all - the renderer must
# degrade both panel pin lines to comments and keep the mirror pins.
SUB_LINE_IP = "Default=https://192.0.2.10:8443/api/v1/subscribe?token=a"

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
           dns_default: str | None = ",".join(DNS_DEFAULT),
           dns_ns: str | None = ",".join(DNS_NS),
           dns_cn: str | None = ",".join(DNS_CN),
           dns_foreign: str | None = ",".join(DNS_FOREIGN),
           geoip_no_resolve: str | None = None,
           sniffer_enable: str | None = None,
           priority_exclude: str | None = None,
           priority_include: str | None = None,
           legacy_exclude: str | None = None,
           country_groups: str | None = DEFAULT_CG,
           full_proxy_sources: str | None = None,
           sub_line: str | None = None):
    """Run the real renderer in an isolated config directory."""
    with tempfile.TemporaryDirectory() as td:
        tdp = Path(td)
        (tdp / "config.template.yaml").write_text(raw)
        (tdp / "subscription.txt").write_text((sub_line or SUB_LINE) + "\n")
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
        }
        if dns_default is not None:
            env["DNS_DEFAULT_NAMESERVER"] = dns_default
        if dns_ns is not None:
            env["DNS_NAMESERVER"] = dns_ns
        if tun_auto_redirect is not None:
            env["TUN_AUTO_REDIRECT"] = tun_auto_redirect
        if tun_enable is not None:
            env["TUN_ENABLE"] = tun_enable
        if external_ui_dir is not None:
            env["EXTERNAL_UI_DIR"] = external_ui_dir
        # The split-horizon pair is REQUIRED (v2 is the only DNS profile) and
        # rides along by default. None = the variable is ABSENT from the env
        # entirely; "" = present-but-empty (the compose ':-' pass-through for
        # a stale pre-v2 .env) — both must fail the render loudly, exercised
        # by the required-pair failure cases below.
        if dns_cn is not None:
            env["DNS_CN_NAMESERVER"] = dns_cn
        if dns_foreign is not None:
            env["DNS_FOREIGN_NAMESERVER"] = dns_foreign
        if geoip_no_resolve is not None:
            env["DNS_GEOIP_NO_RESOLVE"] = geoip_no_resolve
        # Sniffer stays ABSENT unless a case opts in: unset must render
        # byte-identical to the pre-sniffer output (upgrade compat), while
        # .env.example ships true for new installs.
        if sniffer_enable is not None:
            env["SNIFFER_ENABLE"] = sniffer_enable
        # The retired knobs are fail-loud tripwires only (never value
        # sources): a case opting in asserts the render REFUSES.
        if priority_exclude is not None:
            env["PRIORITY_EXCLUDE_FILTER"] = priority_exclude
        if priority_include is not None:
            env["PRIORITY_INCLUDE_FILTER"] = priority_include
        if legacy_exclude is not None:
            env["AUTO_EXCLUDE_FILTER"] = legacy_exclude
        # Country-group spec is REQUIRED: DEFAULT_CG rides along unless a
        # case overrides it (None = absent, "" = present-but-empty — both
        # must refuse to render).
        if country_groups is not None:
            env["COUNTRY_GROUPS"] = country_groups
        # Full-proxy band knob is OPTIONAL (renders only when set): None =
        # absent, "" = the compose ':-' passthrough — both must render
        # byte-identical to a template with the FULL_PROXY machinery
        # stripped (fully additive; upgrade-safe).
        if full_proxy_sources is not None:
            env["FULL_PROXY_SOURCES"] = full_proxy_sources
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


def drop_token_lines(raw: str, name: str) -> str:
    """Delete whole lines carrying a standalone {{NAME}} marker — the
    renderer's spec-unset sed for the COUNTRY_* generation token sites."""
    return "".join(line for line in raw.splitlines(keepends=True)
                   if f"{{{{{name}}}}}" not in line)


def spec_names(spec: str) -> list:
    """Group names from a VALID COUNTRY_GROUPS spec, mirroring the renderer's
    POSIX field split: ';' separates entries, one trailing separator is
    absorbed, the name is everything before the first '='."""
    parts = spec.split(";")
    if parts and parts[-1] == "":
        parts.pop()
    return [p.split("=", 1)[0] for p in parts]


def expected_groups(country_spec: str = DEFAULT_CG,
                    full_proxy: bool = False) -> list:
    """The SPEC-DERIVED proxy-group inventory (in order): the selectors
    first (dashboard order = config order — the cards users touch come
    first; Full Proxy joins them right after Country Pick when the band
    knob is set), then the generated '<Country> Auto' groups in spec
    order, then the hidden All Nodes DNS anchor LAST. Never a hardcoded
    country list (CLAUDE.md rule) — names come from the spec."""
    selectors = ["Proxy Mode", "Streaming Sites", "Country Pick"]
    if full_proxy:
        selectors.append("Full Proxy")
    return selectors + spec_names(country_spec) + ["All Nodes"]


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


def check_dns_detour_targets(doc):
    """Every '#group' detour fragment on a DNS server entry names a real group.

    A '#name' URL fragment routes that resolver through a proxy-group; mihomo
    does not validate it at parse time — a typo'd or renamed group just makes
    those lookups fail at runtime (log-only). The template comment can ask
    "rename both together"; this enforces it.
    """
    groups = {g.get("name") for g in doc.get("proxy-groups") or []
              if isinstance(g, dict)}
    valid = groups | {"DIRECT"}  # an explicit DIRECT detour is legal syntax
    dns = doc.get("dns") or {}
    entries = []
    for field in ("default-nameserver", "nameserver", "fallback",
                  "proxy-server-nameserver"):
        entries.extend(dns.get(field) or [])
    for servers in (dns.get("nameserver-policy") or {}).values():
        entries.extend(servers if isinstance(servers, list) else [servers])
    for e in entries:
        s = str(e)
        if "#" not in s:
            continue
        frag = s.rsplit("#", 1)[1].split("&", 1)[0]  # '#group' or '#group&h3=true'
        if frag not in valid:
            fail(f"dns entry {s!r} detours via unknown group {frag!r} "
                 f"(groups: {sorted(groups)})")


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

    # 2) Run the REAL renderer with the default fixture env (v2 pair included
    # — split-horizon is the only DNS profile).
    proc, rendered = render(raw)
    if proc.returncode != 0 or rendered is None:
        fail(f"render_config.sh exited {proc.returncode}: {proc.stderr.strip()}")

    assert_resolved("default", rendered)

    doc = yaml.safe_load(rendered)

    # 3) Subscription URL must round-trip EXACTLY (the critical regression).
    provider = ((doc.get("proxy-providers") or {}).get("my-airport")) or {}
    url = provider.get("url")
    if url != SUB_URL:
        fail(f"subscription URL mangled: got {url!r}, expected {SUB_URL!r}")

    # 3b) The provider must cache at the STABLE path (seedable, upgrade-adopted);
    # mihomo's md5-of-URL default made the cache undiscoverable for recovery.
    if provider.get("path") != PROVIDER_PATH:
        fail(f"provider path must be {PROVIDER_PATH!r}: got {provider.get('path')!r}")

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
    # surface here as a dict or a mangled token). v2 is the ONLY profile:
    # dns.nameserver is the tunneled foreign list ('#auto' fragments surviving
    # into the parsed values), and proxy-server-nameserver reuses the domestic
    # list so node hostnames resolve direct (the filtered-network
    # chicken-and-egg observed in production).
    dns = doc.get("dns") or {}
    for field, expected in (("default-nameserver", DNS_DEFAULT),
                            ("nameserver", DNS_FOREIGN),
                            ("proxy-server-nameserver", DNS_NS)):
        servers = dns.get(field)
        if servers != expected:
            fail(f"dns.{field} did not round-trip: got {servers!r}, expected {expected!r}")
    # The fallback dual-query — the channel that copied every long-tail
    # hostname to the domestic resolvers — must not exist in ANY render
    # (the legacy profile was purged, issue #43).
    for gone in ("fallback", "fallback-filter"):
        if gone in dns:
            fail(f"dns.{gone} must NOT render — v2 is the only DNS profile "
                 f"(legacy purged): got {dns.get(gone)!r}")
    # Cold-start invariant: the bootstrap and node-hostname resolvers stay
    # UNPROXIED plain lists — no '#group' fragments (the 2026-07 incident).
    for field in ("default-nameserver", "proxy-server-nameserver"):
        tunneled = [e for e in dns.get(field) or [] if "#" in str(e)]
        if tunneled:
            fail(f"dns.{field} must stay UNPROXIED — no '#group' fragments "
                 f"(cold-start invariant): {tunneled}")
    check_dns_detour_targets(doc)

    # 5a) nameserver-policy: the bootstrap pins (geodata mirror, gstatic,
    # airport panel — a cold start has no node to tunnel a resolver or a
    # fetch through; 2026-07-12 provider outage) PLUS the always-on
    # split-horizon entries, exactly.
    if dns.get("nameserver-policy") != EXPECTED_POLICY:
        fail(f"default render nameserver-policy must be exactly the bootstrap "
             f"pins + split-horizon entries {EXPECTED_POLICY!r}: "
             f"got {dns.get('nameserver-policy')!r}")
    if dns.get("fake-ip-filter") != FAKEIP_FILTER:
        fail(f"dns.fake-ip-filter must be {FAKEIP_FILTER!r}: "
             f"got {dns.get('fake-ip-filter')!r}")

    # 5b) Rule / group / provider reference integrity (the MATCH,my-airport
    # crash-loop class) on the fully rendered document.
    check_rule_targets(doc)

    # 5b') Group inventory + the streamlined graph (vNEXT). Exact names in
    # order — selectors first (dashboard order = config order), country
    # groups from the spec, the hidden All Nodes anchor LAST. Members are
    # exact-equality per selector: mihomo defaults a select group with no
    # cache.db entry to its FIRST member, so the first-member assertions
    # pin the out-of-box routing (Proxy Mode -> Country Pick -> the first
    # COUNTRY_GROUPS entry).
    gnames = [g.get("name") for g in doc.get("proxy-groups") or []]
    if gnames != expected_groups():
        fail(f"default proxy-groups must be exactly {expected_groups()!r} "
             f"in order (spec-derived from DEFAULT_CG): got {gnames!r}")
    dgroups = {g.get("name"): g for g in doc.get("proxy-groups")}
    CG_DEFAULT_NAMES = spec_names(DEFAULT_CG)
    pmode = dgroups["Proxy Mode"]
    if pmode.get("type") != "select":
        fail(f"Proxy Mode must be a select group: got {pmode.get('type')!r}")
    if pmode.get("proxies") != ["Country Pick", "DIRECT", "REJECT"]:
        fail(f"Proxy Mode members must be ['Country Pick', 'DIRECT', "
             f"'REJECT'] (Country Pick FIRST = the routing default): "
             f"got {pmode.get('proxies')!r}")
    if pmode.get("use") != ["my-airport"]:
        fail("Proxy Mode must surface raw provider nodes via use: "
             "[my-airport] (pinning ONE exact node is the only complete "
             f"anti-IP-hop tool — brief DEC-3): got {pmode.get('use')!r}")
    streaming = dgroups["Streaming Sites"]
    if streaming.get("type") != "select":
        fail(f"Streaming Sites must be a select group (dashboard-pinnable): "
             f"got {streaming.get('type')!r}")
    if streaming.get("proxies") != (["Proxy Mode"] + CG_DEFAULT_NAMES
                                    + ["DIRECT"]):
        fail(f"Streaming Sites members must be ['Proxy Mode'] + the country "
             f"splice + ['DIRECT'] (Proxy Mode FIRST = day-one default): "
             f"got {streaming.get('proxies')!r}")
    if streaming.get("use") != ["my-airport"]:
        fail("Streaming Sites must surface raw provider nodes via use: "
             "[my-airport] (unlock-node pinning is the documented fix): "
             f"got {streaming.get('use')!r}")
    cpick = dgroups["Country Pick"]
    if cpick.get("type") != "select":
        fail(f"Country Pick must be a select group: got {cpick.get('type')!r}")
    if cpick.get("proxies") != CG_DEFAULT_NAMES:
        fail(f"Country Pick members must be EXACTLY the country splice "
             f"(no DIRECT/REJECT — the fail-closed country autos are the "
             f"only members): got {cpick.get('proxies')!r}")
    if "use" in cpick:
        fail(f"Country Pick must NOT surface raw nodes (countries only): "
             f"got use: {cpick.get('use')!r}")
    dauto = dgroups["All Nodes"]
    if dauto.get("type") != "url-test":
        fail(f"All Nodes must stay a url-test group: got {dauto.get('type')!r}")
    if dauto.get("hidden") is not True:
        fail(f"All Nodes must carry hidden: true (it exists SOLELY as the "
             f"DNS detour anchor — dashboards filter hidden groups): "
             f"got {dauto.get('hidden')!r}")
    if dauto.get("use") != ["my-airport"]:
        fail(f"All Nodes must keep the full provider pool via use: "
             f"[my-airport]: got {dauto.get('use')!r}")
    if gnames[-1] != "All Nodes":
        fail(f"All Nodes must be defined LAST (hidden machinery below the "
             f"user-facing cards): got {gnames!r}")

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

    # 10) v2-only DNS (issue #43): the legacy-profile machinery is GONE. The
    # template must carry NO DNS fence marker and no {{DNS_FALLBACK}} token;
    # the policy entries and the foreign-by-default core render
    # unconditionally (asserted exactly in 5/5a on the default render). The
    # remaining fences must still pair, and their unset-inertness is proven
    # by byte-identity against a stripped template.
    for fence in ("SNIFFER", "FULL_PROXY"):
        if (f"{{{{{fence}_BEGIN}}}}" not in raw
                or f"{{{{{fence}_END}}}}" not in raw):
            fail(f"template must carry the {fence}_BEGIN/{fence}_END fence pair")
    for gone in ("DNSPOLICY_BEGIN", "DNSPOLICY_END", "DNSSPLIT_BEGIN",
                 "DNSSPLIT_END", "DNSLEGACY_BEGIN", "DNSLEGACY_END",
                 "DNS_FALLBACK", "AUTO_EXCLUDE_FILTER",
                 "PRIORITY_BEGIN", "PRIORITY_END",
                 "PRIORITYMEMBER_BEGIN", "PRIORITYMEMBER_END",
                 "PRIORITYSTREAM_BEGIN", "PRIORITYSTREAM_END",
                 "PRIORITY_INCLUDE_FILTER", "PRIORITY_EXCLUDE_FILTER",
                 "COUNTRY_MEMBERS_PROXY"):
        if f"{{{{{gone}}}}}" in raw:
            fail(f"template must NOT carry {{{{{gone}}}}} — legacy purged "
                 f"(the DNS profile in #43; the Priority Nodes category and "
                 f"the PROXY member marker in the group-model streamline)")
    if "{{GEOIP_NO_RESOLVE}}" not in raw:
        fail("template must carry the {{GEOIP_NO_RESOLVE}} token on the GEOIP,CN rule")
    if doc.get("rules") != RULES_BASE:
        fail(f"default rules must be the exact chain in order "
             f"{RULES_BASE!r}: got {doc.get('rules')!r}")
    for marker in ("COUNTRY_GROUPS", "COUNTRY_MEMBERS_PICK",
                   "COUNTRY_MEMBERS_STREAMING", "COUNTRY_MEMBERS_FULL_PROXY",
                   "FULL_PROXY_RULES"):
        if f"{{{{{marker}}}}}" not in raw:
            fail(f"template must carry the {{{{{marker}}}}} generation marker")
    # SNIFFER + FULL_PROXY are the optional fences: unset-inertness is proven
    # by byte-identity against a fence-stripped template (same env, spec on).
    plain_raw = strip_fence(raw, "SNIFFER")
    proc_l, plain = render(plain_raw)
    if proc_l.returncode != 0 or plain is None:
        fail(f"fence-stripped render failed: {proc_l.stderr.strip()}")
    if plain != rendered:
        fail("sniffer-unset render is not byte-identical to a fence-less "
             "template render — the fence is not inert for existing .env files")

    # The REQUIRED pair: a missing OR empty DNS_CN_NAMESERVER /
    # DNS_FOREIGN_NAMESERVER refuses to render, names the variable, writes
    # nothing. Absent and empty behave identically — docker-compose passes
    # '${DNS_CN_NAMESERVER:-}' through as an empty var for a stale pre-v2
    # .env, and that .env must fail LOUD (the entrypoint gate then keeps the
    # previous config running), never render a leaky half-profile.
    for kwargs, missing in (
            ({"dns_cn": None}, "DNS_CN_NAMESERVER"),
            ({"dns_cn": ""}, "DNS_CN_NAMESERVER"),
            ({"dns_foreign": None}, "DNS_FOREIGN_NAMESERVER"),
            ({"dns_foreign": ""}, "DNS_FOREIGN_NAMESERVER"),
            ({"dns_cn": None, "dns_foreign": None}, "DNS_CN_NAMESERVER")):
        proc_h, half = render(raw, **kwargs)
        if proc_h.returncode == 0 or half is not None:
            fail(f"render without the split-horizon pair ({kwargs!r}) was "
                 f"accepted or wrote config.yaml (the pair is REQUIRED)")
        if missing not in proc_h.stderr:
            fail(f"missing-pair error must name {missing}: "
                 f"{proc_h.stderr.strip()!r}")

    # 11) DNS_GEOIP_NO_RESOLVE opt-in, independent of the policy knobs:
    # true appends ',no-resolve' to the GEOIP rule (and ONLY that rule),
    # false is byte-identical to unset, garbage fails closed.
    proc_nr, nr = render(raw, geoip_no_resolve="true")
    if proc_nr.returncode != 0 or nr is None:
        fail(f"DNS_GEOIP_NO_RESOLVE=true render failed: {proc_nr.stderr.strip()}")
    assert_resolved("no-resolve", nr)
    nrdoc = yaml.safe_load(nr)
    if nrdoc.get("rules") != RULES_NO_RESOLVE:
        fail(f"DNS_GEOIP_NO_RESOLVE=true rules must be {RULES_NO_RESOLVE!r}: "
             f"got {nrdoc.get('rules')!r}")
    check_rule_targets(nrdoc)  # the trailing flag must not confuse target resolution
    proc_nf, nf = render(raw, geoip_no_resolve="false")
    if proc_nf.returncode != 0 or nf != rendered:
        fail("DNS_GEOIP_NO_RESOLVE=false must render byte-identical to unset")
    proc_nb, nb = render(raw, geoip_no_resolve="yes")
    if proc_nb.returncode == 0 or nb is not None:
        fail("invalid DNS_GEOIP_NO_RESOLVE was accepted or wrote config.yaml")

    # 11b) Sniffer fence (v1.3.10 incident fix): LAN clients that resolve DNS
    # outside the gateway produce raw-IP flows the GEOSITE rules cannot see;
    # sniffing SNI/HTTP-host and OVERRIDING the destination restores
    # domain routing (and defeats poisoned client-side answers - the node
    # re-dials by hostname remotely). Unset/false renders WITHOUT the block,
    # byte-identical (upgrade compat, proven via the composed strip in 10);
    # true renders the full block; garbage fails closed.
    if "sniffer" in (yaml.safe_load(rendered) or {}):
        fail("default render must NOT contain a sniffer block (SNIFFER_ENABLE unset)")
    proc_sn, sn = render(raw, sniffer_enable="true")
    if proc_sn.returncode != 0 or sn is None:
        fail(f"SNIFFER_ENABLE=true render failed: {proc_sn.stderr.strip()}")
    assert_resolved("sniffer", sn)
    if "\n\n\n" in sn:
        fail("sniffer render contains doubled blank lines - the fence must sit "
             "flush against its neighbors")
    sndoc = yaml.safe_load(sn)
    sniffer = sndoc.get("sniffer") or {}
    for field, expected in (("enable", True),
                            ("parse-pure-ip", True),
                            ("override-destination", True),
                            ("force-dns-mapping", True)):
        if sniffer.get(field) is not expected:
            fail(f"sniffer.{field} must be {expected!r}: got {sniffer.get(field)!r}")
    for proto in ("TLS", "HTTP", "QUIC"):
        if proto not in (sniffer.get("sniff") or {}):
            fail(f"sniffer.sniff must cover {proto}: got {sniffer.get('sniff')!r}")
    if sndoc.get("rules") != RULES_BASE:
        fail(f"[sniffer] rules must be unchanged by the sniffer fence: "
             f"got {sndoc.get('rules')!r}")
    check_rule_targets(sndoc)
    proc_sf, sf = render(raw, sniffer_enable="false")
    if proc_sf.returncode != 0 or sf != rendered:
        fail("SNIFFER_ENABLE=false must render byte-identical to unset")
    proc_sb, sb = render(raw, sniffer_enable="on")
    if proc_sb.returncode == 0 or sb is not None:
        fail("invalid SNIFFER_ENABLE was accepted or wrote config.yaml")

    # 11c) Priority Nodes retirement (group-model streamline): the category
    # is GONE — the tripwires below are the owner-ratified fail-loud pattern
    # (the AUTO_EXCLUDE_FILTER rename precedent, #40 DEC-B): a stale .env
    # still setting a retired knob refuses to render with a
    # removal-instruction error, never a silent route-default change. Empty
    # string == unset (the compose ':-' passthrough keeps the tripwire
    # lines alive in docker-compose.yml without tripping a clean .env).
    for tw_kwargs, named in (
            ({"priority_exclude": "香港|HK"}, "PRIORITY_EXCLUDE_FILTER"),
            ({"priority_include": "日本"}, "PRIORITY_INCLUDE_FILTER"),
            ({"priority_exclude": "香港", "priority_include": "日本"},
             "PRIORITY_EXCLUDE_FILTER"),
            ({"legacy_exclude": "香港"}, "AUTO_EXCLUDE_FILTER")):
        proc_tw, tw = render(raw, **tw_kwargs)
        if proc_tw.returncode == 0 or tw is not None:
            fail(f"stale retired knob ({tw_kwargs!r}) was accepted or wrote "
                 f"config.yaml (the retirement tripwire must fail loud)")
        if named not in proc_tw.stderr:
            fail(f"tripwire error must name {named}: "
                 f"{proc_tw.stderr.strip()!r}")
        if "removed" not in proc_tw.stderr:
            fail(f"tripwire error must state the knob was removed: "
                 f"{proc_tw.stderr.strip()!r}")
    for empty_kwargs in ({"priority_exclude": ""}, {"priority_include": ""},
                         {"legacy_exclude": ""}):
        proc_pe, pe = render(raw, **empty_kwargs)
        if proc_pe.returncode != 0 or pe != rendered:
            fail(f"empty-string retired knob ({empty_kwargs!r}) must render "
                 f"byte-identical to unset (the compose ':-' passthrough)")

    # 11c') COUNTRY_GROUPS is REQUIRED: absent and present-but-empty both
    # refuse to render (a stale pre-country .env passes '' through compose),
    # naming the variable and pointing at the shipped default.
    for cg_missing in (None, ""):
        proc_cr, cr = render(raw, country_groups=cg_missing)
        if proc_cr.returncode == 0 or cr is not None:
            fail(f"render without COUNTRY_GROUPS ({cg_missing!r}) was "
                 f"accepted or wrote config.yaml (Country Pick needs members)")
        if "COUNTRY_GROUPS" not in proc_cr.stderr:
            fail(f"missing-spec error must name COUNTRY_GROUPS: "
                 f"{proc_cr.stderr.strip()!r}")
        if ".env.example" not in proc_cr.stderr:
            fail(f"missing-spec error must point at the .env.example "
                 f"default: {proc_cr.stderr.strip()!r}")

    # 11c'') Renderer-side DNS detour validation (the migration hazard): a
    # '#group' fragment naming no rendered group refuses to render — a stale
    # '#Priority Nodes' (present in every pre-vNEXT .env if the anchor had
    # been renamed) would be a silently dead resolver at runtime, so the
    # renderer owns the loud gate. Valid detours: any rendered group, or an
    # explicit DIRECT; a '&h3=true' suffix after the group name is legal.
    for bad_dns in ("https://1.0.0.1/dns-query#Priority Nodes",
                    "https://1.0.0.1/dns-query#Bogus Group"):
        proc_bd, bd = render(raw, dns_foreign=bad_dns)
        if proc_bd.returncode == 0 or bd is not None:
            fail(f"dangling DNS detour {bad_dns!r} was accepted or wrote "
                 f"config.yaml (a dead resolver is silent at runtime — the "
                 f"render must refuse loudly)")
        if "DNS_FOREIGN_NAMESERVER" not in proc_bd.stderr:
            fail(f"dangling-detour error must name DNS_FOREIGN_NAMESERVER: "
                 f"{proc_bd.stderr.strip()!r}")
    proc_bc, bc = render(raw, dns_cn="https://223.4.4.4/dns-query#Nope")
    if proc_bc.returncode == 0 or bc is not None:
        fail("dangling detour in DNS_CN_NAMESERVER was accepted (the "
             "validation must cover every DNS_* list)")
    for good_dns in ("https://1.0.0.1/dns-query#Country Pick",
                     "https://1.0.0.1/dns-query#Japan Auto",
                     "https://1.0.0.1/dns-query#All Nodes&h3=true",
                     "https://1.0.0.1/dns-query#DIRECT"):
        proc_gd, gd = render(raw, dns_foreign=good_dns)
        if proc_gd.returncode != 0 or gd is None:
            fail(f"valid DNS detour {good_dns!r} refused to render: "
                 f"{proc_gd.stderr.strip()}")

    # 11c''') The SHIPPED .env.example: no retired-knob line survives, the
    # starter COUNTRY_GROUPS spec ships Japan Auto FIRST (Country Pick
    # defaults to its first member — the v1.4.0 Japan default egress
    # carries over, brief DEC-4), and the example's REAL DNS values render
    # end-to-end with every '#fragment' resolving against the rendered
    # inventory (closes the gap where CI only rendered its own DNS fixtures
    # while .env.example could drift).
    env_example = (REPO / ".env.example").read_text()
    for gone_knob in ("PRIORITY_EXCLUDE_FILTER", "PRIORITY_INCLUDE_FILTER",
                      "AUTO_EXCLUDE_FILTER"):
        if re.search(rf"^{gone_knob}=", env_example, re.M):
            fail(f".env.example must not ship a {gone_knob} line (the knob "
                 f"was retired; a kept line would trip every new install)")
    mcg = re.search(r"^COUNTRY_GROUPS=(.+)$", env_example, re.M)
    if not mcg or not mcg.group(1).strip():
        fail(".env.example must ship a non-empty COUNTRY_GROUPS starter "
             "spec (the knob is REQUIRED — Country Pick needs members)")
    default_cg = mcg.group(1).strip()
    if spec_names(default_cg)[0] != "Japan Auto":
        fail(f".env.example COUNTRY_GROUPS must ship Japan Auto FIRST "
             f"(brief DEC-4): got {spec_names(default_cg)!r}")

    def example_val(key: str) -> str:
        m = re.search(rf"^{key}=(.+)$", env_example, re.M)
        if not m or not m.group(1).strip():
            fail(f".env.example must ship a non-empty {key}")
        return m.group(1).strip()

    proc_ex, ex = render(raw,
                         dns_default=example_val("DNS_DEFAULT_NAMESERVER"),
                         dns_ns=example_val("DNS_NAMESERVER"),
                         dns_cn=example_val("DNS_CN_NAMESERVER"),
                         dns_foreign=example_val("DNS_FOREIGN_NAMESERVER"),
                         country_groups=default_cg,
                         sniffer_enable=example_val("SNIFFER_ENABLE"))
    if proc_ex.returncode != 0 or ex is None:
        fail(f".env.example values failed to render: {proc_ex.stderr.strip()}")
    exdoc = yaml.safe_load(ex)
    exnames = [g.get("name") for g in exdoc.get("proxy-groups") or []]
    if exnames != expected_groups(default_cg):
        fail(f".env.example defaults must render the spec-derived inventory "
             f"{expected_groups(default_cg)!r}: got {exnames!r}")
    check_rule_targets(exdoc)
    check_dns_detour_targets(exdoc)
    ex_frags = [e for e in (exdoc.get("dns") or {}).get("nameserver") or []
                if "#" in str(e)]
    if not ex_frags:
        fail(".env.example DNS_FOREIGN_NAMESERVER must keep its '#group' "
             "detour fragments (the tunneled foreign list)")

    # 11d) COUNTRY_GROUPS generation: one url-test group per entry — filter
    # over the provider pool, empty-fallback REJECT (an emptied group must
    # never degrade to the Direct-typed COMPATIBLE placeholder, the
    # unproxied-uplink leak class), tolerance but NO own url:/interval:
    # (provider health check inherited) — spliced as Country Pick's members
    # and into Streaming Sites after Proxy Mode, before DIRECT (spec order
    # = dashboard order). A multi-country regex is simply one combined
    # group (the countries-as-a-group ask). The fixture carries CJK names,
    # '|', '\\d' and '^' anchors; inventories are derived from the spec
    # under test via expected_groups() - never a hardcoded country list.
    CG = 'Japan Auto=日本|JP\\d|^JP;美国=美国|US\\d;亚洲组=日本|台湾|新加坡'
    CG_NAMES = spec_names(CG)
    proc_cg, cg = render(raw, country_groups=CG)
    if proc_cg.returncode != 0 or cg is None:
        fail(f"COUNTRY_GROUPS render failed: {proc_cg.stderr.strip()}")
    assert_resolved("country-groups", cg)
    if "\n\n\n" in cg:
        fail("country-groups render contains doubled blank lines - generated "
             "blocks must sit flush against their neighbors")
    cgdoc = yaml.safe_load(cg)
    cgnames = [g.get("name") for g in cgdoc.get("proxy-groups") or []]
    if cgnames != expected_groups(CG):
        fail(f"spec-on proxy-groups must be exactly {expected_groups(CG)!r} "
             f"in order: got {cgnames!r}")
    cgroups = {g.get("name"): g for g in cgdoc.get("proxy-groups")}
    specd = {p.split("=", 1)[0]: p.split("=", 1)[1]
             for p in CG.split(";") if p}
    for name, regex in specd.items():
        g = cgroups[name]
        if g.get("type") != "url-test":
            fail(f"generated group {name!r} must be url-test: got {g.get('type')!r}")
        if g.get("filter") != regex:
            fail(f"generated group {name!r} filter did not round-trip: "
                 f"got {g.get('filter')!r}, expected {regex!r}")
        if g.get("empty-fallback") != "REJECT":
            fail(f"generated group {name!r} must fail closed via "
                 f"empty-fallback: REJECT: got {g.get('empty-fallback')!r}")
        if g.get("use") != ["my-airport"]:
            fail(f"generated group {name!r} must use: [my-airport]: "
                 f"got {g.get('use')!r}")
        if g.get("tolerance") != 50:
            fail(f"generated group {name!r} must carry tolerance: 50: "
                 f"got {g.get('tolerance')!r}")
        for absent in ("url", "interval"):
            if absent in g:
                fail(f"generated group {name!r} must carry NO own {absent!r} "
                     f"(inherits the provider health check): got {g.get(absent)!r}")
    if cgroups["Country Pick"].get("proxies") != CG_NAMES:
        fail(f"Country Pick members must be exactly the spec order: "
             f"got {cgroups['Country Pick'].get('proxies')!r}")
    if cgroups["Streaming Sites"].get("proxies") != (["Proxy Mode"] + CG_NAMES
                                                     + ["DIRECT"]):
        fail(f"Streaming Sites members with the spec on must be Proxy Mode + "
             f"spec order + DIRECT: got "
             f"{cgroups['Streaming Sites'].get('proxies')!r}")
    if cgroups["Proxy Mode"].get("proxies") != ["Country Pick", "DIRECT",
                                                "REJECT"]:
        fail(f"Proxy Mode members are spec-independent (Country Pick carries "
             f"the countries): got {cgroups['Proxy Mode'].get('proxies')!r}")
    if cgroups["All Nodes"] != dauto:
        fail(f"All Nodes must be UNTOUCHED by the country spec: "
             f"{cgroups['All Nodes']!r}")
    if cgdoc.get("rules") != RULES_BASE:
        fail(f"[country-groups] rules must be unchanged: got {cgdoc.get('rules')!r}")
    check_rule_targets(cgdoc)
    check_dns_detour_targets(cgdoc)

    # Malformed-spec classes: each must refuse to render (no config.yaml)
    # with an error naming COUNTRY_GROUPS - an invalid pattern would panic
    # mihomo at startup, and a shadowing name would corrupt routing. The
    # reserved list carries the NEW selector names AND the retired legacy
    # names (a user group literally named 'All Nodes' or 'Priority Nodes'
    # would resurrect a name the docs history still associates with old
    # semantics), plus 'Full Proxy' (reserved ahead for the
    # per-device-full-proxy epic).
    for bad_spec, why in (
            ('日本=日本`REJECT`', "backtick"),
            ('日本', "entry without '='"),
            ('=日本', "empty name"),
            ('日本=', "empty regex"),
            ('日本= \t', "whitespace-only regex"),
            ('日本=x;日本=y', "duplicate name"),
            ('All Nodes=x', "reserved collision (All Nodes)"),
            ('Priority Nodes=x', "retired-name collision (Priority Nodes)"),
            ('PROXY=x', "retired-name collision (PROXY)"),
            ('STREAMING=x', "retired-name collision (STREAMING)"),
            ('Country Pick=x', "selector collision (Country Pick)"),
            ('Proxy Mode=x', "selector collision (Proxy Mode)"),
            ('Streaming Sites=x', "selector collision (Streaming Sites)"),
            ('Full Proxy=x', "reserved-ahead collision (Full Proxy)"),
            ('DIRECT=x', "reserved adapter collision (DIRECT)"),
            ('日本=x;;美国=y', "empty entry"),
            (' 日本=x', "leading space in name"),
            ('日本 =x', "trailing space in name"),
            ('日\t本=x', "tab in name")):
        proc_b, b = render(raw, country_groups=bad_spec)
        if proc_b.returncode == 0 or b is not None:
            fail(f"malformed COUNTRY_GROUPS ({why}: {bad_spec!r}) was accepted "
                 f"or wrote config.yaml")
        if "COUNTRY_GROUPS" not in proc_b.stderr:
            fail(f"malformed-spec error ({why}) must name COUNTRY_GROUPS: "
                 f"{proc_b.stderr.strip()!r}")
    # DEC-A (2026-07-14): the pre-v1.4 legacy word 'auto' is not reserved -
    # a user group named 'auto' is legal and renders.
    proc_lg, lg = render(raw, country_groups='auto=x')
    if proc_lg.returncode != 0 or lg is None:
        fail(f"COUNTRY_GROUPS name 'auto' must be LEGAL (DEC-A): "
             f"{proc_lg.stderr.strip()}")
    if [g.get("name") for g in (yaml.safe_load(lg).get("proxy-groups") or [])] \
            != expected_groups('auto=x'):
        fail("the legal 'auto' user group did not render as a generated group")
    # A single trailing ';' is the POSIX field-split absorption case - legal.
    proc_tr, tr = render(raw, country_groups='日本=日本;')
    if proc_tr.returncode != 0 or tr is None:
        fail(f"trailing-';' spec must render (field-split absorption): "
             f"{proc_tr.stderr.strip()}")
    if [g.get("name") for g in (yaml.safe_load(tr).get("proxy-groups") or [])] \
            != expected_groups('日本=日本'):
        fail("trailing-';' spec must render exactly one generated group")

    # 11e) FULL_PROXY_SOURCES (per-device full-proxy band, #46): OPTIONAL —
    # set, it renders the fenced Full Proxy select group (members Proxy Mode
    # + the country splice + REJECT, NO DIRECT — a band device can never be
    # silently un-proxied at the group layer; REJECT is the kill switch) and
    # one SRC-IP-CIDR rule per entry at the EXACT post-LAN-rule position
    # (LAN destinations stay DIRECT; everything else — streaming AND CN
    # sites — rides the band group). Unset/empty renders byte-identical to
    # a template with the whole FULL_PROXY machinery stripped (fully
    # additive; upgrade-safe). Bare IPs normalize to /32.
    FP = "192.0.2.16/28,192.0.2.5"
    FP_RULES = ["SRC-IP-CIDR,192.0.2.16/28,Full Proxy",
                "SRC-IP-CIDR,192.0.2.5/32,Full Proxy"]
    # Anchor on PARSED rules, never the raw text — the template's rules
    # comment mentions SRC-IP-CIDR as prose (the comment-prose false-
    # positive class validate_release's helpers document).
    if any("SRC-IP-CIDR" in str(r) for r in doc.get("rules") or []):
        fail("default render must carry NO SRC-IP-CIDR rules "
             "(FULL_PROXY_SOURCES unset)")
    if "Full Proxy" in {g.get("name") for g in doc.get("proxy-groups") or []}:
        fail("default render must NOT contain the Full Proxy group "
             "(FULL_PROXY_SOURCES unset)")
    fp_plain_raw = drop_token_lines(strip_fence(raw, "FULL_PROXY"),
                                    "FULL_PROXY_RULES")
    proc_fs, fp_stripped = render(fp_plain_raw)
    if proc_fs.returncode != 0 or fp_stripped is None:
        fail(f"FULL_PROXY-stripped render failed: {proc_fs.stderr.strip()}")
    if fp_stripped != rendered:
        fail("band-unset render is not byte-identical to a FULL_PROXY-"
             "stripped template render — the fence/marker is not inert for "
             "existing .env files")
    proc_fe, fp_empty = render(raw, full_proxy_sources="")
    if proc_fe.returncode != 0 or fp_empty != rendered:
        fail("FULL_PROXY_SOURCES='' (the compose ':-' passthrough) must "
             "render byte-identical to unset")
    proc_fp, fp_on = render(raw, full_proxy_sources=FP)
    if proc_fp.returncode != 0 or fp_on is None:
        fail(f"FULL_PROXY_SOURCES render failed: {proc_fp.stderr.strip()}")
    assert_resolved("full-proxy", fp_on)
    if "\n\n\n" in fp_on:
        fail("full-proxy render contains doubled blank lines - the fence "
             "must sit flush against its neighbors")
    fpdoc = yaml.safe_load(fp_on)
    fpnames = [g.get("name") for g in fpdoc.get("proxy-groups") or []]
    if fpnames != expected_groups(full_proxy=True):
        fail(f"band-on proxy-groups must be exactly "
             f"{expected_groups(full_proxy=True)!r} in order (Full Proxy "
             f"joins the selectors after Country Pick): got {fpnames!r}")
    fpg = {g.get("name"): g for g in fpdoc.get("proxy-groups")}["Full Proxy"]
    if fpg.get("type") != "select":
        fail(f"Full Proxy must be a select group (zero probe traffic): "
             f"got {fpg.get('type')!r}")
    if fpg.get("proxies") != (["Proxy Mode"] + CG_DEFAULT_NAMES + ["REJECT"]):
        fail(f"Full Proxy members must be ['Proxy Mode'] + the country "
             f"splice + ['REJECT'] (NO DIRECT — brief DEC-3; Proxy Mode "
             f"FIRST = the band follows the dashboard mode by default): "
             f"got {fpg.get('proxies')!r}")
    if "use" in fpg:
        fail(f"Full Proxy must NOT surface raw nodes (pin nodes via Proxy "
             f"Mode instead): got use: {fpg.get('use')!r}")
    for absent in ("url", "interval"):
        if absent in fpg:
            fail(f"Full Proxy (select) must carry no {absent!r}: "
                 f"got {fpg.get(absent)!r}")
    if fpdoc.get("rules") != [RULES_BASE[0]] + FP_RULES + RULES_BASE[1:]:
        fail(f"band-on rules must be the LAN rule, then the SRC-IP-CIDR "
             f"lines (in knob order, /32-normalized), then the unchanged "
             f"chain: got {fpdoc.get('rules')!r}")
    check_rule_targets(fpdoc)
    check_dns_detour_targets(fpdoc)
    # The band composes with the no-resolve knob without disturbing it.
    proc_fn, fp_nr = render(raw, full_proxy_sources=FP,
                            geoip_no_resolve="true")
    if proc_fn.returncode != 0 or fp_nr is None:
        fail(f"band + no-resolve render failed: {proc_fn.stderr.strip()}")
    if yaml.safe_load(fp_nr).get("rules") != ([RULES_NO_RESOLVE[0]]
                                              + FP_RULES
                                              + RULES_NO_RESOLVE[1:]):
        fail("band + no-resolve rules must compose (SRC lines after the "
             "LAN rule, ',no-resolve' on GEOIP,CN)")
    # Malformed-knob classes: each must refuse to render (no config.yaml)
    # with an error naming FULL_PROXY_SOURCES — mirroring the
    # COUNTRY_GROUPS error classes. IPv6 entries additionally point at the
    # ipv6_bypass reality (the gateway is IPv4-only; routable LAN IPv6
    # bypasses it entirely).
    for bad_fp, why, extra in (
            ("2001:db8::1", "IPv6 address", "ipv6_bypass"),
            ("2001:db8::/64", "IPv6 CIDR", "ipv6_bypass"),
            ("host.example.com", "hostname", None),
            ("192.0.2.300", "octet > 255", None),
            ("192.0.2.0/33", "prefix > 32", None),
            ("192.0.2.0/", "empty prefix", None),
            ("192.002.2.5", "leading-zero octet (Go rejects at parse)", None),
            ("192.0.2.0/08", "leading-zero prefix (Go rejects at parse)", None),
            ("192.0.2.0/2x", "non-numeric prefix", None),
            ("192.0.2.0/28/24", "doubled slash", None),
            ("192.0.2.1,,192.0.2.2", "empty entry", None),
            ("192.0.2.5,192.0.2.5", "duplicate entry", None),
            ("192.0.2.5,192.0.2.5/32", "duplicate after /32 norm", None),
            ("192.0.2.`5`", "backtick", None),
            (" 192.0.2.5", "leading whitespace", None),
            ("192.0.2.5, 192.0.2.6", "space after comma", None),
            ("192.0.2", "three octets", None),
            ("1.2.3.4.5", "five octets", None),
            ("192.0.2.a", "non-numeric octet", None)):
        proc_bf, bf = render(raw, full_proxy_sources=bad_fp)
        if proc_bf.returncode == 0 or bf is not None:
            fail(f"malformed FULL_PROXY_SOURCES ({why}: {bad_fp!r}) was "
                 f"accepted or wrote config.yaml")
        if "FULL_PROXY_SOURCES" not in proc_bf.stderr:
            fail(f"malformed-band error ({why}) must name "
                 f"FULL_PROXY_SOURCES: {proc_bf.stderr.strip()!r}")
        if extra and extra not in proc_bf.stderr:
            fail(f"malformed-band error ({why}) must point at {extra}: "
                 f"{proc_bf.stderr.strip()!r}")
    # The shipped .env.example documents the band knob commented-out ONLY
    # (opt-in feature, placeholder addresses per CLAUDE.md — an ACTIVE line
    # would flip every synced .env into band mode).
    if "FULL_PROXY_SOURCES" not in env_example:
        fail(".env.example must document the FULL_PROXY_SOURCES knob "
             "(commented-out placeholder example)")
    if re.search(r"^FULL_PROXY_SOURCES=", env_example, re.M):
        fail(".env.example must NOT ship an active FULL_PROXY_SOURCES line "
             "(the band is opt-in; ship it commented out)")

    # 12) IP-literal subscription host: no DNS pin is possible or needed - the
    # panel entries in nameserver-policy and fake-ip-filter must degrade to
    # comments (never a bogus policy key), the mirror pins stay, and the render
    # remains valid placeholder-free YAML with the URL still exact.
    proc_ip, ip_rendered = render(raw, sub_line=SUB_LINE_IP)
    if proc_ip.returncode != 0 or ip_rendered is None:
        fail(f"IP-literal subscription render failed: {proc_ip.stderr.strip()}")
    assert_resolved("IP-literal-sub", ip_rendered)
    ipdoc = yaml.safe_load(ip_rendered)
    ipdns = ipdoc.get("dns") or {}
    if ipdns.get("nameserver-policy") != {PIN_MIRROR: DNS_NS, PIN_GSTATIC: DNS_NS,
                                          "geosite:cn": DNS_CN,
                                          "geosite:geolocation-!cn": DNS_FOREIGN}:
        fail(f"[IP-literal] nameserver-policy must carry the mirror + gstatic "
             f"pins + the split-horizon entries and NO panel pin: "
             f"got {ipdns.get('nameserver-policy')!r}")
    if ipdns.get("fake-ip-filter") != [PIN_MIRROR]:
        fail(f"[IP-literal] fake-ip-filter must carry ONLY the mirror: "
             f"got {ipdns.get('fake-ip-filter')!r}")
    ip_url = (((ipdoc.get("proxy-providers") or {}).get("my-airport")) or {}).get("url")
    if ip_url != SUB_LINE_IP.split("=", 1)[1]:
        fail(f"[IP-literal] subscription URL mangled: got {ip_url!r}")

    print("OK: renderer preserves URL/secrets; controller, DNS, CORS valid; TUN is ON by "
          "default (stack: system keeps the controller reachable, allow-lan + fake-ip set; "
          "TUN_ENABLE=false omits the block); auto-redirect/enable opt-ins are strict; "
          "split-horizon v2 is the ONLY DNS profile (required pair fails loud when "
          "missing/empty, naming the variable; nameserver = tunneled foreign list with "
          "'#All Nodes' fragments; fallback/fallback-filter never render; no legacy "
          "fence markers or {{DNS_FALLBACK}} token survive) while default/proxy-server-"
          "nameserver stay unproxied; GEOIP no-resolve knob strict; bootstrap "
          "pins (geodata mirror + gstatic + panel host) in nameserver-policy — mirror + "
          "panel in fake-ip-filter — on every variant with the stable provider cache "
          "path, degrading to mirror+gstatic on an IP-literal subscription host; rules "
          "are the exact chain (LAN-direct first, NETFLIX + four audio services -> "
          "Streaming Sites) targeting the renamed selectors; the streamlined graph "
          "renders selectors-first (Proxy Mode -> Country Pick -> DIRECT/REJECT + raw "
          "nodes; Streaming Sites defaulting to Proxy Mode; Country Pick = the country "
          "splice only) with the hidden All Nodes url-test LAST as the DNS anchor; the "
          "Priority Nodes category is purged (template tokens gone, .env.example line "
          "gone, stale PRIORITY_*/AUTO_EXCLUDE_FILTER knobs tripwire loud, empty == "
          "unset); COUNTRY_GROUPS is REQUIRED (absent/empty refuses, naming the "
          "variable and the .env.example default, which ships Japan Auto first) and "
          "generates url-test groups (filter, empty-fallback REJECT, no own probe) "
          "with spec-derived inventories, refusing every malformed-spec class incl. "
          "new-selector/retired-name/Full Proxy collisions; DNS detour fragments are "
          "render-time validated (dangling '#group' refuses; rendered groups, country "
          "names, DIRECT and '&h3' suffixes pass) and the .env.example's REAL DNS "
          "values render end-to-end; FULL_PROXY_SOURCES renders the fenced Full Proxy "
          "select (Proxy Mode + country splice + REJECT, no DIRECT, no raw nodes) plus "
          "/32-normalized SRC-IP-CIDR rules at the exact post-LAN position, is inert "
          "when unset/empty (byte-identity), composes with no-resolve, refuses every "
          "malformed class naming the knob (IPv6 pointing at ipv6_bypass), and ships "
          "commented-out in .env.example; the SNIFFER fence is inert when unset/false and "
          "renders SNI/HTTP/QUIC sniffing with parse-pure-ip + override-destination "
          "when true; geox-url hosts China-reachable; no hardcoded literals; fences "
          "pair, tokens map bidirectionally, rule/group targets resolve (never a "
          "provider), and every variant renders placeholder-free.")


if __name__ == "__main__":
    main()
