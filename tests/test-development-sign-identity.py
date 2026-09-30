#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "development_sign_identity",
    Path(__file__).resolve().parents[1] / "macos/development-sign-identity.py",
)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class DevelopmentSigningTests(unittest.TestCase):
    def resolve(self, output):
        with patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], 0, stdout=output,
        )):
            return signing.resolve("auto")

    def test_prefers_development_certificate_over_distribution(self):
        self.assertEqual(self.resolve(
            f'  1) {"A" * 40} "Developer ID Application: Release (TEAM)"\n'
            f'  2) {"B" * 40} "Apple Development: Developer (TEAM)"\n'
        ), "B" * 40)

    def test_distribution_certificate_can_sign_isolated_development_build(self):
        self.assertEqual(self.resolve(
            f'  1) {"A" * 40} "Developer ID Application: Release (TEAM)"\n'
        ), "A" * 40)

    def test_ambiguous_selection_requires_explicit_identity(self):
        with self.assertRaisesRegex(ValueError, "DEVELOPMENT_SIGN_IDENTITY"):
            self.resolve(
                f'  1) {"A" * 40} "Apple Development: One (TEAM)"\n'
                f'  2) {"B" * 40} "Apple Development: Two (TEAM)"\n'
            )

    def test_no_certificate_cannot_silently_invalidate_existing_grants(self):
        with self.assertRaisesRegex(ValueError, "DEVELOPMENT_SIGN_IDENTITY=-"):
            self.resolve('     0 valid identities found\n')

    def test_explicit_identity_and_ad_hoc_do_not_query_keychain(self):
        with patch.object(signing.subprocess, "run") as query:
            for identity in ("-", "Apple Development: Chosen (TEAM)", "C" * 40):
                self.assertEqual(signing.resolve(identity), identity)
            query.assert_not_called()

    def test_keychain_failure_does_not_silently_replace_signing_identity(self):
        with patch.object(signing.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "security")):
            with self.assertRaises(subprocess.CalledProcessError):
                signing.resolve("auto")


if __name__ == "__main__":
    unittest.main()
