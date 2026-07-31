"""Source discipline for the panel UI: EN/zh dictionaries with identical key
sets, every key the code renders present in both, a data-testid on every
interactive element, ZERO external references anywhere in the tree we author,
and the same-origin serving mount.

These are the SOURCE-side tripwires. Two other gates own what this one cannot
see: `scripts/ci/ui_build_check.py` checks the BUILT artifact (only the built
file ships, and a bundler setting can drop what the source plainly contains),
and `app/ui/e2e/panel.spec.js` drives the rendered page in a real browser -
which is where every claim about layout, geometry and behaviour now lives,
because none of them can be settled by reading text.
"""

import ast
import json
import re
from pathlib import Path

from app.store import settings as settings_store
from app.tests.conftest import auth_headers

APP = Path(__file__).resolve().parents[1]
UI = APP / "ui"
I18N = UI / "public" / "i18n"
SRC = UI / "src"
SOURCES = sorted([*SRC.rglob("*.jsx"), *SRC.rglob("*.js")])
JSX = sorted(SRC.rglob("*.jsx"))


def _read(path):
    return path.read_text(encoding="utf-8")


def test_i18n_key_sets_identical():
    en = json.loads(_read(I18N / "en.json"))
    zh = json.loads(_read(I18N / "zh.json"))
    assert en.keys() == zh.keys(), (
        f"EN/zh dictionaries must carry identical key sets; "
        f"only-en={sorted(set(en) - set(zh))} only-zh={sorted(set(zh) - set(en))}")
    assert en, "the dictionaries must not be empty"
    for key, value in {**en, **zh}.items():
        assert isinstance(value, str) and value.strip(), f"empty entry: {key}"


def _audit_actions():
    """Every action string written into the audit log, across the whole app
    (tests excluded). The UI renders each as `action_<value>`, so one added
    server-side without a translation leaks a raw key into the table - which
    no dictionary-only check can see.

    Resolves a literal OR a module-level constant. The literal-only version
    of this sweep had a hole big enough to drive a feature through:
    `append_audit(conn, action=AUDIT_ACTION, ...)` was simply invisible, so a
    new audited surface could ship with no translation in either dictionary
    and this gate would stay green. Anything it still cannot resolve is a hard
    failure rather than a silent skip - that is the whole difference between a
    gate and a decoration."""
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


# Every `t(...)` call, with its argument text. Anchored on a non-identifier
# char so `.at(` / `format(` cannot masquerade as one.
_T_CALL = re.compile(r"(?<![A-Za-z0-9_.$])t\(\s*([^()]*?)\s*\)")
_LITERAL = re.compile(r'^"([^"]+)"$')
_TEMPLATE = re.compile(r"^`([a-z]+)_\$\{")
# An indirect key must be written as a `label:` property holding a STRING
# LITERAL, so a key reached through a variable is still visible here.
_INDIRECT = re.compile(r"^(?:[A-Za-z_$][\w$]*\.)*label$")
_LABEL_PROP = re.compile(r'\blabel:\s*"([^"]+)"')


def test_every_used_i18n_key_exists():
    """Usage-side parity - the dictionaries agreeing with each other is not
    enough. Every key the components render must resolve, or the raw key leaks
    into the UI in place of a label.

    Three shapes are resolvable and everything else is a HARD FAILURE, for the
    same reason the Python sweep above refuses to skip what it cannot read: a
    key assembled somewhere this gate cannot follow would ship untranslated
    and green.

      t("literal")            direct
      t(`prefix_${...}`)      resolved against the values that actually reach
                              it at runtime
      t(x.label) / t(label)   an indirect key, which must be declared as
                              `label: "the_key"` so it is still a literal
    """
    en = json.loads(_read(I18N / "en.json"))
    # Comments stripped first, for the same reason the Python sweep is parsed
    # rather than grepped: prose ABOUT a call is not a call, and the first
    # draft of this gate reported `t()` from a sentence explaining what t()
    # does.
    text = {path: _code_only(_read(path)) for path in SOURCES}
    joined = "\n".join(text.values())

    used = set()
    prefixes = set()
    unresolved = []
    for path, body in text.items():
        for arg in _T_CALL.findall(body):
            direct = _LITERAL.match(arg)
            if direct:
                used.add(direct.group(1))
                continue
            template = _TEMPLATE.match(arg)
            if template:
                prefixes.add(template.group(1))
                continue
            if _INDIRECT.match(arg):
                continue
            unresolved.append(f"{path.name}: t({arg})")

    assert not unresolved, (
        "an i18n key this gate cannot resolve - use a literal, a "
        "`prefix_${...}` template with a registered resolver, or a "
        f'`label: "key"` property: {unresolved}')

    # Every declared label is a used key. This is what makes the indirect
    # shape safe rather than merely tolerated.
    used |= set(_LABEL_PROP.findall(joined))

    assert prefixes, (
        "no template-literal t(`prefix_${...}`) call was found - if the UI "
        "stopped building keys dynamically this gate should be simplified, "
        "not left silently matching nothing")
    resolvers = {
        # the apply-state machine's four states, read from the module that
        # owns them rather than re-listed here
        "state": lambda: set(re.findall(
            r'"(saved|applying|confirmed|drift)"', _read(SRC / "applystate.js"))),
        "action": _audit_actions,
        # the range vocabulary comes from the BACKEND, so a range added to
        # settings.py without a translation fails here rather than rendering
        # its own key at the operator
        "range": lambda: set(settings_store.STATS_RANGES),
    }
    unknown = prefixes - resolvers.keys()
    assert not unknown, (
        f"the UI builds i18n keys from prefixes this gate cannot resolve: "
        f"{sorted(unknown)} - teach it where those values come from, or a "
        f"missing translation ships unnoticed")
    for prefix in prefixes:
        values = resolvers[prefix]()
        assert values, f"the {prefix!r} resolver matched nothing"
        used |= {f"{prefix}_{value}" for value in values}

    missing = sorted(k for k in used if k not in en)
    assert not missing, f"used i18n keys missing from the dictionaries: {missing}"


def _code_only(text):
    """Source with its comments removed, so prose explaining why an API is
    banned does not itself trip the ban.

    Only FULL-LINE `//` comments are stripped. A blanket `//.*` would also
    truncate the protocol-relative URL the shell builds
    (`` `//${location.hostname}:...` ``) and, with it, anything sharing that
    line - enough to hide a real banned call. Keeping trailing text means a
    trailing comment naming a banned API trips it, a false RED; that is the
    safe direction to err in."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"^[ \t]*//.*$", "", text, flags=re.M)


def test_no_warning_rides_on_a_suppressible_dialog():
    """`alert()` is a no-op once a browser's "prevent this page from creating
    additional dialogs" box is ticked, so a warning delivered that way can
    vanish with nothing in its place. That is fatal for the apply-drift
    message in particular: swallowing it leaves the UI implying the gateway
    matches the store when it may not. `confirm()` stays - it fails CLOSED,
    since a suppressed dialog returns false and the guarded action is
    abandoned."""
    for path in SOURCES:
        code = _code_only(_read(path)).replace("window.alert", "alert")
        assert not re.search(r"(?<![\w.])alert\s*\(", code), (
            f"{path.name}: no user-facing warning may depend on alert() - "
            f"render it in-page")

    shell = _read(SRC / "App.jsx")
    assert 'data-testid="notice"' in shell, (
        "an in-page notice surface must exist to carry those messages")
    # The Alert's OWN attribute list, stopping at `action=` so a role or a
    # sticky position living on the nested dismiss button cannot stand in for
    # one on the surface itself. A regex for the whole opening tag cannot do
    # this: `action={(<Button .../>)}` nests JSX inside the props.
    mark = shell.index('data-testid="notice"')
    props = shell[shell.rindex("<Alert", 0, mark):shell.index("action={", mark)]
    assert 'role="alert"' in props, (
        "the notice must be announced to assistive tech - that is the part of "
        "alert() worth keeping")
    # An in-page banner in normal flow is invisible to a scrolled-down reader,
    # which would swap a suppressible warning for an unseen one.
    assert "sticky" in props, (
        "the notice must stay on screen from any scroll position - being "
        "unsuppressible is worthless if it renders above the fold")

    # The drift message specifically must be handed TO notify - a loose "both
    # strings appear somewhere" check would be satisfied by the sibling error
    # branch's own notify() call.
    devices = _read(SRC / "views" / "DevicesView.jsx")
    assert re.search(r'notify\(t\("delete_drift_warn"\)\)', devices), (
        "the apply-drift warning must be rendered through the in-page surface")

    # notify() must ADD a message rather than replace the surface: alert()
    # queued, so a single slot would silently drop an unread warning when a
    # second failure followed it.
    body = _code_only(shell).split("const notify = useCallback")[1] \
        .split("}, []);")[0]
    assert "prev" in body and "..." in body, (
        "notify() must stack messages onto the existing ones, not overwrite "
        "an unread one")


def test_every_interactive_jsx_element_has_testid():
    """The browser gate rides on these ids, and ids added retroactively are
    how they end up unstable.

    The floor matters as much as the rule: a gate repointed at a tree that
    does not exist yet passes on an empty set and protects nothing.
    """
    assert JSX, "app/ui/src has no .jsx - this gate is reading nothing"
    interactive = re.compile(
        r"<(button|input|select|textarea|a|Button|IconButton|TextInput|"
        r"SelectInput|Switch|Checkbox|Tab|MenuItem)\b[^>]*>")
    seen = 0
    for path in JSX:
        # Comments stripped: `controls.jsx` explains in prose that it renders
        # real `<input>` elements, and the first draft of this gate read that
        # sentence as an untagged control.
        for tag in interactive.finditer(_code_only(_read(path))):
            seen += 1
            assert "data-testid=" in tag.group(0), (
                f"{path.name}: interactive element without data-testid: "
                f"{tag.group(0)[:90]}")
    assert seen >= 15, (
        f"the interactive-element sweep found only {seen} elements - the "
        f"component names above have probably drifted, which would empty this "
        f"gate silently")
    assert _read(SRC / "App.jsx").count("data-testid=") >= 10, (
        "the shell must carry stable testids throughout")


def test_the_jsx_source_makes_no_external_reference():
    """Same rule the classic tree carried, applied to the source we author.
    The BUILT bundle is a different question - React and MUI embed inert
    error-explainer URLs of their own - and it has its own documented
    allowlist in scripts/ci/ui_build_check.py. What must stay true here is
    that nothing WE wrote reaches off-box."""
    assert SOURCES, "app/ui/src has no sources - this gate is reading nothing"
    for path in [*SOURCES, UI / "index.html", UI / "vite.config.js"]:
        found = re.findall(r"https?://[^\s\"'`)]+", _read(path))
        assert not found, f"{path.name}: external reference(s) {found[:3]}"


def test_zero_external_references_in_the_served_tree():
    """Everything the panel SERVES from its own tree, the dictionaries
    included - a translated string carrying a URL would be fetched by whatever
    rendered it."""
    served = [*I18N.glob("*.json"), UI / "index.html"]
    assert len(served) >= 3, "the served-tree sweep is reading almost nothing"
    for path in served:
        text = _read(path)
        found = [m.group(0) for m in re.finditer(r"https?://[^\s\"'<>)]+", text)]
        assert not found, f"{path.name} carries an external URL: {found[:3]}"
        for m in re.finditer(r"\b(?:src|href)=[\"']([^\"']+)[\"']", text):
            target = m.group(1)
            assert not target.startswith(("http:", "https:", "//")), (
                f"{path.name} references outside the tree: {target}")


def test_the_vite_shell_carries_the_a6_marker_in_source():
    """A fast source-side tripwire. It does NOT replace
    scripts/ci/ui_build_check.py, which asserts the same string against the
    BUILT artifact - only the built one ships, and a bundler setting can drop
    what the source clearly contains."""
    html = _read(UI / "index.html")
    stripped = re.sub(r"<!--.*?-->", "", html, flags=re.S)
    assert 'data-i18n="app_title"' in stripped, (
        "the Vite shell must carry data-i18n=\"app_title\" outside a comment "
        "- release phase A6 greps it from raw HTML with no JavaScript running")


def test_the_stats_range_vocabulary_is_one_list():
    """The selector and the `stats_default_range` setting are the same fact
    stored twice, and two copies of one fact drift. A stored default naming a
    range the view cannot draw would land the operator on a blank tab with
    nothing saying why - honoured, and useless."""
    declared = re.search(r"export const RANGES = \[([^\]]*)\]",
                         _read(SRC / "stats.js"))
    assert declared, "app/ui/src/stats.js must declare the range vocabulary"
    ranges = tuple(re.findall(r'"([^"]+)"', declared.group(1)))
    assert ranges == settings_store.STATS_RANGES, (
        f"the view offers {ranges} but the setting accepts "
        f"{settings_store.STATS_RANGES} - they must move together")


def test_the_naming_rule_is_applied_in_exactly_one_place():
    """DEC-C: a device carries two independent human names and the store
    deliberately defines no precedence between them, so the rule is applied
    ONCE in the interface rather than guessed at per call site. A component
    reaching for `.name` directly is that guess reappearing."""
    assert "export function displayName" in _read(SRC / "devices.js"), (
        "the naming precedence must live in one exported function")
    for path in JSX:
        body = _code_only(_read(path))
        hit = re.search(r"\bdev(?:ice)?\.name\b", body)
        assert not hit, (
            f"{path.name} reads a device's `name` directly ({hit.group(0)}) - "
            f"go through displayName()/displacedName(), so the precedence rule "
            f"has exactly one definition")


def test_the_rename_control_writes_the_layer_the_address_can_carry():
    """A /32 has an identity row and a range cannot: `host_key` refuses
    anything wider. An unconditional PUT /v1/identity would fail for a range
    (the CIDR's `/` is a path separator, so it cannot even address the
    endpoint), and an unconditional PATCH would write the losing label on a
    host."""
    body = _read(SRC / "views" / "DevicesView.jsx")
    rename = body.split("const rename = async")[1].split("\n  };")[0]
    assert "isHost(dev.cidr)" in rename, (
        "the rename control must branch on whether the address can carry an "
        "alias at all")
    assert "/v1/identity/" in rename and "/v1/devices/" in rename, (
        "both write targets must be reachable from the one control")


def test_the_add_path_names_a_host_through_the_same_layer_as_rename():
    """If add wrote `devices.name` while rename wrote the alias, every device
    named at creation would diverge on its first rename - and the two-name
    state the row reports as an exception would become the normal one."""
    add = _read(SRC / "views" / "DevicesView.jsx") \
        .split("const addDevice = async")[1].split("\n  };")[0]
    assert re.search(r"host\s*\?\s*\{\s*address,\s*mode", add), (
        "a host add must POST without `name` - its name belongs to the "
        "identity layer")
    assert "/v1/identity/" in add, (
        "a host's typed name must be written as an alias after the device is "
        "created")
    assert "alias_write_failed" in add, (
        "the second write can fail on its own; a device added but unnamed must "
        "say so rather than look like a success")


def test_the_displaced_policy_label_is_shown_and_removable():
    """The alias winning must never mean the other stored name disappears from
    view: hiding it is the only version of this rule that would be a lie. And
    a label the interface shows but no control can remove is text the operator
    is stuck with, so the exit is explicit - never a side effect of a rename,
    which would destroy a second field the operator never mentioned."""
    devices = _read(SRC / "views" / "DevicesView.jsx")
    assert 'data-testid="device-legacy-name"' in devices, (
        "a displaced policy label must stay visible")
    retire = devices.split("const retireLabel = async")[1].split("\n  };")[0]
    assert "window.confirm" in retire, "retiring a label must be confirmed"
    assert re.search(r'\{\s*name:\s*""\s*\}', retire), (
        "retiring writes the shipped PATCH with an empty name, so the old text "
        "stays recoverable from the audit trail")
    rename = devices.split("const rename = async")[1].split("\n  };")[0]
    assert 'name: ""' not in rename, (
        "renaming must not clear the policy label as a side effect")


def test_audit_pages_through_the_server_offset():
    """The view dumped the server's default 200 rows in one table. `offset`
    has been supported since v1.8.0 (routes.py get_audit), so paging needs no
    API change - and the additive-only /v1 rule means it must not get one."""
    js = _read(SRC / "views" / "AuditView.jsx")
    call = re.search(r'api\(\s*\n?\s*"GET",\s*`/v1/audit[^`]*`', js)
    assert call, "the audit view must still fetch /v1/audit"
    assert "offset=" in call.group(0) and "limit=" in call.group(0), (
        f"the audit fetch must page through the server's existing limit/offset "
        f"params, got: {call.group(0)}")
    # A page turn that never landed must put the offset back, or the next
    # click jumps two pages and silently skips the one in between.
    turn = js.split("const page = async")[1].split("\n  };")[0]
    assert re.search(r"if\s*\(await load\([^)]*\)\s*===\s*false\)\s*"
                     r"setOffset\(shown\.current\)", turn), (
        f"a failed page turn must fall back to the page actually PAINTED - the "
        f"intended one may never have rendered. Got: {turn.strip()[:200]}")
    # Every exit from load() must report a boolean, or `=== false` silently
    # stops rolling back.
    load = js.split("const load = useCallback")[1].split("\n  }, []);")[0]
    returns = re.findall(r"\breturn\b([^;\n]*)[;\n]", load)
    assert returns, "load() must report whether it painted"
    for value in returns:
        assert value.strip() in ("true", "false"), (
            f"load() must report an explicit boolean on every path, got "
            f"`return {value.strip()}`")


def test_audit_has_an_empty_state_in_both_languages():
    """Devices has one; audit rendered a bare header with no body and no
    explanation."""
    js = _read(SRC / "views" / "AuditView.jsx")
    en = json.loads(_read(I18N / "en.json"))
    zh = json.loads(_read(I18N / "zh.json"))
    assert 'data-testid="audit-empty"' in js, (
        "the audit view needs an empty state, like devices")
    assert "audit_empty" in en and "audit_empty" in zh, (
        "the audit empty state must exist in BOTH dictionaries")
    # It must not be suppressed on later pages: a blank table with no
    # explanation is the silence this removed.
    guard = js.split('data-testid="audit-empty"')[0].rsplit("{loaded", 1)[1] \
        .split("? (")[0]
    assert "offset" not in guard, (
        f"the empty state must show whenever there are no rows, not only on "
        f"the first page, got: {guard.strip()}")


def test_audit_is_not_silently_stale():
    """The 10s loop refreshed health + stats/devices only, so a left-open audit
    tab kept showing whatever it had at click time with nothing saying so. It
    must now refresh - but only the newest page, since re-fetching a raw offset
    while new entries push rows down would duplicate some and skip others;
    deeper pages say they are paused."""
    js = _read(SRC / "views" / "AuditView.jsx")
    # The view is conditionally mounted, so entering the tab runs EVERY effect
    # - and `tick` is already non-zero after the session's first ten seconds.
    # Without skipping the first run, the mount fetched the same page twice.
    # Asserted here rather than in the browser: reproducing it needs a real
    # 10s tick to elapse, and a spec that sleeps that long to catch one
    # duplicate GET is not worth the wall clock it costs on every run.
    #
    # Checked BEFORE it is used as a split anchor, so losing it reads as this
    # message rather than as an IndexError three lines down.
    anchor = "if (!mounted.current) { mounted.current = true; return; }"
    assert anchor in js, (
        "the auto-refresh effect must skip its own mount run - the "
        "unconditional load(0) above already covers entering the tab")
    loop = js.split(anchor)[1].split("}, [tick, load]);")[0]
    assert "offsetRef.current !== 0" in loop, (
        "the auto-refresh must be confined to the first page - refreshing a "
        "deeper offset reshuffles rows under the reader")
    assert "load(0)" in loop, (
        "the refresh loop must actually re-render the newest page - silence is "
        "the bug")
    assert 'data-testid="audit-paused"' in js, (
        "a page whose auto-refresh is frozen must say so")
    assert 'data-testid="audit-stale"' in js, (
        "a failed refresh must never let what is on screen pass for current")


def test_a_dead_backend_cannot_pass_for_fresh_data():
    """`fetch` REJECTS when the panel is unreachable rather than resolving with
    a status, so without a catch the failure escapes every caller and every
    view keeps rendering stale data with no indication. The stale marker is
    only reachable if api() converts that rejection into a falsy status."""
    body = _read(SRC / "api.js").split("export async function api(")[1]
    assert "try {" in body and "catch" in body, (
        "api() must survive a rejected fetch, not let it escape the caller")
    assert re.search(r"catch[^{]*\{[^}]*status:\s*0", body), (
        "a fetch that never reached the panel must report a non-200 status so "
        "callers take their failure path")
    # And a failed refresh must not wipe a view that was rendering fine.
    devices = _read(SRC / "views" / "DevicesView.jsx")
    refresh = devices.split("const refresh = useCallback")[1].split("}, []);")[0]
    assert refresh.index("if (status !== 200) return;") < refresh.index("setDevices("), (
        "the device list must check the status BEFORE replacing its rows, or a "
        "transient failure blanks a correctly-rendered view")


def test_the_panel_ui_is_served_same_origin(client, panel_env):
    r = client.get("/ui/")
    assert r.status_code in (200, 503)
    r = client.get("/", follow_redirects=False)
    assert r.status_code in (302, 307)
    assert r.headers["location"] == "/ui/"


def test_the_react_tree_is_the_panel_now(client, panel_env):
    """This pinned the CLASSIC tree in place while the React tree was a
    scaffold at /ui/next/ (#78). #80 replaced that tree, so the assertion is
    inverted rather than deleted: /ui/ must now serve the BUILT React shell and
    the scaffold mount must be gone - two panels answering on one origin is how
    a fix lands on the page nobody is looking at.

    The built tree is skipped when absent, because dist/ is gitignored and a
    source checkout must still start. CI orders ui-build before app-unit so
    these assertions are live there; the unbuilt branch is asserted too, so a
    skip cannot quietly become the only path this test ever takes.
    """
    if not (UI / "dist" / "index.html").exists():
        unbuilt = client.get("/ui/")
        assert unbuilt.status_code == 503, (
            "an unbuilt checkout must say so loudly - a bare 404 reads like a "
            "routing bug when the fix is one command")
        assert 'data-i18n="app_title"' not in unbuilt.text, (
            "the unbuilt placeholder must NOT carry the A6 marker, or release "
            "phase A6 would accept a panel that is not there")
        return

    served = client.get("/ui/")
    assert served.status_code == 200
    assert "text/html" in served.headers.get("content-type", "")
    assert 'data-i18n="app_title"' in served.text, (
        "the served build must carry the A6 marker - release phase A6 greps it "
        "from raw HTML with no JavaScript running")
    assert "/ui/assets/" in served.text, (
        "vite `base` must match the mount, or every asset 404s while the page "
        "still renders - a blank screen that reads like a JS error")
    assert client.get("/ui/i18n/en.json").status_code == 200, (
        "the dictionaries must keep serving from the built tree")
    assert client.get("/ui/next/").status_code == 404, (
        "the scaffold mount must be retired with the scaffold")


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


def test_the_playwright_image_matches_the_pinned_playwright():
    """Browsers come from the CI image, so the image tag and the package
    version are one fact stored twice - and two copies of one fact drift.

    They drifted the moment this step was written: the image said v1.56.0 while
    the lockfile resolved 1.62.1, which is a browser mismatch that would either
    error or silently pull ~100MB per run, defeating the whole point of
    pre-baking them.
    """
    pkg = json.loads(_read(UI / "package.json"))
    pinned = pkg["devDependencies"]["@playwright/test"]
    assert not pinned.startswith(("^", "~")), (
        f"@playwright/test must be pinned EXACTLY (got {pinned!r}) - a range "
        f"lets npm resolve a version the CI image has no browsers for")
    ci = _read(APP.parent / ".woodpecker.yml")
    assert f"mcr.microsoft.com/playwright:v{pinned}-" in ci, (
        f"the ui-e2e image must be the v{pinned} Playwright image; the tag and "
        f"the package version are the same fact and must move together")
