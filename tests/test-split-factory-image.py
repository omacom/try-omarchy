#!/usr/bin/env python3
"""Check the factory release assets and the download manifest the app reads."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/split-factory-image.py"


class SplitFactoryImageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="split-factory-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.guest = self.root / "guest"
        self.guest.mkdir()

    def write_guest(self, image: bytes, compressed_sha: str | None = None) -> None:
        (self.guest / "omarchy.img.zst").write_bytes(image)
        (self.guest / "factory.json").write_text(json.dumps({
            "disk": {"sha256": "a" * 64},
            "compressed": {"path": "omarchy.img.zst",
                           "sha256": compressed_sha or hashlib.sha256(image).hexdigest()},
        }))

    def split(self, part_bytes: int, base_url: str = "https://example.com/releases/download/v1.0.0/"):
        return subprocess.run([
            sys.executable, str(SCRIPT), "--guest-dir", str(self.guest), "--base-url", base_url,
            "--output", str(self.root / "assets"), "--manifest", str(self.root / "download.json"),
            "--part-bytes", str(part_bytes),
        ], capture_output=True, text=True)

    def test_parts_are_consecutive_ranges_with_their_digests(self) -> None:
        image = bytes(range(256)) * 10
        self.write_guest(image)
        for part_bytes, count in ((1000, 3), (1280, 2), (5000, 1)):
            with self.subTest(part_bytes=part_bytes):
                result = self.split(part_bytes)
                self.assertEqual(0, result.returncode, result.stderr)
                manifest = json.loads((self.root / "download.json").read_text())
                self.assertEqual(count, len(manifest["parts"]))
                self.assertEqual({"bytes": len(image), "sha256": hashlib.sha256(image).hexdigest()}, manifest["image"])
                self.assertEqual("a" * 64, manifest["identity"])
                joined = b""
                for index, part in enumerate(manifest["parts"], start=1):
                    name = f"omarchy.img.zst.{index:03d}"
                    self.assertEqual(f"https://example.com/releases/download/v1.0.0/{name}", part["url"])
                    data = (self.root / "assets" / name).read_bytes()
                    self.assertEqual(part["bytes"], len(data))
                    self.assertEqual(part["sha256"], hashlib.sha256(data).hexdigest())
                    joined += data
                self.assertEqual(image, joined)
                # A smaller split replaces every older part.
                self.assertEqual(count, len(list((self.root / "assets").iterdir())))

    def test_refuses_an_image_that_does_not_match_the_factory(self) -> None:
        self.write_guest(b"image", compressed_sha="b" * 64)
        result = self.split(2)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("does not match factory.json", result.stderr)

    def test_refuses_insecure_or_malformed_urls(self) -> None:
        self.write_guest(b"image")
        for url in ("http://example.com/x/", "https://example.com/x", "file:///tmp/"):
            with self.subTest(url=url):
                self.assertNotEqual(0, self.split(2, url).returncode)
        self.assertEqual(0, self.split(2, "http://127.0.0.1:8000/").returncode)


if __name__ == "__main__":
    unittest.main()
