#!/usr/bin/env python3
"""Focused policy tests for woodpecker_pin_check.py.

Mirrors privacy_check_test.py / ui_build_check_test.py: a gate that only ever
runs against the real pipeline proves nothing about what it would REJECT, and
this rule fails silently - a regex that stopped matching looks identical to a
pipeline that is fully pinned. So every control below is a throwaway pipeline
file the gate is pointed at, plus one positive control on the real tree.
"""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

import woodpecker_pin_check as gate

DIGEST = "sha256:" + "a" * 64
PINNED = f"python:3.12-slim@{DIGEST}"


def pipeline(*images: str | None, mapping: bool = False) -> str:
    """A minimal Woodpecker pipeline whose steps carry the given image refs.

    Refs are double-quoted so a fixture may start with `@` (YAML reserves a
    bare leading `@`); the real pipeline's unquoted refs are covered by the
    real-tree control. `None` yields a step with no image: line at all.
    `mapping=True` renders the name-keyed `steps:` form (what
    scripts/ci/package_check.py's fixture uses) instead of the list form the
    real pipeline uses - the gate must read both.
    """
    out = ["steps:"]
    for i, img in enumerate(images):
        name = f"step-{i}"
        if mapping:
            out.append(f"  {name}:")
            if img is not None:
                out.append(f'    image: "{img}"')
            out.append("    commands: [true]")
        else:
            out.append(f"  - name: {name}")
            if img is not None:
                out.append(f'    image: "{img}"')
            out.append("    commands: [true]")
    return "\n".join(out) + "\n"


class PinPolicyTests(unittest.TestCase):
    def run_gate(self, text: str) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / ".woodpecker.yml"
            path.write_text(text, encoding="utf-8")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = gate.check(path)
        return rc, buf.getvalue()

    # --- accepted ------------------------------------------------------

    def test_a_fully_pinned_pipeline_is_accepted(self) -> None:
        rc, out = self.run_gate(pipeline(PINNED, f"alpine:3.22@{DIGEST}"))
        self.assertEqual(rc, 0, out)
        self.assertTrue(out.startswith("OK:"), out)

    def test_a_step_without_an_image_is_ignored_not_a_crash(self) -> None:
        rc, out = self.run_gate(pipeline(PINNED, None))
        self.assertEqual(rc, 0, out)

    def test_the_mapping_form_is_read_too(self) -> None:
        rc, out = self.run_gate(pipeline(PINNED, mapping=True))
        self.assertEqual(rc, 0, out)

    # --- rejected ------------------------------------------------------

    def test_a_bare_tag_is_rejected_and_named(self) -> None:
        rc, out = self.run_gate(pipeline(PINNED, "python:3.12-slim"))
        self.assertEqual(rc, 1, out)
        self.assertIn("step step-1: python:3.12-slim", out)

    def test_a_bare_tag_in_the_mapping_form_is_rejected(self) -> None:
        rc, out = self.run_gate(pipeline("alpine", mapping=True))
        self.assertEqual(rc, 1, out)
        self.assertIn("step step-0: alpine", out)

    def test_a_malformed_digest_is_rejected(self) -> None:
        for bad in (
            "python:3.12-slim@sha256:" + "a" * 63,   # too short
            "python:3.12-slim@sha256:" + "a" * 65,   # too long
            "python:3.12-slim@sha256:" + "A" * 64,   # not lowercase hex
            "python:3.12-slim@sha256:" + "g" * 64,   # not hex
            "python:3.12-slim@sha1:" + "a" * 40,     # wrong algorithm
            "@" + DIGEST,                            # digest with no name
        ):
            rc, out = self.run_gate(pipeline(bad))
            self.assertEqual(rc, 1, f"{bad!r} slipped through: {out}")

    def test_a_tagless_digest_only_ref_is_rejected(self) -> None:
        """`alpine@sha256:...` is a valid pull ref, but the rule keeps the tag
        beside the digest so a reviewer can read what the digest is."""
        for bad in (f"alpine@{DIGEST}", f"mcr.microsoft.com/playwright@{DIGEST}",
                    f"localhost:5000/alpine@{DIGEST}"):   # a registry port is not a tag
            rc, out = self.run_gate(pipeline(bad))
            self.assertEqual(rc, 1, f"{bad!r} slipped through: {out}")
            self.assertIn("no tag", out)

    def test_one_tag_pinned_to_two_digests_is_rejected(self) -> None:
        """A partial bump - some lines rewritten, some not - must not pass."""
        other = "python:3.12-slim@sha256:" + "b" * 64
        rc, out = self.run_gate(pipeline(PINNED, other, PINNED))
        self.assertEqual(rc, 1, out)
        self.assertIn("python:3.12-slim", out)
        self.assertIn("2 different digests", out)

    def test_a_pipeline_with_no_images_at_all_is_rejected(self) -> None:
        """Zero refs means a mis-parsed file, not a clean one: never a vacuous OK."""
        for text in ("steps: []\n", "when:\n  event: push\n", pipeline(None, None)):
            rc, out = self.run_gate(text)
            self.assertEqual(rc, 1, f"{text!r} passed vacuously: {out}")
            self.assertIn("no step images", out)

    def test_every_offender_is_listed_not_just_the_first(self) -> None:
        rc, out = self.run_gate(pipeline("alpine:3.22", PINNED, "node:22-slim"))
        self.assertEqual(rc, 1, out)
        self.assertIn("step step-0: alpine:3.22", out)
        self.assertIn("step step-2: node:22-slim", out)
        self.assertNotIn("step step-1:", out)

    # --- the real tree ---------------------------------------------------

    def test_the_committed_pipeline_is_fully_pinned(self) -> None:
        """The positive control on the real file: the gate's reason to exist."""
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = gate.check(gate.PIPELINE)
        self.assertEqual(rc, 0, buf.getvalue())


if __name__ == "__main__":
    unittest.main()
