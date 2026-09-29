#!/usr/bin/env python3
"""Isolated contracts for the host-locale boot script."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
SCRIPT = GUEST / "native-overlay/usr/local/bin/try-omarchy-locale"


class LocaleScriptTests(unittest.TestCase):
    def run_script(
        self, command_line: str, initial_contents: str | None = None
    ) -> tuple[
        subprocess.CompletedProcess[str], Path, tempfile.TemporaryDirectory[str]
    ]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        cmdline = root / "cmdline"
        cmdline.write_text(command_line + "\n", encoding="utf-8")
        locale_conf = root / "locale.conf"
        (root / "locale-pending").touch()
        if initial_contents is not None:
            locale_conf.write_text(initial_contents, encoding="utf-8")
            locale_conf.chmod(0o640)
        result = subprocess.run(
            [str(SCRIPT)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                "PATH": "/usr/bin:/bin",
                "TRY_OMARCHY_LOCALE_CMDLINE_PATH": str(cmdline),
                "TRY_OMARCHY_LOCALE_CONF_PATH": str(locale_conf),
                "TRY_OMARCHY_LOCALE_PENDING_PATH": str(root / "locale-pending"),
            },
        )
        return result, locale_conf, temporary

    def test_preserves_locale_categories_comments_and_permissions(self) -> None:
        for command_line, expected_lang in (
            ("root=/dev/vda rw", "en_US.UTF-8"),
            ("tryomarchy.locale=zh_TW.UTF-8", "zh_TW.UTF-8"),
        ):
            result, conf, temporary = self.run_script(
                command_line,
                '# Custom formats\nLANG=en_US.UTF-8\nLC_TIME="zh_TW.UTF-8"\n'
                'LC_NUMERIC=en_US.UTF-8\nLANGUAGE=zh_TW:en\n',
            )
            with temporary:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(conf.read_text(),
                    '# Custom formats\nLC_TIME="zh_TW.UTF-8"\n'
                    'LC_NUMERIC=en_US.UTF-8\nLANGUAGE=zh_TW:en\n'
                    f'LANG={expected_lang}\n')
                self.assertEqual(conf.stat().st_mode & 0o777, 0o640)

    def test_replaces_duplicate_lang_assignments_without_executing_contents(self) -> None:
        result, conf, temporary = self.run_script(
            "tryomarchy.locale=zh_TW.UTF-8",
            "LANG=en_US.UTF-8\n export LANG=en_US.UTF-8\n# $(exit 99)\nLC_TIME=zh_TW.UTF-8",
        )
        with temporary:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(conf.read_text(),
                "# $(exit 99)\nLC_TIME=zh_TW.UTF-8\nLANG=zh_TW.UTF-8\n")

    def test_no_token_writes_the_default_english_locale(self) -> None:
        result, locale_conf, temporary = self.run_script("root=/dev/vda rw")
        with temporary:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                locale_conf.read_text(encoding="utf-8"), "LANG=en_US.UTF-8\n"
            )

    def test_each_allowlisted_locale_writes_the_matching_lang_line(self) -> None:
        for locale in ("en_US.UTF-8", "zh_TW.UTF-8", "zh_CN.UTF-8"):
            result, locale_conf, temporary = self.run_script(
                f"root=/dev/vda rw tryomarchy.locale={locale}"
            )
            with temporary:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    locale_conf.read_text(encoding="utf-8"), f"LANG={locale}\n"
                )

    def test_locale_not_on_allowlist_falls_back_to_english(self) -> None:
        for locale in ("fr_FR.UTF-8", "en_US", "zh_HK.UTF-8", "en_US.UTF-8x"):
            result, locale_conf, temporary = self.run_script(
                f"root=/dev/vda rw tryomarchy.locale={locale}"
            )
            with temporary:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    locale_conf.read_text(encoding="utf-8"), "LANG=en_US.UTF-8\n"
                )

    def test_empty_token_value_falls_back_to_english(self) -> None:
        result, locale_conf, temporary = self.run_script(
            "root=/dev/vda rw tryomarchy.locale="
        )
        with temporary:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                locale_conf.read_text(encoding="utf-8"), "LANG=en_US.UTF-8\n"
            )

    def test_shell_metacharacter_value_falls_back_and_has_no_side_effect(
        self,
    ) -> None:
        temporary = tempfile.TemporaryDirectory()
        with temporary:
            root = Path(temporary.name)
            marker = root / "pwned"
            payload = f"tryomarchy.locale=$(touch {marker});x"
            result, locale_conf, inner = self.run_script(payload)
            with inner:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    locale_conf.read_text(encoding="utf-8"), "LANG=en_US.UTF-8\n"
                )
            self.assertFalse(marker.exists())

    def test_later_boot_preserves_guest_edits_even_if_host_language_changes(self) -> None:
        result, conf, temporary = self.run_script("tryomarchy.locale=zh_TW.UTF-8")
        with temporary:
            self.assertEqual(result.returncode, 0, result.stderr)
            root = conf.parent
            self.assertFalse((root / "locale-pending").exists())
            conf.write_text("# Guest choice\nLANG=ja_JP.UTF-8\nLC_TIME=en_GB.UTF-8\n")
            (root / "cmdline").write_text("tryomarchy.locale=en_US.UTF-8\n")
            result = subprocess.run([str(SCRIPT)], capture_output=True, text=True, env={
                "PATH": "/usr/bin:/bin",
                "TRY_OMARCHY_LOCALE_CMDLINE_PATH": str(root / "cmdline"),
                "TRY_OMARCHY_LOCALE_CONF_PATH": str(conf),
                "TRY_OMARCHY_LOCALE_PENDING_PATH": str(root / "locale-pending"),
            })
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(conf.read_text(),
                             "# Guest choice\nLANG=ja_JP.UTF-8\nLC_TIME=en_GB.UTF-8\n")

    def test_refuses_to_write_through_a_symlink(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        with temporary:
            root = Path(temporary.name)
            cmdline = root / "cmdline"
            cmdline.write_text(
                "root=/dev/vda rw tryomarchy.locale=zh_TW.UTF-8\n", encoding="utf-8"
            )
            target = root / "outside-target"
            locale_conf = root / "locale.conf"
            (root / "locale-pending").touch()
            locale_conf.symlink_to(target)
            result = subprocess.run(
                [str(SCRIPT)],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "PATH": "/usr/bin:/bin",
                    "TRY_OMARCHY_LOCALE_CMDLINE_PATH": str(cmdline),
                    "TRY_OMARCHY_LOCALE_CONF_PATH": str(locale_conf),
                    "TRY_OMARCHY_LOCALE_PENDING_PATH": str(root / "locale-pending"),
                },
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists())
            self.assertTrue((root / "locale-pending").exists())


if __name__ == "__main__":
    unittest.main()
