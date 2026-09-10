import importlib.machinery
import importlib.util
from pathlib import Path
import socket
import unittest


COMMAND = Path(__file__).resolve().parents[1] / "native-overlay/usr/local/bin/omarchy-native-settings"
LOADER = importlib.machinery.SourceFileLoader("native_settings", str(COMMAND))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
settings = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(settings)


class NativeSettingsTests(unittest.TestCase):
    def setUp(self):
        self.guest, self.host = socket.socketpair()
        self.guest.setblocking(False)
        self.host.settimeout(1)
        self.addCleanup(self.guest.close)
        self.addCleanup(self.host.close)

    def test_requests_settings_and_waits_for_acknowledgment(self):
        self.host.sendall(b"opened\n")
        settings.open_settings(self.guest.fileno())
        self.assertEqual(self.host.recv(64), b"open-settings\n")

    def test_unavailable_or_malformed_responses_fail(self):
        for response in [b"unavailable\n", b"unknown\n", b"x" * 64]:
            with self.subTest(response=response):
                self.host.sendall(response)
                with self.assertRaises(OSError):
                    settings.open_settings(self.guest.fileno())
                self.assertEqual(self.host.recv(64), b"open-settings\n")

    def test_missing_reply_times_out(self):
        with self.assertRaises(TimeoutError):
            settings.open_settings(self.guest.fileno(), timeout=0.02)

    def test_disconnected_host_fails(self):
        self.host.close()
        with self.assertRaises(OSError):
            settings.open_settings(self.guest.fileno())


if __name__ == "__main__":
    unittest.main()
