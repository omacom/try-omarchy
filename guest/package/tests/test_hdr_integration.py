import pathlib
import subprocess
import tempfile
import unittest
import hashlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
PACKAGE = ROOT / 'guest/package/try-omarchy'
LIB = PACKAGE / 'files/usr/lib/try-omarchy'

class HDRIntegration(unittest.TestCase):
    def test_driver_inventory_and_kernel_scope(self):
        directory = PACKAGE / 'hdr-driver'
        for line in (directory / 'SHA256SUMS').read_text().splitlines():
            digest, name = line.split('  ')
            self.assertEqual(hashlib.sha256((directory / name).read_bytes()).hexdigest(), digest)
        self.assertIn('^7[.]2[.]8-[0-9]+-omarchy$', (directory / 'dkms.conf').read_text())

    def run_installer(self, installed, offered='0.56.2-7.323', corrupt=False, repeat=False):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            bundle = root / 'bundle'; bundle.mkdir()
            archive = bundle / 'hyprland-0.56.2-7.323-aarch64.pkg.tar.zst'
            archive.write_bytes(b'synthetic package; pacman mocked')
            digest = '0' * 64 if corrupt else hashlib.sha256(archive.read_bytes()).hexdigest()
            (bundle / 'version').write_text(f'hyprland {offered}\n')
            vd=hashlib.sha256((bundle/'version').read_bytes()).hexdigest()
            (bundle / 'SHA256SUMS').write_text(f'{digest}  {archive.name}\n{vd}  version\n')
            driver=root/'driver';driver.mkdir();(driver/'source').write_text('synthetic')
            sd=hashlib.sha256((driver/'source').read_bytes()).hexdigest()
            (driver/'SHA256SUMS').write_text(f'{sd}  source\n')
            modules=root/'modules'; (modules/'7.2.8-13-omarchy').mkdir(parents=True)
            bindir=root/'bin'; bindir.mkdir()
            script = '''#!/bin/bash
case "$1" in
 -Qp) echo "hyprland OFFERED" ;;
 -Q) echo "hyprland INSTALLED" ;;
 -U) echo installed >> "$TRACE" ;;
esac
'''.replace('OFFERED',offered).replace('INSTALLED',installed)
            (bindir/'pacman').write_text(script)
            for name, body in {'vercmp':'echo -1', 'dkms':'echo dkms >> "$TRACE"', 'depmod':':', 'mkinitcpio':'echo initramfs >> "$TRACE"', 'modinfo':'echo /usr/lib/modules/7.2.8-13-omarchy/updates/dkms/virtio-gpu.ko'}.items():
                (bindir/name).write_text('#!/bin/bash\n'+body+'\n')
            for p in bindir.iterdir():p.chmod(0o755)
            import os
            env=dict(os.environ,PATH=str(bindir)+':'+os.environ['PATH'],TRY_OMARCHY_HDR_BUNDLE=str(bundle),TRY_OMARCHY_HDR_MODULES=str(modules),TRY_OMARCHY_HDR_DRIVER=str(driver),TRY_OMARCHY_HDR_STATE=str(root/'state/stamp'),TRACE=str(root/'trace'))
            result=subprocess.run(['bash',str(LIB/'hdr-install')],env=env,text=True,capture_output=True)
            if repeat:
                result=subprocess.run(['bash',str(LIB/'hdr-install')],env=env,text=True,capture_output=True)
            trace=(root/'trace').read_text() if (root/'trace').exists() else ''
            return result, trace

    def test_supported_upgrade_uses_pacman_and_rebuilds_driver(self):
        result, trace=self.run_installer('0.56.2-7')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(trace.splitlines(),['installed','dkms','dkms','initramfs'])

    def test_current_compositor_is_not_reinstalled(self):
        result, trace=self.run_installer('0.56.2-7.323')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('installed',trace)

    def test_unchanged_second_run_skips_dkms_and_initramfs(self):
        result, trace=self.run_installer('0.56.2-7.323', repeat=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(trace.splitlines(),['dkms','dkms','initramfs'])

    def test_unqualified_compositor_is_not_downgraded(self):
        result,trace=self.run_installer('0.57.0-1')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(trace,'')

    def test_corrupt_archive_is_rejected_before_pacman(self):
        result,trace=self.run_installer('0.56.2-7',corrupt=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(trace,'')

    def test_factory_and_upgrade_share_installer(self):
        self.assertIn('arch-chroot "$target" /usr/lib/try-omarchy/hdr-install',(ROOT/'guest/factory/build-image.sh').read_text())
        self.assertIn('/usr/lib/try-omarchy/hdr-install',(LIB/'package-install').read_text())

if __name__=='__main__':unittest.main()
