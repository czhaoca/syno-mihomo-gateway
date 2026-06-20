#!/usr/bin/env python3
"""Focused policy tests for privacy_check.py."""

from __future__ import annotations

import contextlib
import io
import unittest

import privacy_check as policy


class PrivacyPolicyTests(unittest.TestCase):
    def assert_rejected(self, text: str) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                policy.scan_text("fixture.txt", text)

    def test_secret_paths_fail_closed(self) -> None:
        for path in (
            ".env",
            ".env.prod",
            "CONFIG/SUBSCRIPTION.TXT.backup",
            "config/config.yaml.old",
            "LOGS/update.log",
        ):
            self.assertTrue(policy.is_secret_path(path), path)
        self.assertFalse(policy.is_secret_path(".env.example"))
        self.assertFalse(policy.is_secret_path("config/subscription.txt.example"))

    def test_private_key_variants_are_rejected(self) -> None:
        self.assert_rejected("-----BEGIN RSA " + "PRIVATE KEY-----")
        self.assert_rejected("-----BEGIN OPENSSH " + "PRIVATE KEY-----")

    def test_nonexample_credential_url_is_rejected(self) -> None:
        self.assert_rejected(
            "https://private.invalid/sub?" + "token=not-a-real-token"
        )

    def test_public_examples_remain_allowed(self) -> None:
        policy.scan_text(
            "fixture.txt",
            "git@github.com:public/project.git\n"
            "https://provider.example/sub?token=REPLACE_ME\n",
        )


if __name__ == "__main__":
    unittest.main()
