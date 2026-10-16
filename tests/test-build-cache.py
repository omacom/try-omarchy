#!/usr/bin/env python3

from __future__ import annotations

from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch


REPOSITORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "try_omarchy_build_cache", REPOSITORY / "scripts/build-cache.py"
)
assert SPEC is not None and SPEC.loader is not None
build_cache = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_cache)


FAKE_FACTORY = textwrap.dedent(
    r"""
    import hashlib
    import json
    from pathlib import Path


    def write_fake_factory(output, label):
        output.mkdir(parents=True, exist_ok=True)
        disk = f"disk {label}\n".encode()
        (output / "omarchy-aarch64-edge.img.zst").write_bytes(disk)
        factory = {
            "format": 1, "kind": "upstream-shell-factory", "boot": "uefi-limine",
            "compressed": {"path": "omarchy-aarch64-edge.img.zst", "sha256": hashlib.sha256(disk).hexdigest()},
        }
        (output / "factory.json").write_text(json.dumps(factory) + "\n")
        (output / "packages.txt").write_text(f"omarchy {label}\n")
        (output / "unavailable.txt").write_text("")
        names = ["factory.json", "omarchy-aarch64-edge.img.zst", "packages.txt", "unavailable.txt"]
        (output / "SHA256SUMS").write_text("".join(
            f"{hashlib.sha256((output / name).read_bytes()).hexdigest()}  {name}\n" for name in names
        ))
        (output / "packages").mkdir(exist_ok=True)
        (output / "packages/try-omarchy-0.1.0-1-aarch64.pkg.tar.zst").write_text(label)
    """
)

FAKE_GUEST_BUILDER = FAKE_FACTORY + textwrap.dedent(
    r"""
    import sys
    import time

    root = Path(sys.argv[1])
    mode = sys.argv[2]
    count_path = root / "build-count"
    count = int(count_path.read_text()) + 1 if count_path.exists() else 1
    count_path.write_text(f"{count}\n")
    if mode == "fail":
        raise SystemExit(23)
    if mode == "slow":
        time.sleep(0.2)
    if mode == "mutate":
        (root / "guest/build.input").write_text("changed during build\n")

    write_fake_factory(root / "dist/guest", f"build {count}")
    """
)


class BuildCacheTests(unittest.TestCase):
    def test_app_fingerprint_tracks_the_bundled_package_and_firmware(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "dist/guest/packages/try-omarchy-0.1.0-1-aarch64.pkg.tar.zst"
            firmware = root / "macos/.build/firmware/edk2-aarch64-code.fd"
            for path in (package, firmware):
                path.parent.mkdir(parents=True)
                path.write_text("initial\n")
            for path in build_cache.component_files(root, "app"):
                if not path.exists():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("fixture\n")
            with patch.object(build_cache, "context", return_value={}), \
                    patch.object(build_cache, "build_version", return_value={}), \
                    patch.object(build_cache, "app_external_files", return_value=[]):
                previous = build_cache.fingerprint(root, "app", ["build-app"])
                for path in (package, firmware):
                    path.write_text("updated\n")
                    current = build_cache.fingerprint(root, "app", ["build-app"])
                    self.assertNotEqual(previous, current, path.name)
                    previous = current

    def test_runtime_fingerprint_tracks_compiled_graphics_regressions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            regression = root / "macos/Tests/virgl/test-multisample-formats.c"
            regression.parent.mkdir(parents=True)
            regression.write_text("initial graphics regression\n")
            for path in build_cache.component_files(root, "runtime"):
                if not path.exists():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("fixture\n")
            with patch.object(build_cache, "context", return_value={}):
                previous = build_cache.fingerprint(root, "runtime", ["build-runtime"])
                regression.write_text("updated graphics regression\n")
                current = build_cache.fingerprint(root, "runtime", ["build-runtime"])
            self.assertNotEqual(previous, current)

    @staticmethod
    def prepare_fake_guest(root: Path) -> None:
        (root / "guest").mkdir()
        (root / "guest/build.input").write_text("initial\n")
        (root / "LICENSE").write_text("license\n")

    def test_make_orders_components_and_propagates_force(self) -> None:
        dry_run = subprocess.run(
            ["make", "-n", "build"],
            cwd=REPOSITORY,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        ).stdout
        package = dry_run.index(" guest-package --")
        guest = dry_run.index(" guest --")
        runtime = dry_run.index(" runtime --")
        app = dry_run.index(" app --")
        self.assertLess(package, guest)
        self.assertIn("--factory-only", dry_run[guest:runtime])
        self.assertIn('OMARCHY_DOWNLOAD_CACHE="' + str(REPOSITORY / ".build/downloads") + '"', dry_run)
        self.assertLess(guest, runtime)
        self.assertLess(runtime, app)
        self.assertIn("Build output:", dry_run)
        self.assertIn(
            str(REPOSITORY / "dist/app.noindex/Try Omarchy.app"), dry_run
        )

        forced = subprocess.run(
            ["make", "-n", "build", "FORCE=1"],
            cwd=REPOSITORY,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        ).stdout
        self.assertEqual(4, forced.count('OMARCHY_FORCE_BUILD="1"'))
        self.assertIn("stage-uefi-firmware.sh", forced)

        invalid_release = subprocess.run(
            ["make", "release", "RELEASE_SIGN_IDENTITY=invalid"],
            cwd=REPOSITORY,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.assertNotEqual(0, invalid_release.returncode)
        self.assertNotIn("build-cache.py", invalid_release.stdout)

    def test_development_app_is_excluded_from_spotlight(self) -> None:
        build_script = (REPOSITORY / "macos/build-app.sh").read_text()
        open_script = (REPOSITORY / "macos/open-qemu-gpu.sh").read_text()
        self.assertIn(
            'app="$repo_dir/dist/app.noindex/Try Omarchy.app"',
            build_script,
        )
        self.assertIn(
            'legacy_app="$repo_dir/dist/Try Omarchy.app"',
            build_script,
        )
        self.assertIn('rm -rf -- "$legacy_app"', build_script)
        self.assertNotIn(".metadata_never_index", build_script)
        self.assertIn(
            'app="$repo_dir/dist/app.noindex/Try Omarchy.app"',
            open_script,
        )

    def test_runtime_file_manifest_is_the_single_validated_closure(self) -> None:
        manifest = REPOSITORY / "macos/runtime-files.txt"
        expected = frozenset(manifest.read_text(encoding="ascii").splitlines())
        self.assertEqual(expected, build_cache.RUNTIME_FILES)
        self.assertEqual(17, len(expected))
        self.assertIn("bin/qemu-system-aarch64", expected)
        self.assertIn("bin/zstd", expected)
        self.assertIn("lib/libSDL3.dylib", expected)
        self.assertIn("lib/libusb-1.0.0.dylib", expected)

        with tempfile.TemporaryDirectory() as temporary:
            invalid = Path(temporary) / "runtime-files.txt"
            for contents in (
                "",
                "bin/tool\nbin/tool\n",
                "../outside\n",
                "bin//tool\n",
                "lib/nested/tool\n",
            ):
                invalid.write_text(contents, encoding="ascii")
                with self.assertRaises(RuntimeError):
                    build_cache.read_runtime_manifest(invalid)

    def test_guest_fingerprint_tracks_build_inputs_but_not_documentation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "guest/package/tests").mkdir(parents=True)
            (root / "guest/package/__pycache__").mkdir(parents=True)
            (root / "guest/build.sh").write_text("one\n")
            (root / "LICENSE").write_text("license\n")
            (root / "guest/package/README.md").write_text("first docs\n")
            (root / "guest/package/tests/example.py").write_text("first test\n")
            bytecode = root / "guest/package/__pycache__/helper.pyc"
            bytecode.write_bytes(b"first transient bytecode\n")
            command = [
                str(root / "guest/build.sh"),
                "--output",
                str(root / "dist/guest"),
            ]

            original = build_cache.fingerprint(root, "guest", command)
            (root / "guest/package/README.md").write_text("second docs\n")
            (root / "guest/package/tests/example.py").write_text("second test\n")
            bytecode.write_bytes(b"second transient bytecode\n")
            self.assertEqual(original, build_cache.fingerprint(root, "guest", command))

            (root / "guest/build.sh").write_text("two\n")
            self.assertNotEqual(
                original, build_cache.fingerprint(root, "guest", command)
            )

    def test_a_package_change_rebuilds_the_package_not_the_factory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recipe = root / "guest/package/try-omarchy/PKGBUILD"
            script = root / "guest/package/try-omarchy/files/usr/lib/try-omarchy/menu-entries"
            console = root / "guest/package/try-omarchy/files/etc/limine-entry-tool.d/50-console.conf"
            for path in (recipe, script, console, root / "guest/factory/build-image.sh"):
                path.parent.mkdir(parents=True, exist_ok=True)
            recipe.write_text("pkgrel=1\ndepends=(\n  'bash'\n)\noptdepends=(\n  'wf-recorder: x'\n)\n")
            script.write_text("one\n")
            console.write_text("console=hvc0\n")
            (root / "guest/factory/build-image.sh").write_text("factory\n")
            (root / "LICENSE").write_text("license\n")
            factory = [str(root / "guest/build.sh"), "--factory-only"]
            package = [str(root / "guest/package/build.sh")]
            factory_before = build_cache.fingerprint(root, "guest", factory)
            package_before = build_cache.fingerprint(root, "guest-package", package)

            # Package contents and a release bump reach VMs through the app.
            script.write_text("two\n")
            recipe.write_text(recipe.read_text().replace("pkgrel=1", "pkgrel=2"))
            self.assertEqual(factory_before, build_cache.fingerprint(root, "guest", factory))
            self.assertNotEqual(package_before, build_cache.fingerprint(root, "guest-package", package))

            # What the factory bakes in: the boot image's command line and
            # the dependencies it installs.
            console.write_text("console=hvc0 quiet\n")
            after_console = build_cache.fingerprint(root, "guest", factory)
            self.assertNotEqual(factory_before, after_console)
            recipe.write_text(recipe.read_text().replace("'wf-recorder: x'", "'wf-recorder: x'\n  'mpv: y'"))
            self.assertNotEqual(after_console, build_cache.fingerprint(root, "guest", factory))

    def test_pinned_downloads_are_kept_and_verified(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            archive = work / "fresh/qemu-1.tar.gz"
            archive.parent.mkdir()
            archive.write_bytes(b"pinned archive\n")
            pin = hashlib.sha256(b"pinned archive\n").hexdigest()
            script = f"""
                set -euo pipefail
                log() {{ :; }}; die() {{ echo "$*" >&2; exit 1; }}
                source "{REPOSITORY / 'macos/pinned-runtime-bottles.sh'}"
                pinned_download_to_cache "{archive}"
                mkdir -p "{work}/out"
                pinned_download_from_cache {pin} "{work}/out/qemu-1.tar.gz" && echo hit
                pinned_download_from_cache {'0' * 64} "{work}/out/other.tar.gz" || echo "wrong pin misses"
            """
            result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True,
                                    env={**os.environ, "OMARCHY_DOWNLOAD_CACHE": str(work / "cache")})
            self.assertEqual(result.stdout.split("\n")[:2], ["hit", "wrong pin misses"])
            self.assertEqual((work / "cache/qemu-1.tar.gz").read_bytes(), b"pinned archive\n")
            # A corrupted cache entry is never used.
            (work / "cache/qemu-1.tar.gz").write_bytes(b"tampered\n")
            missed = subprocess.run(["bash", "-c", script.replace("pinned_download_to_cache", ": ")],
                                    capture_output=True, text=True, check=True,
                                    env={**os.environ, "OMARCHY_DOWNLOAD_CACHE": str(work / "cache")})
            self.assertNotIn("hit", missed.stdout)

    def test_guest_validation_checks_manifest_and_successful_output_snapshot(
        self,
    ) -> None:
        namespace: dict[str, object] = {}
        exec(FAKE_FACTORY, namespace)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "dist/guest"
            namespace["write_fake_factory"](output, "one")

            snapshot = build_cache.validate_guest(root, None)
            self.assertEqual(
                snapshot, build_cache.validate_guest(root, {"outputs": snapshot})
            )

            # Rebuilding only the package keeps the factory current.
            package = next((output / "packages").iterdir())
            package.write_text("rebuilt package")
            self.assertEqual(snapshot, build_cache.validate_guest(root, {"outputs": snapshot}))

            artifact = output / "omarchy-aarch64-edge.img.zst"
            metadata = artifact.stat()
            os.utime(artifact, ns=(metadata.st_atime_ns, metadata.st_mtime_ns + 1))
            with self.assertRaisesRegex(build_cache.CacheError, "metadata changed"):
                build_cache.validate_guest(root, {"outputs": snapshot})

            artifact.write_bytes(b"other disk\n")
            with self.assertRaisesRegex(build_cache.CacheError, "SHA256SUMS|checksum"):
                namespace_sums = (output / "SHA256SUMS").read_text()
                (output / "SHA256SUMS").write_text(namespace_sums.replace(
                    namespace_sums.split()[2], "0" * 64, 1))
                build_cache.validate_guest(root, None)

            namespace["write_fake_factory"](output, "two")
            (package.parent / "try-omarchy-0.1.0-2-aarch64.pkg.tar.zst").write_text("second")
            with self.assertRaisesRegex(build_cache.CacheError, "exactly one try-omarchy package"):
                build_cache.validate_guest(root, None)

    def test_app_validation_requires_packaged_icon(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "dist/app.noindex/Try Omarchy.app"
            for relative in (
                "Contents/MacOS/omarchy-vm-helper",
                "Contents/Resources/runtime/bin/Try Omarchy",
                "Contents/Resources/guest/factory.json",
                "Contents/Resources/guest/omarchy-aarch64-edge.img.zst",
                "Contents/Resources/firmware/edk2-aarch64-code.fd",
            ):
                path = app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture\n")

            with self.assertRaisesRegex(
                build_cache.CacheError, "app bundle is missing or unsafe"
            ):
                build_cache.validate_app(root, None)

    def test_app_fingerprint_tracks_git_version_without_source_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in (
                "macos/Info.plist", "LICENSE", ".build/state/guest.json",
                ".build/state/runtime.json", "dist/guest/factory.json",
                "dist/guest/SHA256SUMS",
                *(f"macos/.build/qemu-gpu-runtime/{name}" for name in build_cache.RUNTIME_FILES),
            ):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture\n")
            (root / ".gitignore").write_text("/dist/\n/.build/\n/macos/.build/\n")

            def git(*arguments: str) -> None:
                subprocess.run(
                    ["git", "-C", str(root), *arguments],
                    check=True, capture_output=True,
                )

            git("init", "-q")
            git("config", "user.name", "Cache Tests")
            git("config", "user.email", "cache-tests@example.invalid")
            git("add", ".")
            git("commit", "-qm", "Initial source")

            def fingerprint() -> str:
                return build_cache.fingerprint(root, "app", ["build-app"])

            untagged = fingerprint()
            git("tag", "v1.2.3")
            tagged = fingerprint()
            self.assertNotEqual(untagged, tagged)

            # A file outside the app inputs still makes its version dirty.
            untracked = root / "notes.txt"
            untracked.write_text("untracked\n")
            dirty = fingerprint()
            self.assertNotEqual(tagged, dirty)
            untracked.unlink()
            self.assertEqual(tagged, fingerprint())

            source = root / "macos/Info.plist"
            source.write_text("edited\n")
            dirty = fingerprint()
            git("add", ".")
            git("commit", "-qm", "Edit source")
            committed = fingerprint()
            self.assertNotEqual(dirty, committed)

            git("commit", "--allow-empty", "-qm", "Advance HEAD")
            self.assertNotEqual(committed, fingerprint())
            stable = fingerprint()
            (root / "dist/build-log").write_text("ignored output\n")
            self.assertEqual(stable, fingerprint())

    def test_state_write_is_readable_and_replaces_old_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state/component.json"
            first = {"schemaVersion": build_cache.SCHEMA_VERSION, "fingerprint": "one"}
            second = {"schemaVersion": build_cache.SCHEMA_VERSION, "fingerprint": "two"}
            build_cache.write_state(state, first)
            self.assertEqual(first, build_cache.read_state(state))
            build_cache.write_state(state, second)
            self.assertEqual(second, build_cache.read_state(state))

    def test_cached_runner_skips_rebuilds_and_never_stamps_bad_builds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.prepare_fake_guest(root)
            build_input = root / "guest/build.input"
            state_dir = root / ".build/state"

            def invoke(mode: str = "good", *, force: bool = False) -> None:
                command = [sys.executable, "-c", FAKE_GUEST_BUILDER, str(root), mode]
                with redirect_stdout(io.StringIO()):
                    build_cache.run(root, state_dir, "guest", command, force)

            invoke()
            self.assertEqual("1", (root / "build-count").read_text().strip())
            self.assertTrue((state_dir / "guest.json").is_file())

            invoke()
            self.assertEqual("1", (root / "build-count").read_text().strip())

            build_input.write_text("edited\n")
            invoke()
            self.assertEqual("2", (root / "build-count").read_text().strip())

            invoke(force=True)
            self.assertEqual("3", (root / "build-count").read_text().strip())

            with (root / "dist/guest/omarchy-aarch64-edge.img.zst").open("ab") as stream:
                stream.write(b"tampered")
            invoke()
            self.assertEqual("4", (root / "build-count").read_text().strip())

            with self.assertRaisesRegex(build_cache.CacheError, "exit status 23"):
                invoke("fail")
            self.assertFalse((state_dir / "guest.json").exists())

            invoke()
            self.assertTrue((state_dir / "guest.json").is_file())
            with self.assertRaisesRegex(build_cache.CacheError, "inputs changed"):
                invoke("mutate")
            self.assertFalse((state_dir / "guest.json").exists())

    def test_concurrent_builds_share_the_component_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.prepare_fake_guest(root)
            build_command = [
                sys.executable,
                "-c",
                FAKE_GUEST_BUILDER,
                str(root),
                "slow",
            ]
            wrapper = [
                sys.executable,
                str(REPOSITORY / "scripts/build-cache.py"),
                "--root",
                str(root),
                "--state-dir",
                str(root / ".build/state"),
                "guest",
                "--",
                *build_command,
            ]
            first = subprocess.Popen(
                wrapper, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
            second = subprocess.Popen(
                wrapper, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
            first_output, _ = first.communicate(timeout=10)
            second_output, _ = second.communicate(timeout=10)
            self.assertEqual(0, first.returncode, first_output)
            self.assertEqual(0, second.returncode, second_output)
            self.assertEqual("1", (root / "build-count").read_text().strip())
            combined = first_output + second_output
            self.assertEqual(1, combined.count("recorded successful guest build"))
            self.assertEqual(1, combined.count("guest is up to date"))


if __name__ == "__main__":
    unittest.main()
