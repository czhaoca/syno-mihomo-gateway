#!/usr/bin/env python3
"""CLI contract gate: scripts/cli/spec.yaml is the single source of truth for
gateway.sh's command surface (verbs, options, guardrails, exit codes, outputs,
in English and Chinese). From it this script generates the COMMITTED artifacts:

  scripts/lib/help.sh   runtime --help heredocs gateway.sh sources (English)
  docs/cli.md           the developer/user CLI reference (English)
  docs/zh/cli.md        the same reference in Chinese
  docs/CLI.txt          the plain-text guide shipped in the enduser bundle
  docs/CLI.zh.txt       its Chinese twin

Artifacts are committed (never CI-built) because the release bundle is a
`git archive` of tracked files: the NAS only ever sees the pre-generated
help.sh and CLI.txt.

Modes:
  bare     regenerate to a tempdir, byte-diff against the committed copies,
           and run the live assertions below; exit non-zero on any drift.
  --write  regenerate the artifacts in place (the only sanctioned way to
           change them; never hand-edit).

Live assertions (bare mode):
  * the spec's exit-code table matches the EXIT_* table in scripts/lib/common.sh;
  * the spec's verb set matches gateway.sh's dispatch list;
  * every _gw_check_add name in gateway.sh is named in the spec's json_output
    notes, en AND zh (the --json check vocabulary is a frozen contract, #29);
  * `gateway.sh --help` and `gateway.sh <verb> --help` output is byte-identical
    to the spec-generated help text (the runtime really serves the contract).
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
SPEC = REPO / "scripts" / "cli" / "spec.yaml"
GATEWAY = REPO / "scripts" / "gateway.sh"
COMMON = REPO / "scripts" / "lib" / "common.sh"

ARTIFACTS = {
    "help_sh": REPO / "scripts" / "lib" / "help.sh",
    "md_en": REPO / "docs" / "cli.md",
    "md_zh": REPO / "docs" / "zh" / "cli.md",
    "txt_en": REPO / "docs" / "CLI.txt",
    "txt_zh": REPO / "docs" / "CLI.zh.txt",
}

GENERATED_BANNER = "GENERATED from scripts/cli/spec.yaml - DO NOT EDIT."
REGEN_CMD = "python3 scripts/ci/cli_contract_check.py --write"
REGEN_HINT = f"Regenerate: {REGEN_CMD}"


def fail(msg: str):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def load_spec() -> dict:
    if not SPEC.exists():
        fail(f"missing CLI spec: {SPEC.relative_to(REPO)}")
    with SPEC.open(encoding="utf-8") as fh:
        spec = yaml.safe_load(fh)
    for key in ("meta", "guardrails", "exit_codes", "verbs"):
        if key not in spec:
            fail(f"spec.yaml lacks required top-level key: {key}")
    for verb in spec["verbs"]:
        for key in ("name", "summary", "options"):
            if key not in verb:
                fail(f"spec verb {verb.get('name', '?')} lacks {key}")
    return spec


def t(node, lang: str) -> str:
    """Pull one language string out of an {en, zh} node."""
    if not isinstance(node, dict) or lang not in node:
        fail(f"spec string is missing its '{lang}' variant: {node!r}")
    return node[lang]


# --- text builders ---------------------------------------------------------------

def verb_usage_line(verb: dict) -> str:
    return f"gateway.sh {verb['name']} [options]"


def global_help_text(spec: dict) -> str:
    """The English `gateway.sh --help` payload (also embedded in help.sh)."""
    m = spec["meta"]
    lines = [f"Usage: {m['invocation']}", ""]
    lines.append(t(m["summary"], "en"))
    lines.append("")
    lines.append("Verbs:")
    for verb in spec["verbs"]:
        lines.append(f"  {verb['name']:<10} {t(verb['summary'], 'en')}")
    lines.append("")
    lines.append("Guardrails:")
    for g in spec["guardrails"]:
        lines.append(f"  - {t(g, 'en')}")
    lines.append("")
    lines.append("Exit codes:")
    for ec in spec["exit_codes"]:
        lines.append(f"  {ec['code']}  {t(ec, 'en')}")
    lines.append("")
    lines.append(t(m["logs"], "en"))
    lines.append(f"Full reference: docs/CLI.txt (developers: docs/cli.md)")
    return "\n".join(lines) + "\n"


def verb_help_text(spec: dict, verb: dict) -> str:
    """The English `gateway.sh <verb> --help` payload."""
    lines = [f"Usage: {verb_usage_line(verb)}", ""]
    lines.append(t(verb["summary"], "en"))
    lines.append("")
    if verb["options"]:
        lines.append("Options:")
        width = max(len(o["flag"]) for o in verb["options"])
        for o in verb["options"]:
            lines.append(f"  {o['flag']:<{width}}  {t(o, 'en')}")
        lines.append("")
    notes = verb.get("notes")
    if notes:
        for n in notes:
            lines.append(t(n, "en"))
        lines.append("")
    lines.append("Global help: gateway.sh --help")
    return "\n".join(lines) + "\n"


def gen_help_sh(spec: dict) -> str:
    out = [
        "#!/bin/sh",
        f"# help.sh - {GENERATED_BANNER}",
        f"# {REGEN_HINT}",
        "# Runtime --help text for scripts/gateway.sh. English only by decision",
        "# (DEC-9): Chinese ships as docs/zh/cli.md + docs/CLI.zh.txt from the",
        "# same spec. POSIX /bin/sh, BusyBox-safe.",
        "",
        "usage() {",
        "  cat <<'SMG_HELP_EOF'",
        global_help_text(spec).rstrip("\n"),
        "SMG_HELP_EOF",
        "}",
        "",
        "# gw_help VERB - per-verb help; unknown verbs fall back to the global text.",
        "gw_help() {",
        "  case \"$1\" in",
    ]
    for verb in spec["verbs"]:
        out.append(f"    {verb['name']})")
        out.append("      cat <<'SMG_HELP_EOF'")
        out.append(verb_help_text(spec, verb).rstrip("\n"))
        out.append("SMG_HELP_EOF")
        out.append("      ;;")
    out.append("    *) usage ;;")
    out.append("  esac")
    out.append("}")
    return "\n".join(out) + "\n"


HEADINGS = {
    "en": {
        "title": "Command-line reference (gateway.sh)",
        "invocation": "Invocation",
        "verbs": "Verbs",
        "options": "Options",
        "guardrails": "Guardrails",
        "exit_codes": "Exit codes",
        "code": "Code",
        "meaning": "Meaning",
        "flag": "Flag",
        "description": "Description",
        "json": "Machine-readable output (--json)",
        "generated": f"This page is {GENERATED_BANNER} {REGEN_HINT}",
        # The .txt variant ships in the enduser bundle, which excludes
        # scripts/cli and scripts/ci - no dev regeneration pointer there.
        "generated_txt": "This guide is generated from the project's CLI spec - do not edit it by hand.",
    },
    "zh": {
        "title": "命令行参考（gateway.sh）",
        "invocation": "调用方式",
        "verbs": "子命令",
        "options": "选项",
        "guardrails": "安全护栏",
        "exit_codes": "退出码",
        "code": "退出码",
        "meaning": "含义",
        "flag": "选项",
        "description": "说明",
        "json": "机器可读输出（--json）",
        "generated": f"本页由 scripts/cli/spec.yaml 生成——请勿手工编辑。重新生成：{REGEN_CMD}",
        "generated_txt": "本指南由项目的 CLI 规格自动生成——请勿手工编辑。",
    },
}


def gen_md(spec: dict, lang: str) -> str:
    h = HEADINGS[lang]
    m = spec["meta"]
    out = [f"# {h['title']}", ""]
    out.append(f"<!-- {h['generated']} -->")
    out.append("")
    out.append(t(m["summary"], lang))
    out.append("")
    out.append(f"## {h['invocation']}")
    out.append("")
    out.append("```sh")
    out.append(m["invocation"])
    out.append("```")
    out.append("")
    out.append(f"## {h['guardrails']}")
    out.append("")
    for g in spec["guardrails"]:
        out.append(f"- {t(g, lang)}")
    out.append("")
    out.append(f"## {h['exit_codes']}")
    out.append("")
    out.append(f"| {h['code']} | {h['meaning']} |")
    out.append("|---|---|")
    for ec in spec["exit_codes"]:
        out.append(f"| {ec['code']} | {t(ec, lang)} |")
    out.append("")
    out.append(f"## {h['verbs']}")
    for verb in spec["verbs"]:
        out.append("")
        out.append(f"### `{verb['name']}`")
        out.append("")
        out.append(t(verb["summary"], lang))
        out.append("")
        if verb["options"]:
            out.append(f"| {h['flag']} | {h['description']} |")
            out.append("|---|---|")
            for o in verb["options"]:
                out.append(f"| `{o['flag']}` | {t(o, lang)} |")
            out.append("")
        for n in verb.get("notes", []):
            out.append(t(n, lang))
            out.append("")
    out.append(f"## {h['json']}")
    out.append("")
    out.append(t(spec["json_output"], lang))
    out.append("")
    out.append(t(m["logs"], lang))
    return "\n".join(out) + "\n"


def gen_txt(spec: dict, lang: str) -> str:
    h = HEADINGS[lang]
    m = spec["meta"]
    bar = "=" * 64
    out = [bar, h["title"], bar, ""]
    out.append(t(m["summary"], lang))
    out.append("")
    out.append(f"{h['invocation']}:")
    out.append(f"  {m['invocation']}")
    out.append("")
    out.append(f"{h['guardrails']}:")
    for g in spec["guardrails"]:
        out.append(f"  - {t(g, lang)}")
    out.append("")
    out.append(f"{h['exit_codes']}:")
    for ec in spec["exit_codes"]:
        out.append(f"  {ec['code']}  {t(ec, lang)}")
    out.append("")
    out.append(f"{h['verbs']}:")
    for verb in spec["verbs"]:
        out.append("")
        out.append(f"  {verb['name']}")
        out.append(f"    {t(verb['summary'], lang)}")
        for o in verb["options"]:
            out.append(f"      {o['flag']}")
            out.append(f"          {t(o, lang)}")
        for n in verb.get("notes", []):
            out.append(f"    {t(n, lang)}")
    out.append("")
    out.append(t(spec["json_output"], lang))
    out.append("")
    out.append(t(m["logs"], lang))
    out.append("")
    out.append(h["generated_txt"])
    return "\n".join(out) + "\n"


def generate_all(spec: dict) -> dict:
    return {
        "help_sh": gen_help_sh(spec),
        "md_en": gen_md(spec, "en"),
        "md_zh": gen_md(spec, "zh"),
        "txt_en": gen_txt(spec, "en"),
        "txt_zh": gen_txt(spec, "zh"),
    }


# --- live assertions --------------------------------------------------------------

def check_exit_codes(spec: dict):
    """The spec's exit-code table must match scripts/lib/common.sh exactly."""
    text = COMMON.read_text(encoding="utf-8")
    found = dict(
        (name, int(code))
        for name, code in re.findall(r"^(EXIT_[A-Z]+)=(\d+)", text, re.M)
    )
    spec_codes = {ec["name"]: ec["code"] for ec in spec["exit_codes"]}
    if found != spec_codes:
        fail(
            "exit-code drift between spec.yaml and scripts/lib/common.sh:\n"
            f"  common.sh: {sorted(found.items())}\n"
            f"  spec.yaml: {sorted(spec_codes.items())}"
        )


def check_verbs(spec: dict):
    """The spec's verb set must match gateway.sh's dispatch list."""
    text = GATEWAY.read_text(encoding="utf-8")
    m = re.search(r"^\s*(deploy\|[a-z|]+)\)\s*:\s*;;", text, re.M)
    if not m:
        fail("could not locate the verb dispatch list in gateway.sh")
    dispatch = set(m.group(1).split("|"))
    spec_verbs = {v["name"] for v in spec["verbs"]}
    if dispatch != spec_verbs:
        fail(
            "verb drift between spec.yaml and gateway.sh:\n"
            f"  gateway.sh: {sorted(dispatch)}\n"
            f"  spec.yaml:  {sorted(spec_verbs)}"
        )


def check_json_check_names(spec: dict):
    """Every _gw_check_add name in gateway.sh must be named in the spec's
    json_output notes, en AND zh - the --json check vocabulary is a frozen
    monitoring contract (#29), and these prose notes are its registry."""
    text = GATEWAY.read_text(encoding="utf-8")
    names = set(re.findall(r"_gw_check_add ([a-z_][a-z0-9_]*)", text))
    if not names:
        fail("could not locate any _gw_check_add call in gateway.sh")
    for lang in ("en", "zh"):
        note = t(spec["json_output"], lang)
        missing = sorted(
            n for n in names
            if not re.search(rf"(?<![a-z0-9_]){re.escape(n)}(?![a-z0-9_])", note)
        )
        if missing:
            fail(
                f"spec.yaml json_output ({lang}) does not name check(s): "
                f"{', '.join(missing)}\n"
                "  every _gw_check_add name is frozen --json vocabulary: an added\n"
                "  check must be named in scripts/cli/spec.yaml json_output (en AND\n"
                "  zh) in the same commit, then regenerate via --write if the note\n"
                "  text changed; a RENAME is a breaking monitoring-contract change\n"
                "  and needs explicit owner sign-off (issue #29)"
            )


def run_help(args, data_dir: Path) -> str:
    r = subprocess.run(
        ["sh", str(GATEWAY), *args],
        capture_output=True,
        text=True,
        env={
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "GATEWAY_DATA_DIR": str(data_dir),
        },
    )
    if r.returncode != 0:
        fail(f"gateway.sh {' '.join(args)} exited {r.returncode}: {r.stderr.strip()}")
    return r.stdout


def check_runtime_help(spec: dict):
    """`gateway.sh [--help | <verb> --help]` must serve the spec text verbatim."""
    with tempfile.TemporaryDirectory() as td:
        data = Path(td) / "data"
        got = run_help(["--help"], data)
        want = global_help_text(spec)
        if got != want:
            fail("gateway.sh --help differs from the spec-generated global help "
                 f"(run with --write and commit). First diff around byte {next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), min(len(got), len(want)))}")
        for verb in spec["verbs"]:
            got = run_help([verb["name"], "--help"], data)
            want = verb_help_text(spec, verb)
            if got != want:
                fail(f"gateway.sh {verb['name']} --help differs from the spec-generated help")


def main():
    write = "--write" in sys.argv[1:]
    spec = load_spec()
    check_exit_codes(spec)
    generated = generate_all(spec)

    if write:
        for key, path in ARTIFACTS.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(generated[key], encoding="utf-8")
            print(f"wrote {path.relative_to(REPO)}")
        return

    stale = []
    for key, path in ARTIFACTS.items():
        if not path.exists():
            stale.append(f"{path.relative_to(REPO)} (missing)")
        elif path.read_text(encoding="utf-8") != generated[key]:
            stale.append(f"{path.relative_to(REPO)} (differs)")
    if stale:
        fail(
            "generated CLI artifacts are stale (never hand-edit; run "
            "`python3 scripts/ci/cli_contract_check.py --write` and commit):\n  "
            + "\n  ".join(stale)
        )

    check_verbs(spec)
    check_json_check_names(spec)
    check_runtime_help(spec)
    print(
        "OK: CLI contract is fresh - spec.yaml matches common.sh exit codes, "
        "gateway.sh verbs, and the --json check-name vocabulary; "
        "help.sh/cli.md(en+zh)/CLI.txt(en+zh) regenerate byte-identical; "
        "runtime --help serves the spec text verbatim."
    )


if __name__ == "__main__":
    main()
