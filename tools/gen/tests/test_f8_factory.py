import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

from tools import sdks, spec_watch, weekly_release
from tools.gen.census import census
from tools.gen.emit_moonbit import emit
from tools.gen.selection import apply, validate
from tools.gen.qualify import qualify
from test_generator import document, operation

ROOT = Path(__file__).resolve().parents[3]


class F8FactoryTests(unittest.TestCase):
    def test_qualification_preserves_data_declarations_and_is_idempotent(self):
        source = '// Json(None)\nenum Example {\n  None\n  Json(String)\n}\nlet value = Json("Json(None)")\nmatch value { String(text) => Some(text); _ => None }\n'
        result = qualify(source)
        self.assertIn('// Json(None)', result)
        self.assertIn('  None\n  Json(String)', result)
        self.assertIn('@json.Json::Json("Json(None)")', result)
        self.assertIn('@json.Json::String(text) => Option::Some(text)', result)
        self.assertEqual(qualify(result), result)

    def test_selection_union_exclusions_and_stale_selectors(self):
        doc = document(operation(operation_id='one'))
        doc['paths']['/other'] = {'get': operation(operation_id='two')}
        doc['paths']['/third'] = {'get': operation(operation_id='three')}
        chosen = apply(doc, {'paths': ['/test'], 'operations': ['two', 'three'],
                             'excludes': [{'operation': 'three', 'reason': 'unsupported union, reviewed'}]})
        self.assertEqual(chosen, {'one', 'two'})
        for bad in [{'operations': ['missing']}, {'paths': ['/missing']},
                    {'excludes': [{'operation': 'one', 'reason': ''}]},
                    {'excludes': [{'operation': 'missing', 'reason': 'stale'}]}]:
            with self.subTest(selection=bad), self.assertRaises(ValueError):
                apply(copy.deepcopy(doc), bad)

    def test_pins_select_overlaid_ids_but_check_raw_host_and_auth(self):
        for suffix in ('json', 'yaml'):
            for original_id in (None, 'old_id'):
                with self.subTest(format=suffix, original_id=original_id), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    doc = document(operation(operation_id=original_id))
                    doc['servers'] = [{'url': 'https://raw.invalid'}]
                    doc['components']['securitySchemes'] = {'token': {'type': 'http', 'scheme': 'bearer'}}
                    doc['security'] = [{'token': []}]
                    doc['paths']['/test']['servers'] = [{'url': 'https://raw-path.invalid'}]
                    doc['paths']['/test']['post']['servers'] = [{'url': 'https://raw-op.invalid'}]
                    doc['paths']['/test']['get'] = operation(operation_id='old_excluded')
                    doc['paths']['/test']['get']['servers'] = [{'url': 'https://excluded.invalid'}]
                    doc['paths']['/test']['get']['security'] = []
                    doc['paths']['/other'] = {'get': operation(operation_id='unselected')}
                    doc['paths']['/other']['get']['security'] = []
                    spec = root / ('spec.' + suffix)
                    spec.write_text(json.dumps(doc) if suffix == 'json' else yaml.safe_dump(doc))
                    overlays = root / 'sample/overlays'
                    overlays.mkdir(parents=True)
                    (overlays / 'moonbit.yaml').write_text(yaml.safe_dump({'overlay': '1.0.0', 'actions': [
                        {'target': "$.paths['/test'].post", 'update': {'operationId': 'selected'}},
                        {'target': "$.paths['/test'].get", 'update': {'operationId': 'excluded'}},
                        {'target': '$.servers[0]', 'update': {'url': 'https://overlay.invalid'}},
                        {'target': "$.paths['/test'].servers[0]", 'update': {'url': 'https://overlay-path.invalid'}},
                        {'target': "$.paths['/test'].post.servers[0]", 'update': {'url': 'https://overlay-op.invalid'}},
                        {'target': '$.components.securitySchemes.token', 'update': {'scheme': 'basic'}},
                        {'target': "$.paths['/test'].post", 'update': {'security': []}},
                    ]}))
                    sdk = dict(name='sample', dir='sample', generator='openapi', spec_file=spec.name,
                               client_layer=True, base_url='https://raw.invalid', auth={'kind': 'bearer'},
                               server_urls=['https://raw-path.invalid', 'https://raw-op.invalid'],
                               selection={'operations': ['selected', 'excluded'], 'excludes': [
                                   {'operation': 'excluded', 'reason': 'Reviewed exclusion.'}]})
                    with patch.object(sdks, 'ROOT', root):
                        sdks.pins([sdk])
                        for change, message in [({'base_url': 'https://overlay.invalid'}, 'base_url pin'),
                                                ({'server_urls': ['https://overlay-path.invalid', 'https://overlay-op.invalid']}, 'servers changed'),
                                                ({'auth': {'kind': 'basic'}}, 'auth pin disagrees'),
                                                ({'auth_reason': 'Reviewed', 'auth_spec': {'token': {'type': 'http', 'scheme': 'basic'}}}, 'auth pin disagrees'),
                                                ({'selection': {'operations': ['missing']}}, 'unknown selection operationId')]:
                            with self.subTest(change=change), self.assertRaisesRegex(ValueError, message):
                                sdks.pins([{**sdk, **change}])

    def test_census_compile_reports_generated_location_after_clean_ir(self):
        def broken(ir):
            files = emit(ir)
            files['operations.mbt'] += '\n///|\npub fn broken() -> String { 1 }\n'
            return files
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'spec.json'
            path.write_text(json.dumps(document(operation())))
            with patch('tools.gen.census.emit', broken):
                result = census(path, 'broken', compile=True)
        self.assertGreater(result.diagnostics, 0)
        self.assertEqual(result.compilation, 'failed')
        self.assertTrue(any('operations.mbt' in item['pointer'] for item in result.details), result.details)

    def test_watch_runs_later_consumers_after_one_fails_and_reports_both(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ['first', 'second']:
                (root / name / 'src').mkdir(parents=True)
            (root / 'spec.json').write_text('{}')
            entries = [dict(name=name, dir=name, spec_file='spec.json') for name in ['first', 'second']]
            calls = []
            def execute(command, **kwargs):
                calls.append(command)
                return subprocess.CompletedProcess(command, 2 if command[:3] == ['fake', 'scripts/generate.sh', 'first'] else 0)
            with patch('tools.spec_watch.subprocess.run', execute):
                code = spec_watch.run_group(entries, 'spec.json', root, root / 'logs', 'fake')
            self.assertEqual(code, 1)
            self.assertEqual(len(calls), 8)
            results = json.loads((root / 'logs/results.json').read_text())
            self.assertEqual([r['module'] for r in results], ['first', 'second'])
            self.assertEqual(results[0]['generation'], 2)
            self.assertEqual(results[1]['gates'], 0)
            body = (root / 'logs/body.md').read_text()
            self.assertIn('| first | 2 |', body)
            self.assertIn('| second | 0 |', body)
            self.assertNotIn('bump', ' '.join(str(c) for c in calls))

    def test_watch_budgets_log_tails_across_all_consumers(self):
        stages = ('generation', 'interfaces', 'census', 'gates')
        names = [f'consumer-{i:02}' for i in range(24)]
        entries = [dict(name=name, dir=name, spec_file='spec.json') for name in names]
        logs = {}

        def execute(command, **kwargs):
            log = Path(kwargs['stdout'].name)
            content = (log.stem + ' ' + 'é' * 400 + '\n') * 50 + f'TAIL {log.stem}\n'
            if log.stem == f'{names[0]}-generation':
                content = 'short log\n'
            logs[log.name] = content
            kwargs['stdout'].write(content)
            return subprocess.CompletedProcess(command, 1)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log_dir = root / 'logs'
            with patch('tools.spec_watch.subprocess.run', execute):
                code = spec_watch.run_group(entries, 'spec.json', root, log_dir, 'fake')
            self.assertEqual(code, 1)
            body = (log_dir / 'body.md').read_text()
            self.assertLessEqual(len(body.encode('utf-8')), 60_000)
            self.assertIn('short log', body)
            for name in names:
                self.assertIn(f'| {name} | 1 | 1 | 1 | 1 | 0 |', body)
                for stage in stages:
                    if name == names[0] and stage == 'generation':
                        continue
                    tail = f'TAIL {name}-{stage}'
                    self.assertIn(tail, body)
            # Each long log contributes a comparable excerpt, in addition to its tail.
            counts = [excerpt.count('é') for excerpt in body.split('```text')[1:] if 'TAIL ' in excerpt]
            self.assertEqual(len(counts), len(names) * len(stages) - 1)
            self.assertGreater(min(counts), 100)
            self.assertLessEqual(max(counts) - min(counts), 5)
            for filename, content in logs.items():
                self.assertEqual((log_dir / filename).read_text(), content)

    def test_watch_omits_notes_log_from_previous_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sdk_dir = root / 'sample'
            (sdk_dir / 'src').mkdir(parents=True)
            (sdk_dir / 'CHANGELOG.md').touch()
            (root / 'spec.json').write_text('{}')
            generated = sdk_dir / 'src/generated.mbt'
            logs = root / 'logs'
            entries = [dict(name='sample', dir='sample', spec_file='spec.json')]

            def execute(command, **kwargs):
                if command[0] == 'scripts/release.sh':
                    kwargs['stdout'].write('notes from first run\n')
                elif command[1] == 'scripts/generate.sh':
                    generated.write_text('same generated output')
                return subprocess.CompletedProcess(command, 0)

            with patch('tools.spec_watch.subprocess.run', execute):
                self.assertEqual(spec_watch.run_group(entries, 'spec.json', root, logs, 'fake'), 0)
                self.assertIn('notes from first run', (logs / 'body.md').read_text())
                self.assertEqual(spec_watch.run_group(entries, 'spec.json', root, logs, 'fake'), 0)
            self.assertIn('| sample | 0 | 0 | 0 | 0 | 0 |', (logs / 'body.md').read_text())
            self.assertNotIn('notes from first run', (logs / 'body.md').read_text())
            self.assertFalse((logs / 'sample-notes.log').exists())

    def test_watch_pr_can_open_without_an_artifact_url(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/spec-watch.yml').read_text())
        steps = {step.get('id'): step for step in workflow['jobs']['watch']['steps']}
        upload, pr = steps['logs'], steps['pr']
        with self.subTest('upload errors leave the job eligible to open a PR'):
            self.assertIs(upload.get('continue-on-error'), True)
            self.assertEqual(pr['if'], "steps.fetch.outputs.changed == 'true'")
        self.assertEqual(pr['env']['LOG_URL'], '${{ steps.logs.outputs.artifact-url }}')

        # Execute the actual PR step body with local stubs for both CLI tools.
        stubs = '''
git() {
  if [ "$1" = ls-remote ]; then return 2; fi
  return 0
}
gh() {
  [ "$1 $2" = 'pr create' ] || return 1
  while [ "$#" -gt 0 ] && [ "$1" != --body-file ]; do shift; done
  cp "$2" "$RUNNER_TEMP/pr-body.md"
  echo https://example.invalid/pr/123
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'consumers').mkdir()
            bounded_body = '| sample | 1 | 0 | 0 | 0 | 0 |\n'
            for artifact in ('', 'https://example.invalid/artifacts/42'):
                with self.subTest(artifact=artifact):
                    (root / 'consumers/body.md').write_text(bounded_body)
                    output = root / 'output'
                    output.write_text('')
                    result = subprocess.run(
                        ['bash', '-e', '-c', stubs + pr['run']], cwd=root,
                        env=dict(PATH='/usr/bin:/bin', RUNNER_TEMP=str(root), PROVIDER='sample',
                                 NEW_SHA='0123456789abcdef0123456789abcdef', SPEC_PATH='spec/openapi.json',
                                 MODULE_DIRS='["sample"]', GITHUB_OUTPUT=str(output), LOG_URL=artifact),
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('number=123', output.read_text())
                    expected = bounded_body + (f'\n\n[Full consumer logs]({artifact})\n' if artifact else '')
                    self.assertEqual((root / 'pr-body.md').read_text(), expected)

    def test_weekly_real_bump_fixture_minor_patch_skip_and_explicit(self):
        with tempfile.TemporaryDirectory(prefix='f8-weekly-fixture-') as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            shutil.copy2(ROOT / 'scripts/release.sh', root / 'scripts/release.sh')
            (root / 'tools').mkdir()
            shutil.copy2(ROOT / 'tools/sdks.py', root / 'tools/sdks.py')
            shutil.copytree(ROOT / 'tools/gen', root / 'tools/gen', ignore=shutil.ignore_patterns('__pycache__', 'tests'))
            entries = []
            tables = []
            for name in ['api', 'implementation', 'untouched', 'explicit']:
                directory = root / name
                (directory / 'src/gen').mkdir(parents=True)
                (directory / 'spec').mkdir()
                (directory / 'spec/spec.json').write_text('{}')
                (directory / 'src/pkg.generated.mbti').write_text('api-v1\n')
                (directory / 'src/gen/pkg.generated.mbti').write_text('gen-v1\n')
                (directory / 'moon.mod').write_text(f'name = "gaato/{name}"\nversion = "0.1.0"\nsource = "src"\n')
                notes = '' if name == 'untouched' else '- A change.\n'
                (directory / 'CHANGELOG.md').write_text('# Changelog\n\n## [Unreleased]\n\n' + notes + '\n## [0.1.0]\n')
                sdk = dict(name=name, dir=name, module=f'gaato/{name}', generator='openapi', spec_file=f'{name}/spec/spec.json', spec_url=f'https://example.invalid/{name}', spec_fetch='plain', package=f'gaato/{name}/gen', out=f'{name}/src/gen', publish=True, spec_watch=True, include_all=True, derive_operation_ids=True, census_args=[], offline_packages=[])
                entries.append(sdk)
                tables.append('[[sdk]]\n' + '\n'.join(key + ' = ' + json.dumps(value) for key, value in sdk.items()))
                weekly_release.capture(root, sdk, {'version': '0.1.0', 'created_at': '2026-11-01T00:00:00+00:00', 'checksum': 'published-archive'}, directory)
            (root / 'sdks.toml').write_text('\n\n'.join(tables))
            (root / 'api/src/gen/pkg.generated.mbti').write_text('gen-v2\n')
            (root / 'explicit/moon.mod').write_text('name = "gaato/explicit"\nversion = "0.3.0"\nsource = "src"\n')
            now = datetime(2026, 11, 16, tzinfo=timezone.utc)
            planned = weekly_release.prepare(entries, root, now=now)
            self.assertEqual([(p['module'], p['next'], p['kind']) for p in planned],
                             [('api', '0.2.0', 'minor'), ('implementation', '0.1.1', 'patch'), ('explicit', '0.3.0', 'explicit')])
            self.assertIn('version = "0.2.0"', (root / 'api/moon.mod').read_text())
            self.assertIn('## [0.1.1] - ', (root / 'implementation/CHANGELOG.md').read_text())
            self.assertEqual(weekly_release.plan(entries[:1], root, now=now)[0]['kind'], 'explicit')
            baseline = weekly_release.baseline_path(root, entries[1])
            state = json.loads(baseline.read_text())
            state['version'] = '0.1.1'
            state['published_at'] = '2026-11-16T00:00:00+00:00'
            baseline.write_text(json.dumps(state))
            (root / 'implementation/CHANGELOG.md').write_text('## [Unreleased]\n- Next change\n\n## [0.1.1]\n')
            self.assertEqual(weekly_release.plan(entries[1:2], root, now=now), [])
            self.assertEqual(weekly_release.plan(entries[1:2], root, now=now, manual=True)[0]['next'], '0.1.2')
            print('weekly fixture: api 0.1.0 -> 0.2.0; implementation 0.1.0 -> 0.1.1; untouched skipped; explicit 0.3.0 preserved; same-week skipped; manual override 0.1.2')
