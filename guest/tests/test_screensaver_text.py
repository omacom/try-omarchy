"""Exercise the native screensaver input against actual terminal dimensions."""

import fcntl
import os
from pathlib import Path
import pty
import struct
import subprocess
import tempfile
import termios
import unittest


HELPER = Path(__file__).resolve().parents[1] / "native-overlay/usr/local/bin/omarchy-native-screensaver-text"


class ScreensaverTextTests(unittest.TestCase):
    def render(self, text, rows, cols):
        with tempfile.TemporaryDirectory() as folder:
            logo = Path(folder) / "logo"
            logo.write_text(text)
            master, slave = pty.openpty()
            try:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
                result = subprocess.run([str(HELPER), str(logo)], stdin=slave,
                                        capture_output=True, text=True, check=True)
                self.assertEqual(result.stderr, "")
                return result.stdout
            finally:
                os.close(slave)
                os.close(master)

    def test_normal_terminal_preserves_logo(self):
        logo = ("█" * 54 + "\n") * 26
        self.assertEqual(self.render(logo, 40, 90), logo)

    def test_small_terminal_replaces_oversize_logo(self):
        self.assertEqual(self.render(("█" * 54 + "\n") * 26, 7, 26), "Omarchy\n")

    def test_narrow_terminal_keeps_fallback_inside_canvas(self):
        self.assertEqual(self.render("wide logo\n", 1, 3), "Oma\n")

    def test_unicode_display_width_and_empty_logo(self):
        self.assertEqual(self.render("界界界界\n", 2, 7), "Omarchy\n")
        self.assertEqual(self.render("e\u0301\n", 1, 1), "e\u0301\n")
        self.assertEqual(self.render(" \n", 2, 20), "Omarchy\n")



if __name__ == "__main__":
    unittest.main()
