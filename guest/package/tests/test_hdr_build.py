import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]


class HDRBuildContract(unittest.TestCase):
    def run_build(self, checksum_tool, corrupt_cache=False):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            package = root / 'guest/package'
            package.mkdir(parents=True)
            shutil.copy(ROOT / 'guest/package/build-hdr.sh', package / 'build-hdr.sh')
            shutil.copytree(ROOT / 'guest/package/hdr-hyprland', package / 'hdr-hyprland')
            tools = root / 'bin'
            tools.mkdir()
            for name in ['bash', 'dirname', 'mkdir', 'basename', 'install', 'python3']:
                (tools / name).symlink_to(shutil.which(name))
            checksum = tools / checksum_tool
            checksum.write_text(f'#!{sys.executable}\n' + '''import hashlib, pathlib, sys
args = sys.argv[1:]
if args[:2] == ['-a', '256']:
    args = args[2:]
if args[:1] == ['-c']:
    for line in pathlib.Path(args[1]).read_text().splitlines():
        digest, name = line.split('  ', 1)
        if hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() != digest:
            sys.exit(1)
else:
    for name in args:
        print(hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() + '  ' + name)
''')
            checksum.chmod(0o755)
            docker = tools / 'docker'
            docker.write_text(f'#!{sys.executable}\n' + '''import os, pathlib, sys
args = sys.argv[1:]
if args[:2] == ['image', 'inspect']:
    print('synthetic-builder-image')
else:
    with open(os.environ['BUILD_TRACE'], 'a') as trace:
        trace.write('build\\n')
    output = next(arg[:-8] for arg in args if arg.endswith(':/output'))
    package = pathlib.Path(output) / 'hyprland-0.56.2-7.323-aarch64.pkg.tar.zst'
    package.write_bytes(b'synthetic compositor archive')
    package.chmod(0o444)
''')
            docker.chmod(0o755)
            trace = root / 'trace'
            env = dict(os.environ, PATH=str(tools), BUILD_TRACE=str(trace))
            command = [str(tools / 'bash'), str(package / 'build-hdr.sh'), '--output', str(root / 'first')]
            first = subprocess.run(command, env=env, text=True, capture_output=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            bundle = root / 'first/hdr-packages'
            manifest = (bundle / 'SHA256SUMS').read_text().splitlines()
            self.assertEqual(len(manifest), 2)
            for line in manifest:
                digest, name = line.split('  ', 1)
                self.assertEqual(hashlib.sha256((bundle / name).read_bytes()).hexdigest(), digest)
            self.assertEqual((bundle / 'version').read_text(), 'hyprland 0.56.2-7.323\n')
            if corrupt_cache:
                cached = next((root / '.build/hdr-hyprland').glob('*/hyprland-*.pkg.tar.zst'))
                cached.write_bytes(b'corrupted cache')
            second = subprocess.run(command[:-1] + [str(root / 'second')], env=env, text=True, capture_output=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(trace.read_text().splitlines(), ['build'] * (2 if corrupt_cache else 1))
            self.assertEqual((root / 'second/hdr-packages/SHA256SUMS').read_text().splitlines(), manifest)

    def test_linux_without_shasum(self):
        self.run_build('sha256sum')

    def test_macos_fallback_without_sha256sum(self):
        self.run_build('shasum')

    def test_corrupt_linux_cache_is_rebuilt(self):
        self.run_build('sha256sum', corrupt_cache=True)

    def test_corrupt_macos_cache_is_rebuilt(self):
        self.run_build('shasum', corrupt_cache=True)


if __name__ == '__main__':
    unittest.main()
