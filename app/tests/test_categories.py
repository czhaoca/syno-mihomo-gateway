"""The category dictionary (#97, brief DEC-5): hostname -> geosite id (app
level) -> coarse category.

Behaviour is tested on a synthesised dictionary (example.* names only); the
shipped data files are tested for what must hold of ANY dictionary -
loadable, total, offline - by round-tripping their own entries, so no real
hostname appears here.
"""

import json
import socket
from pathlib import Path

import pytest
from app.store import categories
from app.store.categories import Dictionary, DictionaryError
from app.tests.conftest import example_dictionary

# --- lookup ---------------------------------------------------------------------


@pytest.mark.parametrize("host, hit", [
    ("video.example.com", ("example-video", "video")),
    ("a.b.video.example.com", ("example-video", "video")),
    ("clip.example.net", ("example-video", "video")),
    # a `full` entry is that exact name only
    ("sub.clip.example.net", None),
    ("cdn.example.org", ("example-cdn", "cdn")),
    # the vendor's own suffix: everything of example.com no app claims
    # (DEC-X-2 - a shared edge is labelled by its vendor, never a guess)
    ("edge.example.com", ("example-vendor", "platform")),
    ("example.com", ("example-vendor", "platform")),
    ("VIDEO.Example.COM.", ("example-video", "video")),
    ("example.org", None),
    ("notexample.com", None),
    ("", None),
    ("192.0.2.10", None),
    ("2001:db8::1", None),
    ("[2001:db8::1]", None),
])
def test_a_hostname_resolves_to_its_most_specific_entry(host, hit):
    assert example_dictionary().classify(host) == hit


def test_lookups_are_remembered_but_bounded(monkeypatch):
    monkeypatch.setattr(categories, "MEMO_MAX", 4)
    d = example_dictionary()
    for i in range(10):
        d.classify(f"h{i}.example.org")
    assert len(d._memo) <= 4
    assert d.classify("video.example.com") == ("example-video", "video")


def test_an_app_outside_the_coarse_enum_is_refused():
    with pytest.raises(DictionaryError, match="outside the enum"):
        Dictionary(("video",), {"a": "music"}, {"a": {"domain": ["x.example.com"]}})


def test_a_name_without_a_coarse_category_is_refused():
    with pytest.raises(DictionaryError, match="no coarse category"):
        Dictionary(("video",), {}, {"a": {"domain": ["x.example.com"]}})


def test_a_name_two_apps_claim_is_refused():
    with pytest.raises(DictionaryError, match="two ids"):
        Dictionary(("video",), {"a": "video", "b": "video"},
                   {"a": {"domain": ["x.example.com"]},
                    "b": {"domain": ["x.example.com"]}})


# --- the shipped files ----------------------------------------------------------

def test_the_shipped_dictionary_loads_and_is_total():
    d = categories.load()
    assert len(d.apps) <= 150
    assert set(d.apps.values()) <= set(d.coarse)
    assert "" not in d.coarse and "unknown" not in d.coarse
    assert d.version


def test_every_shipped_entry_classifies_to_its_own_id():
    """The round trip over the real data: each id's own entries resolve to
    it. The one exception is by design: a name a MORE specific id lists
    exactly (the generator keeps such an exact entry only then) resolves to
    that id, while its suffix still holds the subdomains."""
    doc = json.loads((categories.DATA_DIR / "suffixes.json").read_text())
    exact = {name: app for app, kinds in doc["ids"].items()
             for name in kinds["full"]}
    d = categories.load()
    for app, kinds in doc["ids"].items():
        for name in kinds["full"]:
            assert d.classify(name)[0] == app, (app, "full")
        for name in kinds["domain"]:
            assert d.classify(name)[0] == exact.get(name, app), (app, "domain")


def test_loading_and_classifying_open_no_socket(monkeypatch):
    def refuse(*_a, **_k):
        raise AssertionError("the dictionary opened a socket")
    monkeypatch.setattr(socket, "socket", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)
    monkeypatch.setattr(socket, "getaddrinfo", refuse)
    d = categories.load()
    for name in ("unlisted.example.com", "192.0.2.1", "media.example.net"):
        d.classify(name)


def test_files_from_different_tables_are_refused(tmp_path):
    for name in ("coarse.json", "suffixes.json"):
        (tmp_path / name).write_text(
            (categories.DATA_DIR / name).read_text())
    doc = json.loads((tmp_path / "coarse.json").read_text())
    doc["header"]["curated_sha256"] = "0" * 64
    (tmp_path / "coarse.json").write_text(json.dumps(doc))
    with pytest.raises(DictionaryError, match="different tables"):
        categories.load(tmp_path)


def test_a_missing_file_is_a_dictionary_error(tmp_path):
    with pytest.raises(DictionaryError, match="unreadable"):
        categories.load(Path(tmp_path))


@pytest.mark.parametrize("payload", [b"\xff\xfe{}", b"{not json", b"[]"])
def test_a_damaged_file_is_a_dictionary_error_never_a_crash(tmp_path, payload):
    # whatever the damage, it must reach active() as a DictionaryError -
    # anything else would escape it and stop every poll, not only categories
    (tmp_path / "coarse.json").write_text(
        (categories.DATA_DIR / "coarse.json").read_text())
    (tmp_path / "suffixes.json").write_bytes(payload)
    with pytest.raises(DictionaryError, match="unreadable"):
        categories.load(tmp_path)


def test_an_unloadable_dictionary_leaves_the_collector_running(monkeypatch):
    def broken(directory=categories.DATA_DIR):
        raise DictionaryError("category dictionary unreadable: test")
    monkeypatch.setattr(categories, "load", broken)
    monkeypatch.setattr(categories, "_ACTIVE", {})
    assert categories.active() is None
    assert "unreadable" in categories.load_error()


def test_the_active_dictionary_is_loaded_once(monkeypatch):
    calls = []
    real = categories.load

    def counting(directory=categories.DATA_DIR):
        calls.append(1)
        return real(directory)
    monkeypatch.setattr(categories, "load", counting)
    monkeypatch.setattr(categories, "_ACTIVE", {})
    first = categories.active()
    assert isinstance(first, Dictionary)
    assert categories.active() is first
    assert categories.load_error() is None
    assert len(calls) == 1
