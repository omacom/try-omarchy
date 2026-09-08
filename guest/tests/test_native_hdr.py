import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]


class NativeHDRTest(unittest.TestCase):
    def test_private_runtime_requires_an_active_hdr_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "hdr"
            (runtime / "mpv/bin").mkdir(parents=True)
            (runtime / "mesa/lib").mkdir(parents=True)
            player = runtime / "mpv/bin/mpv"
            player.touch()
            player.chmod(0o755)
            (runtime / "mesa/lib/libEGL_mesa.so.0").touch()
            helper = root / "environment.sh"
            helper.write_text((GUEST / "hdr/environment.sh").read_text().replace(
                "/usr/local/lib/omarchy-hdr", str(runtime)))
            fake_hyprctl = root / "hyprctl"
            fake_hyprctl.write_text('#!/bin/sh\nprintf "%s\\n" "$HDR_TEST_MONITORS"\n')
            fake_hyprctl.chmod(0o755)
            environment = {**os.environ, "PATH": str(root) + ":" + os.environ["PATH"],
                           "WAYLAND_DISPLAY": "wayland-test"}
            hdr = {"name": "Virtual-1", "colorManagementPreset": "hdr",
                   "currentFormat": "XRGB2101010"}
            for name, displays, expected in [
                ("paired HDR", [hdr], "HDR"),
                ("8-bit", [{**hdr, "currentFormat": "XRGB8888"}], "SDR"),
                ("SDR preset", [{**hdr, "colorManagementPreset": "srgb"}], "SDR"),
                ("other output", [{**hdr, "name": "HDMI-A-1"}], "SDR"),
                ("no output", [], "SDR"),
                ("bad response", None, "SDR"),
            ]:
                with self.subTest(name=name):
                    environment["HDR_TEST_MONITORS"] = json.dumps(displays)
                    result = subprocess.run(
                        ["bash", "-c", 'source "$1"; if omarchy_hdr_available; then '
                         'echo HDR; else echo SDR; fi', "test", str(helper)],
                        env=environment, text=True, capture_output=True, check=True)
                    self.assertEqual(result.stdout.strip(), expected)
            environment["HDR_TEST_MONITORS"] = json.dumps([hdr])
            environment.pop("WAYLAND_DISPLAY")
            result = subprocess.run(
                ["bash", "-c", 'source "$1"; omarchy_hdr_available', "test", str(helper)],
                env=environment)
            self.assertNotEqual(result.returncode, 0)

    def test_source_digests(self):
        import hashlib
        hdr = GUEST / "hdr"
        metadata = json.loads((hdr / "sources.json").read_text())
        for name, expected in metadata["patches"].items():
            with self.subTest(name=name):
                self.assertEqual(hashlib.sha256((hdr / name).read_bytes()).hexdigest(), expected)
        self.assertEqual(hashlib.sha256((hdr / "linux-source-sha256.json").read_bytes()).hexdigest(),
                         metadata["linuxManifestSha256"])


if __name__ == "__main__":
    unittest.main()
