"""Static-tree discipline for the no-build UI: EN/zh dictionaries with
identical key sets, a data-testid on every interactive element, ZERO
external references anywhere under app/static (fully self-contained), and
the same-origin serving mount."""

import ast
import json
import re
from pathlib import Path

from app.tests.conftest import auth_headers

APP = Path(__file__).resolve().parents[1]
STATIC = APP / "static"
# The Vite source tree (#78). Its BUILT output is checked separately by
# scripts/ci/ui_build_check.py, because only the built file ships and only
# it can prove the A6 marker survived the bundler.
UI_SRC = APP / "ui"
JSX = sorted((UI_SRC / "src").rglob("*.jsx")) if (UI_SRC / "src").exists() else []


def test_i18n_key_sets_identical():
    en = json.loads((STATIC / "i18n" / "en.json").read_text())
    zh = json.loads((STATIC / "i18n" / "zh.json").read_text())
    assert en.keys() == zh.keys(), (
        f"EN/zh dictionaries must carry identical key sets; "
        f"only-en={sorted(set(en) - set(zh))} only-zh={sorted(set(zh) - set(en))}")
    assert en, "the dictionaries must not be empty"
    for key, value in {**en, **zh}.items():
        assert isinstance(value, str) and value.strip(), f"empty entry: {key}"


def _audit_actions():
    """Every action string written into the audit log, across the whole app
    (tests excluded). The UI renders each as `action_<value>`, so one added
    server-side without a translation leaks a raw key into the table -
    which no dictionary-only check can see.

    Resolves a literal OR a module-level constant. The literal-only version
    of this sweep had a hole big enough to drive a feature through:
    `append_audit(conn, action=AUDIT_ACTION, ...)` was simply invisible, so
    a new audited surface could ship with no translation in either
    dictionary and this gate would stay green. Anything it still cannot
    resolve is a hard failure rather than a silent skip - that is the whole
    difference between a gate and a decoration."""
    actions = set()
    unresolved = []
    for path in APP.rglob("*.py"):
        if "tests" in path.parts:
            continue
        # Parsed, not grepped. A regex cannot tell a call from prose about a
        # call: a comment explaining this very gate was enough to make the
        # textual version report an unresolvable action. ast sees only code.
        tree = ast.parse(path.read_text(), filename=str(path))
        consts = {
            t.id: node.value.value
            for node in tree.body
            if isinstance(node, ast.Assign)
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str)
            for t in node.targets if isinstance(t, ast.Name)
        }
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            name = getattr(node.func, "id", None) or getattr(
                node.func, "attr", None)
            if name != "append_audit":
                continue
            for kw in node.keywords:
                if kw.arg != "action":
                    continue
                if (isinstance(kw.value, ast.Constant)
                        and isinstance(kw.value.value, str)):
                    actions.add(kw.value.value)
                elif (isinstance(kw.value, ast.Name)
                        and kw.value.id in consts):
                    actions.add(consts[kw.value.id])
                else:
                    unresolved.append(
                        f"{path.name}:{node.lineno} action="
                        f"{ast.dump(kw.value)[:60]}")
    assert not unresolved, (
        "an audit action this gate cannot resolve - use a string literal or "
        "a module-level constant so the bilingual check can see it: "
        f"{unresolved}")
    assert len(actions) >= 5, (
        "the audit-action sweep found almost nothing - append_audit was "
        f"probably renamed or moved, which would silently empty this "
        f"gate: {actions}")
    return actions


def test_every_used_i18n_key_exists():
    """Usage-side parity (the dictionaries agreeing with each other is not
    enough): every data-i18n/data-i18n-placeholder key in the HTML and
    every key the JS renders must resolve, or the raw key leaks into the
    UI. Template-literal keys - t(`action_${...}`) - are invisible to a
    plain regex, so each prefix is resolved against the values that
    actually reach it at runtime."""
    en = json.loads((STATIC / "i18n" / "en.json").read_text())
    html = (STATIC / "index.html").read_text()
    js = (STATIC / "app.js").read_text()
    used = set(re.findall(r'data-i18n(?:-placeholder)?="([^"]+)"', html))
    used |= set(re.findall(r'(?<![A-Za-z0-9_.])t\("([^"]+)"\)', js))

    prefixes = set(re.findall(r"(?<![A-Za-z0-9_.])t\(`([a-z]+)_\$\{", js))
    assert prefixes, (
        "no template-literal t(`prefix_${...}`) call was found - if the UI "
        "stopped building keys dynamically this gate should be simplified, "
        "not left silently matching nothing")
    resolvers = {
        "state": lambda: set(re.findall(r'"(saved|applying|confirmed|drift)"', js)),
        "action": _audit_actions,
    }
    unknown = prefixes - resolvers.keys()
    assert not unknown, (
        f"the UI builds i18n keys from prefixes this gate cannot resolve: "
        f"{sorted(unknown)} - teach it where those values come from, or a "
        f"missing translation ships unnoticed")
    for prefix in prefixes:
        used |= {f"{prefix}_{value}" for value in resolvers[prefix]()}

    missing = sorted(k for k in used if k not in en)
    assert not missing, f"used i18n keys missing from the dictionaries: {missing}"


def _js_code_only(js):
    """`app.js` with its comments removed, so prose explaining why an API
    is banned does not itself trip the ban.

    Only FULL-LINE `//` comments are stripped. A blanket `//.*` would also
    truncate the protocol-relative URL this file builds
    (`` `//${location.hostname}:...` ``) and, with it, anything sharing
    that line - which is enough to hide a real banned call from the check.
    Keeping trailing text means a trailing comment naming a banned API
    trips the ban, a false RED; that is the safe direction to err in."""
    js = re.sub(r"/\*.*?\*/", "", js, flags=re.S)
    return re.sub(r"^[ \t]*//.*$", "", js, flags=re.M)


def test_no_warning_rides_on_a_suppressible_dialog():
    """`alert()` is a no-op once a browser's "prevent this page from
    creating additional dialogs" box is ticked, so a warning delivered
    that way can vanish with nothing in its place. That is fatal for the
    apply-drift message in particular: swallowing it leaves the UI
    implying the gateway matches the store when it may not. `confirm()`
    stays - it fails CLOSED, since a suppressed dialog returns false and
    the guarded action is abandoned."""
    js = (STATIC / "app.js").read_text()
    html = (STATIC / "index.html").read_text()
    code = _js_code_only(js).replace("window.alert", "alert")
    assert not re.search(r"(?<![\w.])alert\s*\(", code), \
        "no user-facing warning may depend on alert() - render it in-page"
    tag = re.search(r"<div\b[^>]*\bid=\"notice\"[^>]*>", html)
    assert tag, "an in-page notice surface must exist to carry those messages"
    assert 'role="alert"' in tag.group(0), (
        "the notice must be announced to assistive tech - that is the part "
        "of alert() worth keeping")
    assert "data-testid=" in tag.group(0), "the notice needs a stable testid"
    # the drift message specifically must be handed TO notify - a loose
    # "both strings appear somewhere in setMode" check would be satisfied
    # by the sibling error branch's own notify() call
    drift = js.split("async function setMode")[1].split("\nasync function")[0]
    assert re.search(r'notify\(\s*t\("delete_drift_warn"\)\s*\)', drift), \
        "the apply-drift warning must be rendered through the in-page surface"

    body = _js_code_only(js).split("function notify(")[1].split("\nfunction")[0]
    # Without this the surface stays `display: none !important` and the
    # warning is suppressed permanently - a worse failure than alert().
    assert re.search(r'classList\.remove\("hidden"\)', body), \
        "notify() must actually reveal the notice, not just fill it in"
    # An in-page banner in normal flow is invisible to a scrolled-down
    # user, which would swap a suppressible warning for an unseen one.
    base, _ = _split_media((STATIC / "style.css").read_text())
    assert re.search(r"position:\s*sticky", _decls_for(base, "#notice")), (
        "the notice must stay on screen from any scroll position - being "
        "unsuppressible is worthless if it renders above the fold")
    # alert() queued; a single-slot banner would silently drop an unread
    # warning when a second failure followed it.
    assert "appendChild" in body, \
        "notify() must add a message rather than replace the surface"
    # an ASSIGNMENT to textContent before the new line is built would mean
    # the previous message was wiped (`===` is a comparison, not that)
    assert not re.search(r"textContent\s*=(?!=)", body.split("createElement")[0]), \
        "notify() must stack messages, not overwrite an unread one"


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
    """The CLASSIC tree. It is still the panel users have until the React
    rewrite replaces it, so its floor stays exactly where it was - a gate
    repointed at a tree that has not been written yet would pass on an
    empty set and protect nothing in the meantime."""
    html = (STATIC / "index.html").read_text()
    for tag in re.finditer(r"<(button|input|select|textarea|a)\b[^>]*>", html):
        assert "data-testid=" in tag.group(0), (
            f"interactive element without data-testid: {tag.group(0)[:90]}")
    assert html.count("data-testid=") >= 10, \
        "the UI must carry stable testids throughout"


def test_every_interactive_jsx_element_has_testid():
    """The same rule on the React side, applied from the moment the tree
    exists rather than from the moment it is finished. It is vacuous today
    (the scaffold renders no interactive element) and bites the instant one
    appears - which is the point: the Playwright gate rides on these ids,
    and adding them retroactively is how they end up unstable.

    Deliberately NO count floor here: a floor on a tree that is still a
    scaffold would either fail now or be set so low it proves nothing. The
    floor belongs with the rewrite that populates it.
    """
    assert JSX, "app/ui/src has no .jsx - the scaffold moved, so this gate " \
                "is reading nothing and would pass on anything"
    interactive = re.compile(
        r"<(button|input|select|textarea|Button|IconButton|TextField|Select|"
        r"Switch|Checkbox|Tab|MenuItem)\b[^>]*>")
    for path in JSX:
        for tag in interactive.finditer(path.read_text(encoding="utf-8")):
            assert "data-testid=" in tag.group(0), (
                f"{path.name}: interactive element without data-testid: "
                f"{tag.group(0)[:90]}")


def test_the_jsx_source_makes_no_external_reference():
    """Same rule as the static tree, applied to the source we author. The
    BUILT bundle is a different question - React and MUI embed inert
    error-explainer URLs of their own - and it has its own documented
    allowlist in scripts/ci/ui_build_check.py. What must stay true here is
    that nothing WE wrote reaches off-box."""
    assert JSX, "app/ui/src has no .jsx - this gate is reading nothing"
    for path in [*JSX, UI_SRC / "index.html", UI_SRC / "vite.config.js"]:
        text = path.read_text(encoding="utf-8")
        found = re.findall(r"https?://[^\s\"'`)]+", text)
        assert not found, f"{path.name}: external reference(s) {found[:3]}"


def test_the_vite_shell_carries_the_a6_marker_in_source():
    """A fast source-side tripwire. It does NOT replace
    scripts/ci/ui_build_check.py, which asserts the same string against the
    BUILT artifact - only the built one ships, and a bundler setting can
    drop what the source clearly contains."""
    html = (UI_SRC / "index.html").read_text(encoding="utf-8")
    stripped = re.sub(r"<!--.*?-->", "", html, flags=re.S)
    assert 'data-i18n="app_title"' in stripped, (
        "the Vite shell must carry data-i18n=\"app_title\" outside a comment "
        "- release phase A6 greps it from raw HTML with no JavaScript running")


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


def test_the_new_ui_is_additive_and_never_displaces_the_classic_one(
        client, panel_env):
    """The whole shape of #78: introduce the toolchain WITHOUT replacing a
    working panel. `/ui/` must still answer with the classic tree and the
    root redirect must still land there - shipping a scaffold over the UI
    users have would be a regression dressed as progress.

    The built tree is skipped when absent, because dist/ is gitignored and
    a source checkout must still start. That is exactly why this asserts
    the CLASSIC side unconditionally and the new side only when built: a
    test that silently skipped both would protect nothing.
    """
    classic = client.get("/ui/")
    assert classic.status_code == 200
    assert "data-testid" in classic.text
    assert client.get("/ui/i18n/en.json").status_code == 200
    root = client.get("/", follow_redirects=False)
    assert root.headers["location"] == "/ui/", (
        "the root redirect must keep landing on the panel users have")

    dist = APP / "ui" / "dist" / "index.html"
    if not dist.exists():
        return  # unbuilt checkout; scripts/ci/ui_build_check.py covers built
    built = client.get("/ui/next/")
    assert built.status_code == 200
    assert 'data-i18n="app_title"' in built.text, (
        "the served build must carry the A6 marker - release phase A6 greps "
        "it from raw HTML with no JavaScript running")
    assert "/ui/next/assets/" in built.text, (
        "vite `base` must match the mount, or every asset 404s while the "
        "page still renders - a blank screen that reads like a JS error")


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
