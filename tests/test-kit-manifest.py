#!/usr/bin/env python3
"""Check the kit manifest build-kit.sh writes and release.py verifies."""

from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / "scripts"))

import kit_manifest  # noqa: E402


class KitManifestTests(unittest.TestCase):
    def test_only_an_exact_release_tag_is_a_release_version(self) -> None:
        self.assertEqual(kit_manifest.kit_version("v1.2.3"), "v1.2.3")
        self.assertEqual(kit_manifest.kit_version("v0.10.0"), "v0.10.0")
        for describe in (None, "", "v1.2.3-dirty", "v1.2.3-4-gabcdef0", "1.2.3", "v01.2.3", "abcdef0"):
            self.assertEqual(kit_manifest.kit_version(describe), "development", describe)

    def test_protocol_version_comes_from_the_client_library(self) -> None:
        source = (REPOSITORY / kit_manifest.PROTOCOL_SOURCE).read_text()
        expected = int(re.search(r"public static let version = ([0-9]+)", source).group(1))
        self.assertEqual(kit_manifest.run_protocol_version(REPOSITORY), expected)

    def test_writes_the_app_version_protocol_and_date(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            app = work / "Try Omarchy.app"
            (app / "Contents").mkdir(parents=True)
            output = work / "kit.json"
            built = datetime(2026, 10, 23, 9, 30, 5, tzinfo=timezone.utc)
            for describe, version in (("v1.2.3", "v1.2.3"), ("v1.2.3-2-gabcdef0", "development"), (None, "development")):
                info = {} if describe is None else {"TryOmarchyBuildDescribe": describe}
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                kit_manifest.write(REPOSITORY, app, output, built)
                self.assertEqual(kit_manifest.read(output), {
                    "format": 1, "version": version,
                    "runProtocolVersion": kit_manifest.run_protocol_version(REPOSITORY),
                    "buildDate": "2026-10-23T09:30:05Z",
                    "capabilities": ["native-exports"],
                })

    def test_rejects_invalid_manifests(self) -> None:
        valid = {"format": 1, "version": "v1.2.3", "runProtocolVersion": 1, "buildDate": "2026-10-23T09:30:05Z"}
        self.assertEqual(kit_manifest.validate(dict(valid, extra=True)), dict(valid, extra=True))
        self.assertEqual(kit_manifest.validate(dict(valid, capabilities=["native-exports", "later"]))["capabilities"],
                         ["native-exports", "later"])
        for change in ({"format": 2}, {"format": True}, {"version": "1.2.3"}, {"version": "v1.2"},
                       {"version": "dev"}, {"runProtocolVersion": 0}, {"runProtocolVersion": "1"},
                       {"runProtocolVersion": True}, {"buildDate": "2026-10-23"}, {"buildDate": 0},
                       {"capabilities": "native-exports"}, {"capabilities": ["native-exports", "native-exports"]},
                       {"capabilities": ["Native Exports"]}, {"capabilities": [1]}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                kit_manifest.validate(dict(valid, **change))
        for value in ([], "v1.2.3", None):
            with self.assertRaises(ValueError):
                kit_manifest.validate(value)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "kit.json"
            path.write_text("{")
            with self.assertRaises(ValueError):
                kit_manifest.read(path)
            path.write_text(json.dumps(valid))
            self.assertEqual(kit_manifest.read(path), valid)

    def test_checks_a_built_kit_against_this_checkout(self) -> None:
        protocol = kit_manifest.run_protocol_version(REPOSITORY)
        valid = {"format": 1, "version": "development", "runProtocolVersion": protocol,
                 "buildDate": "2026-10-23T09:30:05Z"}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "kit.json"
            path.write_text(json.dumps(valid))
            self.assertEqual(kit_manifest.check(REPOSITORY, path), valid)
            path.write_text(json.dumps(dict(valid, runProtocolVersion=protocol + 1)))
            with self.assertRaises(ValueError):
                kit_manifest.check(REPOSITORY, path)


if __name__ == "__main__":
    unittest.main()
