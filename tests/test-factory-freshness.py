#!/usr/bin/env python3
"""The factory freshness report printed after make build."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("factory_freshness", REPOSITORY / "scripts/factory-freshness.py")
assert SPEC is not None and SPEC.loader is not None
freshness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(freshness)

BUILT = datetime(2026, 10, 16, 10, 0, tzinfo=timezone.utc)


def database(versions: dict[str, str]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for name, version in versions.items():
            desc = f"%FILENAME%\n{name}.pkg\n\n%NAME%\n{name}\n\n%VERSION%\n{version}\n\n".encode()
            info = tarfile.TarInfo(f"{name}-{version}/desc")
            info.size = len(desc)
            archive.addfile(info, io.BytesIO(desc))
    return buffer.getvalue()


class FactoryFreshnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.guest = self.root / "dist/guest"
        self.guest.mkdir(parents=True)
        self.built_with = database({"omarchy-dev": "4.0.0.r1-1", "linux-omarchy": "7.2.8-11", "walker": "2.0-1"})
        (self.guest / "factory.json").write_text(json.dumps({
            "built": BUILT.strftime("%Y-%m-%dT%H:%M:%SZ"), "omarchy": "4.0.0.r1-1", "kernel": "7.2.8-11",
            "omarchy_db_sha256": hashlib.sha256(self.built_with).hexdigest()}))
        (self.guest / "packages.txt").write_text("linux-omarchy 7.2.8-11\nomarchy-dev 4.0.0.r1-1\nwalker 2.0-1\n")
        self.served = self.root / "omarchy.db"

    def report(self, served: bytes | None, after: timedelta) -> list[str]:
        url = "file:///nonexistent/omarchy.db"
        if served is not None:
            self.served.write_bytes(served)
            url = self.served.as_uri()
        return freshness.report(self.root, url, BUILT + after, timeout=1)

    def test_an_unchanged_upstream_is_up_to_date(self) -> None:
        lines = self.report(self.built_with, timedelta(hours=3))
        self.assertEqual(lines, ["[factory] Up to date with Omarchy edge "
                                 "(built 3 h ago; Omarchy 4.0.0.r1-1, kernel 7.2.8-11)."])

    def test_a_move_an_hour_later_names_what_changed(self) -> None:
        moved = database({"omarchy-dev": "4.0.0.r5-1", "linux-omarchy": "7.2.9-1", "walker": "2.0-1",
                          "not-installed": "9-1"})
        lines = self.report(moved, timedelta(hours=1, minutes=5))
        self.assertIn("moved since the factory was built 1 h 5 min ago: 2 installed packages newer upstream "
                      "(omarchy-dev 4.0.0.r1-1 -> 4.0.0.r5-1, linux-omarchy 7.2.8-11 -> 7.2.9-1)", lines[0])
        self.assertIn("Run `make refresh`", lines[1])

    def test_an_index_change_without_new_installed_versions_says_so(self) -> None:
        lines = self.report(database({"omarchy-dev": "4.0.0.r1-1", "linux-omarchy": "7.2.8-11",
                                      "walker": "2.0-1", "new-tool": "1-1"}), timedelta(minutes=30))
        self.assertIn("no package the factory installed has a new version", lines[0])

    def test_offline_shows_the_age_and_suggests_refresh_once_stale(self) -> None:
        recent = self.report(None, timedelta(days=2))
        self.assertEqual(len(recent), 1)
        self.assertIn("Built 2 d ago", recent[0])
        self.assertIn("could not check Omarchy edge", recent[0])
        stale = self.report(None, timedelta(days=8, hours=2))
        self.assertIn("Built 8 d 2 h ago", stale[0])
        self.assertIn("Run `make refresh`", stale[1])

    def test_no_factory_prints_nothing(self) -> None:
        (self.guest / "factory.json").unlink()
        self.assertEqual(self.report(self.built_with, timedelta(hours=1)), [])

    def test_ages_read_naturally(self) -> None:
        self.assertEqual(freshness.age_text(20), "under a minute")
        self.assertEqual(freshness.age_text(59 * 60), "59 min")
        self.assertEqual(freshness.age_text(3600), "1 h")
        self.assertEqual(freshness.age_text(26 * 3600), "1 d 2 h")

    def test_make_build_reports_and_make_refresh_forces_the_factory(self) -> None:
        build = subprocess.run(["make", "-n", "build"], cwd=REPOSITORY, check=True,
                               capture_output=True, text=True).stdout
        self.assertIn("scripts/factory-freshness.py", build)
        refresh = subprocess.run(["make", "-n", "refresh"], cwd=REPOSITORY, check=True,
                                 capture_output=True, text=True).stdout
        self.assertIn("guest FORCE=1", refresh)
        self.assertLess(refresh.index("guest FORCE=1"), refresh.index(" build"))


if __name__ == "__main__":
    unittest.main()
