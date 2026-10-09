#!/usr/bin/env python3
"""Exercise the public release command with real Git and disposable builders."""

from __future__ import annotations

import os
from pathlib import Path
import plistlib
import pty
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]


class ReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "macos").mkdir()
        for name in ("release.py", "app_version.py"):
            shutil.copy2(REPOSITORY / "scripts" / name, self.root / "scripts" / name)
        # Keep the actual public release/preflight recipes; substitute only the
        # expensive guest, runtime, and signed app builders at their boundaries.
        makefile = (REPOSITORY / "Makefile").read_text()
        makefile += '\nguest runtime:\n\t@python3 "$(ROOT)/fake-component.py" "$@"\n'
        (self.root / "Makefile").write_text(makefile)
        (self.root / ".gitignore").write_text("/dist/\n/.build/\n/scripts/__pycache__/\n")
        (self.root / "source.swift").write_text("// initial source\n")
        (self.root / "fake-component.py").write_text('''
import os
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parent
out = root / "dist"
out.mkdir(exist_ok=True)
with (out / "events").open("a") as stream:
    tags = subprocess.check_output(["git", "tag", "--points-at", "HEAD"], text=True).strip()
    stream.write(f"{sys.argv[1]}:{tags}\\n")
if os.environ.get("FAIL_COMPONENT") == sys.argv[1]:
    sys.exit(23)
if sys.argv[1] == "runtime":
    if os.environ.get("DIRTY_COMPONENT"):
        (root / "source.swift").write_text("// changed during build\\n")
    if os.environ.get("MOVE_HEAD"):
        subprocess.run(["git", "commit", "--allow-empty", "-qm", "Concurrent change"], check=True)
''')
        builder = self.root / "macos/build-app.sh"
        builder.write_text(f'#!{sys.executable}\n' + '''
import os
from pathlib import Path
import plistlib
import subprocess
import sys
root = Path(__file__).resolve().parents[1]
out = root / "dist"
with (out / "events").open("a") as stream:
    stream.write("package\\n")
assert sys.argv[1:] == ["--configuration", "production", "--dmg",
    "--guest-dir", str(out / "guest"), "--sign-identity",
    "Developer ID Application: Release Tests (TEST)", "--notarize-profile", "test-profile"]
app = out / "release.noindex/Try Omarchy.app"
plist = app / "Contents/Info.plist"
plist.parent.mkdir(parents=True, exist_ok=True)
plist.write_bytes(plistlib.dumps({}))
subprocess.run([sys.executable, str(root / "scripts/app_version.py"),
    "--root", str(root), "--plist", str(plist)], check=True)
if os.environ.get("WRONG_APP_VERSION"):
    info = plistlib.loads(plist.read_bytes())
    info["CFBundleShortVersionString"] = os.environ["WRONG_APP_VERSION"]
    plist.write_bytes(plistlib.dumps(info))
if os.environ.get("FAIL_PACKAGE"):
    sys.exit(24)
version = plistlib.loads(plist.read_bytes())["CFBundleShortVersionString"]
(out / os.environ.get("DMG_NAME", f"TryOmarchy-v{version}.dmg")).write_text("test DMG\\n")
''')
        builder.chmod(0o755)
        self.git("init", "-q")
        self.git("config", "user.name", "Release Tests")
        self.git("config", "user.email", "release-tests@example.invalid")
        self.git("config", "tag.gpgSign", "false")
        self.git("add", ".")
        self.git("commit", "-qm", "Initial source")

    def git(self, *arguments: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(self.root), *arguments], text=True, stderr=subprocess.STDOUT,
        ).strip()

    def run_release(self, version: str | None = "1.2.3", *, terminal: bool = False,
                    answer: bytes = b"\ny\n", dry_run: bool = False,
                    **environment: str) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        for name in ("VERSION", "MAKEFLAGS", "MAKELEVEL", "MFLAGS", "RELEASE_MAKE"):
            env.pop(name, None)
        env.update(RELEASE_SIGN_IDENTITY="Developer ID Application: Release Tests (TEST)",
                   RELEASE_NOTARY_PROFILE="test-profile", PYTHONDONTWRITEBYTECODE="1")
        env.update(environment)
        command = ["make", "--no-print-directory", "-C", str(self.root)]
        if dry_run:
            command.append("-n")
        command.append("release")
        if version is not None:
            command.append(f"VERSION={version}")
        if terminal:
            master, slave = pty.openpty()
            try:
                os.write(master, answer)
                return subprocess.run(command, env=env, stdin=slave,
                                      capture_output=True, text=True, timeout=15)
            finally:
                os.close(master)
                os.close(slave)
        return subprocess.run(command, env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=15)

    def assert_failed(self, result: subprocess.CompletedProcess, message: str) -> None:
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)

    def test_explicit_version_tags_before_packaging_and_stamps_dmg(self) -> None:
        result = self.run_release()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("tag", self.git("cat-file", "-t", "refs/tags/v1.2.3"))
        self.assertEqual(self.git("rev-parse", "HEAD"), self.git("rev-parse", "v1.2.3^{commit}"))
        self.assertEqual("guest:\nruntime:\npackage\n", (self.root / "dist/events").read_text())
        self.assertTrue((self.root / "dist/TryOmarchy-v1.2.3.dmg").exists())
        self.assertIn(f"Release DMG: {self.root.resolve() / 'dist/TryOmarchy-v1.2.3.dmg'}", result.stdout)
        app_info = plistlib.loads((self.root / "dist/release.noindex/Try Omarchy.app/Contents/Info.plist").read_bytes())
        self.assertEqual("1.2.3", app_info["CFBundleShortVersionString"])
        self.assertEqual("v1.2.3", app_info["TryOmarchyBuildDescribe"])
        self.assertIn("git push origin v1.2.3", result.stdout)
        self.assertNotIn("[y/N]", result.stdout)
        self.assertEqual("", self.git("status", "--porcelain"))

    def test_release_requires_matching_versioned_dmg(self) -> None:
        for name in ("TryOmarchy.dmg", "TryOmarchy-v1.2.2.dmg"):
            with self.subTest(name=name):
                result = self.run_release(DMG_NAME=name)
                self.assert_failed(result, "release DMG was not produced:")
                self.assertIn("TryOmarchy-v1.2.3.dmg", result.stderr)
                self.assertNotIn("Release DMG:", result.stdout)

    def test_prompt_allows_explicit_patch_minor_and_major_selection(self) -> None:
        self.git("tag", "v1.9.9")
        self.git("tag", "v1.10.2")
        self.git("commit", "--allow-empty", "-qm", "Next release")
        for answer, tag in ((b"1\n", "v1.10.3"), (b"minor\n", "v1.11.0"), (b"3\n", "v2.0.0")):
            with self.subTest(tag=tag):
                result = self.run_release(None, terminal=True, answer=answer + b"y\n")
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertIn("1) Patch — v1.10.3", result.stdout)
                self.assertIn("2) Minor — v1.11.0", result.stdout)
                self.assertIn("3) Major — v2.0.0", result.stdout)
                self.assertTrue((self.root / f"dist/TryOmarchy-{tag}.dmg").exists())
                self.git("tag", "-d", tag)

    def test_empty_selection_does_not_default_to_patch(self) -> None:
        self.git("tag", "v1.2.3")
        self.git("commit", "--allow-empty", "-qm", "Next release")
        result = self.run_release(None, terminal=True, answer=b"\n2\ny\n")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("there is no default", result.stdout)
        self.assertEqual("v1.2.3\nv1.3.0", self.git("tag"))

    def test_version_can_be_entered_directly_without_a_custom_menu_option(self) -> None:
        result = self.run_release(None, terminal=True, answer=b"v3.2.1\ny\n")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("Select patch/minor/major (1–3), or type vX.Y.Z:", result.stdout)
        self.assertNotIn("4) Custom", result.stdout)
        self.assertEqual("v3.2.1", self.git("tag"))

    def test_missing_version_without_terminal_fails_before_building(self) -> None:
        self.assert_failed(self.run_release(None), "use make release VERSION=vX.Y.Z")
        self.assertFalse((self.root / "dist").exists())
        self.assertEqual("", self.git("tag"))

    def test_first_release_prompt_and_entered_version(self) -> None:
        result = self.run_release(None, terminal=True, answer=b"v3.0.0\nyes\n")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("No local release tags; increments start from v0.0.0", result.stdout)
        self.assertTrue((self.root / "dist/TryOmarchy-v3.0.0.dmg").exists())
        self.assertIn(f"Create release v3.0.0 from commit {self.git('rev-parse', 'HEAD')[:12]}? [y/N]",
                      result.stdout)

    def test_confirmation_defaults_to_no_and_leaves_checkout_untouched(self) -> None:
        for answer in (b"\n", b"n\n", b"maybe\n", b"\x04"):
            with self.subTest(answer=answer):
                result = self.run_release(None, terminal=True, answer=b"v3.0.0\n" + answer)
                self.assert_failed(result, "release cancelled; no builds or tag changes")
                self.assertIn("Create release v3.0.0 from commit", result.stdout)
                self.assertEqual("", self.git("tag"))
                self.assertFalse((self.root / "dist").exists())

    def test_explicit_version_also_requires_confirmation_in_a_terminal(self) -> None:
        result = self.run_release("v3.0.0", terminal=True, answer=b"n\n")
        self.assert_failed(result, "release cancelled")
        self.assertIn("Create release v3.0.0 from commit", result.stdout)
        self.assertEqual("", self.git("tag"))
        self.assertFalse((self.root / "dist").exists())

    def test_cancelled_prompt_does_not_build_or_tag(self) -> None:
        self.assert_failed(self.run_release(None, terminal=True, answer=b"\x04"), "prompt cancelled")
        self.assertEqual("", self.git("tag"))
        self.assertFalse((self.root / "dist").exists())

    def test_invalid_versions_fail_before_building(self) -> None:
        for version in ("1.2", "1.2.3-rc1", "01.2.3", "1.2.3;touch surprise", "1.2.3`touch surprise`"):
            with self.subTest(version=version):
                self.assert_failed(self.run_release(version), "VERSION must be")
                self.assertEqual("", self.git("tag"))
                self.assertFalse((self.root / "dist").exists())
                self.assertFalse((self.root / "surprise").exists())

    def test_dirty_checkout_including_untracked_files_fails_before_building(self) -> None:
        for staged in (False, True):
            with self.subTest(staged=staged):
                (self.root / "new.swift").write_text("// new source\n")
                if staged:
                    self.git("add", "new.swift")
                self.assert_failed(self.run_release(), "local changes, including untracked")
                self.assertEqual("", self.git("tag"))
                self.assertFalse((self.root / "dist").exists())

    def test_existing_version_on_another_commit_is_never_moved(self) -> None:
        self.git("tag", "v1.2.3")
        original = self.git("rev-parse", "v1.2.3")
        self.git("commit", "--allow-empty", "-qm", "Next release")
        self.assert_failed(self.run_release(), "already belongs to another commit")
        self.assertEqual(original, self.git("rev-parse", "v1.2.3"))
        self.assertFalse((self.root / "dist").exists())

    def test_older_version_and_second_tag_on_same_commit_are_rejected(self) -> None:
        self.git("tag", "v2.0.0")
        self.assert_failed(self.run_release("2.0.1"), "this commit is already tagged")
        self.git("commit", "--allow-empty", "-qm", "Next release")
        self.assert_failed(self.run_release("1.2.3"), "newer than the latest local")
        self.assertEqual("v2.0.0", self.git("tag"))

    def test_component_failure_or_source_change_creates_no_tag(self) -> None:
        for environment, message in (({"FAIL_COMPONENT": "guest"}, "exit status 2"),
                                     ({"MOVE_HEAD": "1"}, "HEAD changed"),
                                     ({"DIRTY_COMPONENT": "1"}, "local changes")):
            with self.subTest(environment=environment):
                self.assert_failed(self.run_release(**environment), message)
                self.assertEqual("", self.git("tag"))
                self.assertNotIn("package", (self.root / "dist/events").read_text())

    def test_packaging_failure_keeps_tag_and_retry_reuses_it(self) -> None:
        self.assert_failed(self.run_release(FAIL_PACKAGE="1"), "Retry with make release VERSION=v1.2.3")
        original = self.git("rev-parse", "refs/tags/v1.2.3")
        result = self.run_release("v1.2.3")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("Reusing v1.2.3", result.stdout)
        self.assertEqual(original, self.git("rev-parse", "refs/tags/v1.2.3"))

    def test_wrong_built_app_version_fails_release(self) -> None:
        result = self.run_release(WRONG_APP_VERSION="1.2.2")
        self.assert_failed(result, "built app version does not match v1.2.3")
        self.assertEqual("v1.2.3", self.git("tag"))

    def test_prompt_on_tagged_head_defaults_to_rebuilding(self) -> None:
        self.git("tag", "-a", "v1.2.3", "-m", "v1.2.3")
        result = self.run_release(None, terminal=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("Enter rebuilds that release", result.stdout)
        self.assertIn("Rebuild release v1.2.3 from commit", result.stdout)
        self.assertEqual("v1.2.3", self.git("tag"))

    def test_invalid_credentials_and_dry_run_never_create_a_tag(self) -> None:
        self.assert_failed(self.run_release(RELEASE_SIGN_IDENTITY="-"), "Developer ID Application")
        result = self.run_release(dry_run=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("scripts/release.py", result.stdout)
        self.assertEqual("", self.git("tag"))
        self.assertFalse((self.root / "dist").exists())


if __name__ == "__main__":
    unittest.main()
