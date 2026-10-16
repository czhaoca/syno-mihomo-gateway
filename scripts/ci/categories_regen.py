#!/usr/bin/env python3
"""Regenerate the panel's category dictionary (#97, brief DEC-5): the data
files under app/store/categories/, all GENERATED, never hand-edited.

  coarse.json        the curated geosite id -> coarse category table below
                     and the bounded coarse enum (COARSE)
  suffixes.json      hostname suffixes and exact names per geosite id,
                     compiled from the pinned upstream geosite source
                     (UPSTREAM at UPSTREAM_REF) for exactly the CURATED ids
  UPSTREAM-LICENSE   the upstream licence, verbatim - the data is derived
                     from it and ships inside the panel image

Development time only. The panel never fetches a dictionary at runtime, and
CI never runs this script against the network: scripts/ci/categories_check.py
checks the committed files offline. Only this script can re-derive
suffixes.json byte for byte, because that needs the upstream tree.

Modes:
  bare            build in memory from the pinned upstream and byte-diff the
                  committed copies; exit non-zero on drift
  --write         rewrite them in place (the only sanctioned way to change
                  any of them)
  --source PATH   an extracted upstream tree (its root or its `data/`
                  directory) or a downloaded tarball, instead of fetching
                  UPSTREAM_REF over the network - refused unless it is that
                  commit (`verify_ref`), since the header stamps it

How suffixes.json is compiled - deterministic, and it never guesses:
  * a curated id OWNS the `domain:` (suffix) and `full:` (exact) rules of its
    own list, plus those it reaches through includes of lists that are not
    curated themselves (a curated include owns its own rules). `keyword:`
    and `regexp:` rules are skipped: they are not suffixes, and a substring
    match is where a dictionary starts guessing;
  * a rule two curated ids own goes to the more SPECIFIC one, the id whose
    whole upstream list is a strict subset of every other claimant's (a
    product list inside its vendor's). With no such id it is dropped, and
    the name falls through to a shorter suffix or stays unattributed (brief
    DEC-X-2: an edge two apps share is labelled by its vendor, never by a
    guessed app). The same rule settles a name one id lists exactly and
    another as a suffix, since the exact entry wins at lookup;
  * a name that is not a plain lowercase ASCII hostname, an IP literal, and
    anything scripts/ci/privacy_check.py refuses are dropped.
"""

import hashlib
import ipaddress
import json
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import privacy_check  # the refusal list the repo gate applies

OUT_DIR = REPO / "app" / "store" / "categories"
COARSE_FILE = OUT_DIR / "coarse.json"
SUFFIX_FILE = OUT_DIR / "suffixes.json"
LICENSE_FILE = OUT_DIR / "UPSTREAM-LICENSE"
REGEN_CMD = "python3 scripts/ci/categories_regen.py --write"

UPSTREAM = "v2fly/domain-list-community"
UPSTREAM_REF = "dd4e3c080cee602512768e8109f89fafaa94b8ca"
UPSTREAM_LICENSE = "MIT"
TARBALL_URL = f"https://codeload.github.com/{UPSTREAM}/tar.gz/{UPSTREAM_REF}"

# Bumped whenever the compile rules above change, so files the old rules
# produced cannot pass the offline check against the new ones.
COMPILER = 1

# DEC-C: a bounded top set, asserted by categories_check.py. Long-tail apps
# stay unattributed rather than growing the shipped file without limit.
MAX_IDS = 150
MAX_RULES = 15000
MAX_BYTES = 400 * 1024

# The coarse level (brief DEC-5, DEC-X-3): a bounded enum, stored long-term.
# `platform` is the honest answer for an umbrella vendor's shared services
# (accounts, APIs, static content) that no single product owns.
COARSE = ("video", "music", "social", "messaging", "gaming", "shopping",
          "news", "search", "ai", "developer", "cloud", "cdn", "storage",
          "productivity", "finance", "education", "travel", "ads", "system",
          "platform")

# The app level: geosite ids, mihomo's own vocabulary (so the id that labels
# a byte can name a rule unchanged), each with its coarse category.
CURATED = {
    # video
    "youtube": "video", "netflix": "video", "bilibili": "video",
    "iqiyi": "video", "youku": "video", "hunantv": "video", "douyu": "video",
    "huya": "video", "twitch": "video", "disney": "video", "hbo": "video",
    "primevideo": "video", "kuaishou": "video", "douyin": "video",
    "tiktok": "video",
    # music and audio
    "spotify": "music", "apple-music": "music", "kugou": "music",
    "kuwo": "music", "tencent-tme": "music", "soundcloud": "music",
    "tidal": "music", "ximalaya": "music",
    # social
    "facebook": "social", "instagram": "social", "twitter": "social",
    "threads": "social", "reddit": "social", "zhihu": "social",
    "douban": "social", "xiaohongshu": "social", "pinterest": "social",
    "linkedin": "social",
    # messaging
    "telegram": "messaging", "whatsapp": "messaging", "signal": "messaging",
    "line": "messaging", "discord": "messaging", "messenger": "messaging",
    "viber": "messaging", "kakao": "messaging",
    # gaming
    "steam": "gaming", "epicgames": "gaming", "playstation": "gaming",
    "xbox": "gaming", "nintendo": "gaming", "blizzard": "gaming",
    "riot": "gaming", "ea": "gaming", "ubisoft": "gaming", "mihoyo": "gaming",
    "hoyoverse": "gaming", "tencent-games": "gaming", "taptap": "gaming",
    # shopping and local services
    "amazon": "shopping", "jd": "shopping", "pinduoduo": "shopping",
    "ebay": "shopping", "shopee": "shopping", "meituan": "shopping",
    "eleme": "shopping", "dewu": "shopping",
    # news
    "bbc": "news", "cnn": "news", "nytimes": "news", "reuters": "news",
    "bloomberg": "news", "scmp": "news", "36kr": "news",
    # search
    "bing": "search", "baidu": "search", "duckduckgo": "search",
    "yandex": "search", "sogou": "search",
    # ai
    "openai": "ai", "anthropic": "ai", "google-gemini": "ai",
    "perplexity": "ai", "deepseek": "ai", "doubao": "ai",
    "huggingface": "ai", "github-copilot": "ai",
    # developer
    "github": "developer", "gitlab": "developer", "gitee": "developer",
    "stackexchange": "developer", "npmjs": "developer",
    "python": "developer", "golang": "developer", "csdn": "developer",
    # cloud
    "aws": "cloud", "azure": "cloud", "alibabacloud": "cloud",
    "qcloud": "cloud", "huaweicloud": "cloud", "volcengine": "cloud",
    # cdn
    "akamai": "cdn", "fastly": "cdn", "cloudflare": "cdn",
    "jsdelivr": "cdn", "wangsu": "cdn", "qiniu": "cdn",
    # storage
    "dropbox": "storage", "onedrive": "storage", "icloud": "storage",
    "aliyun-drive": "storage", "terabox": "storage",
    # productivity
    "notion": "productivity", "slack": "productivity", "zoom": "productivity",
    "lark": "productivity", "dingtalk": "productivity",
    "atlassian": "productivity", "figma": "productivity",
    "adobe": "productivity",
    # finance
    "paypal": "finance", "unionpay": "finance", "visa": "finance",
    "binance": "finance", "futu": "finance", "eastmoney": "finance",
    # education and reference
    "coursera": "education", "duolingo": "education",
    "chaoxing": "education", "cnki": "education", "wikimedia": "education",
    # travel and maps
    "ctrip": "travel", "booking": "travel", "airbnb": "travel",
    "didi": "travel", "amap": "travel",
    # ad and analytics SDKs
    "umeng": "ads", "getui": "ads", "jiguang": "ads", "taboola": "ads",
    # device and OS services
    "apple-update": "system", "connectivity-check": "system",
    "xiaomi": "system", "huawei": "system", "samsung": "system",
    "letsencrypt": "system",
    # umbrella vendors (DEC-X-2: their shared edges are vendor-level)
    "google": "platform", "apple": "platform", "microsoft": "platform",
    "alibaba": "platform", "tencent": "platform", "bytedance": "platform",
    "netease": "platform", "meta": "platform", "sina": "platform",
}

KINDS = ("domain", "full")
_LABEL = r"[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?"
HOSTNAME_RE = re.compile(rf"^(?=.{{1,253}}$){_LABEL}(?:\.{_LABEL})*$")


def is_hostname(name: str) -> bool:
    """A plain lowercase ASCII DNS name that is not an IP literal."""
    if not HOSTNAME_RE.match(name):
        return False
    try:
        ipaddress.ip_address(name)
    except ValueError:
        return True
    return False


def digest(obj) -> str:
    """sha256 of OBJ's compact canonical JSON."""
    return hashlib.sha256(json.dumps(
        obj, sort_keys=True, separators=(",", ":"),
        ensure_ascii=True).encode()).hexdigest()


def curated_digest() -> str:
    """What the committed files were generated FROM: the curated table, the
    enum and the version of the compile rules."""
    return digest({"coarse": list(COARSE), "curated": CURATED,
                   "compiler": COMPILER})


def render(doc: dict) -> str:
    """The one serialization the JSON files are committed in."""
    return json.dumps(doc, indent=1, sort_keys=True, ensure_ascii=True) + "\n"


def render_coarse() -> str:
    return render({
        "header": {"generated_by": "scripts/ci/categories_regen.py",
                   "regen": REGEN_CMD, "never_hand_edit": True,
                   "curated_sha256": curated_digest()},
        "coarse": list(COARSE),
        "ids": dict(sorted(CURATED.items())),
    })


def render_suffixes(ids: dict, dropped: dict, license_text: str) -> str:
    rules = sum(len(v) for entry in ids.values() for v in entry.values())
    return render({
        "header": {"generated_by": "scripts/ci/categories_regen.py",
                   "regen": REGEN_CMD, "never_hand_edit": True,
                   "upstream": UPSTREAM, "upstream_ref": UPSTREAM_REF,
                   "upstream_license": UPSTREAM_LICENSE,
                   "upstream_license_sha256": hashlib.sha256(
                       license_text.encode()).hexdigest(),
                   "curated_sha256": curated_digest(),
                   "payload_sha256": digest(ids),
                   "ids": len(ids), "rules": rules, "dropped": dropped},
        "ids": ids,
    })


# --- the upstream source -----------------------------------------------------

class Source:
    """The upstream `data/` directory: one list per file, parsed on demand."""

    def __init__(self, data: Path):
        self.data = data
        self._lists: dict = {}

    def parse(self, name: str):
        """(rules, includes) of one list, or None when it does not exist.
        rules: (kind, value, attrs); includes: (name, must, must_not)."""
        if name in self._lists:
            return self._lists[name]
        path = self.data / name
        if not path.is_file():
            self._lists[name] = None
            return None
        rules, includes = [], []
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            head, *rest = line.split()
            attrs = frozenset(t[1:] for t in rest if t.startswith("@"))
            if head.startswith("include:"):
                includes.append((
                    head.removeprefix("include:"),
                    frozenset(a for a in attrs if not a.startswith("-")),
                    frozenset(a[1:] for a in attrs if a.startswith("-"))))
                continue
            kind, _, value = head.rpartition(":")
            rules.append((kind or "domain", value.lower(), attrs))
        self._lists[name] = (rules, includes)
        return self._lists[name]

    def walk(self, root: str, stop: frozenset = frozenset()) -> list:
        """Every (kind, value) ROOT reaches, following includes (with their
        attribute filters) except into a list in STOP."""
        out, seen = [], set()

        def visit(name, must, must_not):
            if (name, must, must_not) in seen:
                return
            seen.add((name, must, must_not))
            parsed = self.parse(name)
            if parsed is None:
                raise SystemExit(f"FAIL: {name!r} (reached from {root!r}) "
                                 f"is not an upstream list")
            rules, includes = parsed
            for kind, value, attrs in rules:
                if must <= attrs and not must_not & attrs:
                    out.append((kind, value))
            for target, t_must, t_not in includes:
                if target not in stop:
                    visit(target, must | t_must, must_not | t_not)

        visit(root, frozenset(), frozenset())
        return out


def compile_ids(source: Source, curated: dict | None = None) -> tuple:
    """({geosite id: {"domain": [...], "full": [...]}}, dropped counts) for
    the CURATED ids (default: the table above)."""
    curated = CURATED if curated is None else curated
    missing = sorted(i for i in curated if source.parse(i) is None)
    if missing:
        raise SystemExit(f"FAIL: curated ids missing upstream: {missing}")
    names = frozenset(curated)
    dropped = {"ambiguous": 0, "keyword": 0, "not_a_hostname": 0,
               "privacy": 0, "regexp": 0}
    claims: dict = {}
    for cid in sorted(names):
        for kind, value in source.walk(cid, stop=names - {cid}):
            if kind in KINDS:
                claims.setdefault((kind, value), set()).add(cid)
            else:
                dropped[kind] = dropped.get(kind, 0) + 1
    whole = {cid: frozenset(r for r in source.walk(cid) if r[0] in KINDS)
             for cid in names}

    def most_specific(owners):
        specific = [c for c in owners
                    if all(whole[c] < whole[o] for o in owners - {c})]
        return specific[0] if len(specific) == 1 else None

    owned: dict = {}
    for (kind, value), owners in sorted(claims.items()):
        if not is_hostname(value):
            dropped["not_a_hostname"] += 1
            continue
        if (privacy_check.PRIVATE_SITE in value
                or privacy_check.PRIVATE_SITE_RE.search(value)):
            dropped["privacy"] += 1
            continue
        owner = most_specific(owners) if len(owners) > 1 else next(iter(owners))
        if owner is None:
            dropped["ambiguous"] += 1
            continue
        owned[(kind, value)] = owner
    # A `full` entry beats a `domain` entry for its exact name at lookup, so
    # when two ids hold the same name in the two kinds the exact entry must
    # not override a MORE specific id's suffix: it is dropped then (and, with
    # neither id more specific, counted ambiguous - the suffix stands).
    for (kind, value), owner in list(owned.items()):
        other = owned.get(("domain", value)) if kind == "full" else None
        if other is None or other == owner:
            continue
        winner = most_specific({owner, other})
        if winner != owner:
            if winner is None:
                dropped["ambiguous"] += 1
            del owned[(kind, value)]
    ids = {cid: {kind: [] for kind in KINDS} for cid in sorted(names)}
    for (kind, value), owner in sorted(owned.items()):
        ids[owner][kind].append(value)
    return ids, dict(sorted(dropped.items()))


def _tree(path: Path, scratch: Path) -> Path:
    """The upstream tree's root for PATH (a tarball, the root, or data/)."""
    if path.is_file():
        with tarfile.open(path) as tar:
            tar.extractall(scratch, filter="data")
        tops = [p for p in scratch.iterdir() if p.is_dir()]
        if len(tops) != 1:
            raise SystemExit(f"FAIL: unexpected tarball layout in {path}")
        path = tops[0]
    if path.name == "data" and not (path / "data").is_dir():
        path = path.parent
    if not (path / "data").is_dir() or not (path / "LICENSE").is_file():
        raise SystemExit(f"FAIL: no upstream data/ and LICENSE at {path}")
    verify_ref(path)
    return path


def verify_ref(tree: Path) -> None:
    """Refuse a source that is not UPSTREAM_REF: the header stamps that ref,
    and the offline check trusts the stamp. A GitHub archive's top directory
    carries the commit (`<repo>-<sha>` from codeload, `<owner>-<repo>-<sha7>`
    from the API); a git checkout is asked for its HEAD."""
    short = UPSTREAM_REF[:7]
    if tree.name.endswith((f"-{short}", f"-{UPSTREAM_REF}")):
        return
    if (tree / ".git").exists():
        head = subprocess.run(["git", "-C", str(tree), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=False)
        if head.stdout.strip() == UPSTREAM_REF:
            return
    raise SystemExit(f"FAIL: {tree} is not {UPSTREAM} at {short} - pass "
                     f"that commit's tarball, or a checkout of it")


def build(source_path: Path | None = None) -> dict:
    """{path: text} for every generated file."""
    with tempfile.TemporaryDirectory() as td:
        scratch = Path(td)
        if source_path is None:
            source_path = scratch / "upstream.tar.gz"
            print(f"fetching {TARBALL_URL}", file=sys.stderr)
            with urllib.request.urlopen(TARBALL_URL, timeout=120) as resp:
                source_path.write_bytes(resp.read())
        extract = scratch / "tree"
        extract.mkdir()
        tree = _tree(source_path, extract)
        license_text = (tree / "LICENSE").read_text(encoding="utf-8")
        ids, dropped = compile_ids(Source(tree / "data"))
    return {COARSE_FILE: render_coarse(),
            SUFFIX_FILE: render_suffixes(ids, dropped, license_text),
            LICENSE_FILE: license_text}


def main(argv: list[str]) -> int:
    source = None
    if "--source" in argv:
        at = argv.index("--source")
        if at + 1 >= len(argv):
            print("FAIL: --source needs a path", file=sys.stderr)
            return 2
        source = Path(argv[at + 1])
    files = build(source)
    if "--write" in argv:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        for path, text in files.items():
            path.write_text(text, encoding="utf-8")
            print(f"wrote {path.relative_to(REPO)}")
        return 0
    stale = [str(p.relative_to(REPO)) for p, text in files.items()
             if not p.is_file() or p.read_text(encoding="utf-8") != text]
    if stale:
        print(f"FAIL: stale {', '.join(stale)} - run {REGEN_CMD}",
              file=sys.stderr)
        return 1
    print("categories: in sync with the pinned upstream")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
