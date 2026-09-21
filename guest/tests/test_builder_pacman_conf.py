import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


GUEST = Path(__file__).resolve().parents[1]
MODULE = importlib.util.spec_from_file_location(
    "builder_pacman_conf", GUEST / "scripts/write-builder-pacman-conf.py"
)
builder = importlib.util.module_from_spec(MODULE)
MODULE.loader.exec_module(builder)


class BuilderPacmanConfigTests(unittest.TestCase):
    def setUp(self):
        self.spec = json.loads((GUEST / "spec.json").read_text())
        self.lock = json.loads((GUEST / "packages.lock.json").read_text())["packages"]

    def test_builder_exposes_pair_without_changing_guest_holds(self):
        guest_config = GUEST / "pacman.aarch64.conf"
        original = guest_config.read_text()
        pins = builder.load_abi_pins(self.spec, self.lock)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "pacman.conf"
            builder.write_builder_config(
                guest_config=guest_config,
                output=output,
                package_cache=None,
                disable_sandbox=True,
                abi_repo=Path(directory) / "abi-repo",
                pinned_cache_repo=None,
                drop_ignore={pin["name"] for pin in pins},
            )
            config = output.read_text()
        self.assertEqual(guest_config.read_text(), original)
        self.assertIn("hyprland aquamarine hyprtoolkit\n", original)
        self.assertIn("IgnorePkg = linux-aarch64 linux-aarch64-headers hyprland\n", config)
        self.assertLess(config.index("[try-omarchy-abi-pins]"), config.index("[extra]"))
        self.assertIn("DisableSandbox\n", config)

    def test_missing_toolkit_archive_is_rejected(self):
        pins = builder.load_abi_pins(self.spec, self.lock)
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / "aquamarine-0.14.0-2-aarch64.pkg.tar.zst").touch()
            (repo / "try-omarchy-abi-pins.db.tar.gz").touch()
            with self.assertRaisesRegex(SystemExit, "hyprtoolkit"):
                builder.ensure_abi_repo(pins, repo)

    def test_snapshot_only_replaces_arm_mirrors_in_builder(self):
        guest_config = GUEST / "pacman.aarch64.conf"
        original = guest_config.read_text()
        snapshot = self.spec["inputs"]["packageRepositorySnapshot"]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "pacman.conf"
            builder.write_builder_config(
                guest_config=guest_config,
                output=output,
                package_cache=None,
                disable_sandbox=False,
                abi_repo=None,
                pinned_cache_repo=None,
                drop_ignore=set(),
                repository_snapshot=snapshot,
            )
            config = output.read_text()
        self.assertEqual(guest_config.read_text(), original)
        self.assertEqual(config.count(f"Server = {snapshot}/$repo"), 4)
        self.assertNotIn("Include = /etc/pacman.d/mirrorlist", config)
        self.assertIn("SigLevel = Required DatabaseOptional", config)
        self.assertIn("ParallelDownloads = 1", config)
        self.assertIn("ParallelDownloads = 5", original)
        self.assertIn("XferCommand = /usr/bin/curl", config)
        self.assertIn("--retry 8", config)
        self.assertNotIn("XferCommand", original)
        self.assertNotIn("DownloadUser", config)
        self.assertIn("DownloadUser = alpm", original)
        self.assertIn("Server = https://pkgs.omarchy.org/$arch", config)

    def test_mirror_toolkit_version_cannot_replace_the_reviewed_pin(self):
        self.lock["hyprtoolkit"] = "0.5.4-6"
        with self.assertRaisesRegex(SystemExit, "does not match lock"):
            builder.load_abi_pins(self.spec, self.lock)

    def test_complete_signed_cache_includes_epochs_and_both_archive_formats(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "cache"
            cache.mkdir()
            for name in ("mesa-1:26.2.2-1-aarch64.pkg.tar.xz", "rpm-tools-6.0.1-2-aarch64.pkg.tar.zst"):
                (cache / name).write_text("package")
                (cache / (name + ".sig")).write_text("signature")
            repository = Path(directory) / "repository"
            with patch.object(builder.subprocess, "run") as run:
                self.assertTrue(builder.prepare_locked_cache(
                    cache, repository,
                    {"mesa": "1:26.2.2-1", "rpm-tools": "6.0.1-2",
                     "aquamarine": "0.14.0-2", "omarchy-keyring": "20251027-1"},
                    {"aquamarine"},
                ))
            run.assert_called_once()
            self.assertEqual(len(list(repository.iterdir())), 4)

    def test_incomplete_or_unsigned_cache_keeps_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            (cache / "mesa-1:26.2.2-1-aarch64.pkg.tar.xz").touch()
            repository = cache / "repository"
            with patch.object(builder.subprocess, "run") as run:
                self.assertFalse(builder.prepare_locked_cache(
                    cache, repository, {"mesa": "1:26.2.2-1"}, set(),
                ))
                self.assertFalse(builder.prepare_locked_cache(
                    cache, repository, {"missing": "1-1"}, set(),
                ))
            run.assert_not_called()
            self.assertFalse(repository.exists())


if __name__ == "__main__":
    unittest.main()
