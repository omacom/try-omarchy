import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
SCRIPT = GUEST / "native-overlay/usr/local/bin/try-omarchy-timezone"
loader = importlib.machinery.SourceFileLoader("timezone_sync", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
sync = importlib.util.module_from_spec(spec)
loader.exec_module(sync)


class TimeZoneTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.zones = self.root / "zoneinfo"
        for zone in ("UTC", "Asia/Tokyo", "Europe/Lisbon", "America/New_York", "Etc/GMT+9"):
            file = self.zones / zone
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(zone)
        self.localtime = self.root / "localtime"
        self.localtime.symlink_to(self.zones / "UTC")
        self.state = self.root / "timezone.json"
        self.applied = []

    def replace_zone(self, target):
        temporary = self.root / "new-localtime"
        temporary.symlink_to(target)
        os.replace(temporary, self.localtime)

    def apply(self, zone):
        def setter(target):
            self.applied.append(zone)
            self.replace_zone(target)
        return sync.synchronize(zone, self.state, self.localtime, self.zones, setter)

    def test_new_guest_and_travel_follow_current_mac_without_repeated_writes(self):
        self.assertTrue(self.apply("Asia/Tokyo"))
        self.assertFalse(self.apply("Asia/Tokyo"))
        self.assertTrue(self.apply("America/New_York"))
        self.assertEqual(self.applied, ["Asia/Tokyo", "America/New_York"])
        self.assertEqual(self.localtime.resolve(), self.zones / "America/New_York")

    def test_manual_guest_choice_survives_host_changes_and_reboots(self):
        self.apply("Asia/Tokyo")
        self.replace_zone(self.zones / "Europe/Lisbon")
        self.assertFalse(self.apply("America/New_York"))
        self.assertFalse(self.apply("Asia/Tokyo"))
        self.assertEqual(self.applied, ["Asia/Tokyo"])
        self.assertEqual(json.loads(self.state.read_text()), {"mode": "manual"})
        self.assertEqual(self.localtime.resolve(), self.zones / "Europe/Lisbon")

    def test_manual_same_zone_replacement_opts_out(self):
        self.apply("Asia/Tokyo")
        self.replace_zone(self.zones / "Asia/Tokyo")
        self.assertFalse(self.apply("Europe/Lisbon"))
        self.assertEqual(json.loads(self.state.read_text())["mode"], "manual")

    def test_setup_different_selection_is_preserved(self):
        # Initialization runs before provisioning; live snapshots run after it.
        self.apply("Asia/Tokyo")
        self.replace_zone(self.zones / "Europe/Lisbon")
        self.assertFalse(self.apply("Asia/Tokyo"))
        self.assertEqual(self.localtime.resolve(), self.zones / "Europe/Lisbon")

    def test_invalid_and_unavailable_zones_leave_guest_unchanged(self):
        for zone in ("../../etc/passwd", "/UTC", "Asia//Tokyo", "Asia/./Tokyo",
                     "Asia/Tokyo systemd.unit=rescue", "Asia/Tokyo\n", "Europe/Missing", "A" * 129, 1):
            with self.subTest(zone=zone), self.assertRaises(ValueError):
                self.apply(zone)
        self.assertFalse(self.state.exists())
        self.assertEqual(self.localtime.resolve(), self.zones / "UTC")

    def test_zoneinfo_symlink_cannot_escape_database(self):
        secret = self.root / "outside"
        secret.write_text("outside database")
        (self.zones / "escape").symlink_to(secret)
        with self.assertRaises(ValueError):
            self.apply("escape")

    def test_interrupted_update_preserves_current_zone_on_retry(self):
        self.apply("Asia/Tokyo")
        self.replace_zone(self.zones / "Europe/Lisbon")
        # An unexpected localtime change is preserved even if a previous
        # writer died before saving its state; don't guess it was ours.
        self.assertFalse(self.apply("America/New_York"))
        self.assertEqual(self.localtime.resolve(), self.zones / "Europe/Lisbon")

    def test_failed_timedated_does_not_record_success(self):
        def fail(_):
            raise OSError("timedated unavailable")
        with self.assertRaises(OSError):
            sync.synchronize("Asia/Tokyo", self.state, self.localtime, self.zones, fail)
        self.assertFalse(self.state.exists())
        self.assertTrue(self.apply("Asia/Tokyo"))

    def test_utc_alias_is_supported_and_state_is_root_private(self):
        self.assertFalse(self.apply("UTC"))
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertTrue(self.apply("Etc/GMT+9"))
