#!/usr/bin/env python3
"""Batch watched SDK releases against interfaces from immutable published packages.

refresh records registry version/checksum/time and the package's shipped .mbti
hashes, never the current checkout's guess about a previous release. It also
repairs the publish-succeeded/record-commit-failed case on the next run.
Before first publication it records an unpublished state without inventing an
API baseline, so the chosen initial version can be released unchanged.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import sdks


def version(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+', value):
        raise ValueError('release versions must be numeric major.minor.patch: ' + value)
    return tuple(map(int, value.split('.')))


def api_snapshot(directory):
    files = sorted((directory / 'src').rglob('pkg.generated.mbti'))
    if not files:
        raise ValueError('no generated interfaces in ' + str(directory))
    return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}


def baseline_path(root, sdk):
    return root / '.release-baselines' / (sdk['name'] + '.json')


def registry_versions(sdk):
    home = Path(os.environ.get('MOON_HOME', str(Path.home() / '.moon')))
    path = home / 'registry/index/user' / (sdk['module'] + '.index')
    if not path.is_file():
        return []
    records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return [item for item in records if not item.get('yanked')]


def capture(root, sdk, record, package):
    manifest = (package / 'moon.mod').read_text()
    if not re.search(r'^name = "' + re.escape(sdk['module']) + '"$', manifest, re.M) or not re.search(r'^version = "' + re.escape(record['version']) + '"$', manifest, re.M):
        raise ValueError('published package identity/version mismatch: ' + sdk['name'])
    api = api_snapshot(package)
    required = {'src/pkg.generated.mbti'}
    if sdk['out'] != sdk['dir'] + '/src':
        required.add('src/gen/pkg.generated.mbti')
    if not required.issubset(api):
        raise ValueError('published package lacks its root/generated interfaces: ' + sdk['name'])
    baseline = dict(module=sdk['module'], version=record['version'], published_at=record['created_at'],
                    artifact_checksum=record['checksum'], api=api)
    path = baseline_path(root, sdk)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(baseline, sort_keys=True, indent=2) + '\n')
    return baseline


def refresh(entries, root, published_root=None):
    for sdk in entries:
        if not (sdk['publish'] and sdk['spec_watch']):
            continue
        records = registry_versions(sdk)
        path = baseline_path(root, sdk)
        if not records:
            # An absent index is normal before first publication. Never erase
            # a real baseline when an incomplete local index loses its entry.
            current = json.loads(path.read_text()) if path.is_file() else {}
            if current.get('module') == sdk['module'] and current.get('version'):
                print(f'baseline {sdk["name"]}: no registry versions; retaining published baseline {current["version"]}')
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(dict(module=sdk['module'], state='unpublished'), sort_keys=True, indent=2) + '\n')
            print(f'baseline {sdk["name"]}: no published baseline (unpublished)')
            continue
        record = max(records, key=lambda item: version(item['version']))
        if path.is_file():
            current = json.loads(path.read_text())
            if current.get('module') == sdk['module'] and current.get('version') == record['version'] and current.get('artifact_checksum') == record['checksum']:
                continue
        if published_root:
            capture(root, sdk, record, published_root / sdk['module'])
        else:
            with tempfile.TemporaryDirectory(prefix='published-sdk-baseline-') as temporary:
                directory = Path(temporary)
                (directory / 'src').mkdir()
                (directory / 'src/moon.pkg').write_text('// Resolve a published package without compiling or changing its sources.\n')
                (directory / 'moon.mod').write_text(f'name = "factory/published_baseline"\nversion = "0.0.0"\nsource = "src"\nimport {{ "{sdk["module"]}@{record["version"]}" }}\n')
                subprocess.run(['moon', '-C', str(directory), 'check'], check=True)
                capture(root, sdk, record, directory / '.mooncakes' / sdk['module'])
        print(f'baseline {sdk["name"]}@{record["version"]} from registry artifact {record["checksum"]}')


def unreleased(directory):
    text = (directory / 'CHANGELOG.md').read_text()
    match = re.search(r'^## \[Unreleased\]\s*\n(.*?)(?=^## |\Z)', text, re.M | re.S)
    if not match:
        raise ValueError('CHANGELOG has no Unreleased section: ' + str(directory))
    return bool(re.search(r'^-\s+\S', match[1], re.M))


def plan(entries, root, *, now=None, manual=False):
    now = now or datetime.now(timezone.utc)
    results = []
    for sdk in entries:
        if not (sdk['publish'] and sdk['spec_watch']):
            continue
        directory = root / sdk['dir']
        path = baseline_path(root, sdk)
        if not path.is_file():
            print(f'skip {sdk["name"]}: missing published baseline; run refresh first', file=sys.stderr)
            continue
        baseline = json.loads(path.read_text())
        if baseline.get('module') != sdk['module']:
            raise ValueError('invalid published baseline: ' + sdk['name'])
        current = re.search(r'^version = "([^"]+)"$', (directory / 'moon.mod').read_text(), re.M)[1]
        version(current)
        if baseline.get('state') == 'unpublished' and set(baseline) == {'module', 'state'}:
            results.append(dict(module=sdk['name'], directory=sdk['dir'], current=current, next=current, kind='first'))
            continue
        if not baseline.get('api') or not baseline.get('artifact_checksum'):
            raise ValueError('invalid published baseline: ' + sdk['name'])
        if version(current) < version(baseline['version']):
            raise ValueError(f'{sdk["name"]}: checkout is older than the published baseline')
        if version(current) > version(baseline['version']):
            results.append(dict(module=sdk['name'], directory=sdk['dir'], current=current, next=current, kind='explicit'))
            continue
        if not unreleased(directory):
            continue
        published = datetime.fromisoformat(baseline['published_at'].replace('Z', '+00:00'))
        # A scheduled retry must not create a second automatic release in the
        # same UTC ISO week; dispatch and explicit human bumps are exceptions.
        if not manual and published.isocalendar()[:2] == now.isocalendar()[:2]:
            continue
        major, minor, patch = version(current)
        changed = api_snapshot(directory) != baseline['api']
        next_version = f'{major}.{minor + 1}.0' if changed else f'{major}.{minor}.{patch + 1}'
        results.append(dict(module=sdk['name'], directory=sdk['dir'], current=current, next=next_version, kind='minor' if changed else 'patch'))
    return results


def prepare(entries, root, *, now=None, manual=False, dry_run=False):
    # Validate the entire plan before the first mutation so invalid candidates
    # cannot leave earlier modules half-bumped. Unrefreshed modules are skipped.
    results = plan(entries, root, now=now, manual=manual)
    for item in results:
        print(f'{item["module"]}: {item["current"]} -> {item["next"]} ({item["kind"]})')
        if not dry_run and item['kind'] != 'explicit':
            # For a first release, the same-version helper only prepares the
            # CHANGELOG; it preserves the chosen initial version and pins.
            subprocess.run(['scripts/release.sh', 'bump', item['directory'], item['next']], cwd=root, check=True)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['refresh', 'prepare'])
    parser.add_argument('--published-root', type=Path, help='already fetched .mooncakes directory (bootstrap/offline verification)')
    parser.add_argument('--manual', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    entries = sdks.load()
    if args.command == 'refresh':
        refresh(entries, sdks.ROOT, args.published_root)
    else:
        prepare(entries, sdks.ROOT, manual=args.manual, dry_run=args.dry_run)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print('weekly-release: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
