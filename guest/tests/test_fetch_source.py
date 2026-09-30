from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


GUEST = Path(__file__).resolve().parents[1]
FETCH_SOURCE = GUEST / "scripts/fetch-source.sh"
BUILD = GUEST / "build.sh"


class FetchSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        source = self.root / "source"
        source.mkdir()
        subprocess.run(["git", "init", "--quiet", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(source), "config", "user.email", "test@example.com"], check=True)
        (source / "version").write_text("4.0.0.alpha\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(source), "add", "version"], check=True)
        environment = os.environ.copy()
        environment.update(
            {
                "GIT_AUTHOR_DATE": "2026-08-25T10:12:38Z",
                "GIT_COMMITTER_DATE": "2026-08-25T10:12:38Z",
            }
        )
        subprocess.run(
            ["git", "-C", str(source), "commit", "--quiet", "-m", "source"],
            check=True,
            env=environment,
        )
        self.commit = subprocess.check_output(
            ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
        ).strip()
        self.tree = subprocess.check_output(
            ["git", "-C", str(source), "rev-parse", "HEAD^{tree}"], text=True
        ).strip()
        self.origin = self.root / "origin.git"
        subprocess.run(["git", "clone", "--quiet", "--bare", str(source), str(self.origin)], check=True)
        self.spec = self.root / "spec.json"
        self.spec.write_text(
            json.dumps(
                {
                    "upstream": {
                        "repository": str(self.origin).removesuffix(".git"),
                        "commit": self.commit,
                        "tree": self.tree,
                    }
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def select_build_source(self, spec: Path) -> subprocess.CompletedProcess[str]:
        # Exercise the entrypoint's source selection without requiring root,
        # Linux, or the package/image assembly that follows it.
        build = BUILD.read_text(encoding="utf-8")
        selection = build[build.index('work=$(mkdir -p'):build.index('root=$(mktemp -d')]
        return subprocess.run(
            [
                "bash", "-euo", "pipefail", "-c",
                'work=$1; spec=$2; guest_dir=$3; source_dir=""; '
                'fail() { echo "$*" >&2; exit 1; };\n' + selection,
                "build-source-test", str(self.root / "work"), str(spec), str(GUEST),
            ],
            check=False, text=True, capture_output=True,
        )

    def test_build_caches_each_pin_without_rewriting_existing_sources(self) -> None:
        work = self.root / "work"
        work.mkdir()
        legacy = work / "omarchy-source"
        subprocess.run(["git", "clone", "--quiet", str(self.origin), str(legacy)], check=True)
        (legacy / "local-file").write_text("preserve me\n", encoding="utf-8")

        first = self.select_build_source(self.spec)
        self.assertEqual(first.returncode, 0, first.stderr)
        first_checkout = work / f"omarchy-source-{self.commit}"
        self.assertTrue((first_checkout / "version").is_file())

        source = self.root / "source"
        (source / "version").write_text("4.0.4\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(source), "commit", "--quiet", "-am", "release"], check=True)
        subprocess.run(["git", "-C", str(source), "push", "--quiet", str(self.origin), "HEAD"], check=True)
        new_commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        new_tree = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD^{tree}"], text=True).strip()
        new_spec = self.root / "new-spec.json"
        spec = json.loads(self.spec.read_text())
        spec["upstream"].update(commit=new_commit, tree=new_tree)
        new_spec.write_text(json.dumps(spec), encoding="utf-8")

        updated = self.select_build_source(new_spec)
        self.assertEqual(updated.returncode, 0, updated.stderr)
        self.assertEqual((work / f"omarchy-source-{new_commit}" / "version").read_text(), "4.0.4\n")
        self.assertEqual((first_checkout / "version").read_text(), "4.0.0.alpha\n")
        self.assertEqual((legacy / "local-file").read_text(), "preserve me\n")

        reused = self.select_build_source(self.spec)
        self.assertEqual(reused.returncode, 0, reused.stderr)
        self.assertIn("Using verified Omarchy checkout", reused.stdout)

        (first_checkout / "version").write_text("local change\n", encoding="utf-8")
        dirty = self.select_build_source(self.spec)
        self.assertNotEqual(dirty.returncode, 0)
        self.assertIn("is not the clean pinned Omarchy checkout", dirty.stderr)
        self.assertEqual((first_checkout / "version").read_text(), "local change\n")

    def test_recovers_an_interrupted_initial_fetch(self) -> None:
        destination = self.root / "checkout"
        subprocess.run(["git", "init", "--quiet", str(destination)], check=True)
        subprocess.run(
            ["git", "-C", str(destination), "remote", "add", "origin", str(self.origin)],
            check=True,
        )
        (destination / ".git/shallow.lock").write_text("interrupted\n", encoding="utf-8")

        result = subprocess.run(
            [str(FETCH_SOURCE), "--destination", str(destination), "--spec", str(self.spec)],
            check=True,
            text=True,
            capture_output=True,
        )

        self.assertEqual(
            subprocess.check_output(
                ["git", "-C", str(destination), "rev-parse", "HEAD"], text=True
            ).strip(),
            self.commit,
        )
        self.assertIn("Recovered verified Omarchy checkout", result.stdout)
        self.assertFalse((destination / ".git/shallow.lock").exists())

    def test_does_not_rewrite_a_valid_but_wrong_checkout(self) -> None:
        destination = self.root / "checkout"
        subprocess.run(["git", "clone", "--quiet", str(self.origin), str(destination)], check=True)
        (destination / "later").write_text("later\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(destination), "add", "later"], check=True)
        subprocess.run(["git", "-C", str(destination), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(destination), "config", "user.email", "test@example.com"], check=True)
        subprocess.run(["git", "-C", str(destination), "commit", "--quiet", "-m", "later"], check=True)

        result = subprocess.run(
            [str(FETCH_SOURCE), "--destination", str(destination), "--spec", str(self.spec)],
            check=False,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not the clean pinned Omarchy checkout", result.stderr)


if __name__ == "__main__":
    unittest.main()
