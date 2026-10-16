#!/usr/bin/env python3
"""Controls for categories_check.py (#97), in the privacy_check_test.py
idiom: a gate that only ever runs against the committed files proves nothing
about what it would REJECT. Each control damages a copy of the real files in
one way the gate exists to catch and asserts that the gate names it."""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

import categories_check as gate
import categories_regen as regen

FILES = ("coarse.json", "suffixes.json", "UPSTREAM-LICENSE")


class CategoriesGateTests(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.dir = Path(self._td.name)
        for name in FILES:
            shutil.copy(regen.OUT_DIR / name, self.dir / name)

    def tearDown(self):
        self._td.cleanup()

    def suffixes(self) -> dict:
        return json.loads((self.dir / "suffixes.json").read_text())

    def write_suffixes(self, doc: dict, *, redigest: bool = False) -> None:
        if redigest:
            doc["header"]["payload_sha256"] = regen.digest(doc["ids"])
        (self.dir / "suffixes.json").write_text(regen.render(doc))

    def assertRejected(self, needle: str):
        found = gate.problems(self.dir)
        self.assertTrue(any(needle in p for p in found),
                        f"expected a problem containing {needle!r}, got "
                        f"{found}")

    def test_the_committed_files_pass(self):
        self.assertEqual(gate.problems(self.dir), [])

    def test_a_hand_edited_entry_is_refused(self):
        doc = self.suffixes()
        app = next(iter(doc["ids"]))
        doc["ids"][app]["domain"] = sorted(
            [*doc["ids"][app]["domain"], "added-by-hand.example.com"])
        self.write_suffixes(doc)
        self.assertRejected("does not match its digest")

    def test_a_hand_reformatted_file_is_refused(self):
        doc = self.suffixes()
        (self.dir / "suffixes.json").write_text(json.dumps(doc))
        self.assertRejected("committed serialization")

    def test_an_oversize_map_is_refused(self):
        doc = self.suffixes()
        app = next(iter(doc["ids"]))
        doc["ids"][app]["full"] = sorted(
            doc["ids"][app]["full"]
            + [f"n{i}.oversize.example.com" for i in range(regen.MAX_RULES)])
        doc["header"]["rules"] += regen.MAX_RULES
        self.write_suffixes(doc, redigest=True)
        self.assertRejected("over the bound of")

    def test_an_uncurated_id_is_refused(self):
        doc = self.suffixes()
        doc["ids"]["not-curated"] = {"domain": ["x.example.com"], "full": []}
        doc["header"]["ids"] += 1
        doc["header"]["rules"] += 1
        self.write_suffixes(doc, redigest=True)
        self.assertRejected("differ from the curated table")

    def test_a_name_held_by_two_ids_is_refused(self):
        doc = self.suffixes()
        first, second = list(doc["ids"])[:2]
        stolen = doc["ids"][first]["domain"][0]
        doc["ids"][second]["domain"] = sorted(
            [*doc["ids"][second]["domain"], stolen])
        doc["header"]["rules"] += 1
        self.write_suffixes(doc, redigest=True)
        self.assertRejected("name held by both")

    def test_an_ip_literal_is_refused(self):
        doc = self.suffixes()
        app = next(iter(doc["ids"]))
        doc["ids"][app]["full"] = sorted(
            [*doc["ids"][app]["full"], "192.0.2.1"])
        doc["header"]["rules"] += 1
        self.write_suffixes(doc, redigest=True)
        self.assertRejected("is not a hostname")

    def test_a_stale_upstream_ref_is_refused(self):
        doc = self.suffixes()
        doc["header"]["upstream_ref"] = "0" * 40
        self.write_suffixes(doc)
        self.assertRejected("upstream_ref")

    def test_a_curated_table_change_without_regen_is_refused(self):
        original = dict(regen.CURATED)
        try:
            regen.CURATED["youtube"] = "music"
            self.assertRejected("curated_sha256")
            self.assertRejected("coarse.json differs")
        finally:
            regen.CURATED.clear()
            regen.CURATED.update(original)

    def test_a_hand_edited_coarse_file_is_refused(self):
        path = self.dir / "coarse.json"
        path.write_text(path.read_text().replace('"video"', '"films"', 1))
        self.assertRejected("coarse.json differs")

    def test_a_swapped_license_is_refused(self):
        (self.dir / "UPSTREAM-LICENSE").write_text("no licence\n")
        self.assertRejected("UPSTREAM-LICENSE")

    def test_a_sentinel_in_the_enum_is_refused(self):
        original = regen.COARSE
        try:
            regen.COARSE = (*original, "unknown")
            self.assertRejected("sentinel 'unknown'")
        finally:
            regen.COARSE = original

    def test_a_missing_file_is_unreadable_not_a_crash(self):
        (self.dir / "suffixes.json").unlink()
        self.assertRejected("unreadable")


class CompilerTests(unittest.TestCase):
    """The compile rules on a synthesised upstream tree (example.com names
    only): ownership through includes, the specificity rule, and drops."""

    def tree(self, lists: dict) -> regen.Source:
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        data = Path(td.name) / "data"
        data.mkdir()
        for name, body in lists.items():
            (data / name).write_text(body)
        return regen.Source(data)

    def test_a_curated_include_owns_its_own_rules(self):
        source = self.tree({
            "vendor": "vendor.example.com\ninclude:app\ninclude:part\n",
            "app": "app.example.com\nfull:exact.app.example.com\n",
            "part": "part.example.com\n"})
        ids, _ = regen.compile_ids(source, {"vendor": "platform",
                                            "app": "video"})
        self.assertEqual(ids["vendor"]["domain"],
                         ["part.example.com", "vendor.example.com"])
        self.assertEqual(ids["app"], {"domain": ["app.example.com"],
                                      "full": ["exact.app.example.com"]})

    def test_a_shared_name_goes_to_the_more_specific_list(self):
        source = self.tree({
            "vendor": "include:shared\nvendor.example.com\n",
            "product": "include:shared\n",
            "shared": "shared.example.com\n"})
        ids, dropped = regen.compile_ids(source, {"vendor": "platform",
                                                  "product": "ai"})
        self.assertEqual(ids["product"]["domain"], ["shared.example.com"])
        self.assertEqual(dropped["ambiguous"], 0)

    def test_a_name_two_unrelated_lists_share_is_dropped(self):
        source = self.tree({"one": "edge.example.com\none.example.com\n",
                            "two": "edge.example.com\ntwo.example.com\n"})
        ids, dropped = regen.compile_ids(source, {"one": "cdn", "two": "cdn"})
        self.assertNotIn("edge.example.com", ids["one"]["domain"])
        self.assertNotIn("edge.example.com", ids["two"]["domain"])
        self.assertEqual(dropped["ambiguous"], 1)

    def test_an_exact_name_never_overrides_a_more_specific_suffix(self):
        # the vendor lists the product's host exactly; the product's own
        # suffix must still win it
        source = self.tree({
            "vendor": "include:product\nfull:host.example.com\n"
                      "vendor.example.com\n",
            "product": "host.example.com\n"})
        ids, _ = regen.compile_ids(source, {"vendor": "platform",
                                            "product": "system"})
        self.assertEqual(ids["vendor"]["full"], [])
        self.assertEqual(ids["product"]["domain"], ["host.example.com"])

    def test_an_exact_name_of_the_more_specific_id_is_kept(self):
        source = self.tree({
            "vendor": "include:product\nhost.example.com\n",
            "product": "full:host.example.com\n"})
        ids, _ = regen.compile_ids(source, {"vendor": "platform",
                                            "product": "system"})
        self.assertEqual(ids["product"]["full"], ["host.example.com"])
        self.assertEqual(ids["vendor"]["domain"], ["host.example.com"])

    def test_keywords_regexps_and_addresses_never_classify(self):
        source = self.tree({"app": "keyword:example\nregexp:^a\\.example\n"
                                   "full:192.0.2.7\nok.example.com\n"})
        ids, dropped = regen.compile_ids(source, {"app": "video"})
        self.assertEqual(ids["app"], {"domain": ["ok.example.com"],
                                      "full": []})
        self.assertEqual((dropped["keyword"], dropped["regexp"],
                          dropped["not_a_hostname"]), (1, 1, 1))

    def test_an_attribute_filtered_include_takes_only_matching_rules(self):
        source = self.tree({
            "app": "include:mixed @ads\n",
            "mixed": "ads.example.com @ads\nplain.example.com\n"})
        ids, _ = regen.compile_ids(source, {"app": "ads"})
        self.assertEqual(ids["app"]["domain"], ["ads.example.com"])

    def tree_named(self, root: Path, name: str) -> Path:
        tree = root / name
        (tree / "data").mkdir(parents=True)
        (tree / "LICENSE").write_text("MIT\n")
        return tree

    def test_a_source_at_another_commit_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            for name in ("domain-list-community-0000000", "anything"):
                tree = self.tree_named(Path(td), name)
                with self.assertRaises(SystemExit):
                    regen._tree(tree, Path(td))

    def test_a_source_named_for_the_pinned_commit_is_accepted(self):
        short = regen.UPSTREAM_REF[:7]
        with tempfile.TemporaryDirectory() as td:
            for name in (f"v2fly-domain-list-community-{short}",
                         f"domain-list-community-{regen.UPSTREAM_REF}"):
                tree = self.tree_named(Path(td), name)
                self.assertEqual(regen._tree(tree / "data", Path(td)), tree)

    def test_a_curated_id_missing_upstream_fails_the_build(self):
        source = self.tree({"app": "app.example.com\n"})
        with self.assertRaises(SystemExit):
            regen.compile_ids(source, {"app": "video", "gone": "video"})


if __name__ == "__main__":
    unittest.main()
