import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

GUEST = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("locked_cache", GUEST / "scripts/prepare-locked-package-cache.py")
cache_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache_module)


class LockedPackageCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / "cache"
        self.output = self.root / "repository"
        self.cache.mkdir()
        self.output.mkdir()

    def archive(self, filename, signed=True):
        path = self.cache / filename
        path.write_bytes(b"package")
        if signed:
            Path(str(path) + ".sig").write_bytes(b"signature")
        return path

    def test_build_only_packages_are_included_without_changing_factory_pins(self):
        factory = {"shared": "1-1"}
        self.assertEqual(cache_module.reviewed_packages(factory, {"shared": "1-1", "compiler": "2-1"}),
                         {"shared": "1-1", "compiler": "2-1"})
        self.assertEqual(factory, {"shared": "1-1"})
        with self.assertRaisesRegex(ValueError, "conflicting"):
            cache_module.reviewed_packages(factory, {"shared": "2-1"})

    def test_hyprland_builder_retains_cache_but_removes_guest_repository_and_holds(self):
        script = (GUEST / "scripts/register-patched-hyprland.sh").read_text()
        program = script.split('<<\'PY\' || fail "could not derive the Hyprland builder pacman configuration"\n', 1)[1].split("\nPY\n", 1)[0]
        source = self.root / "source.conf"
        output = self.root / "builder.conf"
        source.write_text("[options]\nIgnorePkg = hyprland\n[try-omarchy-pinned-cache]\nServer = file:///cache\n[core]\nServer = https://mirror.example/core\n[omarchy]\nServer = https://pkgs.omarchy.org/aarch64\n")
        import sys
        subprocess.run([sys.executable, "-c", program, str(source), str(output)], check=True)
        result = output.read_text()
        self.assertIn("[try-omarchy-pinned-cache]\nServer = file:///cache", result)
        self.assertIn("[core]", result)
        self.assertNotIn("omarchy", result.replace("try-omarchy-pinned-cache", "cache"))
        self.assertNotIn("IgnorePkg", result)

    def test_only_complete_exact_locked_versions_are_selected(self):
        wanted = self.archive("fixture-1.2-3-aarch64.pkg.tar.xz")
        self.archive("fixture-1.3-1-aarch64.pkg.tar.zst")
        self.archive("unsigned-1-1-any.pkg.tar.zst", signed=False)
        self.assertEqual(cache_module.select_archives(self.cache, {"fixture": "1.2-3", "unsigned": "1-1"}, []),
                         [("fixture", "1.2-3", wanted)])

    def test_epoch_names_and_any_architecture_are_supported(self):
        epoch = self.archive("first-2:1.0-1-aarch64.pkg.tar.xz")
        plain = self.archive("second-1.0-1-any.pkg.tar.zst")
        self.assertEqual(cache_module.select_archives(self.cache, {"first": "2:1.0-1", "second": "2:1.0-1"}, []),
                         [("first", "2:1.0-1", epoch), ("second", "2:1.0-1", plain)])

    def test_missing_required_pin_and_ambiguous_archives_stop(self):
        with self.assertRaisesRegex(ValueError, "required signed cache pin"):
            cache_module.select_archives(self.cache, {"fixture": "1-1"}, ["fixture"])
        self.archive("fixture-1-1-any.pkg.tar.zst")
        self.archive("fixture-1-1-aarch64.pkg.tar.xz")
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            cache_module.select_archives(self.cache, {"fixture": "1-1"}, [])

    def test_symlinked_archive_is_refused(self):
        target = self.root / "external"
        target.write_bytes(b"package")
        archive = self.cache / "fixture-1-1-any.pkg.tar.zst"
        archive.symlink_to(target)
        Path(str(archive) + ".sig").write_bytes(b"signature")
        with self.assertRaisesRegex(ValueError, "symlinked"):
            cache_module.select_archives(self.cache, {"fixture": "1-1"}, [])

    def test_bad_signature_cannot_publish_package_or_database(self):
        self.archive("fixture-1-1-any.pkg.tar.zst")
        with patch.object(cache_module.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "pacman-key")):
            with self.assertRaises(subprocess.CalledProcessError):
                cache_module.prepare(self.cache, self.output, {"fixture": "1-1"}, [])
        self.assertEqual(list(self.output.iterdir()), [])

    def test_signed_package_with_wrong_identity_is_refused(self):
        self.archive("fixture-1-1-any.pkg.tar.zst")
        for metadata in ("pkgname = other\npkgver = 1-1\narch = any\n",
                         "pkgname = fixture\npkgver = 2-1\narch = any\n",
                         "pkgname = fixture\npkgver = 1-1\narch = x86_64\n"):
            with self.subTest(metadata=metadata), patch.object(cache_module.subprocess, "run"), \
                    patch.object(cache_module.subprocess, "check_output", return_value=metadata):
                with self.assertRaisesRegex(ValueError, "lock identity"):
                    cache_module.prepare(self.cache, self.output, {"fixture": "1-1"}, [])
        self.assertEqual(list(self.output.iterdir()), [])

    def test_verified_package_and_signature_reach_local_repository(self):
        archive = self.archive("fixture-1-1-any.pkg.tar.zst")
        with patch.object(cache_module.subprocess, "run") as run, \
                patch.object(cache_module.subprocess, "check_output", return_value="pkgname = fixture\npkgver = 1-1\narch = any\n"):
            cache_module.prepare(self.cache, self.output, {"fixture": "1-1"}, [])
        self.assertEqual((self.output / archive.name).read_bytes(), b"package")
        self.assertEqual((self.output / (archive.name + ".sig")).read_bytes(), b"signature")
        self.assertEqual(run.call_args_list[0].args[0][0], "pacman-key")
        self.assertEqual(run.call_args_list[1].args[0][0], "repo-add")


if __name__ == "__main__":
    unittest.main()
