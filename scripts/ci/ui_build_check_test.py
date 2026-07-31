#!/usr/bin/env python3
"""Focused policy tests for ui_build_check.py.

Mirrors privacy_check_test.py: a gate that only ever runs against the real
tree proves nothing about what it would REJECT. Both controls matter here
because both of this gate's rules are the kind that fail silently - a
marker check that never fails looks identical to one whose subject moved,
and an allowlist that never rejects looks identical to the ban switched
off.

Note the URL controls inject into the BUILT artifact rather than into
source. Injecting a URL into an unused source module proves nothing:
rollup tree-shakes it and it never reaches the bundle - which is exactly
how the first version of this control passed while testing nothing.
"""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

import ui_build_check as gate

MARKER_SHELL = (
    '<!doctype html><html><head>'
    '<title data-i18n="app_title">Gateway Panel</title>'
    "</head><body><div id=\"root\"></div></body></html>"
)


class UiBuildPolicyTests(unittest.TestCase):
    @contextlib.contextmanager
    def dist(self, index_html: str, asset: str = ""):
        """A throwaway dist/ that the gate is pointed at."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "dist"
            (root / "assets").mkdir(parents=True)
            (root / "index.html").write_text(index_html, encoding="utf-8")
            if asset:
                (root / "assets" / "index-test.js").write_text(
                    asset, encoding="utf-8")
            original = gate.DIST
            gate.DIST = root
            try:
                yield
            finally:
                gate.DIST = original

    def assert_rejected(self, fn) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                fn()

    # --- the A6 marker -------------------------------------------------

    def test_a_shell_carrying_the_marker_is_accepted(self) -> None:
        with self.dist(MARKER_SHELL):
            gate.check_marker()  # must not raise

    def test_a_shell_without_the_marker_is_rejected(self) -> None:
        with self.dist(MARKER_SHELL.replace(' data-i18n="app_title"', "")):
            self.assert_rejected(gate.check_marker)

    def test_a_marker_only_inside_a_comment_is_rejected(self) -> None:
        """A minifier setting would drop it, and the A6 release gate greps
        raw HTML with no JavaScript running - so the marker has to ride a
        real attribute, not prose about one."""
        commented = (
            '<!doctype html><html><head><!-- data-i18n="app_title" -->'
            "<title>Gateway Panel</title></head><body></body></html>"
        )
        with self.dist(commented):
            self.assert_rejected(gate.check_marker)

    def test_a_missing_build_is_rejected_rather_than_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            original = gate.DIST
            gate.DIST = Path(td) / "absent"
            try:
                self.assert_rejected(gate.check_marker)
            finally:
                gate.DIST = original

    # --- the external-URL allowlist ------------------------------------

    def test_an_allowlisted_url_is_accepted(self) -> None:
        for allowed in sorted(gate.ALLOWED_URL_PREFIXES):
            with self.dist(MARKER_SHELL, asset=f'var a="{allowed}x";'):
                gate.check_urls()  # must not raise

    def test_a_non_allowlisted_url_is_rejected(self) -> None:
        with self.dist(MARKER_SHELL,
                       asset='var b="https://evil.example.com/beacon";'):
            self.assert_rejected(gate.check_urls)

    def test_a_non_allowlisted_url_in_the_shell_is_rejected(self) -> None:
        """Not only in the JS chunk: the shell is served too."""
        leaky = MARKER_SHELL.replace(
            "<body>", '<body><img src="https://evil.example.com/pixel">')
        with self.dist(leaky):
            self.assert_rejected(gate.check_urls)

    def test_a_lookalike_prefix_does_not_slip_through(self) -> None:
        """`startswith` is the matcher, so a host that merely BEGINS like an
        allowlisted one must still be refused - otherwise the allowlist is
        a substring amnesty."""
        with self.dist(MARKER_SHELL,
                       asset='var c="https://react.dev.evil.example.com/x";'):
            self.assert_rejected(gate.check_urls)

    def test_every_allowlist_entry_states_a_reason(self) -> None:
        """An allowlist nobody can justify is the ban switched off."""
        for prefix, reason in gate.ALLOWED_URL_PREFIXES.items():
            self.assertTrue(reason.strip(), f"{prefix} has no stated reason")


if __name__ == "__main__":
    unittest.main()
