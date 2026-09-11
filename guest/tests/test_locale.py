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
        self, command_line: str
    ) -> tuple[
        subprocess.CompletedProcess[str], Path, tempfile.TemporaryDirectory[str]
    ]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        cmdline = root / "cmdline"
        cmdline.write_text(command_line + "\n", encoding="utf-8")
        locale_conf = root / "locale.conf"
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
            },
        )
        return result, locale_conf, temporary

    def test_no_token_writes_the_default_english_locale(self) -> None:
        result, locale_conf, temporary = self.run_script("root=/dev/vda rw")
        with temporary:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                locale_conf.read_text(encoding="utf-8"), "LANG=en_US.UTF-8\n"
            )

    def test_each_allowlisted_locale_writes_the_matching_lang_line(self) -> None:
        for locale in ("en_US.UTF-8", "zh_TW.UTF-8"):
            result, locale_conf, temporary = self.run_script(
                f"root=/dev/vda rw tryomarchy.locale={locale}"
            )
            with temporary:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    locale_conf.read_text(encoding="utf-8"), f"LANG={locale}\n"
                )

    def test_locale_not_on_allowlist_falls_back_to_english(self) -> None:
        for locale in ("fr_FR.UTF-8", "en_US", "zh_CN.UTF-8", "en_US.UTF-8x"):
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

    def test_running_twice_leaves_identical_contents(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        with temporary:
            root = Path(temporary.name)
            cmdline = root / "cmdline"
            cmdline.write_text(
                "root=/dev/vda rw tryomarchy.locale=zh_TW.UTF-8\n", encoding="utf-8"
            )
            locale_conf = root / "locale.conf"
            env = {
                "PATH": "/usr/bin:/bin",
                "TRY_OMARCHY_LOCALE_CMDLINE_PATH": str(cmdline),
                "TRY_OMARCHY_LOCALE_CONF_PATH": str(locale_conf),
            }
            for _ in range(2):
                result = subprocess.run(
                    [str(SCRIPT)],
                    check=False,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=env,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                locale_conf.read_text(encoding="utf-8"), "LANG=zh_TW.UTF-8\n"
            )

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
                },
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
