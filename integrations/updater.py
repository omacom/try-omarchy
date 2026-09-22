#!/usr/bin/env python3
"""Review, install, and report the guest integrations bundled with Try Omarchy."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
BUNDLE = Path(__file__).resolve().parent
STORE = Path('/usr/local/share/try-omarchy/integrations')
STATE = Path('/var/lib/try-omarchy/integrations')
PORT = Path('/dev/virtio-ports/dev.tryomarchy.integrations')
COMPONENTS = {
    'sudo': ('Touch ID support for sudo (pairing remains optional)', 'install-touch-id-sudo.sh'),
    'battery': ('Mac battery in the Omarchy bar', 'install-battery-into-existing-guest.sh'),
}
# Matches PACKAGE_VERSION in the module's dkms.conf and the factory package.
BATTERY_VERSION = '1.0.0'
BATTERY_MODULE_FILES = ('try-omarchy-battery.c', 'Makefile', 'dkms.conf')
BATTERY_PORT = Path('/dev/virtio-ports/dev.tryomarchy.battery')
KERNEL_MODULES = Path('/usr/lib/modules')
BOOTSTRAP_FILES = {
    'try-omarchy-integrations': '/usr/local/bin/try-omarchy-integrations',
    'try-omarchy-integrations.service': '/usr/lib/systemd/system/try-omarchy-integrations.service',
}


def run(args, **kwargs):
    kwargs.setdefault('check', True)
    return subprocess.run(args, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(directory):
    data = json.loads((directory / 'manifest.json').read_text())
    if data.get('schema') != 1 or data.get('version') != 1 or not isinstance(data.get('files'), dict):
        raise RuntimeError('This integration bundle needs a newer updater.')
    if not 1 <= len(data['files']) <= 100:
        raise RuntimeError('Invalid integration file inventory.')
    actual = set()
    for entry in directory.rglob('*'):
        if entry.is_symlink() or not (entry.is_file() or entry.is_dir()):
            raise RuntimeError('Integration bundle contains a symlink or special file.')
        if entry.is_file() and entry.name != 'manifest.json':
            actual.add(str(entry.relative_to(directory)))
    if actual != set(data['files']):
        raise RuntimeError('Integration bundle has unexpected or missing files.')
    for name, expected in data['files'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or not isinstance(expected, str):
            raise RuntimeError('Invalid integration file path.')
        path = directory / relative
        if any(p.is_symlink() for p in [path, *path.parents] if p != directory.parent):
            raise RuntimeError('Integration bundle contains a symlink.')
        if not path.is_file() or digest(path) != expected:
            raise RuntimeError(f'Integration bundle verification failed: {name}')
    identity = hashlib.sha256(json.dumps(data['files'], sort_keys=True).encode()).hexdigest()
    if identity != data.get('identity'):
        raise RuntimeError('Integration manifest identity mismatch.')
    return data


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def safe_destination(path):
    for parent in [path, *path.parents]:
        if parent.is_symlink():
            raise RuntimeError(f'Refusing symlink destination: {path}')
        if parent.exists():
            info = parent.stat()
            if info.st_uid != 0 or info.st_mode & 0o022:
                raise RuntimeError(f'Destination must be root-owned and not user-writable: {parent}')


def component_paths(name, directory=None):
    directory = directory or BUNDLE
    if name == 'bootstrap':
        return [(directory / source, Path(target)) for source, target in BOOTSTRAP_FILES.items()]
    overlay = directory / 'guest/native-overlay'
    if name == 'sudo':
        names = ['usr/local/lib/try-omarchy/native-authentication-broker',
                 'usr/local/sbin/try-omarchy-touch-id-enroll',
                 'usr/local/sbin/try-omarchy-touch-id-control',
                 'usr/local/bin/try-omarchy-touch-id', 'usr/local/bin/try-omarchy-touch-id-test',
                 'etc/udev/rules.d/93-omarchy-native-authentication.rules']
    elif name == 'battery':
        # DKMS sources live where the factory image's package puts them, so a
        # factory guest already reports current and is not reinstalled.
        module = directory / 'guest/native-module/try-omarchy-battery'
        sources = Path(f'/usr/src/try-omarchy-battery-{BATTERY_VERSION}')
        names = ['usr/local/bin/omarchy-native-battery-bridge',
                 'usr/lib/systemd/system/omarchy-native-battery-bridge.service',
                 'etc/udev/rules.d/95-omarchy-native-battery.rules',
                 'etc/modules-load.d/95-try-omarchy-battery.conf',
                 'etc/UPower/UPower.conf.d/90-try-omarchy.conf']
        return ([(module / file, sources / file) for file in BATTERY_MODULE_FILES]
                + [(overlay / name, Path('/') / name) for name in names])
    else:
        raise RuntimeError('Unsupported integration component: ' + name)
    return [(overlay / name, Path('/') / name) for name in names]


def files_current(name, directory=None):
    return all(not target.is_symlink() and target.is_file() and digest(source) == digest(target)
               and target.stat().st_uid == 0 and not target.stat().st_mode & 0o022
               and stat.S_IMODE(target.stat().st_mode) == stat.S_IMODE(source.stat().st_mode)
               for source, target in component_paths(name, directory))


def component_configuration_paths(name):
    if name == 'sudo':
        # The sudo installer migrates enrollment and PAM policy, and updates
        # account defaults. Retain these before any of those operations run.
        return [Path(path) for path in (
            '/etc/pam.d/sudo',
            '/var/lib/try-omarchy/native-authentication.json',
            '/etc/skel/.config/omarchy/extensions/omarchy-menu.jsonc',
        )]
    return []


def backup_component(name, directory, backup):
    targets = [target for _, target in component_paths(name, directory)]
    targets.extend(component_configuration_paths(name))
    for target in targets:
        safe_destination(target)
        if target.exists():
            if not target.is_file():
                raise RuntimeError(f'Refusing non-file backup source: {target}')
            dest = backup / str(target).lstrip('/')
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, dest)


def unavailable_reason(name):
    """Why a component cannot be installed in this guest, or None."""
    if name != 'battery':
        return None
    if not BATTERY_PORT.exists():
        return 'this app did not provide the battery port; restart Try Omarchy and retry'
    if shutil.which('dkms') is None:
        return 'this VM has no DKMS to build the battery module; a newer VM image is required'
    # Missing after a kernel update until reboot, and on images without headers.
    if not (KERNEL_MODULES / os.uname().release / 'build').exists():
        return 'no kernel headers for the running kernel; restart Omarchy after a kernel update and retry'
    return None


def battery_module_built():
    result = run(['dkms', 'status', '-k', os.uname().release, f'try-omarchy-battery/{BATTERY_VERSION}'],
                 check=False, capture_output=True, text=True)
    return result.returncode == 0 and 'installed' in result.stdout


def guest_status(loaded_identity=None):
    data = manifest(BUNDLE)
    progress = json.loads((STATE / 'progress.json').read_text()) if (STATE / 'progress.json').exists() else {'status': 'complete'}
    components = {}
    for name in ['bootstrap', *COMPONENTS]:
        try:
            components[name] = 'current' if files_current(name) else 'repair'
        except (OSError, ValueError):
            components[name] = 'repair'
        if components[name] == 'repair' and unavailable_reason(name):
            components[name] = 'disabled'
    if progress.get('status') != 'complete' or (loaded_identity is not None and loaded_identity != data['identity']):
        components['bootstrap'] = 'repair'
    return {'schema': 1, 'version': data['version'], 'identity': loaded_identity or data['identity'],
            'components': components, 'paired': Path('/var/lib/try-omarchy/native-authentication.json').is_file()}


def report():
    loaded_identity = manifest(BUNDLE)['identity']
    while True:
        with PORT.open('wb', buffering=0) as channel:
            while True:
                channel.write(json.dumps(guest_status(loaded_identity), separators=(',', ':')).encode() + b'\n')
                time.sleep(10)


def verify_upgrade(installed_directory, incoming_directory):
    if not (installed_directory / 'manifest.json').is_file():
        return
    installed = json.loads((installed_directory / 'manifest.json').read_text())
    if installed.get('schema') != 1 or installed.get('version') != 1 or not isinstance(installed.get('files'), dict):
        raise RuntimeError('The installed bundle needs a matching or newer updater.')
    identity = hashlib.sha256(json.dumps(installed['files'], sort_keys=True).encode()).hexdigest()
    if installed.get('identity') != identity:
        raise RuntimeError('The installed bundle inventory cannot be verified; retain it and repair its manifest before retrying.')
    incoming = manifest(incoming_directory)
    if set(installed['files']) - set(incoming['files']):
        raise RuntimeError('The installed bundle contains additional integrations. Use a matching or newer app; this bundle will not remove their support.')


def install(user, selected):
    if os.geteuid() != 0:
        raise RuntimeError('Installation requires the guest administrator password.')
    if 'omarchy.qemu_virgl=1' not in Path('/proc/cmdline').read_text().split():
        raise RuntimeError('Run this installer inside Try Omarchy.')
    account = pwd.getpwnam(user)
    if account.pw_uid == 0 or os.environ.get('SUDO_UID') != str(account.pw_uid):
        raise RuntimeError('Run this command with sudo from your normal Omarchy account.')
    manifest(BUNDLE)
    for path in (STATE, STORE, *(target for _, target in component_paths('bootstrap'))):
        safe_destination(path)
    verify_upgrade(STORE, BUNDLE)
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STATE / 'install.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if Path('/var/lib/pacman/db.lck').exists():
            raise RuntimeError('Close the package updater before installing integrations.')
        # Stage a private, verified copy before any privileged installer executes.
        stage = Path(tempfile.mkdtemp(prefix='bundle-', dir=STATE))
        shutil.copytree(BUNDLE, stage / 'payload', symlinks=True)
        payload = stage / 'payload'
        data = manifest(payload)
        for path in payload.rglob('*'):
            os.chown(path, 0, 0)
            path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
        state_path = STATE / 'state.json'
        state = json.loads(state_path.read_text()) if state_path.exists() else {'completed': {}}
        for name in selected:
            # Resume only a verified completed step; a receipt alone is insufficient.
            try:
                healthy = files_current(name, payload)
            except (OSError, ValueError):
                healthy = False
            if state['completed'].get(name) == data['identity'] and healthy:
                print(f'{name}: already verified; retained.')
                continue
            if name == 'battery' and healthy and battery_module_built():
                # Factory and retrofitted guests: leave package-owned files alone.
                print('battery: already installed; retained.')
                state['completed'][name] = data['identity']
                atomic_json(state_path, state)
                continue
            reason = unavailable_reason(name)
            if reason:
                print(f'{name}: skipped; {reason}.')
                continue
            atomic_json(STATE / 'progress.json', {'component': name, 'status': 'installing'})
            backup = Path(tempfile.mkdtemp(prefix=f'{name}-backup-', dir=STATE))
            backup_component(name, payload, backup)
            script = payload / 'guest/scripts' / COMPONENTS[name][1]
            args = ['/bin/bash', str(script)]
            environment = os.environ.copy()
            if name == 'sudo':
                # The existing installer otherwise invokes a user helper inside
                # our root-private staging tree. Publish menus only after STORE.
                environment['SUDO_USER'] = 'root'
            elif name == 'battery':
                args += ['--source', str(payload / 'guest')]
            run(args, env=environment)
            if not files_current(name, payload):
                raise RuntimeError(f'{name}: installed files did not pass verification. Backup: {backup}')
            state['completed'][name] = data['identity']
            atomic_json(state_path, state)
        STORE.parent.mkdir(parents=True, exist_ok=True)
        replacement = Path(tempfile.mkdtemp(prefix='.integrations-', dir=STORE.parent)) / 'bundle'
        shutil.copytree(payload, replacement)
        manifest(replacement)
        # Keep the previous bundle so an interrupted replacement can be repaired.
        if STORE.exists():
            STORE.rename(stage / 'previous-bundle')
        try:
            replacement.rename(STORE)
        except OSError:
            if not STORE.exists() and (stage / 'previous-bundle').exists():
                (stage / 'previous-bundle').rename(STORE)
            raise
        for source, target in component_paths('bootstrap', payload):
            shutil.copy2(source, target)
        if not files_current('bootstrap', payload):
            raise RuntimeError('Bootstrap files did not pass verification. Retry integration setup.')
        # Preserve existing user menu entries, including the sudo entry just installed.
        run(['runuser', '-u', user, '--', '/usr/bin/python3', '-I', str(STORE / 'updater.py'), 'menu-install'])
        run(['systemctl', 'daemon-reload'])
        run(['systemctl', 'enable', '--now', 'try-omarchy-integrations.service'])
        run(['systemctl', 'restart', 'try-omarchy-integrations.service'])
        atomic_json(STATE / 'progress.json', {'status': 'complete'})
        print('Integrations installed and checked. Backups retained in ' + str(STATE))
        print('Open Omarchy Menu > Setup > Try Omarchy Integrations for updates and optional features.')


def menu_entry(path=None, refresh=True):
    spec = importlib.util.spec_from_file_location('integration_menu', BUNDLE / 'guest/scripts/install-touch-id-menu-entry.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    destination = path or Path.home() / '.config/omarchy/extensions/omarchy-menu.jsonc'
    module.install(destination)
    module.ENTRY_ID = '"setup.try-omarchy-integrations"'
    module.ENTRY = '  "setup.try-omarchy-integrations": {"label":"Try Omarchy Integrations","action":"setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.terminal --title=Try-Omarchy-Integrations -e /usr/local/bin/try-omarchy-integrations"},\n'
    previous_entry = '  "setup.try-omarchy-integrations": {"label":"Try Omarchy Integrations","action":"omarchy-launch-floating-terminal-with-presentation /usr/local/bin/try-omarchy-integrations"},\n'
    module.install(destination, previous_entry=previous_entry)
    if refresh:
        environment = os.environ.copy()
        environment.setdefault('OMARCHY_PATH', str(Path.home() / '.local/share/omarchy'))
        result = run(['omarchy', 'menu', 'refresh'], env=environment, check=False, capture_output=True, text=True)
        if result.returncode:
            detail = (result.stderr or result.stdout).strip()
            print(f'Menu entries saved; live refresh deferred: {detail}. They will load when the Omarchy shell starts.')


def review():
    manifest(BUNDLE)
    print('\nTry Omarchy Integrations\n')
    for name in COMPONENTS:
        try:
            state = 'installed' if files_current(name) else 'available or needs repair'
        except (OSError, ValueError):
            state = 'available or needs repair'
        reason = unavailable_reason(name) if state != 'installed' else None
        if reason:
            state = 'unavailable (' + reason + ')'
        print(f'  {COMPONENTS[name][0]}: {state}')
    print('\n1. Install/update integration support\n2. Set up or test Touch ID for sudo\n3. Exit')
    choice = input('\nChoose [1-3]: ').strip()
    if choice == '2':
        try:
            run(['/usr/local/bin/try-omarchy-touch-id'])
        finally:
            if sys.stdin.isatty():
                input('\nPress Enter to close the Touch ID result…')
        return
    if choice != '1':
        return
    selected = list(COMPONENTS)
    print('\nExisting integration files may be replaced; backups will be retained.')
    for name in selected:
        for source, target in component_paths(name):
            if target.is_file() and digest(source) != digest(target):
                print('  Replace with bundled version: ' + str(target))
    print('Your VM, applications, and personal files will be retained. No OS packages will be upgraded.')
    if input('Continue with installation? [y/N] ').strip().lower() != 'y':
        return
    user = pwd.getpwuid(os.getuid()).pw_name
    try:
        run(['sudo', '/usr/bin/python3', '-I', str(BUNDLE / 'updater.py'), 'install', user, *selected])
        menu_entry()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print('Integration setup could not complete: ' + str(error), file=sys.stderr)
        print('Review the messages above before closing. Resolve the reported problem and retry.', file=sys.stderr)
        raise
    finally:
        if sys.stdin.isatty():
            input('\nPress Enter to close the installation result…')


if __name__ == '__main__':
    try:
        action = sys.argv[1] if len(sys.argv) > 1 else 'review'
        if action == 'report':
            report()
        elif action == 'review':
            review()
        elif action == 'menu':
            menu_entry()
        elif action == 'menu-install':
            menu_entry(refresh=False)
        elif action == 'stage-menu' and len(sys.argv) == 3:
            menu_entry(Path(sys.argv[2]), refresh=False)
        elif action == 'install' and len(sys.argv) >= 4 and all(s in COMPONENTS for s in sys.argv[3:]):
            install(sys.argv[2], sys.argv[3:])
        else:
            raise RuntimeError('Unknown integration action.')
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print('Integration setup could not complete: ' + str(error), file=sys.stderr)
        print('Previous files and progress are retained. Resolve the reported problem and retry.', file=sys.stderr)
        sys.exit(1)
