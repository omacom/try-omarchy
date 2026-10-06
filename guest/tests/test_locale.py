#!/usr/bin/env python3
"""Isolated contracts for the host-locale boot script."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
SCRIPT = GUEST / "native-overlay/usr/local/bin/try-omarchy-locale"
FACTORY_PROFILE = (GUEST / "fragments/fcitx5-profile.ini").read_bytes()


class LocaleScriptTests(unittest.TestCase):
    def invoke_script(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            env={
                "PATH": "/usr/bin:/bin",
                "TRY_OMARCHY_LOCALE_CMDLINE_PATH": str(root / "cmdline"),
                "TRY_OMARCHY_LOCALE_CONF_PATH": str(root / "locale.conf"),
                "TRY_OMARCHY_LOCALE_PENDING_PATH": str(root / "locale-pending"),
                "TRY_OMARCHY_LOCALE_FCITX5_PROFILE_PATH": str(root / "profile"),
            },
        )

    def run_script(
        self, command_line: str, initial_contents: str | None = None,
        profile_contents: bytes | None = FACTORY_PROFILE,
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
        if profile_contents is not None:
            profile = root / "profile"
            profile.write_bytes(profile_contents)
            profile.chmod(0o640)
        result = self.invoke_script(root)
        return result, locale_conf, temporary

    def test_preserves_locale_categories_comments_and_permissions(self) -> None:
        for command_line, expected_lang in (
            ("root=/dev/vda rw", "en_US.UTF-8"),
            ("tryomarchy.locale=zh_TW.UTF-8", "zh_TW.UTF-8"),
            ("tryomarchy.locale=ko_KR.UTF-8", "ko_KR.UTF-8"),
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
        for locale in ("en_US.UTF-8", "zh_TW.UTF-8", "zh_CN.UTF-8", "ko_KR.UTF-8"):
            result, locale_conf, temporary = self.run_script(
                f"root=/dev/vda rw tryomarchy.locale={locale}"
            )
            with temporary:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    locale_conf.read_text(encoding="utf-8"), f"LANG={locale}\n"
                )

    def test_korean_selects_its_group_preserving_other_bytes_and_permissions(self) -> None:
        contents = b"# Keep this comment\r\nCustom=$(exit 99)\n" + FACTORY_PROFILE
        result, conf, temporary = self.run_script(
            "tryomarchy.locale=ko_KR.UTF-8", profile_contents=contents
        )
        with temporary:
            self.assertEqual(result.returncode, 0, result.stderr)
            profile = conf.parent / "profile"
            self.assertEqual(profile.read_bytes(), contents.replace(
                b"[GroupOrder]\n0=Default\n1=Korean\n",
                b"[GroupOrder]\n0=Korean\n1=Default\n",
            ))
            self.assertEqual(profile.stat().st_mode & 0o777, 0o640)
            self.assertFalse((conf.parent / "locale-pending").exists())
            self.assertEqual(list(conf.parent.glob(".fcitx5-profile.*")), [])

    def test_other_locales_leave_profile_byte_identical(self) -> None:
        for locale in ("en_US.UTF-8", "zh_TW.UTF-8", "zh_CN.UTF-8", "ja_JP.UTF-8", ""):
            with self.subTest(locale=locale):
                contents = b"# Preserve even non-UTF-8 bytes: \xff\r\n" + FACTORY_PROFILE
                result, conf, temporary = self.run_script(
                    f"tryomarchy.locale={locale}", profile_contents=contents
                )
                with temporary:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((conf.parent / "profile").read_bytes(), contents)
                    self.assertFalse((conf.parent / "locale-pending").exists())

    def test_korean_leaves_customized_group_orders_untouched(self) -> None:
        for order in (
            b"[GroupOrder]\n0=Korean\n1=Default\n",
            b"[GroupOrder]\n0=Default\n1=Korean\n2=Custom\n",
            b"[GroupOrder]\n0=Default\n1=Custom\n",
            b"[GroupOrder]\n0=Default\n",
            b"[GroupOrder]\n0=Default\n1=Korean\n# Keep my order\n",
            b"[GroupOrder]\n0=Default\n1=Korean\n[GroupOrder]\n0=Custom\n",
            b"[CustomGroupOrder]\n0=Default\n1=Korean\n",
            b"",
        ):
            with self.subTest(order=order):
                contents = FACTORY_PROFILE.split(b"[GroupOrder]")[0] + order
                result, conf, temporary = self.run_script(
                    "tryomarchy.locale=ko_KR.UTF-8", profile_contents=contents
                )
                with temporary:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((conf.parent / "profile").read_bytes(), contents)
                    self.assertFalse((conf.parent / "locale-pending").exists())

    def test_korean_tolerates_missing_profile_without_recreating_it(self) -> None:
        result, conf, temporary = self.run_script(
            "tryomarchy.locale=ko_KR.UTF-8", profile_contents=None
        )
        with temporary:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr, "")
            self.assertEqual(conf.read_text(), "LANG=ko_KR.UTF-8\n")
            self.assertFalse((conf.parent / "profile").exists())
            self.assertFalse((conf.parent / "locale-pending").exists())

    def test_korean_profile_initialization_is_idempotent(self) -> None:
        result, conf, temporary = self.run_script("tryomarchy.locale=ko_KR.UTF-8")
        with temporary:
            self.assertEqual(result.returncode, 0, result.stderr)
            root = conf.parent
            profile = root / "profile"
            expected = profile.read_bytes()
            original_stat = profile.stat()
            for retry_pending in (False, True):
                with self.subTest(retry_pending=retry_pending):
                    if retry_pending:
                        (root / "locale-pending").touch()
                    result = self.invoke_script(root)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(conf.read_text(), "LANG=ko_KR.UTF-8\n")
                    self.assertEqual(profile.read_bytes(), expected)
                    self.assertEqual(profile.stat().st_ino, original_stat.st_ino)
                    self.assertEqual(profile.stat().st_mtime_ns, original_stat.st_mtime_ns)
                    self.assertFalse((root / "locale-pending").exists())

    def test_profile_symlinks_are_refused_only_for_korean(self) -> None:
        for locale in ("ko_KR.UTF-8", "en_US.UTF-8", "zh_TW.UTF-8", "zh_CN.UTF-8"):
            for dangling in (False, True):
                with self.subTest(locale=locale, dangling=dangling), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    (root / "cmdline").write_text(f"tryomarchy.locale={locale}\n")
                    (root / "locale-pending").touch()
                    target = root / "outside-target"
                    if not dangling:
                        target.write_bytes(FACTORY_PROFILE)
                    profile = root / "profile"
                    profile.symlink_to(target)
                    result = self.invoke_script(root)
                    if locale == "ko_KR.UTF-8":
                        self.assertNotEqual(result.returncode, 0)
                        self.assertTrue((root / "locale-pending").exists())
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertFalse((root / "locale-pending").exists())
                    self.assertTrue(profile.is_symlink())
                    if dangling:
                        self.assertFalse(target.exists())
                    else:
                        self.assertEqual(target.read_bytes(), FACTORY_PROFILE)

    def test_korean_refuses_non_regular_profiles_and_retains_pending_marker(self) -> None:
        for kind in ("directory", "fifo"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "cmdline").write_text("tryomarchy.locale=ko_KR.UTF-8\n")
                (root / "locale-pending").touch()
                profile = root / "profile"
                if kind == "directory":
                    profile.mkdir()
                else:
                    os.mkfifo(profile)
                result = self.invoke_script(root)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("fcitx5 profile must be a regular file", result.stderr)
                self.assertTrue((root / "locale-pending").exists())
                self.assertFalse((root / "locale.conf").exists())

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
            result = self.invoke_script(root)
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
            result = self.invoke_script(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists())
            self.assertTrue((root / "locale-pending").exists())


if __name__ == "__main__":
    unittest.main()
