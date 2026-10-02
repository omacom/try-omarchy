import importlib.util
import json
import sys
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

    def test_builder_installs_held_packages_without_changing_guest_config(self):
        guest_config = GUEST / "pacman.aarch64.conf"
        original = guest_config.read_text()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "pacman.conf"
            builder.write_builder_config(
                guest_config=guest_config,
                output=output,
                package_cache=Path(directory) / "cache",
                disable_sandbox=True,
                pinned_cache_repo=None,
            )
            config = output.read_text()
        self.assertEqual(guest_config.read_text(), original)
        self.assertIn("hyprland aquamarine hyprtoolkit hyprland-guiutils\n", original)
        self.assertNotIn("IgnorePkg", config)
        self.assertIn("DisableSandbox\n", config)
        self.assertIn(f"CacheDir = {directory}/cache\n", config)

    def test_mirror_only_replaces_arm_mirrors_in_builder(self):
        guest_config = GUEST / "pacman.aarch64.conf"
        original = guest_config.read_text()
        mirrors = self.spec["inputs"]["packageRepositoryMirrors"]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "pacman.conf"
            builder.write_builder_config(
                guest_config=guest_config,
                output=output,
                package_cache=None,
                disable_sandbox=False,
                pinned_cache_repo=None,
                repository_mirrors=mirrors,
            )
            config = output.read_text()
        self.assertEqual(guest_config.read_text(), original)
        for mirror in mirrors:
            self.assertEqual(config.count(f"Server = {mirror}/$repo"), 4)
        self.assertLess(config.index(mirrors[0]), config.index(mirrors[1]))
        self.assertNotIn("Include = /etc/pacman.d/mirrorlist", config)
        self.assertIn("SigLevel = Required DatabaseOptional", config)
        self.assertIn("ParallelDownloads = 5", config)
        self.assertIn("ParallelDownloads = 5", original)
        self.assertNotIn("XferCommand", config)
        self.assertNotIn("XferCommand", original)
        self.assertNotIn("DownloadUser", config)
        self.assertIn("DownloadUser = alpm", original)
        self.assertIn("Server = https://pkgs.omarchy.org/$arch", config)

    def test_mirror_rejects_insecure_urls_and_configuration_injection(self):
        for mirror in (
            "http://ca.us.mirror.archlinuxarm.org/aarch64",
            "https://example.org/aarch64\n[untrusted]",
        ):
            with self.subTest(mirror=mirror), tempfile.TemporaryDirectory() as directory:
                spec_path = Path(directory) / "spec.json"
                self.spec["inputs"]["packageRepositoryMirrors"] = [mirror]
                spec_path.write_text(json.dumps(self.spec))
                output = Path(directory) / "pacman.conf"
                arguments = [
                    "write-builder-pacman-conf.py",
                    "--spec", str(spec_path),
                    "--guest-config", str(GUEST / "pacman.aarch64.conf"),
                    "--output", str(output),
                ]
                with patch.object(sys, "argv", arguments):
                    with self.assertRaisesRegex(SystemExit, "HTTPS ARM mirror URL"):
                        builder.main()
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
