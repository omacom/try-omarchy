import contextlib
import importlib.util
import io
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch


GUEST = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("repair_update_holds", GUEST / "scripts/repair-update-holds.py")
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class UpdateHoldsTests(unittest.TestCase):
    def test_preserves_custom_settings_comments_and_multiple_directives(self):
        original = "# custom\n[options]\n  IgnorePkg = custom linux-aarch64 # keep this\nIgnorePkg = aquamarine\nUnknownSetting = yes\n[custom]\nServer = https://example.com/$arch\n"
        result = repair.add_holds(original)
        self.assertIn("custom linux-aarch64 linux-aarch64-headers hyprland hyprtoolkit # keep this", result)
        self.assertTrue(result.endswith("IgnorePkg = aquamarine\nUnknownSetting = yes\n[custom]\nServer = https://example.com/$arch\n"))
        self.assertEqual(repair.add_holds(result), result)

    def test_missing_directive_added_inside_options(self):
        for original in ("[options]", "# IgnorePkg = ignored\n[options]\nColor\n[core]\nServer = example\n"):
            result = repair.add_holds(original)
            self.assertIn("[options]\nIgnorePkg = " + " ".join(repair.HOLDS), result)
            self.assertEqual(repair.add_holds(result), result)

    def test_crlf_and_absent_final_newline_preserved(self):
        original = "[options]\r\nIgnorePkg = custom # comment\r\n[core]\r\nServer = example"
        result = repair.add_holds(original)
        self.assertNotIn("\n", result.replace("\r\n", ""))
        self.assertTrue(result.endswith("Server = example"))

    def test_rejects_missing_or_duplicate_options(self):
        for original in ("IgnorePkg = custom\n[core]\n", "[options]\n[options]\n"):
            with self.assertRaises(ValueError):
                repair.add_holds(original)

    def test_holds_match_factory_configuration(self):
        text = (GUEST / "pacman.aarch64.conf").read_text()
        holds = next(line.split("=", 1)[1].split() for line in text.splitlines() if line.startswith("IgnorePkg ="))
        self.assertEqual(set(holds), set(repair.HOLDS))

    def setUp(self):
        output = contextlib.redirect_stdout(io.StringIO())
        output.__enter__()
        self.addCleanup(output.__exit__, None, None, None)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.paths = [self.root / relative for relative in repair.CONFIGS]
        for path in self.paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("[options]\nIgnorePkg = linux-aarch64 custom\n[extra]\nServer = example\n")
            path.chmod(0o640)
        (self.root / "var/lib/pacman").mkdir(parents=True)
        self.originals = [path.read_bytes() for path in self.paths]

    def test_preview_has_no_side_effects(self):
        repair.repair(self.root)
        self.assertEqual([p.read_bytes() for p in self.paths], self.originals)
        self.assertFalse((self.root / "var/lib/try-omarchy").exists())
        self.assertFalse((self.root / "var/lib/pacman/db.lck").exists())

    def test_apply_backup_modes_hook_restore_and_repeat(self):
        repair.repair(self.root, apply=True)
        backups = list((self.root / "var/lib/try-omarchy").iterdir())
        self.assertEqual(len(backups), 1)
        for path, before in zip(self.paths, self.originals):
            self.assertEqual((backups[0] / path.relative_to(self.root)).read_bytes(), before)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
        # The existing pre-refresh hook restores the saved configuration.
        self.paths[1].write_bytes(self.paths[0].read_bytes())
        after = [p.read_bytes() for p in self.paths]
        repair.repair(self.root, apply=True)
        self.assertEqual([p.read_bytes() for p in self.paths], after)
        self.assertEqual(list((self.root / "var/lib/try-omarchy").iterdir()), backups)
        self.assertFalse((self.root / "var/lib/pacman/db.lck").exists())

    def test_checks_both_files_before_writing(self):
        self.paths[1].write_text("[core]\n")
        with self.assertRaises(ValueError):
            repair.repair(self.root, apply=True)
        self.assertEqual(self.paths[0].read_bytes(), self.originals[0])

    def test_refuses_symlink(self):
        self.paths[1].unlink()
        self.paths[1].symlink_to(self.paths[0])
        with self.assertRaises(ValueError):
            repair.repair(self.root, apply=True)
        self.assertEqual(self.paths[0].read_bytes(), self.originals[0])

    def test_active_pacman_lock_is_not_removed(self):
        lock = self.root / "var/lib/pacman/db.lck"
        lock.write_text("in use")
        with self.assertRaises(FileExistsError):
            repair.repair(self.root, apply=True)
        self.assertEqual(lock.read_text(), "in use")
        self.assertEqual([p.read_bytes() for p in self.paths], self.originals)

    def test_second_write_failure_restores_first(self):
        replace = repair.replace_file

        def fail_second(path, content):
            if path == self.paths[1]:
                raise OSError("simulated write failure")
            replace(path, content)

        with patch.object(repair, "replace_file", side_effect=fail_second):
            with self.assertRaises(OSError):
                repair.repair(self.root, apply=True)
        self.assertEqual([p.read_bytes() for p in self.paths], self.originals)
        self.assertFalse((self.root / "var/lib/pacman/db.lck").exists())


if __name__ == "__main__":
    unittest.main()
