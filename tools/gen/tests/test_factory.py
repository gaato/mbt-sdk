from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import yaml

from tools import new_sdk, sdks
from test_generator import document, operation


class FactoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for module in (sdks, new_sdk):
            patcher = patch.object(module, 'ROOT', self.root)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.doc = document(operation())
        self.doc.update(servers=[{'url': 'https://example.invalid/v1'}])
        self.doc['components']['securitySchemes'] = {'token': {'type': 'http', 'scheme': 'bearer'}}
        self.doc['security'] = [{'token': []}]
        self.spec = self.root / 'input.json'
        self.spec.write_text(json.dumps(self.doc))
        self.write('seed/moon.mod', 'name = "gaato/seed"\nversion = "0.1.0"\nimport {\n  "gaato/mttp_core@0.1.0",\n}\n')
        self.write('seed/spec/spec.json', json.dumps(self.doc))
        self.write('seed/spec/SOURCE.md', '- Source: https://example.invalid/spec.json\n')
        self.write('moon.work', 'members = [\n  "seed",\n]\n')
        self.write('runtime-tests/moon.mod', 'name = "gaato/runtime-tests"\nimport {\n}\n')
        self.write('scripts/docs_audit.json', '{"modules": [], "generated": []}\n')
        self.write('README.md', '<!-- BEGIN sdks: modules -->\n<!-- END sdks: modules -->\n')
        self.write('ARCHITECTURE.md', '<!-- BEGIN sdks: http-layer -->\n| SDKs | seed | Generated API vocabulary and vendor policy |\n<!-- END sdks: http-layer -->\n')
        self.write('docs/release.md', '<!-- BEGIN sdks: publish -->\n<!-- END sdks: publish -->\n')
        self.write('sdks.toml', '''[[sdk]]
name = "seed"
dir = "seed"
module = "gaato/seed"
generator = "openapi"
spec_file = "seed/spec/spec.json"
spec_url = "https://example.invalid/spec.json"
spec_fetch = "plain"
package = "gaato/seed/gen"
out = "seed/src/gen"
include_all = true
derive_operation_ids = true
publish = false
spec_watch = false
census_args = []
offline_packages = []
''')

    def write(self, file, text):
        path = self.root / file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def create(self, *flags):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return new_sdk.run(['sample', '--spec-url', 'https://example.invalid/spec.json', '--spec-file', str(self.spec), *flags])

    def snapshot(self):
        result = {}
        for path in sorted(self.root.rglob('*')):
            relative = str(path.relative_to(self.root))
            if path.is_symlink():
                result[relative] = ('symlink', path.readlink())
            elif path.is_dir():
                result[relative] = ('directory', None)
            else:
                result[relative] = ('file', path.read_bytes())
        return result

    def test_scaffold_pins_provenance_empty_overlays_and_sync(self):
        self.assertEqual(self.create(), 0)
        sdk = sdks.load()[-1]
        self.assertEqual(sdk['base_url'], self.doc['servers'][0]['url'])
        self.assertEqual(sdk['auth'], {'kind': 'bearer'})
        self.assertFalse(sdk['publish'])
        self.assertFalse(sdk['spec_watch'])
        self.assertTrue(sdk['include_all'])
        self.assertEqual((self.root / sdk['spec_file']).read_bytes(), self.spec.read_bytes())
        self.assertIn(hashlib.sha256(self.spec.read_bytes()).hexdigest(), (self.root / 'sample/spec/SOURCE.md').read_text())
        self.assertTrue((self.root / 'sample/README.md').is_symlink())
        self.assertEqual((self.root / 'sample/README.md').read_text(), (self.root / 'sample/src/overview.mbt.md').read_text())
        self.assertIn('https://github.com/gaato/mbt-sdk/blob/main/docs/behavior/sample.md', (self.root / 'sample/README.md').read_text())
        self.assertIn('## [Unreleased]', (self.root / 'sample/CHANGELOG.md').read_text())
        self.assertFalse((self.root / 'sample/src/gen').exists())
        self.assertFalse(sdks.sync(sdks.load(), True))
        for label in ('A —', 'B —', 'C —'):
            self.assertIn(label, (self.root / 'docs/behavior/sample.md').read_text())

    def test_yaml_scaffold_retains_root_auth_with_public_operation(self):
        self.doc['paths']['/public'] = {'get': {
            'operationId': 'public_get', 'security': [], 'responses': {'200': {}},
        }}
        self.spec = self.root / 'input.yaml'
        # Keep the date unquoted so PyYAML constructs a non-JSON date value.
        self.spec.write_text(yaml.safe_dump(self.doc, sort_keys=False).replace(
            '  securitySchemes:', '  schemas:\n    Dated:\n      type: string\n      format: date\n      example: 2026-11-16\n  securitySchemes:'))
        self.assertEqual(self.create(), 0)
        sdk = sdks.load()[-1]
        self.assertEqual(sdk['auth'], {'kind': 'alternatives', 'schemes': [
            {'kind': 'bearer'}, {'kind': 'none'},
        ]})
        sdks.pins([sdk])
        self.assertFalse(sdks.sync(sdks.load(), True))
        with self.assertRaisesRegex(ValueError, 'auth pin disagrees'):
            sdks.pins([{**sdk, 'auth': {'kind': 'none'}}])

    def test_discovery_scaffold_records_revision_and_auth_alternatives(self):
        discovery = {
            'kind': 'discovery#restDescription', 'discoveryVersion': 'v1',
            'name': 'demo', 'version': 'v1', 'revision': '20261116',
            'rootUrl': 'https://api.example/', 'servicePath': 'v1/',
            'parameters': {'key': {'type': 'string', 'location': 'query'}},
            'schemas': {}, 'resources': {},
        }
        self.spec.write_text(json.dumps(discovery))
        self.assertEqual(self.create('--generator', 'discovery'), 0)
        sdk = sdks.load()[-1]
        self.assertEqual(sdk['generator'], 'discovery')
        self.assertEqual(sdk['spec_file'], 'sample/spec/discovery.json')
        self.assertEqual(sdk['base_url'], 'https://api.example/v1')
        self.assertEqual(sdk['auth'], {'kind': 'alternatives', 'schemes': [
            {'kind': 'header', 'name': 'x-goog-api-key'},
            {'kind': 'query', 'name': 'key'},
        ]})
        source = (self.root / 'sample/spec/SOURCE.md').read_text()
        self.assertIn('- Discovery revision: 20261116', source)
        self.assertFalse(sdks.sync(sdks.load(), True))

    def test_discovery_scaffold_includes_oauth_bearer_alternative(self):
        scope = 'https://www.googleapis.com/auth/example.read'
        discovery = {
            'kind': 'discovery#restDescription', 'discoveryVersion': 'v1',
            'name': 'demo', 'version': 'v1', 'revision': '20261116',
            'rootUrl': 'https://api.example/', 'servicePath': 'v1/',
            'parameters': {'key': {'type': 'string', 'location': 'query'}},
            'auth': {'oauth2': {'scopes': {scope: {'description': 'Read examples.'}}}},
            'schemas': {},
            'resources': {'items': {'methods': {'get': {
                'id': 'demo.items.get', 'path': 'items', 'httpMethod': 'GET',
                'scopes': [scope], 'response': {'type': 'object'},
            }}}},
        }
        self.spec.write_text(json.dumps(discovery))
        self.assertEqual(self.create('--generator', 'discovery'), 0)
        self.assertEqual(sdks.load()[-1]['auth'], {
            'kind': 'alternatives',
            'schemes': [
                {'kind': 'header', 'name': 'x-goog-api-key'},
                {'kind': 'query', 'name': 'key'},
                {'kind': 'bearer'},
            ],
        })

    def test_generate_is_opt_in_and_overwrite_is_refused(self):
        self.assertEqual(self.create('--generate'), 0)
        generated = self.root / 'sample/src/gen/types.mbt'
        before = generated.read_bytes()
        ledger = (self.root / 'sdks.toml').read_bytes()
        self.assertEqual(self.create('--generate'), 1)
        self.assertEqual(generated.read_bytes(), before)
        self.assertEqual((self.root / 'sdks.toml').read_bytes(), ledger)

    def test_dry_run_never_fetches_or_writes(self):
        before = (self.root / 'sdks.toml').read_bytes()
        with patch.object(new_sdk, 'urlopen', side_effect=AssertionError('network')):
            self.assertEqual(self.create('--dry-run', '--generate'), 0)
        self.assertFalse((self.root / 'sample').exists())
        self.assertEqual((self.root / 'sdks.toml').read_bytes(), before)

    def test_scaffold_prints_unmodelled_body_notes_separately(self):
        self.doc['paths']['/test']['post']['requestBody'] = {'content': {'image/png': {'schema': {'type': 'string'}}}}
        self.spec.write_text(json.dumps(self.doc))
        output = io.StringIO()
        with redirect_stdout(output), redirect_stderr(io.StringIO()):
            status = new_sdk.run(['sample', '--spec-url', 'https://example.invalid/spec.json', '--spec-file', str(self.spec)])
        self.assertEqual(status, 0)
        self.assertIn('diagnostics=0 notes=1', output.getvalue())
        self.assertIn('notes (non-failing):', output.getvalue())
        self.assertIn('/requestBody/content/image~1png: request body image/png is not modelled; the caller sets the body', output.getvalue())
        self.assertFalse((self.root / 'sample/src/gen').exists())

    def test_download_path_uses_only_spec_url(self):
        with patch.object(new_sdk, 'urlopen') as fetch:
            fetch.return_value.read.return_value = self.spec.read_bytes()
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(new_sdk.run(['sample', '--spec-url', 'https://example.invalid/spec.json']), 0)
            fetch.assert_called_once_with('https://example.invalid/spec.json', timeout=60)

    def test_existing_ledger_name_and_directory_are_refused(self):
        self.write('sample/keep', 'do not overwrite')
        self.assertEqual(self.create(), 1)
        self.assertEqual((self.root / 'sample/keep').read_text(), 'do not overwrite')
        with redirect_stderr(io.StringIO()):
            self.assertEqual(new_sdk.run(['seed', '--spec-url', 'https://example.invalid/spec.json', '--spec-file', str(self.spec)]), 1)

    def test_deleted_ledger_entry_detected_before_and_after_generation(self):
        seed_ledger = (self.root / 'sdks.toml').read_text()
        self.assertEqual(self.create(), 0)
        (self.root / 'sdks.toml').write_text(seed_ledger)
        with self.assertRaisesRegex(ValueError, 'sample: registered SDK missing from sdks.toml'):
            sdks.sync(sdks.load(), True)
        # A custom module name is still detected by generated ownership.
        self.write('sample/moon.mod', 'name = "other/custom"\n')
        self.write('sample/src/gen/types.mbt', '// GENERATED by tools/gen — DO NOT EDIT.\n')
        with self.assertRaisesRegex(ValueError, 'sample: registered SDK missing from sdks.toml'):
            sdks.sync(sdks.load(), True)

    def test_source_url_drift_is_an_error(self):
        self.assertEqual(self.create(), 0)
        self.write('sample/spec/SOURCE.md', '- Source: https://example.invalid/different.json\n')
        with self.assertRaisesRegex(ValueError, 'sample: SOURCE.md Source line disagrees'):
            sdks.sync(sdks.load(), True)

    def test_handwritten_modules_are_not_orphans(self):
        for name in ('jsonrpc', 'jsonrpc-async', 'codex-app-server', 'compat', 'conformance', 'runtime-tests'):
            self.write(f'{name}/moon.mod', f'name = "gaato/{name}"\n')
            self.write(f'{name}/src/gen/handwritten.mbt', '// Handwritten code\n')
        with redirect_stderr(io.StringIO()):
            sdks.sync(sdks.load(), False)
        self.assertFalse(sdks.sync(sdks.load(), True))

    def test_unrepresentable_auth_refuses_before_creation(self):
        self.doc['components']['securitySchemes']['token'] = {
            'type': 'openIdConnect',
            'openIdConnectUrl': 'https://example.invalid/.well-known/openid-configuration',
        }
        self.spec.write_text(json.dumps(self.doc))
        self.assertEqual(self.create(), 1)
        self.assertFalse((self.root / 'sample').exists())

    def test_cookie_auth_refuses_without_any_files_or_ledger_change(self):
        self.doc['components']['securitySchemes']['token'] = {
            'type': 'apiKey',
            'in': 'cookie',
            'name': 'session',
        }
        self.spec.write_text(json.dumps(self.doc))
        before = self.snapshot()
        ledger = (self.root / 'sdks.toml').read_bytes()

        self.assertEqual(self.create(), 1)

        self.assertEqual(self.snapshot(), before)
        self.assertEqual((self.root / 'sdks.toml').read_bytes(), ledger)
        self.assertFalse((self.root / 'sample').exists())
        self.assertFalse((self.root / 'docs/behavior/sample.md').exists())

    def test_auth_pin_uses_or_requirements_and_rejects_and_requirements(self):
        doc = document(operation())
        doc['components']['securitySchemes'] = {
            'header': {'type': 'apiKey', 'in': 'header', 'name': 'x-api-key'},
            'query': {'type': 'apiKey', 'in': 'query', 'name': 'key'},
            'bearer': {'type': 'http', 'scheme': 'bearer'},
        }
        doc['security'] = [{'bearer': []}]
        self.assertEqual(new_sdk.auth_pin(doc), {'kind': 'bearer'})
        public = operation(operation_id='public')
        public['security'] = []
        doc['paths']['/public'] = {'get': public}
        self.assertEqual(new_sdk.auth_pin(doc), {
            'kind': 'alternatives',
            'schemes': [
                {'kind': 'bearer'},
                {'kind': 'none'},
            ],
        })
        doc['paths'].pop('/public')
        doc['security'] = [{'header': []}, {'query': []}]
        self.assertEqual(new_sdk.auth_pin(doc), {
            'kind': 'alternatives',
            'schemes': [
                {'kind': 'header', 'name': 'x-api-key'},
                {'kind': 'query', 'name': 'key'},
            ],
        })
        doc['security'] = [{'header': [], 'bearer': []}]
        with self.assertRaisesRegex(ValueError, 'AND authentication'):
            new_sdk.auth_pin(doc)
