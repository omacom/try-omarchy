import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PATCH = Path(__file__).resolve().parents[1] / 'patches/omarchy/1password-arm64-installer.patch'


class OnePasswordRunningGuardTests(unittest.TestCase):
    def run_guard(self, status):
        additions = '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                              if line.startswith('+') and not line.startswith('+++'))
        guard = additions.split('require_1password_stopped() {', 1)[1].split('\n}\n', 1)[0]
        script = '''set -euo pipefail
pgrep() {
  [[ "$*" == '-x 1password' ]] || return 99
  return "$PROCESS_STATUS"
}
require_1password_stopped() {\n''' + guard + '''
}
require_1password_stopped
printf 'replacement allowed\n'
'''
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                              env={**os.environ, 'PROCESS_STATUS': str(status)})

    def test_running_app_blocks_replacement(self):
        result = self.run_guard(0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Quit 1Password completely', result.stderr)
        self.assertNotIn('replacement allowed', result.stdout)

    def test_no_running_app_allows_replacement(self):
        result = self.run_guard(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('replacement allowed', result.stdout)

    def test_process_inspection_failure_blocks_replacement(self):
        for status in (2, 3, 127):
            with self.subTest(status=status):
                result = self.run_guard(status)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Could not check', result.stderr)
                self.assertNotIn('replacement allowed', result.stdout)

    def test_checks_before_download_and_before_application_mutation(self):
        additions = '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                              if line.startswith('+') and not line.startswith('+++'))
        body = additions.split('install_1password_arm64() {', 1)[1].split('\n}', 1)[0]
        # Exercise the real installer prefix, stubbing downloads and unrelated setup.
        prefix = body.split('  sudo cp -a', 1)[0]
        for becomes_running in (False, True):
            with self.subTest(becomes_running=becomes_running), tempfile.TemporaryDirectory() as tmp:
                script = '''set -euo pipefail
checks=0
require_1password_stopped() {
 checks=$((checks + 1))
 if [[ $checks == 2 && $BECOMES_RUNNING == yes ]]; then return 1; fi
}
download() { :; }
install() { :; }
gpg() {
 if [[ " $* " == *' --show-keys '* ]]; then
  printf 'pub:::::::::\\nfpr:::::::::expected:\\n'
 elif [[ " $* " == *' --verify '* ]]; then
  printf '[GNUPG:] VALIDSIG expected\\n'
 fi
}
tar() { :; }
find() { printf '/fake/archive\\n'; }
omarchy-pkg-add() { :; }
sudo() { printf 'mutated\\n'; }
ONEPASSWORD_ARM_URL=unused
ONEPASSWORD_KEY_URL=unused
ONEPASSWORD_SIGNING_FINGERPRINT=expected
install_prefix() {
''' + prefix + '''
}
install_prefix
[[ $checks == 2 ]]
'''
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                                        env={**os.environ, 'TMPDIR': tmp,
                                             'BECOMES_RUNNING': 'yes' if becomes_running else 'no'})
                self.assertEqual(result.returncode == 0, not becomes_running, result.stderr)
                self.assertEqual('mutated' in result.stdout, not becomes_running)


if __name__ == '__main__':
    unittest.main()
