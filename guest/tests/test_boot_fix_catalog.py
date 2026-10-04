import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import test_settings_install as support

fixes = support.fixes
spec = importlib.util.spec_from_file_location('boot_catalog_tests', support.GUEST / 'scripts/boot-fix-components.py')
extras = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extras)
CATALOG = support.GUEST / 'migrations/catalog.json'


class BootFixCatalogTests(unittest.TestCase):
    def test_packaged_catalog_is_bound_to_bundle_consent(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = support.SettingsInstallTests().make_payload(directory)
            catalog_path = payload / 'catalog.json'
            self.assertEqual(CATALOG.read_bytes(), catalog_path.read_bytes())
            manifest = fixes.bundle_manifest(payload)
            self.assertEqual(fixes.digest(catalog_path.read_bytes()), manifest['files']['catalog.json'])
            catalog = extras.read_catalog(catalog_path)
            catalog['migrations'][0]['revision'] += 1
            catalog_path.write_text(json.dumps(catalog))
            with self.assertRaisesRegex(RuntimeError, 'payload verification'):
                fixes.bundle_manifest(payload)
            with patch.object(fixes, 'recover') as recover:
                with self.assertRaises(RuntimeError):
                    fixes.migrate(payload, Path(directory) / 'root', True, '')
                recover.assert_not_called()
            rebuilt = fixes.bundle_manifest(payload, create=True)
            self.assertNotEqual(manifest['identity'], rebuilt['identity'])

    def test_catalog_order_drives_pending_and_terminal_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = support.SettingsInstallTests().make_payload(directory)
            catalog_path = payload / 'catalog.json'
            catalog = extras.read_catalog(catalog_path)
            catalog['migrations'].reverse()
            catalog_path.write_text(json.dumps(catalog))
            fixes.bundle_manifest(payload, create=True)
            expected = [entry['id'] for entry in catalog['migrations']]
            reports = []
            fixes.migrate(payload, Path(directory) / 'root', True, '', emit=reports.append)
            self.assertGreaterEqual(len(reports), 2)
            for report in reports:
                self.assertEqual(expected, list(report['components']))
            self.assertEqual('running', reports[0]['state'])
            self.assertEqual({'pending'}, set(reports[0]['components'].values()))
            with patch.object(fixes, 'recover', side_effect=RuntimeError('interrupted recovery')):
                failed = fixes.migrate(payload, Path(directory) / 'root', True, '')
            self.assertEqual('recovery-required', failed['state'])
            self.assertEqual(expected, list(failed['components']))

    def test_missing_and_unimplemented_handlers_rejected_by_packaging_and_runtime(self):
        original = json.loads(CATALOG.read_text())
        for mutation in ('missing', 'unimplemented'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                payload = support.SettingsInstallTests().make_payload(directory)
                catalog = copy.deepcopy(original)
                if mutation == 'missing':
                    catalog['migrations'].pop(0)
                else:
                    catalog['migrations'][0]['id'] = 'unimplemented'
                (payload / 'catalog.json').write_text(json.dumps(catalog))
                with self.assertRaisesRegex(RuntimeError, 'implemented components'):
                    fixes.bundle_manifest(payload, create=True)
                with patch.object(fixes, 'recover') as recover:
                    with self.assertRaisesRegex(RuntimeError, 'implemented components'):
                        fixes.migrate(payload, Path(directory) / 'root', True, '')
                    recover.assert_not_called()
                guest = Path(directory) / 'guest'
                (guest / 'migrations').mkdir(parents=True)
                (guest / 'migrations/catalog.json').write_text(json.dumps(catalog))
                with self.assertRaisesRegex(RuntimeError, 'implemented components'):
                    extras.package(guest, Path(directory) / 'unused-payload')

    def test_catalog_rejects_ambiguous_or_unbounded_metadata(self):
        original = json.loads(CATALOG.read_text())
        mutations = {
            'unsupported schema': lambda c: c.update(schema=2),
            'boolean schema': lambda c: c.update(schema=True),
            'unknown top field': lambda c: c.update(command='echo unexpected'),
            'empty migrations': lambda c: c.update(migrations=[]),
            'too many migrations': lambda c: c.update(migrations=c['migrations'] * 3),
            'duplicate id': lambda c: c['migrations'].append(c['migrations'][0]),
            'unsafe id': lambda c: c['migrations'][0].update(id='../battery'),
            'zero revision': lambda c: c['migrations'][0].update(revision=0),
            'boolean revision': lambda c: c['migrations'][0].update(revision=True),
            'large revision': lambda c: c['migrations'][0].update(revision=65536),
            'empty title': lambda c: c['migrations'][0].update(title=''),
            'padded title': lambda c: c['migrations'][0].update(title=' Battery '),
            'multiline title': lambda c: c['migrations'][0].update(title='Battery\nwidget'),
            'long title': lambda c: c['migrations'][0].update(title='x' * 81),
            'long icon': lambda c: c['migrations'][0].update(icon='x' * 65),
            'invalid icon': lambda c: c['migrations'][0].update(icon='battery/100'),
            'empty note': lambda c: c['migrations'][0].update(note=''),
            'long note': lambda c: c['migrations'][0].update(note='x' * 241),
            'unknown field': lambda c: c['migrations'][0].update(command='/bin/anything'),
            'unknown group': lambda c: c['migrations'][0].update(group='missing'),
            'non-string group': lambda c: c['migrations'][0].update(group=[]),
            'unused group': lambda c: c['groups'].update(unused={'title': 'Unused', 'icon': 'square'}),
            'invalid group': lambda c: c['groups']['system'].update(icon=''),
            'unknown group field': lambda c: c['groups']['system'].update(command='anything'),
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'catalog.json'
            for label, mutate in mutations.items():
                with self.subTest(case=label):
                    catalog = copy.deepcopy(original)
                    mutate(catalog)
                    path.write_text(json.dumps(catalog))
                    with self.assertRaises(RuntimeError):
                        extras.read_catalog(path)
            for text in ('{}', '[]', ' ' * 32769,
                         CATALOG.read_text().replace('"schema": 1', '"schema": 1, "schema": 1'),
                         CATALOG.read_text().replace('"groups": {', '"groups": {"system": {},')):
                with self.subTest(raw=text[:30]):
                    path.write_text(text)
                    with self.assertRaises(RuntimeError):
                        extras.read_catalog(path)
