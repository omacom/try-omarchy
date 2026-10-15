import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import test_settings_install as support
from test_boot_components import users
from test_boot_components import extras

spec = importlib.util.spec_from_file_location('japanese_migration', support.GUEST / 'scripts/migrate-japanese-input.py')
japanese = importlib.util.module_from_spec(spec)
spec.loader.exec_module(japanese)


def register(root, *names):
    """Record packages in a fake pacman local database."""
    for name in names:
        entry = root / 'var/lib/pacman/local' / f'{name}-1.0-1'
        entry.mkdir(parents=True, exist_ok=True)
        (entry / 'desc').write_text(f'%NAME%\n{name}\n\n%VERSION%\n1.0-1\n\n')


class JapaneseMigrationTests(unittest.TestCase):
    def prepare(self, directory, profile='profile-korean.ini'):
        payload = support.SettingsInstallTests().make_payload(directory)
        home = Path(directory) / 'home'
        for relative, data in {
            japanese.INPUT: b'-- existing keyboard layout\nhl.config({input = {kb_layout = "jp"}})\n',
            japanese.PROFILE: (payload / profile).read_bytes(),
        }.items():
            path = home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o600)
        return payload, home

    def run_user(self, payload, home, approved=True, cmdline='tryomarchy.keyboard=jis', language='en_US.UTF-8', layout='us'):
        return users.migrate(payload, home, approved, japanese=True, cmdline=cmdline, language=language, layout=layout)

    def test_skip_then_apply_and_repeat_preserve_layout_and_metadata(self):
        for seed in ('profile-chewing.ini', 'profile-korean.ini', 'fcitx5-profile.ini'):
            with self.subTest(seed=seed), tempfile.TemporaryDirectory() as directory:
                payload, home = self.prepare(directory, seed)
                original = (home / japanese.INPUT).read_bytes()
                self.assertEqual('skipped', self.run_user(payload, home, False)['state'])
                self.assertEqual(original, (home / japanese.INPUT).read_bytes())
                self.assertFalse((home / japanese.CONFIG).exists())
                result = self.run_user(payload, home)
                self.assertEqual('applied', result['japanese-input'])
                input_text = (home / japanese.INPUT).read_text()
                self.assertTrue(input_text.startswith(original.decode()))
                self.assertNotIn('apple-keyboard-input.lua', input_text)
                self.assertEqual(1, input_text.count('qemu-virtio-pinch-touchpad'))
                profile = japanese.parse((home / japanese.PROFILE).read_bytes())
                self.assertEqual('mozc', profile['Groups/0/Items/1']['Name'])
                self.assertEqual('keyboard-us', profile['Groups/0/Items/0']['Name'])
                keys = japanese.parse((home / japanese.CONFIG).read_bytes())
                self.assertEqual('Hangul', keys['Hotkey/ActivateKeys']['0'])
                self.assertEqual('Hangul_Hanja', keys['Hotkey/DeactivateKeys']['0'])
                paths = [home / p for p in japanese.TARGETS if p != japanese.INPUT]
                inodes = [p.stat().st_ino for p in paths]
                self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in paths))
                self.assertEqual('current', self.run_user(payload, home)['japanese-input'])
                self.assertEqual(inodes, [p.stat().st_ino for p in paths])

    def test_fcitx_saved_stock_and_korean_group_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, home = self.prepare(directory)
            profile = home / japanese.PROFILE
            original = profile.read_text().replace('DefaultIM=keyboard-us', 'DefaultIM=chewing')
            original = original.replace('0=Default\n1=Korean', '0=Korean\n1=Default')
            profile.write_text(original)
            self.run_user(payload, home)
            updated = japanese.parse(profile.read_bytes())
            self.assertEqual({'0': 'Korean', '1': 'Default'}, updated['GroupOrder'])
            self.assertEqual(japanese.parse(original.encode())['Groups/1'], updated['Groups/1'])
            self.assertEqual('chewing', updated['Groups/0/Items/1']['Name'])
            self.assertEqual('mozc', updated['Groups/0/Items/2']['Name'])
            self.assertEqual('current', self.run_user(payload, home)['japanese-input'])

    def test_current_japanese_factory_profile_keeps_its_keyboard(self):
        from test_japanese_input import module as initializer
        with tempfile.TemporaryDirectory() as directory:
            payload, home = self.prepare(directory, 'fcitx5-profile.ini')
            profile = home / japanese.PROFILE
            initializer.initialize(profile, payload / 'fcitx5-profile.ini',
                                   'tryomarchy.keyboard=jis', 'ja_JP.UTF-8', 'jp')
            original = profile.read_bytes()
            self.assertEqual('current', self.run_user(payload, home, layout='jp')['japanese-input'])
            self.assertEqual(original, profile.read_bytes())
            self.assertEqual('current', self.run_user(payload, home, layout='jp')['japanese-input'])

    def test_japanese_layout_is_matched_so_mozc_uses_its_jis_kana_table(self):
        for seed in ('profile-chewing.ini', 'profile-korean.ini'):
            with self.subTest(seed=seed), tempfile.TemporaryDirectory() as directory:
                payload, home = self.prepare(directory, seed)
                profile = home / japanese.PROFILE
                self.assertEqual('applied', self.run_user(payload, home, layout='jp')['japanese-input'])
                updated = japanese.parse(profile.read_bytes())
                self.assertEqual('jp', updated['Groups/0']['Default Layout'])
                self.assertEqual(['keyboard-jp', 'mozc', 'chewing'],
                                 [updated[f'Groups/0/Items/{i}']['Name'] for i in range(3)])
                if 'Groups/1' in updated:
                    # The separate Korean group keeps its own keyboard.
                    self.assertEqual('keyboard-us', updated['Groups/1/Items/0']['Name'])
                migrated = profile.read_bytes()
                self.assertEqual('current', self.run_user(payload, home, layout='jp')['japanese-input'])
                self.assertEqual(migrated, profile.read_bytes())

    def test_layout_is_kept_when_japanese_is_not_preferred(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, home = self.prepare(directory, 'profile-chewing.ini')
            self.run_user(payload, home, cmdline='tryomarchy.keyboard=ansi', layout='jp')
            updated = japanese.parse((home / japanese.PROFILE).read_bytes())
            self.assertEqual('us', updated['Groups/0']['Default Layout'])
            self.assertEqual(['keyboard-us', 'chewing', 'mozc'],
                             [updated[f'Groups/0/Items/{i}']['Name'] for i in range(3)])

    def test_japanese_mac_language_prefers_mozc_on_older_english_guests(self):
        for geometry in ('ansi', 'iso'):
            with self.subTest(geometry=geometry), tempfile.TemporaryDirectory() as directory:
                payload, home = self.prepare(directory, 'profile-chewing.ini')
                cmdline = f'tryomarchy.keyboard={geometry} tryomarchy.mac_language=ja'
                self.assertEqual('applied', self.run_user(payload, home, cmdline=cmdline)['japanese-input'])
                updated = japanese.parse((home / japanese.PROFILE).read_bytes())
                self.assertEqual('mozc', updated['Groups/0']['DefaultIM'])
                self.assertEqual(['keyboard-us', 'mozc', 'chewing'],
                                 [updated[f'Groups/0/Items/{i}']['Name'] for i in range(3)])
                # JIS mode keys are seeded only for JIS hardware.
                self.assertFalse((home / japanese.CONFIG).exists())

    def test_vconsole_layout_matches_the_factory_initializer(self):
        for text, expected in (
            ('KEYMAP=jp106\nXKBLAYOUT=jp\n', 'jp'),
            ('XKBLAYOUT="de" # German\n', 'de'),
            ("XKBLAYOUT='jp'\n", 'jp'),
            ('KEYMAP=us\n', 'us'),
            ('XKBLAYOUT=us,jp\n', 'us'),
            ('XKBLAYOUT=\n', 'us'),
            ('', 'us'),
        ):
            with self.subTest(text=text):
                self.assertEqual(expected, japanese.keyboard_layout(text))

    def test_japanese_work_has_its_own_component_result(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, home = self.prepare(directory)
            users.migrate(payload, home, True)
            skipped = self.run_user(payload, home, False)
            self.assertEqual('current', skipped['outcome'])
            self.assertEqual('pending', skipped['japanese-input'])
            applied = self.run_user(payload, home)
            # Both overlays extend input.lua, but pinch was already current.
            self.assertEqual('current', applied['outcome'])
            self.assertEqual('applied', applied['japanese-input'])

    def test_ansi_and_iso_keep_geometry_and_seed_no_jis_keys(self):
        for geometry, language in (('ansi', 'ja_JP.UTF-8'), ('iso', 'en_US.UTF-8')):
            with self.subTest(geometry=geometry), tempfile.TemporaryDirectory() as directory:
                payload, home = self.prepare(directory)
                self.run_user(payload, home, cmdline=f'tryomarchy.keyboard={geometry}', language=language)
                self.assertNotIn('apple-keyboard-input.lua', (home / japanese.INPUT).read_text())
                self.assertFalse((home / japanese.CONFIG).exists())
                profile = japanese.parse((home / japanese.PROFILE).read_bytes())
                self.assertEqual('mozc' if language.startswith('ja') else 'chewing', profile['Groups/0/Items/1']['Name'])
                self.assertEqual('current', self.run_user(payload, home, cmdline=f'tryomarchy.keyboard={geometry}', language=language)['japanese-input'])

    def test_custom_profile_shortcuts_and_model_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, home = self.prepare(directory)
            data = {japanese.PROFILE: b'# my engines\n', japanese.CONFIG: b'[Hotkey/TriggerKeys]\n0=Alt+space\n',
                    japanese.INPUT: b'hl.config({input = {kb_model = "custom"}})\n'}
            for relative, contents in data.items():
                (home / relative).write_bytes(contents)
            result = self.run_user(payload, home)
            self.assertEqual('preserved', result['japanese-input'])
            for relative in (japanese.PROFILE, japanese.CONFIG):
                self.assertEqual(data[relative], (home / relative).read_bytes())
            self.assertNotIn('apple-keyboard-input.lua', (home / japanese.INPUT).read_text())

    def test_symlinked_profile_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, home = self.prepare(directory)
            profile = home / japanese.PROFILE
            target = home / 'saved-profile'
            profile.rename(target)
            original = target.read_bytes()
            profile.symlink_to(target)
            self.assertEqual('preserved', self.run_user(payload, home)['japanese-input'])
            self.assertEqual(original, target.read_bytes())

    def test_failed_and_interrupted_writes_restore_originals_even_when_skipped(self):
        class PowerLoss(BaseException):
            pass
        for failure in (OSError, PowerLoss):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                payload, home = self.prepare(directory)
                original = {p: p.read_bytes() for p in home.rglob('*') if p.is_file()}
                transaction = users.load('transaction_test', payload / 'migrate.py')
                writer = transaction.write_file
                failed = False
                def fail(path, value, *args):
                    nonlocal failed
                    if path == home / japanese.CONFIG and not failed:
                        failed = True
                        raise failure('write failed')
                    return writer(path, value, *args)
                loader = users.load
                with patch.object(users, 'load', side_effect=lambda name, path: transaction if name == 'user_transaction' else loader(name, path)), patch.object(transaction, 'write_file', side_effect=fail):
                    if failure == PowerLoss:
                        with self.assertRaises(PowerLoss):
                            self.run_user(payload, home)
                    else:
                        self.assertEqual('failed', self.run_user(payload, home)['state'])
                self.run_user(payload, home, False)
                for path, data in original.items():
                    self.assertEqual(data, path.read_bytes())
                self.assertFalse((home / japanese.CONFIG).exists())

    def test_japanese_input_is_independent_of_the_keyboard_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, _ = self.prepare(directory)
            root = Path(directory) / 'root'
            result = support.fixes.migrate(payload, root, True, '')
            self.assertEqual('unavailable', result['components']['japanese-input'])
            helper = root / 'usr/share/try-omarchy/apple-keyboard-input.lua'
            self.assertFalse(helper.exists())
            register(root, *extras.JAPANESE_PACKAGES)
            result = support.fixes.migrate(payload, root, True, '')
            self.assertEqual('current', result['components']['japanese-input'])
            helper.parent.mkdir(parents=True, exist_ok=True)
            helper.write_text('-- personal key map\n')
            result = support.fixes.migrate(payload, root, True, '')
            self.assertEqual('current', result['components']['japanese-input'])
            self.assertEqual('-- personal key map\n', helper.read_text())

    def test_reviewed_older_keyboard_overlay_is_upgraded(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, _ = self.prepare(directory)
            root = Path(directory) / 'root'
            relative = 'usr/share/try-omarchy/apple-keyboard-input.lua'
            original = (support.GUEST / 'tests/fixtures/apple-keyboard-before-japanese.lua').read_bytes()
            preimages = json.loads((payload / 'preimages.json').read_text())
            self.assertIn(support.fixes.digest(original), preimages[relative])
            register(root, *extras.JAPANESE_PACKAGES)
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(original)
            self.assertTrue(support.installer.install_keyboard_system(payload, root))
            self.assertEqual((payload / 'apple-keyboard-input.lua').read_bytes(), (root / relative).read_bytes())

    def test_root_report_includes_user_work_and_does_not_bypass_skip(self):
        import pwd
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            payload, home = self.prepare(directory)
            root = Path(directory) / 'root'
            register(root, *extras.JAPANESE_PACKAGES)
            account = SimpleNamespace(pw_uid=1000, pw_name='owner', pw_dir=str(home))
            calls = []
            def run(args, **kwargs):
                calls.append(args)
                result = self.run_user(payload, home, approved='--apply' in args)
                return SimpleNamespace(stdout=json.dumps(result))
            with patch.object(pwd, 'getpwall', return_value=[account]), patch.object(support.fixes.subprocess, 'run', side_effect=run):
                self.assertEqual('pending', support.fixes.migrate(payload, root, False, '', users=True)['components']['japanese-input'])
                result = support.fixes.migrate(payload, root, True, '', users=True)
                self.assertEqual('applied', result['components']['japanese-input'])
                self.assertEqual('complete', result['state'])
            self.assertTrue(all('--japanese' in args for args in calls))

    def test_missing_mozc_is_installed_only_after_approval_and_repeat_is_noop(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, _ = self.prepare(directory)
            root = Path(directory) / 'root'
            pacman = root / 'usr/bin/pacman'
            pacman.parent.mkdir(parents=True)
            pacman.touch()
            module = support.fixes.components(payload)
            def install(root):
                register(root, *extras.JAPANESE_PACKAGES)
                return 'applied'
            with patch.object(support.fixes, 'components', return_value=module), patch.object(module, 'install_japanese', side_effect=install) as installer:
                skipped = support.fixes.migrate(payload, root, False, '')
                self.assertEqual('pending', skipped['components']['japanese-input'])
                installer.assert_not_called()
                applied = support.fixes.migrate(payload, root, True, '')
                self.assertEqual('applied', applied['components']['japanese-input'])
                self.assertEqual('complete', applied['state'])
                installer.assert_called_once_with(root)
                current = support.fixes.migrate(payload, root, True, '')
                self.assertEqual('current', current['components']['japanese-input'])
                installer.assert_called_once()

    def test_package_failure_is_reported_and_does_not_apply_input_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, home = self.prepare(directory)
            root = Path(directory) / 'root'
            pacman = root / 'usr/bin/pacman'
            pacman.parent.mkdir(parents=True)
            pacman.touch()
            module = support.fixes.components(payload)
            original = (home / japanese.PROFILE).read_bytes()
            with patch.object(support.fixes, 'components', return_value=module), patch.object(module, 'install_japanese', side_effect=RuntimeError('download failed')):
                result = support.fixes.migrate(payload, root, True, '')
            self.assertEqual('failed', result['state'])
            self.assertEqual('failed', result['components']['japanese-input'])
            self.assertEqual(original, (home / japanese.PROFILE).read_bytes())

    def test_file_planners_run_after_the_package_update(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, _ = self.prepare(directory)
            root = Path(directory) / 'root'
            support.SettingsInstallTests().seed_legacy_native_files(root)
            (root / 'usr/bin/pacman').touch()
            module = support.fixes.components(payload)
            clipboard = root / support.fixes.FILES['omarchy-native-clipboard-bridge']
            def install(root):
                clipboard.write_bytes((payload / 'omarchy-native-clipboard-bridge').read_bytes())
                return 'applied'
            with patch.object(support.fixes, 'components', return_value=module), patch.object(module, 'install_japanese', side_effect=install):
                result = support.fixes.migrate(payload, root, True, '')
            self.assertEqual('complete', result['state'])
            self.assertEqual('current', result['components']['clipboard'])
            self.assertEqual('applied', result['components']['japanese-input'])

    def test_boot_restarts_python_after_package_success_or_failure_without_repeating_it(self):
        class Restart(BaseException):
            pass
        for failed in (False, True):
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as directory:
                payload, _ = self.prepare(directory)
                root = Path(directory) / 'root'
                pacman = root / 'usr/bin/pacman'
                pacman.parent.mkdir(parents=True)
                pacman.touch()
                module = support.fixes.components(payload)
                def install(root):
                    if failed:
                        raise RuntimeError('update interrupted after replacing Python')
                    register(root, *extras.JAPANESE_PACKAGES)
                    return 'applied'
                continuation = 'failed' if failed else 'applied'
                with patch.object(support.fixes, 'components', return_value=module), patch.object(module, 'install_japanese', side_effect=install) as installer, patch.object(support.fixes, 'plan', wraps=support.fixes.plan) as planner:
                    with self.assertRaises(Restart):
                        support.fixes.migrate(payload, root, True, '', restart=lambda result: (_ for _ in ()).throw(Restart(result)))
                    planner.assert_not_called()
                    result = support.fixes.migrate(payload, root, True, '', package_result=continuation)
                    installer.assert_called_once()
                self.assertEqual('failed' if failed else 'complete', result['state'])
                self.assertEqual(continuation, result['components']['japanese-input'])

    def test_only_missing_japanese_packages_are_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(list(extras.JAPANESE_PACKAGES), extras.missing_japanese(root))
            # A v0.5 guest: Fcitx, its GTK/Qt modules, and CJK fonts, without Mozc.
            register(root, 'fcitx5', 'fcitx5-chewing', 'fcitx5-gtk', 'fcitx5-qt', 'noto-fonts-cjk')
            self.assertEqual(['fcitx5-mozc', 'fcitx5-configtool'], extras.missing_japanese(root))
            self.assertFalse(extras.japanese_available(root))
            register(root, 'fcitx5-mozc', 'fcitx5-configtool')
            self.assertEqual([], extras.missing_japanese(root))
            self.assertTrue(extras.japanese_available(root))

    def test_installs_only_missing_packages_without_a_system_upgrade(self):
        with patch.object(extras, 'missing_japanese', side_effect=[['fcitx5-mozc', 'fcitx5-configtool'], []]), \
                patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'exists', return_value=False), patch.object(extras, 'run') as run:
            self.assertEqual('applied', extras.install_japanese(Path('/')))
        self.assertEqual(['systemctl', 'start', 'NetworkManager.service'], run.call_args_list[0].args[0])
        self.assertEqual(['nm-online', '-q', '-t', '15'], run.call_args_list[1].args[0])
        self.assertEqual(['pacman', '-Sy', '--needed', '--noconfirm', '--ignore',
                          'linux-aarch64,linux-aarch64-headers,hyprland,aquamarine,hyprtoolkit,hyprland-guiutils,try-omarchy-runtime',
                          'fcitx5-mozc', 'fcitx5-configtool'], run.call_args_list[2].args[0])
        self.assertLessEqual(run.call_args_list[2].kwargs['timeout'], 300)

    def test_unverified_installation_is_reported_as_a_failure(self):
        with patch.object(extras, 'missing_japanese', return_value=['fcitx5-mozc']), \
                patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'exists', return_value=False), patch.object(extras, 'run'):
            with self.assertRaises(RuntimeError):
                extras.install_japanese(Path('/'))

    def test_active_package_lock_is_preserved_and_installed_packages_are_not_upgraded(self):
        with patch.object(extras, 'missing_japanese', return_value=['fcitx5-mozc']), \
                patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'exists', return_value=True), patch.object(extras, 'run') as run:
            self.assertEqual('unavailable', extras.install_japanese(Path('/')))
            run.assert_not_called()
        with patch.object(extras, 'missing_japanese', return_value=[]), patch.object(extras, 'run') as run:
            self.assertEqual('current', extras.install_japanese(Path('/')))
            run.assert_not_called()

if __name__ == '__main__':
    unittest.main()
