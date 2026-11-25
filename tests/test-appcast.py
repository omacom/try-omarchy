#!/usr/bin/env python3
"""Write and verify appcasts with a throwaway Ed25519 key and real signatures."""

from __future__ import annotations

import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from xml.etree import ElementTree


REPOSITORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / "scripts"))
import appcast  # noqa: E402
import release  # noqa: E402


class AppcastTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tools = tempfile.TemporaryDirectory(prefix="appcast-test-")
        cls.addClassCleanup(cls.tools.cleanup)
        cls.key_tool = Path(cls.tools.name) / "update-key"
        subprocess.run(["xcrun", "swiftc", str(REPOSITORY / "tests/app-updates/update-key.swift"),
                        "-o", str(cls.key_tool)], check=True)
        cls.seed, cls.public_key = cls.generate()

    @classmethod
    def generate(cls) -> list[str]:
        return subprocess.check_output([str(cls.key_tool), "generate"], text=True).split()

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="appcast-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Try Omarchy.app"
        (self.app / "Contents").mkdir(parents=True)
        self.dmg = self.root / "TryOmarchy.dmg"
        self.dmg.write_bytes(b"dmg" * 1000)
        self.feed = self.root / "appcast.xml"
        self.info = {
            "CFBundleVersion": "601", "CFBundleShortVersionString": "1.5.0", "LSMinimumSystemVersion": "15.0",
            "SUFeedURL": appcast.FEED_URL, "SUPublicEDKey": self.public_key,
        }
        self.write_info()
        # Sparkle's tool reads the key from a file or the keychain; the rest is the same.
        tool = self.root / "macos/.build/artifacts/sparkle/Sparkle/bin/sign_update"
        tool.parent.mkdir(parents=True)
        tool.write_text(f'#!/bin/sh\n[ "$1" = --ed-key-file ] && [ "$3" = -p ] || exit 64\n'
                        f'exec "{self.key_tool}" sign "$(cat "$2")" "$4"\n')
        tool.chmod(0o755)
        key_file = self.root / "seed"
        key_file.write_text(self.seed)
        environment = mock.patch.dict(os.environ, RELEASE_UPDATE_KEY_FILE=str(key_file))
        environment.start()
        self.addCleanup(environment.stop)

    def write_info(self, **changes: str | None) -> None:
        info = {key: value for key, value in (self.info | changes).items() if value is not None}
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

    def create(self) -> bool:
        return appcast.create(self.root, self.feed, self.app, self.dmg, "v1.5.0")

    def verify(self) -> None:
        appcast.verify(self.feed, self.app, self.dmg, "v1.5.0")

    def test_offers_the_signed_dmg_of_the_release(self) -> None:
        self.assertTrue(self.create())
        self.verify()
        item, = ElementTree.parse(self.feed).findall("./channel/item")
        enclosure = item.find("enclosure")
        self.assertEqual("https://github.com/omacom/try-omarchy/releases/download/v1.5.0/TryOmarchy.dmg",
                         enclosure.get("url"))
        self.assertEqual("3000", enclosure.get("length"))
        self.assertEqual("601", item.findtext(appcast.sparkle("version")))
        self.assertEqual("1.5.0", item.findtext(appcast.sparkle("shortVersionString")))
        self.assertEqual("15.0", item.findtext(appcast.sparkle("minimumSystemVersion")))
        self.assertIn('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"', self.feed.read_text())

    def test_is_a_release_asset_once_written(self) -> None:
        feed = self.root / "dist/appcast.xml"
        feed.parent.mkdir()
        self.assertNotIn(feed, release.release_assets(self.root))
        feed.write_text("")
        self.assertIn(feed, release.release_assets(self.root))

    def test_refuses_a_dmg_changed_after_signing(self) -> None:
        self.create()
        self.dmg.write_bytes(b"DMG" * 1000)
        with self.assertRaisesRegex(ValueError, "installed apps would refuse it"):
            self.verify()

    def test_refuses_a_key_the_app_does_not_accept(self) -> None:
        _, other = self.generate()
        self.write_info(SUPublicEDKey=other)
        with self.assertRaisesRegex(ValueError, "installed apps would refuse it"):
            self.create()

    def test_refuses_an_appcast_of_another_build(self) -> None:
        self.create()
        self.write_info(CFBundleVersion="602")
        with self.assertRaisesRegex(ValueError, "does not describe TryOmarchy.dmg of v1.5.0: version"):
            self.verify()
        self.write_info()
        with self.assertRaisesRegex(ValueError, "link, url"):
            appcast.verify(self.feed, self.app, self.dmg, "v1.5.1")

    def test_refuses_a_version_sparkle_would_prefer(self) -> None:
        self.create()
        self.feed.write_text(self.feed.read_text().replace("<enclosure ", '<enclosure sparkle:version="1" '))
        with self.assertRaisesRegex(ValueError, "unexpected enclosure attributes"):
            self.verify()

    def test_refuses_a_missing_or_malformed_appcast(self) -> None:
        for content in (None, "", "<rss><channel/></rss>", "<rss><channel><item/></channel></rss>"):
            self.feed.unlink(missing_ok=True)
            if content is not None:
                self.feed.write_text(content)
            with self.subTest(content=content), self.assertRaisesRegex(ValueError, "no valid appcast"):
                self.verify()

    def test_an_app_without_updates_gets_no_appcast(self) -> None:
        self.create()
        self.write_info(SUFeedURL=None, SUPublicEDKey=None)
        with self.assertRaisesRegex(ValueError, "from another build"):
            self.verify()
        self.assertFalse(self.create())
        self.assertFalse(self.feed.exists())
        self.verify()

    def test_refuses_a_partial_or_redirected_configuration(self) -> None:
        for changes in ({"SUPublicEDKey": None}, {"SUPublicEDKey": "short"}, {"SUFeedURL": None},
                        {"SUFeedURL": "https://example.invalid/appcast.xml"}):
            self.write_info(**changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.create()

    def test_build_numbers_must_rise_with_every_release(self) -> None:
        def git(*arguments: str) -> None:
            subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Appcast Tests",
                            "-c", "user.email=appcast-tests@example.invalid", *arguments], check=True, capture_output=True)
        git("init", "-q")
        git("commit", "-q", "--allow-empty", "-m", "One")
        git("branch", "side")
        git("commit", "-q", "--allow-empty", "-m", "Two")
        git("tag", "v1.4.0")
        git("commit", "-q", "--allow-empty", "-m", "Three")
        appcast.check_build_number(self.root, "v1.5.0", ["v1.4.0"])
        git("tag", "v1.5.0")
        appcast.check_build_number(self.root, "v1.5.0", ["v1.4.0", "v1.5.0"])
        git("checkout", "-q", "side")
        git("commit", "-q", "--allow-empty", "-m", "Hotfix")
        with self.assertRaisesRegex(ValueError, "build 2 is not newer than v1.4.0's build 2"):
            appcast.check_build_number(self.root, "v1.5.1", ["v1.4.0"])
        with mock.patch.object(appcast.subprocess, "check_output", return_value="true\n"):
            with self.assertRaisesRegex(ValueError, "unshallow"):
                appcast.check_build_number(self.root, "v1.5.1", [])


if __name__ == "__main__":
    unittest.main()
