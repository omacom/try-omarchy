#!/usr/bin/env python3
"""Tests for macos/publish-migration-exports.sh."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "publish-migration-exports.sh"
EXPORT_ID = "6022f2ec-746c-4636-b786-2240103a7efb"
OTHER_ID = "c4e6a8b0-2d4f-4a6c-9e8f-0a1b2c3d4e03"


SALT, KEY, MAC = "A" * 22, "B" * 43, "C" * 43
HEADER = f"age-encryption.org/v1\n-> scrypt {SALT} 18\n{KEY}\n--- {MAC}\n".encode()


class PublishMigrationExports(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.vm = self.root / "shell"
        self.outbox = self.vm / "export-outbox"
        self.outbox.mkdir(parents=True)
        (self.vm / "disk.img").write_text("the VM disk")
        self.destination = self.root / "Exports"

    def write_export(self, name=EXPORT_ID, bundle=HEADER + b"\x00\x01",
                     **receipt_changes):
        folder = self.outbox / name
        folder.mkdir()
        (folder / "bundle.age").write_bytes(bundle)
        receipt = {"schema": "omarchy-migration/receipt/1", "export_id": name,
                   "bundle": {"format": "age-v1-scrypt", "bytes": len(bundle),
                              "sha256": hashlib.sha256(bundle).hexdigest()}}
        for key, value in receipt_changes.items():
            if key in ("bytes", "sha256", "format"):
                receipt["bundle"][key] = value
            else:
                receipt[key] = value
        (folder / "receipt.json").write_text(json.dumps(receipt))
        return folder

    def publish(self):
        return subprocess.run([str(SCRIPT), "--outbox", str(self.outbox), "--destination", str(self.destination)],
                              capture_output=True, text=True, timeout=60)

    def published(self):
        return sorted(p.name for p in self.destination.iterdir()) if self.destination.exists() else []

    def test_publishes_a_checked_export_and_empties_the_outbox(self):
        source = self.write_export()
        bundle = (source / "bundle.age").read_bytes()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        published = self.destination / EXPORT_ID
        self.assertEqual(result.stdout, f"{published}\n")
        self.assertEqual(self.published(), [EXPORT_ID])
        self.assertEqual(sorted(p.name for p in published.iterdir()), ["bundle.age", "receipt.json"])
        self.assertEqual((published / "bundle.age").read_bytes(), bundle)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o700)
        self.assertEqual(published.stat().st_mode & 0o777, 0o700)
        for path in (published, *published.iterdir()):
            self.assertEqual(path.stat().st_gid, os.getgid(), path)
        for path in published.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600, path)
        self.assertEqual(list(self.outbox.iterdir()), [])

    def test_rejects_anything_but_an_exact_matching_export(self):
        self.write_export(EXPORT_ID.upper())
        (self.write_export("c4e6a8b0-2d4f-4a6c-9e8f-0a1b2c3d4e01") / "request.json").write_text("{}")
        self.write_export("c4e6a8b0-2d4f-4a6c-9e8f-0a1b2c3d4e02", bytes=1)
        self.write_export("c4e6a8b0-2d4f-4a6c-9e8f-0a1b2c3d4e04", sha256="0" * 64)
        self.write_export("c4e6a8b0-2d4f-4a6c-9e8f-0a1b2c3d4e05", bundle=b"ustar plaintext")
        self.write_export("c4e6a8b0-2d4f-4a6c-9e8f-0a1b2c3d4e06", export_id=OTHER_ID)
        self.write_export("c4e6a8b0-2d4f-4a6c-9e8f-0a1b2c3d4e07", format="age-v1-x25519")
        for index, header in enumerate((
                HEADER.replace(b"scrypt", b"X25519"), HEADER.replace(b" 18\n", b" 22\n"),
                HEADER.replace(f"{SALT}".encode(), b"A" * 21), HEADER[:-1],
                HEADER.replace(b"--- ", b"-> scrypt " + SALT.encode() + b" 18\n" + KEY.encode() + b"\n--- "))):
            self.write_export(f"d4e6a8b0-2d4f-4a6c-9e8f-0a1b2c3d4e0{index}", bundle=header)
        linked = self.write_export("c4e6a8b0-2d4f-4a6c-9e8f-0a1b2c3d4e08")
        (self.root / "elsewhere").write_bytes((linked / "bundle.age").read_bytes())
        (linked / "bundle.age").unlink()
        (linked / "bundle.age").symlink_to(self.root / "elsewhere")
        (self.outbox / f".export.{EXPORT_ID}").mkdir()
        (self.outbox / "stray").write_text("x")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.published(), [])
        self.assertEqual(list(self.outbox.iterdir()), [])
        self.assertEqual(result.stderr.count("skipped"), 14, result.stderr)
        self.assertNotIn(".export.", result.stderr)
        self.assertTrue((self.root / "elsewhere").exists())

    def test_hostile_names_never_reach_outside_the_outbox(self):
        for name in ("a .. b", "..x", "line\nbreak", "-rf"):
            (self.outbox / name).mkdir()
        (self.outbox / "link").symlink_to(self.vm)
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.outbox.iterdir()), [])
        self.assertEqual((self.vm / "disk.img").read_text(), "the VM disk")

    def test_never_replaces_a_published_export(self):
        (self.destination / EXPORT_ID).mkdir(parents=True)
        (self.destination / EXPORT_ID / "receipt.json").write_text("earlier")
        self.write_export()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already published", result.stderr)
        self.assertEqual((self.destination / EXPORT_ID / "receipt.json").read_text(), "earlier")
        self.assertEqual(self.published(), [EXPORT_ID])
        self.assertEqual(list(self.outbox.iterdir()), [])

    def test_nothing_to_do_without_an_outbox(self):
        self.outbox.rmdir()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.destination.exists())

    def test_nothing_to_do_with_an_empty_outbox(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.destination.exists())

    def test_refuses_an_outbox_that_is_a_link(self):
        self.outbox.rmdir()
        self.outbox.symlink_to(self.vm)
        result = self.publish()
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsafe outbox", result.stderr)
        self.assertEqual((self.vm / "disk.img").read_text(), "the VM disk")


if __name__ == "__main__":
    unittest.main()
