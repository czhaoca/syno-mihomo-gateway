"""The category dictionary (#97, brief DEC-5): a hostname resolves to a
geosite id (the APP level), which maps to one of a bounded set of coarse
categories (the COARSE level).

Only a hostname classifies a flow (panel-ui-v2 DEC-C). A routing rule or a
GeoIP match never does: those name a routing decision, not an application.
The data files beside this module are generated at development time by
scripts/ci/categories_regen.py and checked offline by
scripts/ci/categories_check.py. Nothing here touches the network.
"""

import ipaddress
import json
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent
KINDS = ("domain", "full")
# lookups remembered per dictionary; cleared whole when full
MEMO_MAX = 8192
_MISS = object()


class DictionaryError(ValueError):
    """The data files are missing, malformed or disagree with each other."""


def normalise(host: str) -> str:
    """HOST lowercased without a trailing dot, or "" when it is not a
    hostname (empty, or an IP literal - an address names no application)."""
    name = str(host or "").strip().lower().rstrip(".")
    if not name:
        return ""
    try:
        ipaddress.ip_address(name.strip("[]"))
    except ValueError:
        return name
    return ""


class Dictionary:
    """One loaded dictionary.

    COARSE is the enum, APPS maps each geosite id to its coarse id, and
    SUFFIXES gives each id its `domain` (the name and every subdomain) and
    `full` (exactly that name) entries. A name another id already holds is
    refused: the generator gives every name to exactly one id."""

    def __init__(self, coarse, apps: dict, suffixes: dict,
                 version: str = ""):
        self.coarse = tuple(coarse)
        self.apps = dict(apps)
        self.version = version
        bad = sorted(c for c in self.apps.values() if c not in self.coarse)
        if bad:
            raise DictionaryError(f"coarse ids outside the enum: {bad}")
        self._names = {kind: {} for kind in KINDS}
        for app, kinds in suffixes.items():
            if app not in self.apps:
                raise DictionaryError(f"{app!r} has no coarse category")
            for kind in KINDS:
                table = self._names[kind]
                for name in kinds.get(kind, ()):
                    if table.setdefault(name, app) != app:
                        raise DictionaryError(
                            f"{kind} {name!r} belongs to two ids")
        self._memo: dict = {}

    def _lookup(self, name: str):
        app = self._names["full"].get(name)
        if app is None:
            labels = name.split(".")
            domain = self._names["domain"]
            # longest suffix first: the most specific entry wins
            for i in range(len(labels)):
                app = domain.get(".".join(labels[i:]))
                if app is not None:
                    break
        return (app, self.apps[app]) if app is not None else None

    def classify(self, host: str):
        """(app id, coarse id) for HOST, or None when the dictionary has no
        answer - no hostname, or one it does not know."""
        name = normalise(host)
        if not name:
            return None
        hit = self._memo.get(name, _MISS)
        if hit is _MISS:
            hit = self._lookup(name)
            if len(self._memo) >= MEMO_MAX:
                self._memo.clear()
            self._memo[name] = hit
        return hit


def load(directory: Path = DATA_DIR) -> Dictionary:
    """The dictionary in DIRECTORY's coarse.json and suffixes.json."""
    try:
        coarse = json.loads((Path(directory) / "coarse.json")
                            .read_text(encoding="utf-8"))
        suffixes = json.loads((Path(directory) / "suffixes.json")
                              .read_text(encoding="utf-8"))
        made_from = coarse["header"]["curated_sha256"]
        header = suffixes["header"]
        if header["curated_sha256"] != made_from:
            raise DictionaryError("coarse.json and suffixes.json were "
                                  "generated from different tables")
        version = f"{header['upstream_ref'][:12]}-{made_from[:8]}"
        return Dictionary(coarse["coarse"], coarse["ids"], suffixes["ids"],
                          version)
    except (OSError, KeyError, TypeError, AttributeError, ValueError) as exc:
        # ValueError covers a malformed document (JSONDecodeError) and an
        # undecodable one (UnicodeDecodeError) alike
        raise DictionaryError(f"category dictionary unreadable: "
                              f"{exc.__class__.__name__}: {exc}") from exc


_ACTIVE: dict = {}


def active():
    """The shipped dictionary, loaded once; None when it cannot be loaded.

    A broken data file must not stop the collector: its bytes are then
    counted as classified by no dictionary at all, which is the truth, and
    `load_error()` says why."""
    if "dictionary" not in _ACTIVE:
        try:
            _ACTIVE["dictionary"] = load()
            _ACTIVE["error"] = None
        except DictionaryError as exc:
            _ACTIVE["dictionary"] = None
            _ACTIVE["error"] = str(exc)
    return _ACTIVE["dictionary"]


def load_error():
    """Why `active()` has no dictionary, or None."""
    active()
    return _ACTIVE["error"]
