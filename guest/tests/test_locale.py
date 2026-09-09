#!/usr/bin/env python3
"""Isolated contracts for the host-locale systemd generator."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
GENERATOR = (
    GUEST / "native-overlay/usr/lib/systemd/system-generators/try-omarchy-locale"
)


class LocaleGeneratorTests(unittest.TestCase):
    def run_generator(
        self, command_line: str
    ) -> tuple[
        subprocess.CompletedProcess[str], Path, tempfile.TemporaryDirectory[str]
    ]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        normal_output = root / "normal"
        normal_output.mkdir()
        cmdline = root / "cmdline"
        cmdline.write_text(command_line + "\n", encoding="utf-8")
        environment_d = root / "environment.d"
        test_generator = root / "generator"
        source = GENERATOR.read_text(encoding="utf-8")
        source = source.replace("/proc/cmdline", str(cmdline)).replace(
            "/run/environment.d", str(environment_d)
        )
        test_generator.write_text(source, encoding="utf-8")
        test_generator.chmod(0o755)
        result = subprocess.run(
            [
                str(test_generator),
                str(normal_output),
                str(root / "early"),
                str(root / "late"),
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return result, environment_d, temporary

    def assert_nothing_written(
        self,
        result: subprocess.CompletedProcess[str],
        environment_d: Path,
    ) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(environment_d.exists())

    def test_no_token_writes_nothing(self) -> None:
        result, environment_d, temporary = self.run_generator("root=/dev/vda rw")
        with temporary:
            self.assert_nothing_written(result, environment_d)

    def test_each_allowlisted_locale_writes_the_matching_lang_line(self) -> None:
        for locale in ("en_US.UTF-8", "zh_TW.UTF-8"):
            result, environment_d, temporary = self.run_generator(
                f"root=/dev/vda rw tryomarchy.locale={locale}"
            )
            with temporary:
                conf = environment_d / "91-try-omarchy-locale.conf"
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(conf.read_text(encoding="utf-8"), f"LANG={locale}\n")
                self.assertEqual(
                    [
                        path.relative_to(environment_d).as_posix()
                        for path in environment_d.rglob("*")
                    ],
                    ["91-try-omarchy-locale.conf"],
                )

    def test_locale_not_on_allowlist_writes_nothing(self) -> None:
        for locale in ("fr_FR.UTF-8", "en_US", "zh_CN.UTF-8", "en_US.UTF-8x"):
            result, environment_d, temporary = self.run_generator(
                f"root=/dev/vda rw tryomarchy.locale={locale}"
            )
            with temporary:
                self.assert_nothing_written(result, environment_d)

    def test_empty_token_value_writes_nothing(self) -> None:
        result, environment_d, temporary = self.run_generator(
            "root=/dev/vda rw tryomarchy.locale="
        )
        with temporary:
            self.assert_nothing_written(result, environment_d)

    def test_shell_metacharacter_value_writes_nothing_and_has_no_side_effect(
        self,
    ) -> None:
        temporary = tempfile.TemporaryDirectory()
        with temporary:
            root = Path(temporary.name)
            marker = root / "pwned"
            payload = f"tryomarchy.locale=$(touch {marker});x"
            result, environment_d, inner = self.run_generator(payload)
            with inner:
                self.assert_nothing_written(result, environment_d)
            self.assertFalse(marker.exists())

    def test_malformed_invocation_fails(self) -> None:
        result = subprocess.run([str(GENERATOR)], check=False)
        self.assertEqual(result.returncode, 64)


if __name__ == "__main__":
    unittest.main()
