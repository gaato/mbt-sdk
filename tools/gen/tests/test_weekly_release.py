"""First publication and mixed batches use only temporary registry artifacts."""
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from tools import weekly_release


ROOT = Path(__file__).resolve().parents[3]
NOW = datetime(2026, 11, 16, tzinfo=timezone.utc)


class WeeklyReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='f8d-weekly-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'moon-home'
        self.environment = patch.dict(os.environ, MOON_HOME=str(self.home))
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def module(self, name, version='0.1.0'):
        directory = self.root / name
        (directory / 'src/gen').mkdir(parents=True)
        (directory / 'moon.mod').write_text(f'name = "gaato/{name}"\nversion = "{version}"\nsource = "src"\n')
        (directory / 'src/pkg.generated.mbti').write_text('api-v1\n')
        (directory / 'src/gen/pkg.generated.mbti').write_text('gen-v1\n')
        (directory / 'CHANGELOG.md').write_text('# Changelog\n\n## [Unreleased]\n\n- Initial release.\n')
        return dict(name=name, dir=name, module=f'gaato/{name}', out=f'{name}/src/gen',
                    generator='openapi', spec_file=f'{name}/spec.json', spec_url=f'https://example.invalid/{name}',
                    spec_fetch='plain', package=f'gaato/{name}/gen', publish=True, spec_watch=True,
                    include_all=True, derive_operation_ids=True, census_args=[], offline_packages=[])

    def index(self, sdk, records):
        path = self.home / 'registry/index/user' / (sdk['module'] + '.index')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps(record) + '\n' for record in records))

    def published(self, sdk):
        record = dict(version='0.1.0', created_at='2026-11-01T00:00:00+00:00', checksum='published-archive')
        self.index(sdk, [record])
        weekly_release.capture(self.root, sdk, record, self.root / sdk['dir'])
        return record

    def test_refresh_no_index_or_empty_index_then_capture_first_publication(self):
        for index in ('missing', 'empty'):
            with self.subTest(index=index):
                sdk = self.module(index)
                if index == 'empty':
                    self.index(sdk, [])
                output = io.StringIO()
                with redirect_stdout(output), patch('tools.weekly_release.subprocess.run') as execute:
                    weekly_release.refresh([sdk], self.root)
                execute.assert_not_called()
                state = json.loads(weekly_release.baseline_path(self.root, sdk).read_text())
                self.assertEqual(state, {'module': sdk['module'], 'state': 'unpublished'})
                self.assertIn('no published baseline', output.getvalue())
                for manual in (False, True):
                    planned = weekly_release.prepare([sdk], self.root, now=NOW, manual=manual, dry_run=True)
                    self.assertEqual([(p['next'], p['kind']) for p in planned], [('0.1.0', 'first')])
                # A human may choose a different initial version before publication.
                directory = self.root / sdk['dir']
                (directory / 'moon.mod').write_text(f'name = "{sdk["module"]}"\nversion = "0.3.0"\nsource = "src"\n')
                self.assertEqual(weekly_release.plan([sdk], self.root, now=NOW)[0]['next'], '0.3.0')
                package = self.root / 'published' / sdk['module']
                shutil.copytree(directory, package)
                # Refresh must capture the artifact, not the newer working tree.
                (directory / 'src/gen/pkg.generated.mbti').write_text('unpublished-api-v2\n')
                record = dict(version='0.3.0', created_at=NOW.isoformat(), checksum='first-published-archive')
                self.index(sdk, [record])
                weekly_release.refresh([sdk], self.root, self.root / 'published')
                baseline = json.loads(weekly_release.baseline_path(self.root, sdk).read_text())
                self.assertNotIn('state', baseline)
                self.assertEqual(baseline['version'], '0.3.0')
                self.assertEqual(baseline['artifact_checksum'], record['checksum'])
                self.assertEqual(baseline['api'], weekly_release.api_snapshot(package))
                self.assertNotEqual(baseline['api'], weekly_release.api_snapshot(directory))
                self.assertEqual(weekly_release.plan([sdk], self.root, now=NOW), [])

    def test_missing_baseline_skips_only_that_published_module(self):
        missing = self.module('missing_baseline')
        record = self.published(missing)
        weekly_release.baseline_path(self.root, missing).unlink()
        ready = self.module('ready')
        self.published(ready)
        output = io.StringIO()
        for entries in ([missing, ready], [ready, missing]):
            with self.subTest(order=[s['name'] for s in entries]), redirect_stderr(output):
                planned = weekly_release.plan(entries, self.root, now=NOW)
                self.assertEqual([(p['module'], p['next']) for p in planned], [('ready', '0.1.1')])
        self.assertIn('missing_baseline', output.getvalue())
        self.assertIn('refresh', output.getvalue())
        self.assertEqual(weekly_release.registry_versions(missing), [record])

    def test_refresh_empty_index_retains_a_real_baseline(self):
        sdk = self.module('established')
        self.published(sdk)
        path = weekly_release.baseline_path(self.root, sdk)
        before = path.read_bytes()
        self.index(sdk, [])
        weekly_release.refresh([sdk], self.root)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(weekly_release.plan([sdk], self.root, now=NOW)[0]['kind'], 'patch')

    def test_mixed_batch_first_release_and_existing_bumps_with_real_helper(self):
        entries = [self.module(name) for name in ('first', 'minor', 'patch', 'explicit_first')]
        for sdk in entries[1:3]:
            self.published(sdk)
        (self.root / 'minor/src/gen/pkg.generated.mbti').write_text('gen-v2\n')
        (self.root / 'explicit_first/moon.mod').write_text('name = "gaato/explicit_first"\nversion = "0.4.0"\nsource = "src"\n')
        (self.root / 'explicit_first/CHANGELOG.md').write_text('## [Unreleased]\n\n## [0.4.0] - 2026-11-16\n\n- Reviewed initial release.\n')
        weekly_release.refresh(entries, self.root)
        (self.root / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/release.sh', self.root / 'scripts/release.sh')
        (self.root / 'tools').mkdir()
        shutil.copy2(ROOT / 'tools/sdks.py', self.root / 'tools/sdks.py')
        shutil.copytree(ROOT / 'tools/gen', self.root / 'tools/gen', ignore=shutil.ignore_patterns('__pycache__', 'tests'))
        for sdk in entries:
            (self.root / sdk['spec_file']).write_text('{}')
        (self.root / 'sdks.toml').write_text('\n\n'.join('[[sdk]]\n' + '\n'.join(key + ' = ' + json.dumps(value) for key, value in sdk.items()) for sdk in entries))
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        planned = weekly_release.prepare(entries, self.root, now=NOW, dry_run=True)
        self.assertEqual({p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}, before)
        self.assertEqual([(p['module'], p['next'], p['kind']) for p in planned], [
            ('first', '0.1.0', 'first'), ('minor', '0.2.0', 'minor'), ('patch', '0.1.1', 'patch'),
            ('explicit_first', '0.4.0', 'first')])
        explicit_notes = (self.root / 'explicit_first/CHANGELOG.md').read_bytes()
        self.assertEqual(weekly_release.prepare(entries, self.root, now=NOW), planned)
        self.assertIn('version = "0.1.0"', (self.root / 'first/moon.mod').read_text())
        self.assertIn('## [0.1.0] - ', (self.root / 'first/CHANGELOG.md').read_text())
        self.assertFalse(weekly_release.unreleased(self.root / 'first'))
        self.assertEqual((self.root / 'explicit_first/CHANGELOG.md').read_bytes(), explicit_notes)
        self.assertIn('version = "0.2.0"', (self.root / 'minor/moon.mod').read_text())
        self.assertIn('version = "0.1.1"', (self.root / 'patch/moon.mod').read_text())
        print('mixed first-release fixture: first 0.1.0 unchanged; minor 0.2.0; patch 0.1.1; human first 0.4.0 preserved; dry-run wrote nothing')
