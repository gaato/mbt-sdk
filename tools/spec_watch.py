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


STAGES = ('generation', 'interfaces', 'census', 'gates', 'notes')
# UTF-8 byte limit leaves room for the workflow to append the artifact link.
BODY_BUDGET = 60_000
LOG_TAIL_BYTES = 12_000


def snapshot(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob('*') if p.is_file() and p.suffix in ('.mbt', '.mbti')}


def process(sdk, root, logs, runner):
    name = sdk['name']
    notes_log = logs / f'{name}-notes.log'
    notes_log.unlink(missing_ok=True)
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
            with notes_log.open('w') as stream:
                result['notes'] = subprocess.run(['scripts/release.sh', 'note', sdk['dir'], 'Changed', text], cwd=root, text=True, stdout=stream, stderr=subprocess.STDOUT).returncode
    return result


def log_tail(path):
    with path.open('rb') as stream:
        end = stream.seek(0, 2)
        stream.seek(max(0, end - LOG_TAIL_BYTES))
        tail = stream.read().decode('utf-8', errors='replace')
    return '\n'.join(tail.splitlines()[-35:]).replace('```', '~~~').encode('utf-8')


def render_body(spec_path, results, logs):
    body = [f'Updated shared specification `{spec_path}`.', '',
            '| Module | Generation | Interfaces | Census + compile | Gates | Notes |',
            '|---|---:|---:|---:|---:|---:|']
    for result in results:
        body.append('| ' + result['module'] + ' | ' + ' | '.join(str(result[stage]) for stage in STAGES) + ' |')
    body += ['', 'No version bump. Generated changes are recorded under `[Unreleased]` and batched by the weekly release job.',
             'Auto-merge requires every status above to be zero and the branch CI to pass.', '']
    summary = '\n'.join(body)
    remaining = BODY_BUDGET - len(summary.encode('utf-8'))
    if remaining < 0:
        raise ValueError('consumer status table alone exceeds the PR body budget')

    sections = []
    footer = '\n```\n</details>\n'
    for result in results:
        for stage in STAGES:
            path = logs / f'{result["module"]}-{stage}.log'
            if not path.exists():
                continue
            tail = log_tail(path)
            if tail:
                header = f'\n<details><summary>{result["module"]}: {stage}</summary>\n\n```text\n'
                sections.append((header, tail))
                remaining -= len(header.encode('utf-8')) + len(footer)
    if remaining < len(sections):
        return summary

    # Allocate equally among remaining logs, returning unused space from
    # short tails before allocating space to longer ones.
    shares = [0] * len(sections)
    by_size = sorted(range(len(sections)), key=lambda index: len(sections[index][1]))
    for count, index in enumerate(by_size):
        share = min(len(sections[index][1]), remaining // (len(sections) - count))
        shares[index] = share
        remaining -= share
    excerpts = [header + tail[-share:].decode('utf-8', errors='ignore') + footer
                for (header, tail), share in zip(sections, shares, strict=True)]
    return summary + ''.join(excerpts)


def run_group(entries, spec_path, root, logs, runner='moonbit'):
    consumers = [s for s in entries if s['spec_file'] == spec_path]
    if not consumers:
        raise ValueError('unknown spec source: ' + spec_path)
    logs.mkdir(parents=True, exist_ok=True)
    results = [process(sdk, root, logs, runner) for sdk in consumers]
    (logs / 'results.json').write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
    (logs / 'body.md').write_text(render_body(spec_path, results, logs), encoding='utf-8')
    return int(any(result[stage] != 0 for result in results for stage in STAGES))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--spec-path', required=True)
    parser.add_argument('--log-dir', type=Path, required=True)
    parser.add_argument('--runner', default='moonbit')
    args = parser.parse_args()
    return run_group(sdks.load(), args.spec_path, sdks.ROOT, args.log_dir, args.runner)


if __name__ == '__main__':
    raise SystemExit(main())
