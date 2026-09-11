#!/usr/bin/env python3
"""Package reviewed guest integrations independently of the factory image."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    'scripts/install-touch-id-sudo.sh', 'scripts/install-touch-id-menu-entry.py',
    'scripts/install-clock-recovery.sh', 'scripts/install-onepassword-touch-id.sh',
    'scripts/repair-update-holds.py',
    'native-overlay/usr/local/lib/try-omarchy/native-authentication-broker',
    'native-overlay/usr/local/lib/try-omarchy/onepassword-touch-id-agent',
    'native-overlay/usr/local/lib/try-omarchy/onepassword-password-dialog',
    'native-overlay/usr/local/lib/try-omarchy/guest-clock-recover',
    'native-overlay/usr/local/sbin/try-omarchy-touch-id-enroll',
    'native-overlay/usr/local/sbin/try-omarchy-touch-id-control',
    'native-overlay/usr/local/bin/try-omarchy-touch-id',
    'native-overlay/usr/local/bin/try-omarchy-touch-id-test',
    'native-overlay/etc/udev/rules.d/93-omarchy-native-authentication.rules',
    'native-overlay/usr/lib/systemd/system/try-omarchy-onepassword-touch-id@.service',
    'native-overlay/usr/lib/systemd/system/try-omarchy-clock-recovery.service',
    'native-overlay/usr/lib/systemd/system/try-omarchy-clock-recovery.timer',
]

def build(destination):
    destination.mkdir(parents=True, exist_ok=False)
    for name in FILES:
        target = destination / 'guest' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / 'guest' / name, target)
    for name in ('updater.py', 'setup', 'try-omarchy-integrations', 'try-omarchy-integrations.service'):
        shutil.copy2(ROOT / 'integrations' / name, destination / name)
    files = {str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(destination.rglob('*')) if p.is_file()}
    identity = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    (destination / 'manifest.json').write_text(json.dumps({
        'schema': 1, 'version': 1, 'identity': identity, 'files': files,
    }, sort_keys=True, indent=2) + '\n')

if __name__ == '__main__':
    build(Path(sys.argv[1]))
