#!/usr/bin/env python3

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
VERSION_SCRIPT = REPOSITORY / "scripts/app_version.py"


class AppVersionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="app-version-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(VERSION_SCRIPT, self.root / "scripts/app_version.py")
        shutil.copy2(REPOSITORY / "Makefile", self.root / "Makefile")
        (self.root / ".gitignore").write_text("/dist/\n/.build/\n")
        self.source = self.root / "source.swift"
        self.source.write_text("// initial source\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Version Tests")
        self.git("config", "user.email", "version-tests@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "Initial source")
        self.plist = self.root / "dist/Info.plist"
        self.plist.parent.mkdir()
        self.original = plistlib.dumps({
            "CFBundleShortVersionString": "0.4.0",
            "CFBundleVersion": "5",
            "CFBundleIdentifier": "dev.tryomarchy.native",
        })

    def git(self, *arguments: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(self.root), *arguments],
            text=True, stderr=subprocess.STDOUT,
        ).strip()

    def stamp(self) -> dict[str, str]:
        self.plist.write_bytes(self.original)
        subprocess.run(
            [sys.executable, str(VERSION_SCRIPT), "--root", str(self.root),
             "--plist", str(self.plist)],
            check=True, capture_output=True, text=True,
        )
        value = plistlib.loads(self.plist.read_bytes())
        self.assertEqual("dev.tryomarchy.native", value["CFBundleIdentifier"])
        return value

    def preflight(self, expected_error: str | None = None) -> None:
        result = subprocess.run(
            ["make", "--no-print-directory", "-C", str(self.root), "version-preflight"],
            capture_output=True, text=True,
        )
        if expected_error is None:
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        else:
            self.assertNotEqual(0, result.returncode)
            self.assertIn(expected_error, result.stderr)

    def test_tagged_release_and_ignored_build_outputs(self) -> None:
        self.git("tag", "-a", "v1.2.3", "-m", "Release")
        (self.root / ".build").mkdir()
        (self.root / ".build/output").write_text("ignored build output")
        value = self.stamp()
        self.assertEqual("1.2.3", value["CFBundleShortVersionString"])
        self.assertEqual("1", value["CFBundleVersion"])
        self.assertEqual("v1.2.3", value["TryOmarchyBuildDescribe"])
        self.preflight()

    def test_untracked_source_is_dirty_until_committed(self) -> None:
        self.git("tag", "v1.2.3")
        (self.root / "added.swift").write_text("// untracked app source\n")
        for staged in (False, True):
            with self.subTest(staged=staged):
                if staged:
                    self.git("add", "added.swift")
                value = self.stamp()
                self.assertEqual("0.0.0", value["CFBundleShortVersionString"])
                self.assertEqual("v1.2.3-dirty", value["TryOmarchyBuildDescribe"])
                self.preflight("worktree must be clean")
        self.git("commit", "-qm", "Add source")
        value = self.stamp()
        self.assertEqual("0.0.0", value["CFBundleShortVersionString"])
        self.assertEqual("2", value["CFBundleVersion"])
        self.assertRegex(value["TryOmarchyBuildDescribe"], r"^v1\.2\.3-1-g[0-9a-f]+$")
        self.preflight("HEAD must carry an exact")

    def test_modified_tracked_source_is_dirty(self) -> None:
        self.git("tag", "v1.2.3")
        self.source.write_text("// modified source\n")
        value = self.stamp()
        self.assertEqual("0.0.0", value["CFBundleShortVersionString"])
        self.assertEqual("v1.2.3-dirty", value["TryOmarchyBuildDescribe"])
        self.preflight("worktree must be clean")

    def test_untagged_and_non_release_tags(self) -> None:
        self.assertEqual("0.0.0", self.stamp()["CFBundleShortVersionString"])
        self.preflight("HEAD must carry an exact")
        self.git("tag", "v1foo")
        self.assertEqual("0.0.0", self.stamp()["CFBundleShortVersionString"])
        self.preflight("HEAD must carry an exact")

    def test_source_archive_keeps_plist_but_cannot_be_released(self) -> None:
        shutil.rmtree(self.root / ".git")
        self.stamp()
        self.assertEqual(self.original, self.plist.read_bytes())
        self.preflight("HEAD must carry an exact")


if __name__ == "__main__":
    unittest.main()
