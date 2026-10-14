#!/usr/bin/python3 -I
"""Run user-owned migration steps as the desktop account, before login."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def migrate(payload, home, approved, uid=None, japanese=False, cmdline='', language=''):
    uid = os.getuid() if uid is None else uid
    fixes = load('user_transaction', payload / 'migrate.py')
    fixes.STATE = '.local/state/try-omarchy/boot-fixes'
    input_path = '.config/hypr/input.lua'
    menu_path = '.config/omarchy/extensions/omarchy-menu.jsonc'
    app_path = '.local/share/applications/Alacritty.desktop'
    backup_path = '.local/share/applications/.Alacritty.desktop.try-omarchy-backup'
    input_fixes = load('japanese_input', payload / 'japanese-input.py')
    fixes.TARGETS = {input_path, menu_path, app_path, backup_path} | input_fixes.TARGETS
    fixes.LINKS = {}
    fixes.MAX_FILE = 262144
    try:
        fixes.recover(home, uid)
    except (OSError, RuntimeError, ValueError, KeyError):
        return {'state': 'recovery-required', 'outcome': 'pending', 'japanese-input': 'pending'}
    changes = []
    preserved = False
    japanese_outcome = 'current'

    def add(relative, data, mode=0o644):
        before = fixes.snapshot(home / relative, home, uid)
        after = fixes.replacement(data, uid, before['gid'] if before else os.getgid()) if data is not None else None
        if after:
            after['mode'] = before['mode'] if before else mode
        if before != after:
            changes.append({'path': relative, 'before': before, 'after': after})

    try:
        before = fixes.snapshot(home / input_path, home, uid)
        if before:
            text = base64.b64decode(before['data']).decode()
            if 'pinch-input.lua' not in text and 'qemu-virtio-pinch-touchpad' not in text:
                add(input_path, text.encode() + b'\n' + (payload / 'pinch-input.lua').read_bytes())
    except (OSError, RuntimeError, ValueError):
        preserved = True
    try:
        before = fixes.snapshot(home / app_path, home, uid)
        if before and not shutil.which('alacritty', path=f'{home}/.local/bin:/usr/local/bin:/usr/bin:/bin'):
            # Exact pinned upstream desktop file, as in the manual helper.
            if fixes.digest(base64.b64decode(before['data'])) != '713703ba90ff8cd8d66eeb2804202e05e0c80c48e651ad00b9b7276f3d057683':
                raise RuntimeError('Customized Alacritty launcher')
            if fixes.snapshot(home / backup_path, home, uid) is not None:
                raise RuntimeError('Existing Alacritty launcher backup')
            changes.extend([{'path': backup_path, 'before': None, 'after': before},
                            {'path': app_path, 'before': before, 'after': None}])
    except (OSError, RuntimeError, ValueError):
        preserved = True
    try:
        before = fixes.snapshot(home / menu_path, home, uid)
        # Use the same preserving JSONC insertion as the former setup command.
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            menu = Path(temporary) / 'menu.jsonc'
            if before:
                menu.write_bytes(base64.b64decode(before['data']))
            updater = load('user_menu_updater', payload / 'integrations/updater.py')
            updater.menu_entry(path=menu, refresh=False)
            add(menu_path, menu.read_bytes())
    except (OSError, RuntimeError, ValueError):
        preserved = True
    desktop_changed = bool(changes)
    if japanese:
        japanese_changes, japanese_outcome = input_fixes.plan(fixes, payload, home, uid, cmdline, language)
        # Pinch and Apple input share a destination and one journal entry.
        for change in japanese_changes:
            existing = next((c for c in changes if c['path'] == change['path']), None)
            if existing:
                original = base64.b64decode(change['before']['data'])
                addition = base64.b64decode(change['after']['data'])[len(original):]
                existing['after']['data'] = base64.b64encode(base64.b64decode(existing['after']['data']) + addition).decode()
            else:
                changes.append(change)
    if changes and not approved:
        return {'state': 'skipped', 'outcome': 'pending' if desktop_changed else 'preserved' if preserved else 'current', 'japanese-input': japanese_outcome}
    if not changes:
        return {'state': 'complete', 'outcome': 'preserved' if preserved else 'current', 'japanese-input': japanese_outcome}
    state = fixes.apply_transaction(changes, home, uid)
    return {'state': state, 'outcome': ('preserved' if preserved else 'applied' if desktop_changed else 'current') if state == 'complete' else 'pending' if desktop_changed else 'current',
            'japanese-input': ('applied' if japanese_outcome == 'pending' else japanese_outcome) if state == 'complete' else 'pending'}


if __name__ == '__main__':
    args = sys.argv[1:]
    if os.geteuid() == 0 or args not in (['--apply'], ['--check'], ['--apply', '--japanese'], ['--check', '--japanese']):
        raise SystemExit('Run as the desktop user with --apply or --check')
    locale = Path('/etc/locale.conf')
    language = next((line.partition('=')[2].strip().strip('\"\'') for line in
                     (locale.read_text() if locale.is_file() else '').splitlines() if line.startswith('LANG=')), '')
    result = migrate(Path(__file__).resolve().parent, Path.home(), args[0] == '--apply',
                     japanese='--japanese' in args, cmdline=Path('/proc/cmdline').read_text(), language=language)
    print(json.dumps(result))
