#!/usr/bin/env python3
"""Regression tests for selecting a host-backed guest microphone."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


HELPER = (
    Path(__file__).resolve().parents[1]
    / "native-overlay/usr/bin/omarchy-audio-input-set-default"
)


class AudioInputHelperTests(unittest.TestCase):
    def test_only_application_recordings_move_to_the_selected_source(self) -> None:
        self.assert_application_recordings_move("C")

    def test_localized_sessions_still_move_application_recordings(self) -> None:
        self.assert_application_recordings_move("zh_CN.UTF-8")

    def assert_application_recordings_move(self, locale: str) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            commands = root / "commands"
            commands.mkdir()
            log = root / "calls.log"

            self.write_command(
                commands / "timeout",
                """
                shift
                exec "$@"
                """,
            )
            self.write_command(
                commands / "wpctl",
                """
                printf 'wpctl %s\n' "$*" >>"$AUDIO_INPUT_TEST_LOG"
                """,
            )
            self.write_command(
                commands / "pactl",
                r"""
                if [[ $1 == list && $2 == source-outputs ]]; then
                  header='Source Output'
                  if [[ ${LC_ALL:-} == zh_CN.UTF-8 ]]; then
                    header='信源输出'
                  fi
                  printf '%b' "$header"' #41\n\tProperties:\n\t\tpulse.module.id = "100"\n\t\tmedia.name = "output.omarchy_host_input_internal"\n'"$header"' #52\n\tProperties:\n\t\tapplication.name = "Voice Recorder"\n'"$header"' #63\n\tProperties:\n\t\tapplication.name = "EasyEffects"\n'
                  exit 0
                fi
                printf 'pactl %s\n' "$*" >>"$AUDIO_INPUT_TEST_LOG"
                """,
            )

            environment = os.environ.copy()
            environment["PATH"] = f"{commands}:{environment['PATH']}"
            environment["AUDIO_INPUT_TEST_LOG"] = str(log)
            environment["LC_ALL"] = locale
            environment["LANGUAGE"] = "zh_CN"
            subprocess.run(
                [str(HELPER), "77", "omarchy_host_input_macbook"],
                check=True,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            calls = log.read_text().splitlines()
            self.assertEqual(
                calls,
                [
                    "wpctl set-default 77",
                    "pactl set-default-source omarchy_host_input_macbook",
                    "pactl move-source-output 52 omarchy_host_input_macbook",
                ],
            )
            self.assertFalse(any(" 41 " in f" {call} " for call in calls))
            self.assertFalse(any(" 63 " in f" {call} " for call in calls))

    def test_requires_both_source_identifiers(self) -> None:
        result = subprocess.run(
            [str(HELPER)],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("Usage:", result.stderr)

    @staticmethod
    def write_command(path: Path, body: str) -> None:
        path.write_text("#!/bin/bash\n" + textwrap.dedent(body).lstrip())
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
