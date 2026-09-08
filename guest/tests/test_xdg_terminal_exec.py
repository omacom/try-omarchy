#!/usr/bin/env python3
"""Regression tests for Omarchy's default-terminal xdg-terminal-exec shim."""

from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import tempfile
import textwrap
import unittest


HELPER = (
    Path(__file__).resolve().parents[1]
    / "factory-overlay/usr/local/bin/xdg-terminal-exec"
)


class XdgTerminalExecTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.home = self.root / "home"
        self.config = self.home / ".config"
        self.config.mkdir(parents=True)
        self.log = self.root / "launch.log"

    def write_command(self, *names: str) -> None:
        for name in names:
            path = self.commands / name
            path.write_text(
                textwrap.dedent(
                    f"""\
                    #!/bin/bash
                    printf '%s' '{name}' >>"$XDG_TERMINAL_TEST_LOG"
                    printf ':%s' "$*" >>"$XDG_TERMINAL_TEST_LOG"
                    printf '\\n' >>"$XDG_TERMINAL_TEST_LOG"
                    """
                ),
                encoding="utf-8",
            )
            path.chmod(0o755)

    def write_list(self, *desktop_ids: str, name: str = "xdg-terminals.list") -> None:
        body = "# Terminal emulator preference order for xdg-terminal-exec\n\n"
        body += "".join(f"{desktop_id}\n" for desktop_id in desktop_ids)
        (self.config / name).write_text(body, encoding="utf-8")

    def run_helper(self, *arguments: str, **env: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PATH"] = str(self.commands)
        environment["HOME"] = str(self.home)
        environment["XDG_CONFIG_HOME"] = str(self.config)
        environment["XDG_TERMINAL_TEST_LOG"] = str(self.log)
        environment.pop("XDG_CURRENT_DESKTOP", None)
        environment.update(env)
        return subprocess.run(
            [str(HELPER), *arguments],
            check=False,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_helper_is_executable(self) -> None:
        self.assertTrue(HELPER.stat().st_mode & stat.S_IXUSR)

    def test_print_id_defaults_to_foot(self) -> None:
        self.write_command("foot")
        result = self.run_helper("--print-id")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "foot.desktop\n")
        self.assertEqual(result.stderr, "")

    def test_print_id_follows_xdg_terminals_list(self) -> None:
        self.write_command("alacritty", "foot")
        self.write_list("Alacritty.desktop")
        result = self.run_helper("--print-id")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "Alacritty.desktop\n")

    def test_print_id_skips_missing_preferred_terminal(self) -> None:
        self.write_command("foot")
        self.write_list("Alacritty.desktop", "foot.desktop")
        result = self.run_helper("--print-id")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "foot.desktop\n")

    def test_print_id_skips_unknown_desktop_ids(self) -> None:
        self.write_command("foot")
        self.write_list("org.wezfurlong.wezterm.desktop", "foot.desktop")
        result = self.run_helper("--print-id")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "foot.desktop\n")

    def test_print_id_reports_kitty_when_selected(self) -> None:
        self.write_command("kitty", "foot")
        self.write_list("kitty.desktop")
        result = self.run_helper("--print-id")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "kitty.desktop\n")

    def test_launch_alacritty_uses_desktop_argument_keys(self) -> None:
        self.write_command("alacritty", "foot")
        self.write_list("Alacritty.desktop")
        result = self.run_helper(
            "--app-id",
            "omarchy.term",
            "--title",
            "Omarchy",
            "--dir",
            "/tmp/project",
            "-e",
            "nvim",
            "README.md",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.log.read_text(encoding="utf-8"),
            "alacritty:--class=omarchy.term --title=Omarchy "
            "--working-directory=/tmp/project -e nvim README.md\n",
        )

    def test_launch_kitty_uses_directory_and_dash_dash(self) -> None:
        self.write_command("kitty")
        self.write_list("kitty.desktop")
        result = self.run_helper("--dir=/home/user", "htop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.log.read_text(encoding="utf-8"),
            "kitty:--directory=/home/user -- htop\n",
        )

    def test_launch_without_command_does_not_pass_exec_argument(self) -> None:
        self.write_command("foot")
        result = self.run_helper("--dir", "/tmp")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.log.read_text(encoding="utf-8"),
            "foot:--working-directory=/tmp\n",
        )

    def test_launch_uses_path_resolved_binary(self) -> None:
        self.write_command("alacritty")
        self.write_list("Alacritty.desktop")
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text(encoding="utf-8"), "alacritty:\n")

    def test_desktop_specific_preference_file(self) -> None:
        self.write_command("kitty", "foot")
        self.write_list("kitty.desktop", name="Hyprland-xdg-terminals.list")
        result = self.run_helper("--print-id", XDG_CURRENT_DESKTOP="Hyprland")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "kitty.desktop\n")


if __name__ == "__main__":
    unittest.main()
