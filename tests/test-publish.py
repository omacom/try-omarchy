#!/usr/bin/env python3
"""Exercise make publish with real Git, a local origin, and a recording fake gh."""

from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
FAKE_GH = '''
import json, os, sys
state_path = os.environ["FAKE_GH_STATE"]
state = json.load(open(state_path))
args = sys.argv[1:]
state["calls"].append(args)
def save():
    json.dump(state, open(state_path, "w"))
if args[:3] == ["api", "--paginate", "--slurp"]:
    print(json.dumps([state["releases"]]))
elif args[:3] == ["api", "-X", "PATCH"]:
    release_id = int(args[3].rsplit("/", 1)[1])
    for release in state["releases"]:
        if release["id"] == release_id:
            release["tag_name"] = args[5].split("=", 1)[1]
elif args[:2] == ["release", "create"]:
    state["releases"].append({"id": 99, "name": args[args.index("--title") + 1], "tag_name": args[2], "draft": True})
elif args[:2] == ["release", "view"]:
    print(f"https://github.com/omacom/try-omarchy/releases/tag/{args[2]}")
save()
'''


class PublishTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="publish-test-")
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name).resolve()
        self.root = base / "checkout"
        self.origin = base / "origin.git"
        (self.root / "scripts").mkdir(parents=True)
        for name in ("publish.py", "release.py", "app_version.py"):
            shutil.copy2(REPOSITORY / "scripts" / name, self.root / "scripts" / name)
        (self.root / ".gitignore").write_text("/dist/\n/scripts/__pycache__/\n")
        subprocess.run(["git", "init", "-q", "--bare", str(self.origin)], check=True)
        self.git("init", "-q")
        self.git("config", "user.name", "Publish Tests")
        self.git("config", "user.email", "publish-tests@example.invalid")
        self.git("config", "tag.gpgSign", "false")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("add", ".")
        self.git("commit", "-qm", "Initial source")
        self.git("tag", "-a", "v1.2.3", "-m", "v1.2.3")
        self.build("v1.2.3")
        self.bin = base / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(f"#!{sys.executable}\n" + FAKE_GH)
        gh.chmod(0o755)
        self.state = base / "gh.json"
        self.set_releases([])

    def git(self, *arguments: str, cwd: Path | None = None) -> str:
        return subprocess.check_output(["git", "-C", str(cwd or self.root), *arguments], text=True).strip()

    def build(self, tag: str, factory_tag: str | None = None) -> None:
        dist = self.root / "dist"
        app = dist / "release.noindex/Try Omarchy.app/Contents"
        (app / "Resources/guest").mkdir(parents=True, exist_ok=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": tag.removeprefix("v"), "TryOmarchyBuildDescribe": tag}))
        (dist / "factory").mkdir(exist_ok=True)
        (dist / "factory/omarchy-aarch64-edge.img.zst.001").write_text("image")
        url = f"https://github.com/omacom/try-omarchy/releases/download/{factory_tag or tag}/omarchy-aarch64-edge.img.zst.001"
        (app / "Resources/guest/download.json").write_text(json.dumps({"parts": [{"url": url, "bytes": 5}]}))
        (dist / "TryOmarchy.dmg").write_text("dmg")

    def set_releases(self, releases: list[dict]) -> None:
        self.state.write_text(json.dumps({"releases": releases, "calls": []}))

    def calls(self) -> list[list[str]]:
        return json.loads(self.state.read_text())["calls"]

    def publish(self) -> subprocess.CompletedProcess:
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_GH_STATE=str(self.state),
                   PYTHONDONTWRITEBYTECODE="1")
        return subprocess.run([sys.executable, str(self.root / "scripts/publish.py"), "--root", str(self.root)],
                              env=env, capture_output=True, text=True, timeout=30)

    def remote_tag(self) -> str:
        return self.git("rev-parse", "v1.2.3^{commit}", cwd=self.origin)

    def assets(self) -> list[str]:
        return [str(self.root / "dist/TryOmarchy.dmg"), str(self.root / "dist/factory/omarchy-aarch64-edge.img.zst.001")]

    def test_pushes_the_tag_then_creates_a_draft_with_the_assets(self) -> None:
        result = self.publish()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.remote_tag())
        create = next(call for call in self.calls() if call[:2] == ["release", "create"])
        self.assertEqual(["release", "create", "v1.2.3", "--repo", "omacom/try-omarchy", "--draft",
                          "--verify-tag", "--title", "v1.2.3", *self.assets()], create)
        self.assertIn("Draft ready: https://github.com/omacom/try-omarchy/releases/tag/v1.2.3", result.stdout)

    def test_uploads_to_the_existing_draft_for_the_tag(self) -> None:
        self.set_releases([{"id": 7, "name": "1.2.3 notes", "tag_name": "v1.2.3", "draft": True}])
        result = self.publish()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn(["release", "upload", "v1.2.3", "--repo", "omacom/try-omarchy", "--clobber", *self.assets()],
                      self.calls())
        self.assertFalse(any(call[:2] == ["release", "create"] for call in self.calls()))

    def test_selects_the_tag_on_an_untagged_draft_with_its_name(self) -> None:
        self.set_releases([{"id": 415651654, "name": "v1.2.3", "tag_name": "", "draft": True}])
        result = self.publish()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        calls = self.calls()
        patch = ["api", "-X", "PATCH", "repos/omacom/try-omarchy/releases/415651654", "-f", "tag_name=v1.2.3"]
        self.assertIn(patch, calls)
        self.assertLess(calls.index(patch), next(i for i, call in enumerate(calls) if call[:2] == ["release", "upload"]))

    def test_an_already_pushed_tag_is_reused(self) -> None:
        self.git("push", "-q", "origin", "refs/tags/v1.2.3")
        result = self.publish()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("v1.2.3 is already on origin", result.stdout)

    def test_refuses_an_origin_tag_on_another_commit(self) -> None:
        self.git("tag", "-d", "v1.2.3")
        self.git("commit", "-q", "--allow-empty", "-m", "Elsewhere")
        self.git("tag", "-a", "v1.2.3", "-m", "v1.2.3")
        self.git("push", "-q", "origin", "refs/tags/v1.2.3")
        self.git("tag", "-d", "v1.2.3")
        self.git("tag", "-a", "v1.2.3", "-m", "v1.2.3", "HEAD~1")
        result = self.publish()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("not the built commit", result.stderr)
        self.assertEqual([], self.calls())

    def test_refuses_a_published_release(self) -> None:
        self.set_releases([{"id": 7, "name": "v1.2.3", "tag_name": "v1.2.3", "draft": False}])
        result = self.publish()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("already published", result.stderr)
        self.assertFalse(any(call[:2] == ["release", "upload"] for call in self.calls()))

    def test_refuses_mismatched_or_missing_builds(self) -> None:
        self.build("v1.2.3", factory_tag="v1.2.2")
        result = self.publish()
        self.assertIn("does not point at v1.2.3", result.stderr)
        self.build("v1.2.3")
        (self.root / "dist/factory/omarchy-aarch64-edge.img.zst.001").unlink()
        self.assertIn("factory release asset is missing", self.publish().stderr)
        shutil.rmtree(self.root / "dist")
        self.assertIn("run make release first", self.publish().stderr)
        self.assertEqual([], self.calls())
        self.assertNotEqual(0, subprocess.run(["git", "-C", str(self.origin), "rev-parse", "v1.2.3"],
                                              capture_output=True).returncode)


if __name__ == "__main__":
    unittest.main()
