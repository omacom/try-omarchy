import hashlib
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

GUEST = Path(__file__).resolve().parents[1]
HELPER = GUEST / "native-overlay/usr/local/sbin/try-omarchy-migrate-alacritty"
loader = importlib.machinery.SourceFileLoader("alacritty_migration", str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
migration = importlib.util.module_from_spec(spec)
loader.exec_module(migration)


class AlacrittyMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.directory = self.root / "bin"
        self.directory.mkdir(mode=0o755)
        self.cmdline = self.root / "cmdline"
        self.cmdline.write_text("quiet omarchy.virgl_dual_source=1\n")
        self.original = (GUEST / "tests/fixtures/alacritty-software-wrapper").read_bytes()
        self.wrapper = self.directory / "alacritty"
        self.wrapper.write_bytes(self.original)
        self.wrapper.chmod(0o755)
        self.backup = self.directory / migration.BACKUP
        self.addCleanup(self.temporary.cleanup)

    def run_migration(self, directory=None, uid=None):
        return migration.migrate(self.cmdline, directory or self.directory,
                                 os.getuid() if uid is None else uid)

    def test_factory_fixture_matches_allowlisted_digest(self):
        self.assertEqual(hashlib.sha256(self.original).hexdigest(), migration.WRAPPER_SHA256)
        self.assertEqual(len(self.original), migration.WRAPPER_SIZE)

    def test_exact_factory_wrapper_backed_up_with_metadata(self):
        original = self.wrapper.stat()
        self.assertIn("Migrated:", self.run_migration())
        self.assertFalse(self.wrapper.exists())
        self.assertEqual(self.backup.read_bytes(), self.original)
        self.assertEqual(self.backup.stat().st_ino, original.st_ino)
        self.assertEqual(self.backup.stat().st_mode, original.st_mode)

    def test_marker_must_be_exact(self):
        for marker in ("quiet", "omarchy.virgl_dual_source=10",
                       "xomarchy.virgl_dual_source=1", "omarchy.qemu_virgl=1"):
            with self.subTest(marker=marker):
                self.cmdline.write_text(marker)
                self.assertIn("Skipped:", self.run_migration())
                self.assertEqual(self.wrapper.read_bytes(), self.original)
                self.assertFalse(self.backup.exists())

    def test_custom_wrapper_preserved(self):
        self.wrapper.write_bytes(self.original + b"\n# custom\n")
        self.assertIn("custom contents", self.run_migration())
        self.assertTrue(self.wrapper.exists())
        self.assertFalse(self.backup.exists())

    def test_symlink_wrapper_preserved(self):
        target = self.root / "custom"
        self.wrapper.rename(target)
        self.wrapper.symlink_to(target)
        self.assertIn("symbolic link", self.run_migration())
        self.assertTrue(self.wrapper.is_symlink())
        self.assertEqual(target.read_bytes(), self.original)

    def test_symlink_directory_refused(self):
        link = self.root / "linked-bin"
        link.symlink_to(self.directory)
        with self.assertRaises(OSError):
            self.run_migration(link)
        self.assertTrue(self.wrapper.exists())

    def test_symlink_ancestor_refused(self):
        nested = self.directory / "nested"
        nested.mkdir()
        link = self.root / "ancestor"
        link.symlink_to(self.directory)
        with self.assertRaises(OSError):
            self.run_migration(link / "nested")
        self.assertTrue(self.wrapper.exists())

    def test_existing_backup_not_overwritten(self):
        self.backup.write_text("prior backup")
        self.assertIn("backup already exists", self.run_migration())
        self.assertEqual(self.backup.read_text(), "prior backup")
        self.assertTrue(self.wrapper.exists())

    def test_backup_symlink_not_followed(self):
        target = self.root / "untouched"
        target.write_text("custom")
        self.backup.symlink_to(target)
        self.assertIn("backup already exists", self.run_migration())
        self.assertEqual(target.read_text(), "custom")
        self.assertTrue(self.wrapper.exists())

    def test_second_run_is_noop(self):
        self.run_migration()
        inode = self.backup.stat().st_ino
        self.assertIn("No migration needed", self.run_migration())
        self.assertEqual(self.backup.stat().st_ino, inode)

    def test_untrusted_owner_preserved(self):
        self.assertIn("not protected", self.run_migration(uid=os.getuid() + 1))
        self.assertTrue(self.wrapper.exists())

    def test_writable_directory_preserved(self):
        self.directory.chmod(0o777)
        self.assertIn("not protected", self.run_migration())
        self.assertTrue(self.wrapper.exists())

    def test_writable_wrapper_preserved(self):
        self.wrapper.chmod(0o777)
        self.assertIn("not an unmodified factory", self.run_migration())
        self.assertTrue(self.wrapper.exists())

    def test_hardlinked_wrapper_preserved(self):
        os.link(self.wrapper, self.root / "other-link")
        self.assertIn("not an unmodified factory", self.run_migration())
        self.assertTrue(self.wrapper.exists())

    def test_fifo_not_opened_for_blocking_read(self):
        self.wrapper.unlink()
        os.mkfifo(self.wrapper)
        self.assertIn("not an unmodified factory", self.run_migration())
        self.assertTrue(self.wrapper.exists())

    def test_service_and_factory_hooks(self):
        service = (GUEST / "native-overlay/usr/lib/systemd/system/try-omarchy-migrate-alacritty.service").read_text()
        self.assertIn("ConditionKernelCommandLine=" + migration.MARKER, service)
        self.assertIn("Before=sddm.service display-manager.service", service)
        self.assertIn("ExecStart=/usr/local/sbin/try-omarchy-migrate-alacritty", service)
        self.assertIn('"$root/usr/local/sbin/try-omarchy-migrate-alacritty"',
                      (GUEST / "scripts/configure-rootfs.sh").read_text())
        self.assertIn("systemctl enable try-omarchy-migrate-alacritty.service",
                      (GUEST / "scripts/finalize-rootfs.sh").read_text())


if __name__ == "__main__":
    unittest.main()
