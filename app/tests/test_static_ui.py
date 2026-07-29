"""Static-tree discipline for the no-build UI: EN/zh dictionaries with
identical key sets, a data-testid on every interactive element, ZERO
external references anywhere under app/static (fully self-contained), and
the same-origin serving mount."""

import json
import re
from pathlib import Path

from app.tests.conftest import auth_headers

STATIC = Path(__file__).resolve().parents[1] / "static"


def test_i18n_key_sets_identical():
    en = json.loads((STATIC / "i18n" / "en.json").read_text())
    zh = json.loads((STATIC / "i18n" / "zh.json").read_text())
    assert en.keys() == zh.keys(), (
        f"EN/zh dictionaries must carry identical key sets; "
        f"only-en={sorted(set(en) - set(zh))} only-zh={sorted(set(zh) - set(en))}")
    assert en, "the dictionaries must not be empty"
    for key, value in {**en, **zh}.items():
        assert isinstance(value, str) and value.strip(), f"empty entry: {key}"


def test_every_used_i18n_key_exists():
    """Usage-side parity (the dictionaries agreeing with each other is not
    enough): every data-i18n/data-i18n-placeholder key in the HTML and
    every static t("...")/`state_*`/`action_*` key the JS renders must
    resolve, or the raw key leaks into the UI."""
    en = json.loads((STATIC / "i18n" / "en.json").read_text())
    html = (STATIC / "index.html").read_text()
    js = (STATIC / "app.js").read_text()
    used = set(re.findall(r'data-i18n(?:-placeholder)?="([^"]+)"', html))
    used |= set(re.findall(r'(?<![A-Za-z0-9_.])t\("([^"]+)"\)', js))
    for state in re.findall(r'"(saved|applying|confirmed|drift)"', js):
        used.add(f"state_{state}")
    missing = sorted(k for k in used if k not in en)
    assert not missing, f"used i18n keys missing from the dictionaries: {missing}"


def test_band_confirm_guards_both_mutation_paths():
    """CI has no JS runtime, so pin the DEC-4 gate textually: the confirm
    key must guard BOTH the flip path and the add path, and the add path
    must refresh the band list before deciding (the race the cycle-2
    judge caught)."""
    js = (STATIC / "app.js").read_text()
    assert js.count('t("band_confirm")') >= 2, \
        "the band confirm must gate flips AND adds"
    add_body = js.split("async function addDevice")[1].split(
        "async function")[0]
    assert "band_confirm" in add_body and "BAND" in add_body
    assert 'api("GET", "/v1/devices")' in add_body, \
        "the add path must refresh the band list before deciding"
    assert "if (!BAND.length)" not in add_body, \
        "the refresh must be UNCONDITIONAL - a stale non-empty cache " \
        "must never decide the gate"
    assert "band_confirm_unknown" in add_body, \
        "an unreadable band list must fail closed (confirm), not open"


def test_every_interactive_element_has_testid():
    html = (STATIC / "index.html").read_text()
    for tag in re.finditer(r"<(button|input|select|textarea|a)\b[^>]*>", html):
        assert "data-testid=" in tag.group(0), (
            f"interactive element without data-testid: {tag.group(0)[:90]}")
    assert html.count("data-testid=") >= 10, \
        "the UI must carry stable testids throughout"


def _split_media(css):
    """(stylesheet outside any @media, [(condition, body), ...])."""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    base, blocks, i = [], [], 0
    while True:
        opener = re.compile(r"@media([^{]*)\{").search(css, i)
        if not opener:
            base.append(css[i:])
            return "".join(base), blocks
        base.append(css[i:opener.start()])
        depth, j = 1, opener.end()
        while j < len(css) and depth:
            depth += {"{": 1, "}": -1}.get(css[j], 0)
            j += 1
        blocks.append((opener.group(1).strip(), css[opener.end():j - 1]))
        i = j


def _cap_for(css_body, hooks):
    """The widest `max-width: <n>px` any rule in `css_body` puts on one of
    `hooks` (a set of selectors the element matches), or None."""
    caps = [int(px)
            for selector, decls in re.findall(r"([^{}]+)\{([^{}]*)\}", css_body)
            if {s.strip() for s in selector.split(",")} & hooks
            for px in re.findall(r"max-width:\s*(\d+)px", decls)]
    return max(caps) if caps else None


def _view_hooks(html, view_id):
    """Every selector the given view section matches, read from the markup
    so a hook rename follows the HTML instead of breaking this test."""
    tag = re.search(rf"<section\b[^>]*id=\"{view_id}\"[^>]*>", html)
    assert tag, f"the {view_id} section must exist"
    classes = re.search(r'class="([^"]*)"', tag.group(0))
    return {f"#{view_id}"} | {
        f".{c}" for c in (classes.group(1).split() if classes else [])}


def test_stylesheet_sizes_each_view_responsively():
    """A single unconditional `max-width: 640px` on the `main` shell capped
    EVERY view at phone width, so the 5-column audit table rendered in
    ~614px on a 2560px desktop. CI has no browser, so resolve the cascade
    textually rather than pinning selector spelling: the shell carries no
    blanket cap, and the table-bearing views are widened strictly under a
    min-width breakpoint (so phone width keeps its original geometry)."""
    base, media = _split_media((STATIC / "style.css").read_text())
    html = (STATIC / "index.html").read_text()

    shell = re.search(r"(?<![\w.#-])main\s*\{([^}]*)\}", base)
    shell_decls = shell.group(1) if shell else ""
    assert "max-width" not in shell_decls, (
        "the shell must not cap every view at one width - per-view widths "
        "belong on the view sections")
    assert "padding" not in shell_decls, (
        "shell padding is subtracted from the viewport BEFORE the per-view "
        "cap applies, so each view renders wider than its cap intends - "
        "keep padding and max-width on the same box")

    widening = [body for condition, body in media if "min-width" in condition]
    assert widening, "style.css must declare at least one min-width breakpoint"

    for view_id in ("view-stats", "view-audit"):
        hooks = _view_hooks(html, view_id)
        phone = _cap_for(base, hooks)
        desktop = max((c for c in (_cap_for(b, hooks) for b in widening)
                       if c is not None), default=None)
        assert desktop is not None, (
            f"#{view_id} must be widened under a min-width breakpoint, not "
            f"left on the shared phone-width cap")
        assert phone is None or desktop > phone, (
            f"#{view_id} is capped at {desktop}px on desktop but {phone}px "
            f"below the breakpoint - the breakpoint must widen it")


def _rule(css_body, selector):
    """The declarations of the rule whose selector list contains exactly
    `selector`, or None."""
    for sel, decls in re.findall(r"([^{}]+)\{([^{}]*)\}", css_body):
        if selector in {s.strip() for s in sel.split(",")}:
            return decls
    return None


def _decls_for(css_body, selector):
    """EVERY declaration block naming `selector`, concatenated - so the
    assertion does not depend on which rule happens to come first."""
    return " ".join(
        decls for sel, decls in re.findall(r"([^{}]+)\{([^{}]*)\}", css_body)
        if selector in {s.strip() for s in sel.split(",")})


def test_wrapping_never_shatters_short_tokens():
    """`word-break: break-all` on the shared `th, td` rule broke every cell
    at whatever character hit the edge, so `2026-07-26T14:03:11Z` rendered
    as `2026-07-2 / 6T14:03:1 / 1Z` and requester IPs split mid-octet. The
    shared rule must not force ANY intra-word break - `break-word` also
    splits a token that cannot fit - because it is shared with the stats
    table, whose device column carries IPs. Only free text may opt in."""
    css = (STATIC / "style.css").read_text()
    base, _ = _split_media(css)
    shared = _rule(base, "td")
    assert shared is not None, "the shared cell rule must still exist"
    for forbidden in ("break-all", "break-word", "anywhere"):
        assert forbidden not in shared, (
            f"the shared cell rule must not force `{forbidden}` - it applies "
            f"to the stats table's IP column too, and every intra-word break "
            f"mode can split an atomic token")
    # the free-text column is the one place an intra-word break is right
    assert re.search(r"#audit-table td\.col-note\s*\{[^}]*overflow-wrap:\s*anywhere",
                     css), "the note column should absorb long unbroken text"
    # Every atomic column refuses to wrap at all. col-target matters most:
    # removing `break-all` is NOT enough for it, because the default
    # line-breaker still offers a break after the `/` in a CIDR (Unicode
    # class SY - what makes long URLs wrap with no CSS at all).
    for column in ("#audit-table td.col-time", "#audit-table td.col-target",
                   "#audit-table td.col-requester"):
        assert "nowrap" in _decls_for(base, column), (
            f"{column} carries an atomic token (ISO stamp / CIDR / IP) and "
            f"must not wrap")


def test_audit_pages_through_the_server_offset():
    """The view dumped the server's default 200 rows in one table. `offset`
    has been supported since v1.8.0 (routes.py get_audit), so paging needs
    no API change - and the additive-only /v1 rule means it must not get
    one."""
    js = (STATIC / "app.js").read_text()
    audit_call = re.search(r'api\(\s*"GET",\s*[`"]/v1/audit[^`")]*', js)
    assert audit_call, "renderAudit must still fetch /v1/audit"
    assert "offset=" in audit_call.group(0) and "limit=" in audit_call.group(0), (
        "the audit fetch must page through the server's existing "
        f"limit/offset params, got: {audit_call.group(0)}")
    # A page turn that never landed must put the offset back, or the next
    # click jumps two pages and silently skips the one in between.
    turn = js.split("async function pageAudit(")[1].split("\n}")[0]
    assert re.search(r"if\s*\(await renderAudit\(\)\s*===\s*false\)"
                     r"\s*auditOffset\s*=\s*auditShown", turn), (
        "a failed page turn must put the offset back to the page actually "
        f"PAINTED - the intended one may never have rendered. Got: "
        f"{turn.strip()}")
    # every exit from renderAudit must report a boolean, or `=== false`
    # silently stops rolling back
    render = js.split("async function renderAudit()")[1].split("\nasync function")[0]
    returns = re.findall(r"\breturn\b([^;]*);", render)
    assert returns, "renderAudit must report whether it painted"
    for value in returns:
        assert value.strip() in ("true", "false"), (
            f"renderAudit must return an explicit boolean on every path, "
            f"got `return {value.strip()}`")


def test_audit_has_an_empty_state_in_both_languages():
    """Devices has one (index.html:55-57); audit rendered a bare header with
    no body and no explanation."""
    html = (STATIC / "index.html").read_text()
    en = json.loads((STATIC / "i18n" / "en.json").read_text())
    zh = json.loads((STATIC / "i18n" / "zh.json").read_text())
    tag = re.search(r"<p\b[^>]*\bid=\"audit-empty\"[^>]*>", html)
    assert tag, "the audit view needs an empty state, like devices"
    key = re.search(r'data-i18n="([^"]+)"', tag.group(0))
    assert key, "the audit empty state must be translatable"
    assert key.group(1) in en and key.group(1) in zh, (
        f"the audit empty state key {key.group(1)!r} must exist in BOTH "
        f"dictionaries")
    # it must not be suppressed on later pages: a blank table with no
    # explanation is the silence this ticket exists to remove
    js = (STATIC / "app.js").read_text()
    toggle = re.search(r'\$\("#audit-empty"\)\.classList\.toggle\(([^;]+)\);', js)
    assert toggle, "the empty state must be toggled from the render path"
    assert "auditOffset" not in toggle.group(1) and "offset" not in toggle.group(1), (
        "the empty state must show whenever there are no rows, not only on "
        f"the first page, got: {toggle.group(1).strip()}")


def test_audit_is_not_silently_stale():
    """The 10s loop refreshed health + stats/devices only, so a left-open
    audit tab kept showing whatever it had at click time with nothing
    saying so. It must now refresh - but only the newest page, since
    re-fetching a raw offset while new entries push rows down would
    duplicate some and skip others; deeper pages say they are paused."""
    js = (STATIC / "app.js").read_text()
    loop = js.split("setInterval(")[1].split("}, ")[0]
    assert "audit" in loop, (
        "the refresh loop must either re-render the audit view or surface "
        "how stale it is - silence is the bug")
    assert "auditOffset === 0" in loop, (
        "the auto-refresh must be confined to the first page - refreshing a "
        "deeper offset reshuffles rows under the reader")
    assert re.search(r'\$\("#audit-paused"\)', js), \
        "a page whose auto-refresh is frozen must say so"


def test_a_dead_backend_cannot_pass_for_fresh_data():
    """`fetch` REJECTS when the panel is unreachable rather than resolving
    with a status, so without a catch the failure escapes every caller and
    every view keeps rendering stale data with no indication. The stale
    marker is only reachable if api() converts that rejection into a
    falsy status."""
    js = (STATIC / "app.js").read_text()
    body = js.split("async function api(")[1].split("\n}")[0]
    assert "try {" in body and "catch" in body, \
        "api() must survive a rejected fetch, not let it escape the caller"
    assert re.search(r"catch[^{]*\{[^}]*status:\s*0", body), (
        "a fetch that never reached the panel must report a non-200 status "
        "so callers take their failure path")
    # and a failed refresh must not wipe a view that was rendering fine
    devices = js.split("async function renderDevices()")[1].split("\n}")[0]
    clear = devices.index('list.textContent = ""')
    guard = devices.index("if (status !== 200) return;")
    assert guard < clear, (
        "renderDevices must check the status BEFORE clearing the list, or a "
        "transient failure blanks a correctly-rendered view")


INERT_NAMESPACE_URIS = {
    # XML namespace IDENTIFIERS - never fetched, required by the DOM API
    # (createElementNS); everything else http(s):// is forbidden.
    "http://www.w3.org/2000/svg",
    "http://www.w3.org/1999/xhtml",
}


def test_zero_external_references():
    # No http(s):// fetches, imports, hrefs, or srcs may leave the tree —
    # the ONLY sanctioned absolute link target is the same-LAN MetaCubexD
    # deep-link, which the JS builds at runtime from window.location (so no
    # literal URL may appear anywhere either).
    for path in STATIC.rglob("*"):
        if path.is_dir() or path.name == ".gitkeep":
            continue
        text = path.read_text()
        for m in re.finditer(r"https?://[^\s\"'<>)]+", text):
            assert m.group(0) in INERT_NAMESPACE_URIS, (
                f"{path.name} carries an external URL: {m.group(0)}")
        if path.suffix in (".html", ".js"):
            assert "import " not in text or "from \"http" not in text
            for m in re.finditer(r"\b(?:src|href)=[\"']([^\"']+)[\"']", text):
                target = m.group(1)
                assert not target.startswith(("http:", "https:", "//")), (
                    f"{path.name} references outside the tree: {target}")


def test_static_tree_is_served_same_origin(client, panel_env):
    r = client.get("/ui/")
    assert r.status_code == 200
    assert "text/html" in r.headers.get("content-type", "")
    assert "data-testid" in r.text
    r = client.get("/ui/i18n/en.json")
    assert r.status_code == 200
    # root redirects into the UI so the panel URL alone lands somewhere
    r = client.get("/", follow_redirects=False)
    assert r.status_code in (302, 307)
    assert r.headers["location"] == "/ui/"


def test_band_member_flag_semantics(client, panel_env, monkeypatch):
    h = auth_headers(panel_env)
    made = client.post("/v1/devices",
                       json={"address": "192.168.1.240", "mode": "full-tunnel"},
                       headers=h)
    assert made.status_code == 201
    # knob unset: no band members, flag present and false (tolerated)
    rows = client.get("/v1/devices").json()["devices"]
    assert all(r["band_member"] is False for r in rows)
    # knob set: devices inside the band carry the flag
    monkeypatch.setenv("FULL_PROXY_SOURCES", "192.168.1.240/28")
    rows = client.get("/v1/devices").json()["devices"]
    assert [r["band_member"] for r in rows] == [True]
    client.post("/v1/devices",
                json={"address": "198.51.100.9", "mode": "full-direct"},
                headers=h)
    rows = client.get("/v1/devices").json()["devices"]
    flags = {r["cidr"]: r["band_member"] for r in rows}
    assert flags["192.168.1.240/32"] is True
    assert flags["198.51.100.9/32"] is False
    # the canonical band list rides along for the UI's pre-add confirm
    body = client.get("/v1/devices").json()
    assert body["band"] == ["192.168.1.240/28"]
    # a garbage knob degrades to no-badge, never an error
    monkeypatch.setenv("FULL_PROXY_SOURCES", "not,valid,entries")
    r = client.get("/v1/devices")
    assert r.status_code == 200
    assert all(row["band_member"] is False for row in r.json()["devices"])
    assert r.json()["band"] == []
