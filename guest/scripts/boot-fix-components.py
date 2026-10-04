"""Reviewed existing-guest repairs, planned as one recoverable file transaction."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import sys

GROUPS = {
    'ghostty': {
        'install-ghostty-arm64': ('usr/local/lib/try-omarchy/install-ghostty-arm64', 0o755),
        'ghostty-PKGBUILD': ('usr/local/share/try-omarchy/ghostty/PKGBUILD', 0o644),
        'ghostty-wrapper': ('usr/local/share/try-omarchy/ghostty/ghostty-wrapper', 0o755),
        'ghostty-build-spec.json': ('usr/local/share/try-omarchy/ghostty/build-spec.json', 0o644),
        'omarchy-install-terminal': ('usr/bin/omarchy-install-terminal', 0o755),
    },
    'clock': {
        'guest-clock-recover': ('usr/local/lib/try-omarchy/guest-clock-recover', 0o755),
        'try-omarchy-clock-recovery.service': ('usr/lib/systemd/system/try-omarchy-clock-recovery.service', 0o644),
        'try-omarchy-clock-recovery.timer': ('usr/lib/systemd/system/try-omarchy-clock-recovery.timer', 0o644),
    },
    'touch-id': {
        'native-authentication-broker': ('usr/local/lib/try-omarchy/native-authentication-broker', 0o755),
        'try-omarchy-touch-id-enroll': ('usr/local/sbin/try-omarchy-touch-id-enroll', 0o755),
        'try-omarchy-touch-id-control': ('usr/local/sbin/try-omarchy-touch-id-control', 0o755),
        'try-omarchy-touch-id': ('usr/local/bin/try-omarchy-touch-id', 0o755),
        'try-omarchy-touch-id-test': ('usr/local/bin/try-omarchy-touch-id-test', 0o755),
        '93-omarchy-native-authentication.rules': ('etc/udev/rules.d/93-omarchy-native-authentication.rules', 0o644),
    },
    'onepassword': {
        'onepassword-touch-id-agent': ('usr/local/lib/try-omarchy/onepassword-touch-id-agent', 0o755),
        'onepassword-password-dialog': ('usr/local/lib/try-omarchy/onepassword-password-dialog', 0o755),
        'try-omarchy-onepassword-touch-id@.service': ('usr/lib/systemd/system/try-omarchy-onepassword-touch-id@.service', 0o644),
    },
    'battery': {
        'try-omarchy-battery.c': ('usr/src/try-omarchy-battery-1.3.0/try-omarchy-battery.c', 0o644),
        'Makefile': ('usr/src/try-omarchy-battery-1.3.0/Makefile', 0o644),
        'dkms.conf': ('usr/src/try-omarchy-battery-1.3.0/dkms.conf', 0o644),
        'omarchy-native-battery-bridge': ('usr/local/bin/omarchy-native-battery-bridge', 0o755),
        'omarchy-native-battery-bridge.service': ('usr/lib/systemd/system/omarchy-native-battery-bridge.service', 0o644),
        '95-omarchy-native-battery.rules': ('etc/udev/rules.d/95-omarchy-native-battery.rules', 0o644),
        '95-try-omarchy-battery.conf': ('etc/modules-load.d/95-try-omarchy-battery.conf', 0o644),
        '90-try-omarchy.conf': ('etc/UPower/UPower.conf.d/90-try-omarchy.conf', 0o644),
    },
}
LINKS = {
    'etc/systemd/system/timers.target.wants/try-omarchy-clock-recovery.timer': '/usr/lib/systemd/system/try-omarchy-clock-recovery.timer',
    'etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service': '/usr/lib/systemd/system/systemd-timesyncd.service',
    'etc/systemd/system/multi-user.target.wants/omarchy-native-battery-bridge.service': '/usr/lib/systemd/system/omarchy-native-battery-bridge.service',
    'etc/systemd/system/multi-user.target.wants/try-omarchy-integrations.service': '/usr/lib/systemd/system/try-omarchy-integrations.service',
    'var/lib/dkms/try-omarchy-battery/1.3.0/source': '/usr/src/try-omarchy-battery-1.3.0',
}
EXTRA_FILES = {'omarchy-lock-password', 'repair-update-holds.py', 'components.py',
               'preimages.json', 'user-fixes.py', 'pinch-input.lua', 'power-profile-hooks.json'}
POWER_TARGETS = {'usr/bin/omarchy-powerprofiles-list', 'usr/bin/omarchy-powerprofiles-set',
                 'usr/share/omarchy/shell/plugins/panels/power/Panel.qml',
                 'usr/share/omarchy/shell/plugins/panels/power/Model.js',
                 'usr/share/omarchy/shell/plugins/menu/Menu.qml'}
FIXED_TARGETS = {p for group in GROUPS.values() for p, _ in group.values()} | set(LINKS) | POWER_TARGETS | {
    'etc/pam.d/omarchy-lock-password', 'etc/pacman.conf', 'usr/share/try-omarchy/pacman.conf',
    'usr/local/bin/try-omarchy-integrations', 'usr/lib/systemd/system/try-omarchy-integrations.service',
}
MODULE = 'try_omarchy_battery'
VERSION = '1.3.0'


class BatteryUnavailable(RuntimeError):
    pass


class BatteryPreserved(RuntimeError):
    pass


def kernel():
    value = os.uname().release
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,127}', value):
        raise RuntimeError('Unsupported kernel release')
    return value


def targets(payload):
    k = kernel()
    LINKS[f'var/lib/dkms/try-omarchy-battery/kernel-{k}-aarch64'] = f'{VERSION}/{k}/aarch64'
    return FIXED_TARGETS | set(LINKS) | {
        f'usr/local/share/try-omarchy/integrations/{p.relative_to(payload / "integrations")}'
        for p in (payload / 'integrations').rglob('*') if p.is_file()
    } | {f'usr/lib/modules/{k}/updates/dkms/{MODULE}.ko{s}' for s in ('', '.xz', '.gz', '.zst')} | {
        f'var/lib/dkms/try-omarchy-battery/{VERSION}/{k}/aarch64/module/{MODULE}.ko',
    }


def allowed_link(relative, value):
    if value == LINKS.get(relative):
        return True
    if relative == f'var/lib/dkms/try-omarchy-battery/kernel-{kernel()}-aarch64':
        return value in {f'{v}/{kernel()}/aarch64' for v in ('1.0.0', '1.1.0', '1.2.0', VERSION)}
    return False


def run(args, check=True, timeout=20):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=timeout,
                          env={**os.environ, 'PATH': '/usr/local/sbin:/usr/local/bin:/usr/bin:/bin'})


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def plan(fixes, payload, root, uid):
    changes, outcomes = [], {}
    preimages = json.loads((payload / 'preimages.json').read_text())

    def add(group, relative, data, mode, recognized=True):
        before = fixes.snapshot(root / relative, root, uid)
        if before and recognized and base64.b64decode(before['data']) != data:
            if fixes.digest(base64.b64decode(before['data'])) not in preimages.get(relative, []):
                raise RuntimeError('Customized integration file')
        after = fixes.replacement(data, uid, before['gid'] if before else os.getgid())
        after['mode'] = mode
        if before != after:
            group.append({'path': relative, 'before': before, 'after': after})

    def link(group, relative):
        before = fixes.snapshot(root / relative, root, uid)
        after = {'link': LINKS[relative], 'uid': uid, 'gid': os.getgid()}
        if before not in (None, after):
            raise RuntimeError('Customized integration enablement')
        if before != after:
            group.append({'path': relative, 'before': before, 'after': after})

    for name, files in GROUPS.items():
        group = []
        try:
            if name == 'onepassword' and not (root / 'usr/local/lib/try-omarchy/onepassword-touch-id-agent').exists():
                outcomes[name] = 'current'  # Opt-in; do not enable a new feature.
                continue
            if name == 'onepassword' and outcomes.get('touch-id') in ('preserved', 'unavailable'):
                raise RuntimeError('Authentication support was preserved')
            if name == 'touch-id' and not all((root / p).exists() for p in (
                    'usr/bin/openssl', 'usr/lib/security/pam_exec.so')):
                outcomes[name] = 'unavailable'
                continue
            if name == 'clock' and (root / 'etc/systemd/system/try-omarchy-clock-recovery.timer').is_symlink():
                raise RuntimeError('Explicit clock recovery override')
            if name == 'clock' and (root / 'usr/lib/systemd/system/try-omarchy-clock-recovery.timer').exists() and not (root / 'etc/systemd/system/timers.target.wants/try-omarchy-clock-recovery.timer').exists():
                raise RuntimeError('Clock recovery was disabled')
            if name == 'battery' and ((root / 'etc/systemd/system/omarchy-native-battery-bridge.service').exists()
                    or (root / 'etc/systemd/system/omarchy-native-battery-bridge.service').is_symlink()):
                raise RuntimeError('Explicit battery service override')
            if (name == 'battery' and (root / 'usr/lib/systemd/system/omarchy-native-battery-bridge.service').exists()
                    and not (root / 'etc/systemd/system/multi-user.target.wants/omarchy-native-battery-bridge.service').is_symlink()):
                raise RuntimeError('Battery integration was disabled')
            if name == 'battery' and not all((root / p).exists() for p in (
                    'usr/bin/dkms', f'usr/lib/modules/{kernel()}/build',
                    'dev/virtio-ports/dev.tryomarchy.battery')):
                outcomes[name] = 'unavailable'
                continue
            for source, (relative, mode) in files.items():
                add(group, relative, (payload / source).read_bytes(), mode)
            # Preserve an enrolled older authentication protocol for explicit
            # review; installing support never edits enrollment or sudo PAM.
            if name == 'touch-id' and group and (root / 'var/lib/try-omarchy/native-authentication.json').exists():
                raise RuntimeError('Enrolled authentication needs explicit review')
            if name == 'clock':
                if not (root / 'usr/lib/systemd/system/systemd-timesyncd.service').is_file():
                    outcomes[name] = 'unavailable'
                    continue
                link(group, 'etc/systemd/system/timers.target.wants/try-omarchy-clock-recovery.timer')
                link(group, 'etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service')
            if name == 'battery':
                link(group, 'etc/systemd/system/multi-user.target.wants/omarchy-native-battery-bridge.service')
                link(group, 'var/lib/dkms/try-omarchy-battery/1.3.0/source')
                # A current source alone does not prove the module is current.
                loaded = root / f'sys/module/{MODULE}/version'
                if root == Path('/') and (run(['modinfo', '-F', 'version', MODULE], check=False).stdout.strip() != VERSION
                        or not loaded.is_file() or loaded.read_text().strip() != VERSION):
                    outcomes[name] = 'pending'
                else:
                    outcomes[name] = 'pending' if group else 'current'
            else:
                outcomes[name] = 'pending' if group else 'current'
            changes.extend(group)
        except (OSError, RuntimeError, ValueError):
            outcomes[name] = 'preserved'

    for name in ('power', 'holds', 'lock', 'integrations'):
        group = []
        try:
            if name == 'power':
                for hook in json.loads((payload / 'power-profile-hooks.json').read_text()):
                    relative = hook['path']
                    before = fixes.snapshot(root / relative, root, uid)
                    if before is None:
                        continue
                    text = base64.b64decode(before['data']).decode()
                    sha = fixes.digest(text.encode())
                    if sha == hook['afterSha256']:
                        continue
                    version = next((v for v in [hook, *hook.get('previousVersions', [])] if sha == v['beforeSha256']), None)
                    if version is None:
                        raise RuntimeError('Customized power plugin')
                    for old, new in version['replacements']:
                        if text.count(old) != 1:
                            raise RuntimeError('Power plugin preimage mismatch')
                        text = text.replace(old, new)
                    if fixes.digest(text.encode()) != hook['afterSha256']:
                        raise RuntimeError('Power plugin postimage mismatch')
                    add(group, relative, text.encode(), before['mode'], recognized=False)
            elif name == 'holds':
                if (root / 'var/lib/pacman/db.lck').exists():
                    outcomes[name] = 'unavailable'
                    continue
                helper = load('holds', payload / 'repair-update-holds.py')
                for relative in helper.CONFIGS:
                    before = fixes.snapshot(root / relative, root, uid)
                    if before is None:
                        outcomes[name] = 'unavailable'
                        break
                    text = helper.add_holds(base64.b64decode(before['data']).decode())
                    add(group, relative, text.encode(), before['mode'], recognized=False)
                if name in outcomes:
                    continue
            elif name == 'lock':
                # Seed only a missing password policy; preserve all existing PAM.
                relative = 'etc/pam.d/omarchy-lock-password'
                before = fixes.snapshot(root / relative, root, uid)
                data = (payload / 'omarchy-lock-password').read_bytes()
                if before and base64.b64decode(before['data']) != data:
                    raise RuntimeError('Existing lock policy')
                if not (root / 'usr/lib/security/pam_faillock.so').is_file():
                    outcomes[name] = 'unavailable'
                    continue
                add(group, relative, data, 0o644)
            else:
                bundle = payload / 'integrations'
                updater = load('updater', bundle / 'updater.py')
                incoming = updater.manifest(bundle.resolve())
                store = root / 'usr/local/share/try-omarchy/integrations'
                installed = updater.manifest(store.resolve()) if store.exists() else None
                if installed and set(installed['files']) - set(incoming['files']):
                    raise RuntimeError('Newer integration bundle')
                for path in sorted(bundle.rglob('*')):
                    if not path.is_file():
                        continue
                    relative = f'usr/local/share/try-omarchy/integrations/{path.relative_to(bundle)}'
                    # The verified previous bundle is an exact preimage.
                    add(group, relative, path.read_bytes(), path.stat().st_mode & 0o777, recognized=False)
                for source, relative in updater.BOOTSTRAP_FILES.items():
                    add(group, relative.lstrip('/'), (bundle / source).read_bytes(), 0o755 if source.endswith('integrations') else 0o644)
                link(group, 'etc/systemd/system/multi-user.target.wants/try-omarchy-integrations.service')
            changes.extend(group)
            outcomes[name] = 'pending' if group else 'current'
        except (OSError, RuntimeError, ValueError):
            outcomes[name] = 'preserved'
    return changes, outcomes


def build_battery(fixes, payload, root, uid, changes):
    """Build privately before touching the installed module or DKMS registry."""
    k = kernel()
    if os.uname().machine != 'aarch64' or root != Path('/'):
        raise BatteryUnavailable('Battery builds require the ARM64 guest')
    for command in ('dkms', 'make', 'gcc', 'modinfo', 'modprobe', 'depmod'):
        if shutil.which(command) is None:
            raise BatteryUnavailable('Battery build tool unavailable')
    state = fixes.journal_path(root, uid).parent
    with tempfile.TemporaryDirectory(prefix='battery-build-', dir=state) as temporary:
        stage = Path(temporary)
        sources = stage / 'src' / f'try-omarchy-battery-{VERSION}'
        sources.mkdir(parents=True)
        for name in ('try-omarchy-battery.c', 'Makefile', 'dkms.conf'):
            shutil.copy2(payload / name, sources / name)
        # Kbuild has no installed-DKMS/signing-key side effects. Publish its
        # verified module and the DKMS source/build/active receipts together.
        run(['make', '-j2', '-C', f'/usr/lib/modules/{k}/build', f'M={sources}', 'modules'], timeout=180)
        built = sources / f'{MODULE}.ko'
        if (run(['modinfo', '-F', 'version', str(built)]).stdout.strip() != VERSION
                or run(['modinfo', '-F', 'vermagic', str(built)]).stdout.split()[0] != k):
            raise RuntimeError('Battery build verification failed')
        existing = run(['modinfo', '-n', MODULE], check=False)
        relative = f'usr/lib/modules/{k}/updates/dkms/{MODULE}.ko'
        if existing.returncode == 0:
            relative = str(Path(existing.stdout.strip()).resolve()).lstrip('/')
            if relative not in targets(payload):
                raise BatteryPreserved('Unsupported battery module location')
            if run(['modinfo', '-F', 'version', MODULE]).stdout.strip() not in ('1.0.0', '1.1.0', '1.2.0', VERSION):
                raise BatteryPreserved('Unrecognized battery module version')
        data = built.read_bytes()
        if relative.endswith('.xz'):
            import lzma
            data = lzma.compress(data)
        elif relative.endswith('.gz'):
            import gzip
            data = gzip.compress(data, mtime=0)
        elif relative.endswith('.zst'):
            compressed = stage / f'{MODULE}.ko.zst'
            run(['zstd', '-q', str(built), '-o', str(compressed)])
            data = compressed.read_bytes()
        receipt = f'var/lib/dkms/try-omarchy-battery/{VERSION}/{k}/aarch64/module/{MODULE}.ko'
        group = []
        for target, content in ((relative, data), (receipt, built.read_bytes())):
            before = fixes.snapshot(root / target, root, uid)
            after = fixes.replacement(content, uid, os.getgid())
            after['mode'] = 0o644
            if before != after:
                group.append({'path': target, 'before': before, 'after': after})
        active = f'var/lib/dkms/try-omarchy-battery/kernel-{k}-aarch64'
        before = fixes.snapshot(root / active, root, uid)
        if before is not None and ('link' not in before or not allowed_link(active, before['link'])):
            raise BatteryPreserved('Customized DKMS active receipt')
        after = {'link': LINKS[active], 'uid': uid, 'gid': os.getgid()}
        if before != after:
            group.append({'path': active, 'before': before, 'after': after})
        changes.extend(group)


def runtime_before(outcomes, root):
    if root != Path('/'):
        return {}
    services = []
    if outcomes.get('battery') == 'pending':
        services += ['omarchy-native-battery-bridge.service', 'upower.service']
    if outcomes.get('clock') == 'pending':
        services += ['systemd-timesyncd.service', 'try-omarchy-clock-recovery.timer']
    if outcomes.get('integrations') == 'pending':
        services += ['try-omarchy-integrations.service']
    return {'services': {s: run(['systemctl', 'is-active', '--quiet', s], check=False).returncode == 0 for s in services},
            'battery-loaded': (root / f'sys/module/{MODULE}').exists() if outcomes.get('battery') == 'pending' else None}


def activate(runtime, restoring=False):
    if not runtime:
        return
    run(['systemctl', 'daemon-reload'])
    if runtime.get('battery-loaded') is not None:
        run(['systemctl', 'stop', 'omarchy-native-battery-bridge.service'])
        if Path(f'/sys/module/{MODULE}').exists():
            run(['modprobe', '-r', MODULE])
        run(['depmod', '-a', kernel()])
        if not restoring or runtime['battery-loaded']:
            run(['modprobe', MODULE])
        if not restoring and Path(f'/sys/module/{MODULE}/version').read_text().strip() != VERSION:
            raise RuntimeError('Loaded battery module verification failed')
        if not restoring and 'installed' not in run(['dkms', 'status', '-k', kernel(), f'try-omarchy-battery/{VERSION}']).stdout:
            raise RuntimeError('Battery DKMS registration verification failed')
    run(['udevadm', 'control', '--reload-rules'])
    run(['udevadm', 'trigger', '--subsystem-match=virtio-ports'])
    for service, was_active in runtime['services'].items():
        if service == 'upower.service':
            run(['systemctl', 'try-restart', service])
        elif restoring:
            run(['systemctl', 'start' if was_active else 'stop', service])
        else:
            run(['systemctl', 'restart', service])
    if not restoring and runtime.get('battery-loaded') is not None:
        if not Path('/sys/devices/platform/try-omarchy-battery/state').exists():
            raise RuntimeError('Battery device verification failed')


def package(guest, payload):
    """One inventory builder shared by app packaging and migration fixtures."""
    spec = json.loads((guest / 'spec.json').read_text())
    pins = spec['supplyChain']['ghostty']
    hook = next(b for b in spec['authenticity']['backports'] if b['id'] == 'ghostty-arm64-terminal')
    terminal = guest / 'migrations/omarchy-install-terminal'
    if hashlib.sha256(terminal.read_bytes()).hexdigest() != hook['targets'][0]['afterSha256']:
        raise RuntimeError('Ghostty terminal hook does not match the reviewed backport')
    for name, field in (('PKGBUILD', 'recipeSha256'), ('ghostty-wrapper', 'wrapperSha256')):
        asset = guest / 'native-overlay/usr/local/share/try-omarchy/ghostty' / name
        if hashlib.sha256(asset.read_bytes()).hexdigest() != pins[field]:
            raise RuntimeError('Ghostty update asset digest mismatch: ' + name)
    (payload / 'ghostty-build-spec.json').write_text(json.dumps({'supplyChain': {'ghostty': pins}}, sort_keys=True) + '\n')
    for group in GROUPS.values():
        for name, (relative, mode) in group.items():
            if name != 'ghostty-build-spec.json':
                source = (guest / 'native-module/try-omarchy-battery' / name if relative.startswith('usr/src/')
                          else terminal if name == 'omarchy-install-terminal' else guest / 'native-overlay' / relative)
                shutil.copy2(source, payload / name)
            (payload / name).chmod(mode)
    for name, source in {
        'components.py': guest / 'scripts/boot-fix-components.py',
        'repair-update-holds.py': guest / 'scripts/repair-update-holds.py',
        'user-fixes.py': guest / 'scripts/migrate-user-fixes.py',
        'preimages.json': guest / 'migrations/preimages.json',
        'omarchy-lock-password': guest / 'migrations/omarchy-lock-password',
        'pinch-input.lua': guest / 'native-overlay/usr/share/try-omarchy/pinch-input.lua',
    }.items():
        shutil.copy2(source, payload / name)
    builder = load('integration_builder', guest.parent / 'integrations/build-bundle.py')
    builder.build(payload / 'integrations')


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] != '--payload':
        raise SystemExit('Usage: boot-fix-components.py --payload GUEST DESTINATION')
    package(Path(sys.argv[2]), Path(sys.argv[3]))
