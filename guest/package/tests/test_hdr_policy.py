import pathlib
import subprocess
import sys
import tempfile
import unittest

POLICY = pathlib.Path(__file__).resolve().parents[1] / 'try-omarchy/files/usr/lib/try-omarchy/hdr-monitor-policy'


def edid(hdr=False, white=600):
    base = bytearray(128)
    base[:8] = b'\x00\xff\xff\xff\xff\xff\xff\x00'
    text = f'TO-SDR:{white}'.encode().ljust(13, b' ')
    base[108:126] = b'\x00\x00\x00\xfe\x00' + text
    base[126] = int(hdr)
    base[127] = -sum(base[:127]) % 256
    if not hdr:
        return bytes(base)
    cta = bytearray(128)
    cta[:8] = bytes([2, 3, 8, 0, 0xe3, 6, 4, 1])
    cta[127] = -sum(cta[:127]) % 256
    return bytes(base + cta)


class HDRPolicy(unittest.TestCase):
    def policy(self, data):
        with tempfile.NamedTemporaryFile() as file:
            file.write(data)
            file.flush()
            return subprocess.check_output([sys.executable, str(POLICY), file.name], text=True).strip()

    def test_hdr_preserves_host_sdr_white(self):
        self.assertEqual(self.policy(edid(True)), 'bitdepth = 10, cm = "hdredid", sdr_max_luminance = 600')

    def test_white_descriptor_in_cta_extension(self):
        data = bytearray(edid(True))
        data[136:154] = data[108:126]
        data[108:126] = bytes(18)
        data[127] = -sum(data[:127]) % 256
        data[255] = -sum(data[128:255]) % 256
        self.assertIn("sdr_max_luminance = 600", self.policy(data))

    def test_sdr_does_not_advertise_hdr(self):
        self.assertEqual(self.policy(edid()), 'bitdepth = 8, cm = "srgb"')

    def test_corrupt_cta_does_not_enable_hdr(self):
        data = bytearray(edid(True))
        data[-1] ^= 1
        self.assertEqual(self.policy(data), 'bitdepth = 8, cm = "srgb"')

    def test_invalid_white_hint_uses_standard_reference(self):
        self.assertIn('sdr_max_luminance = 203', self.policy(edid(True, 9999)))

    def test_invalid_base_does_not_enable_hdr(self):
        self.assertEqual(self.policy(b'bad edid'), 'bitdepth = 8, cm = "srgb"')


if __name__ == '__main__':
    unittest.main()
