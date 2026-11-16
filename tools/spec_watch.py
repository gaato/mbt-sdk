#!/usr/bin/env python3
"""Regenerate every consumer of one vendored spec, preserving every result.

This is the local processing part of spec-watch. Fetching and PR publication
belong to the workflow; no VCS, provider API or credential access occurs here.
"""
import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import subprocess
import sys

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import sdks


def snapshot(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob('*') if p.is_file() and p.suffix in ('.mbt', '.mbti')}


def process(sdk, root, logs, runner):
    name = sdk['name']
    source = root / sdk['dir'] / 'src'
    before = snapshot(source)
    result = {'module': name}
    commands = {
        'generation': ['scripts/generate.sh', name],
        'interfaces': ['bash', '-c', 'moon update && moon -C "$1" fmt && moon -C "$1" info', '_', sdk['dir']],
        'census': ['uv', 'run', '--with', 'pyyaml', '--with', 'jsonpath-rfc9535', 'python', 'tools/gen/census.py', sdk['spec_file'], name, '--sdk', name, '--compile', '--expect-zero'],
        'gates': ['scripts/gates.sh', '--sdk', name, '--no-js'],
    }
    for stage, command in commands.items():
        # Every stage and consumer runs even if a preceding one fails. In
        # particular, a stale interface never masquerades as a successful check.
        with (logs / f'{name}-{stage}.log').open('w') as stream:
            try:
                completed = subprocess.run([runner, *command], cwd=root, text=True, stdout=stream, stderr=subprocess.STDOUT)
                result[stage] = completed.returncode
            except OSError as error:
                stream.write(str(error) + '\n')
                result[stage] = 127
    result['notes'] = 0
    if result['generation'] == result['interfaces'] == 0 and before != snapshot(source):
        digest = hashlib.sha256((root / sdk['spec_file']).read_bytes()).hexdigest()[:12]
        text = f'**Regenerated from the upstream spec fetched {date.today().isoformat()}** (sha256 `{digest}`). Changes are batched for the next weekly release; see the generated interface diff.'
        if (root / sdk['dir'] / 'CHANGELOG.md').is_file():
            with (logs / f'{name}-notes.log').open('w') as stream:
                result['notes'] = subprocess.run(['scripts/release.sh', 'note', sdk['dir'], 'Changed', text], cwd=root, text=True, stdout=stream, stderr=subprocess.STDOUT).returncode
    return result


def run_group(entries, spec_path, root, logs, runner='moonbit'):
    consumers = [s for s in entries if s['spec_file'] == spec_path]
    if not consumers:
        raise ValueError('unknown spec source: ' + spec_path)
    logs.mkdir(parents=True, exist_ok=True)
    results = [process(sdk, root, logs, runner) for sdk in consumers]
    (logs / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    body = [f'Updated shared specification `{spec_path}`.', '',
            '| Module | Generation | Interfaces | Census + compile | Gates | Notes |',
            '|---|---:|---:|---:|---:|---:|']
    for result in results:
        body.append('| ' + result['module'] + ' | ' + ' | '.join(str(result[stage]) for stage in ('generation', 'interfaces', 'census', 'gates', 'notes')) + ' |')
    body += ['', 'No version bump. Generated changes are recorded under `[Unreleased]` and batched by the weekly release job.',
             'Auto-merge requires every status above to be zero and the branch CI to pass.', '']
    for result in results:
        for stage in ('generation', 'interfaces', 'census', 'gates'):
            path = logs / f'{result["module"]}-{stage}.log'
            tail = '\n'.join(path.read_text()[-12000:].splitlines()[-35:]).replace('```', '~~~')
            body += [f'<details><summary>{result["module"]}: {stage}</summary>', '', '```text', tail, '```', '</details>', '']
    (logs / 'body.md').write_text('\n'.join(body))
    return int(any(result[stage] != 0 for result in results for stage in ('generation', 'interfaces', 'census', 'gates', 'notes')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--spec-path', required=True)
    parser.add_argument('--log-dir', type=Path, required=True)
    parser.add_argument('--runner', default='moonbit')
    args = parser.parse_args()
    return run_group(sdks.load(), args.spec_path, sdks.ROOT, args.log_dir, args.runner)


if __name__ == '__main__':
    raise SystemExit(main())
