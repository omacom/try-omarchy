import contextlib
import importlib.util
import io
import tarfile
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

GUEST = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, GUEST / "scripts" / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


migration = load("migrate-stable-arm-repository")
keyring = load("prepare-omarchy-keyring")
LEGACY = """# custom settings
[options]
IgnorePkg = linux-aarch64 hyprland hyprland-guiutils custom
[try-omarchy]
SigLevel = Optional TrustAll
Server = file:///usr/share/try-omarchy/repo
[extra]
Include = /etc/pacman.d/mirrorlist
[omarchy]
SigLevel = Optional TrustAll # keep signature comment
Server = https://pkgs.omarchy.org/$arch # keep server comment
[custom]
Server = https://example.com/$arch
"""


class StableArmRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        output = contextlib.redirect_stdout(io.StringIO())
        output.__enter__()
        self.addCleanup(output.__exit__, None, None, None)
        for relative in migration.CONFIGS:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(LEGACY)
            path.chmod(0o640)
        path = self.root / migration.DENYLIST
        path.parent.mkdir(parents=True)
        path.write_text("# custom list\ncursor-bin\tCursor\nspotify\tSpotify\ncustom\tCustom\n")
        (self.root / "usr/bin").mkdir()
        for fixture in (GUEST / "tests/fixtures/arm-channel").iterdir():
            shutil.copy2(fixture, self.root / "usr/bin" / fixture.name)
        (self.root / "var/lib/pacman").mkdir(parents=True)

    def files(self):
        return {str(path.relative_to(self.root)): path.read_bytes()
                for path in self.root.rglob("*") if path.is_file()}

    def test_preserves_holds_other_repositories_comments_and_line_endings(self):
        for original in (LEGACY, LEGACY.replace("\n", "\r\n")):
            with self.subTest(crlf="\r" in original):
                result = migration.update_config(original)
                self.assertEqual(result.split("[omarchy]")[0], original.split("[omarchy]")[0])
                self.assertEqual(result.split("[custom]")[1], original.split("[custom]")[1])
                self.assertIn("# keep signature comment", result)
                self.assertIn("# keep server comment", result)
                self.assertIn(migration.STABLE, result)
                self.assertIn(migration.SIGNATURE_POLICY, result)
                self.assertEqual(migration.update_config(result), result)
                if "\r" in original:
                    self.assertNotIn("\n", result.replace("\r\n", ""))

    def test_adds_explicit_signature_policy_when_absent(self):
        text = "[omarchy]\nServer = " + migration.LEGACY
        result = migration.update_config(text)
        self.assertIn("[omarchy]\nSigLevel = " + migration.SIGNATURE_POLICY, result)
        self.assertEqual(migration.update_config(result), result)

    def test_refuses_ambiguous_custom_or_nonstable_repositories(self):
        variants = [LEGACY + "\n[omarchy]\n",
                    LEGACY.replace(migration.LEGACY, "https://pkgs.omarchy.org/edge/$arch"),
                    LEGACY.replace(migration.LEGACY, "https://example.com/$arch"),
                    LEGACY.replace("[omarchy]", "[omarchy]\nInclude = /custom"),
                    LEGACY.replace("[omarchy]", "[omarchy]\nCacheServer = https://example.com"),
                    LEGACY.replace("[omarchy]", "[omarchy]\nServer = " + migration.LEGACY)]
        for text in variants:
            with self.subTest(text=text), self.assertRaises(ValueError):
                migration.update_config(text)

    def test_preview_is_offline_and_changes_nothing(self):
        before = self.files()
        with patch.object(migration, "keyring_plans") as prepare:
            migration.migrate(self.root)
            prepare.assert_not_called()
        self.assertEqual(self.files(), before)

    def test_older_guest_without_refusal_helper_or_list_can_migrate(self):
        (self.root / migration.DENYLIST).unlink()
        migration.apply_plans(self.root, migration.plan(self.root))
        self.assertFalse((self.root / migration.DENYLIST).exists())
        self.assertIn(migration.STABLE, (self.root / migration.CONFIGS[0]).read_text())
        before = self.files()
        migration.apply_plans(self.root, migration.plan(self.root))
        self.assertEqual(self.files(), before)

    def test_missing_list_with_installed_refusal_helper_requires_review(self):
        (self.root / migration.DENYLIST).unlink()
        helper = self.root / "usr/local/bin/omarchy-pkg-refuse-aarch64-unavailable"
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_text("#!/bin/bash\n")
        before = self.files()
        with self.assertRaisesRegex(ValueError, "package list is missing"):
            migration.plan(self.root)
        self.assertEqual(self.files(), before)

    def test_apply_preserves_independent_settings_modes_refresh_and_repeat(self):
        active = self.root / migration.CONFIGS[1]
        active.write_text(LEGACY.replace("custom\n", "active-only\n"))
        before = self.files()
        plans = migration.plan(self.root)
        migration.apply_plans(self.root, plans)
        for relative in migration.CONFIGS:
            path = self.root / relative
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
        self.assertIn("active-only", active.read_text())
        backup, = (self.root / "var/lib/try-omarchy").iterdir()
        for path, original, _ in plans:
            self.assertEqual((backup / path.relative_to(self.root)).read_bytes(), original)
        self.assertNotIn("cursor-bin", (self.root / migration.DENYLIST).read_text())
        self.assertIn("custom\tCustom", (self.root / migration.DENYLIST).read_text())
        # Exercise the same saved-to-active copy as pre-refresh-pacman.
        active.write_bytes((self.root / migration.CONFIGS[0]).read_bytes())
        self.assertIn(migration.STABLE, active.read_text())
        migrated = self.files()
        migration.apply_plans(self.root, migration.plan(self.root))
        self.assertEqual(self.files(), migrated)
        self.assertNotEqual(migrated[migration.CONFIGS[0]], before[migration.CONFIGS[0]])

    def test_modified_command_stops_before_configuration_changes(self):
        (self.root / "usr/bin/omarchy-version-channel").write_text("custom command\n")
        before = self.files()
        with self.assertRaisesRegex(ValueError, "modified or unsupported"):
            migration.migrate(self.root, apply=True)
        self.assertEqual(self.files(), before)

    def test_rejects_symlinked_file_and_parent(self):
        path = self.root / migration.CONFIGS[1]
        path.unlink()
        path.symlink_to(self.root / migration.CONFIGS[0])
        with self.assertRaisesRegex(ValueError, "symlinked"):
            migration.plan(self.root)
        alias = self.root / "alias"
        alias.symlink_to(self.root / "usr/share/try-omarchy", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked"):
            migration.regular(self.root, "alias/pacman.conf")

    def test_preserves_active_pacman_lock(self):
        lock = self.root / "var/lib/pacman/db.lck"
        lock.write_text("active")
        before = self.files()
        with self.assertRaises(FileExistsError):
            migration.apply_plans(self.root, migration.plan(self.root))
        self.assertEqual(self.files(), before)

    def test_detects_concurrent_configuration_change(self):
        plans = migration.plan(self.root)
        (self.root / migration.CONFIGS[0]).write_text("changed meanwhile")
        before = self.files()
        with self.assertRaisesRegex(ValueError, "input changed"):
            migration.apply_plans(self.root, plans)
        self.assertEqual(self.files(), before)

    def test_write_failure_rolls_back_existing_and_new_files(self):
        existing = self.root / migration.CONFIGS[0]
        new = self.root / "etc/new-file"
        last = self.root / migration.CONFIGS[1]
        original = existing.read_bytes()
        plans = [(existing, original, b"changed"), (new, None, b"new"),
                 (last, last.read_bytes(), b"last")]
        replace = migration.replace_file

        def fail_last(path, content):
            if path == last:
                raise OSError("simulated write failure")
            replace(path, content)

        with patch.object(migration, "replace_file", side_effect=fail_last):
            with self.assertRaises(OSError):
                migration.apply_plans(self.root, plans)
        self.assertEqual(existing.read_bytes(), original)
        self.assertFalse(new.exists())
        self.assertFalse((self.root / "var/lib/pacman/db.lck").exists())

    def test_channel_commands_report_arm_stable_and_refuse_switching(self):
        migration.apply_plans(self.root, migration.plan(self.root))
        command_dir = self.root / "usr/bin"
        for name in ("omarchy-version-channel", "omarchy-channel-current", "omarchy-channel-set"):
            path = command_dir / name
            path.write_text(path.read_text().replace("/usr/share/try-omarchy/pacman.conf",
                                                   str(self.root / migration.CONFIGS[0])))
            path.chmod(0o755)
        for name, text in {"uname": "echo aarch64", "pacman-conf": 'echo "${TEST_SERVER}"'}.items():
            path = command_dir / name
            path.write_text("#!/bin/sh\n" + text + "\n")
            path.chmod(0o755)
        env = {**os.environ, "PATH": str(command_dir) + ":" + os.environ["PATH"],
               "OMARCHY_PATH": "/usr/share/omarchy", "TEST_SERVER": "https://pkgs.omarchy.org/stable/aarch64"}

        def run(name, *args):
            return subprocess.run([str(command_dir / name), *args], env=env,
                                  capture_output=True, text=True)

        self.assertEqual(run("omarchy-version-channel").stdout.strip(), "arm / stable")
        self.assertEqual(run("omarchy-channel-current").stdout.strip(), "stable")
        for channel in ("stable", "rc", "edge", "dev"):
            result = run("omarchy-channel-set", channel)
            self.assertEqual(result.returncode, 1)
            self.assertIn("channel switching is not supported", result.stderr)
        env["TEST_SERVER"] = "https://pkgs.omarchy.org/edge/aarch64"
        self.assertEqual(run("omarchy-channel-current").stdout.strip(), "unknown")
        env["OMARCHY_PATH"] = "/home/user/omarchy"
        self.assertEqual(run("omarchy-channel-current").stdout.strip(), "dev")

    def test_launcher_rejects_unreviewed_keyring_pins(self):
        launcher = (GUEST.parent / "macos/run-qemu-gpu.sh").read_text()
        helpers = "def fail(message: str)" + launcher.split("def fail(message: str)", 1)[1].split("def load_json", 1)[0]
        chain = "supply_chain_keys = " + launcher.split("supply_chain_keys = ", 1)[1].split("hyprland = exact_keys(", 1)[0]
        spec = json.loads((GUEST / "spec.json").read_text())
        exec(helpers + chain, {"spec": spec})
        for field in spec["supplyChain"]["omarchyKeyring"]:
            with self.subTest(field=field):
                changed = json.loads(json.dumps(spec))
                changed["supplyChain"]["omarchyKeyring"][field] = "unreviewed"
                with self.assertRaisesRegex(SystemExit, "keyring is not the reviewed package"):
                    exec(helpers + chain, {"spec": changed})
        lock = json.loads((GUEST / "packages.lock.json").read_text())
        self.assertEqual(spec["supplyChain"]["omarchyKeyring"]["version"], lock["packages"]["omarchy-keyring"])

    def test_repository_flags_are_removed_without_changing_records(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            entry = tarfile.TarInfo("fixture-1-1/desc")
            entry.pax_headers = {"SCHILY.fflags": "nocow", "mtime": "123.5"}
            entry.size = len(b"original package record")
            archive.addfile(entry, io.BytesIO(b"original package record"))
        portable = migration.portable_database(stream.getvalue())
        with tarfile.open(fileobj=io.BytesIO(portable)) as archive:
            entry = archive.getmember("fixture-1-1/desc")
            self.assertNotIn("SCHILY.fflags", entry.pax_headers)
            self.assertEqual(entry.pax_headers["mtime"], "123.5")
            self.assertEqual(archive.extractfile(entry).read(), b"original package record")

    def test_repository_update_rejects_lost_or_changed_package_records(self):
        def database(records):
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode="w:gz") as archive:
                for name, data in records.items():
                    entry = tarfile.TarInfo(name)
                    entry.size = len(data)
                    archive.addfile(entry, io.BytesIO(data))
            return stream.getvalue()

        original = {"fixture-1-1/desc": b"original"}
        keyring = {"omarchy-keyring-20251027-1/desc": b"keyring"}
        migration.verify_repository_records(database(original), database(original | keyring), "20251027-1")
        for records in (keyring, keyring | {"fixture-1-1/desc": b"changed"}, original):
            with self.assertRaises(ValueError):
                migration.verify_repository_records(database(original), database(records), "20251027-1")

    def test_keyring_digest_failure_does_not_publish_an_archive(self):
        destination = self.root / "package-output"

        def download(args, **kwargs):
            Path(args[-1]).write_bytes(b"corrupt package")

        with patch.object(keyring.subprocess, "run", side_effect=download):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                keyring.prepare(GUEST, destination)
        self.assertEqual(list(destination.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
