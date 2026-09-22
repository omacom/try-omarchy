from importlib.machinery import SourceFileLoader
from pathlib import Path
import unittest
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / 'native-overlay/usr/local/lib/try-omarchy/guest-clock-recover'
clock = SourceFileLoader('guest_clock_recover', str(HELPER)).load_module()


class ClockRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.files = {'/proc/cmdline': 'root=/dev/vda omarchy.qemu_virgl=1',
                      '/sys/class/rtc/rtc0/name': 'rtc-pl031 9010000.pl031\n',
                      '/sys/class/rtc/rtc0/since_epoch': '1789044748\n'}
        def patch(target, **kwargs):
            p = mock.patch(target, **kwargs)
            result = p.start()
            self.addCleanup(p.stop)
            return result
        patch('os.geteuid', return_value=0)
        patch('pathlib.Path.read_text', autospec=True,
              side_effect=lambda p: self.files[str(p)])
        self.wall = patch('time.time', return_value=1789044748)
        self.monotonic = patch('time.monotonic', side_effect=[100, 100.1])
        self.step = patch('time.clock_settime', create=True)
        self.restart = patch('subprocess.run')
        if not hasattr(clock.time, 'CLOCK_REALTIME'):
            p = mock.patch.object(clock.time, 'CLOCK_REALTIME', 0, create=True)
            p.start(); self.addCleanup(p.stop)

    def test_overnight_pause_recovers_even_without_network_time(self):
        self.wall.return_value -= 7 * 3600 + 22 * 60
        self.assertTrue(clock.recover())
        self.step.assert_called_once_with(clock.time.CLOCK_REALTIME, 1789044748.1)
        self.restart.assert_called_once_with(
            ['/usr/bin/systemctl', '--no-block', 'try-restart', 'systemd-timesyncd.service'],
            check=True, timeout=5)

    def test_small_drift_and_backward_corrections_are_left_to_ntp(self):
        for offset in [-3600, -1, 0, 1, 5]:
            with self.subTest(offset=offset):
                self.wall.return_value = 1789044748 - offset
                self.monotonic.side_effect = [100, 100.1]
                self.assertFalse(clock.recover())
        self.step.assert_not_called()
        self.restart.assert_not_called()

    def test_wrong_guest_and_wrong_rtc_do_not_change_time(self):
        for path, value in [('/proc/cmdline', 'root=/dev/vda'),
                            ('/sys/class/rtc/rtc0/name', 'unrelated-clock')]:
            with self.subTest(path=path), mock.patch.dict(self.files, {path: value}):
                self.assertFalse(clock.recover())
        self.step.assert_not_called()

    def test_slow_sample_is_rejected_instead_of_applying_stale_time(self):
        self.wall.return_value -= 3600
        self.monotonic.side_effect = [100, 104]
        with self.assertRaises(ValueError):
            clock.recover()
        self.step.assert_not_called()

    def test_bad_rtc_data_does_not_change_time(self):
        self.files['/sys/class/rtc/rtc0/since_epoch'] = 'invalid'
        with self.assertRaises(ValueError):
            clock.recover()
        self.step.assert_not_called()

    def test_failed_clock_set_does_not_report_success_or_restart_ntp(self):
        self.wall.return_value -= 3600
        self.step.side_effect = PermissionError('clock denied')
        self.assertEqual(clock.main(), 1)
        self.restart.assert_not_called()

    def test_unprivileged_invocation_is_rejected(self):
        with mock.patch('os.geteuid', return_value=1000):
            self.assertEqual(clock.main(), 1)
        self.step.assert_not_called()


if __name__ == '__main__':
    unittest.main()
