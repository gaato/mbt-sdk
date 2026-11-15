#!/usr/bin/env python3
"""Scaffold and register an unpublished SDK from a public OpenAPI specification."""
from __future__ import annotations

import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile
import tomllib
from urllib.parse import urlparse
from urllib.request import urlopen

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools import sdks
from tools.gen.diagnostics import GenerationError
from tools.gen.census import run as census_run
from tools.gen.main import run as generate_run
from tools.gen.normalize import normalize_spec

ROOT = sdks.ROOT


def auth_pin(doc):
    schemes = doc.get('components', {}).get('securitySchemes', {})
    pins = []
    for scheme in schemes.values():
        if scheme.get('type') == 'http' and str(scheme.get('scheme', '')).lower() == 'bearer':
            pins.append({'kind': 'bearer'})
        elif scheme.get('type') == 'apiKey' and scheme.get('in') == 'header':
            pins.append({'kind': 'header', 'name': scheme['name']})
        else:
            raise ValueError('securitySchemes cannot be represented by the ledger auth pin; review authentication before scaffolding')
    if pins and any(pin != pins[0] for pin in pins):
        raise ValueError('multiple distinct authentication schemes need an explicit ledger policy')
    return pins[0] if pins else None


def scaffold(args):
    name = args.name
    if not re.fullmatch(r'[a-z][a-z0-9_-]*', name):
        raise ValueError('name must be a lowercase SDK identifier')
    module = args.module or f'gaato/{name}'
    if not re.fullmatch(r'[a-z][a-z0-9_-]*/[a-z][a-z0-9_-]*', module):
        raise ValueError('module must have the form owner/name')
    ledger_path = ROOT / 'sdks.toml'
    ledger = ledger_path.read_text()
    registered = tomllib.loads(ledger)['sdk']
    directory = ROOT / name
    behavior = ROOT / f'docs/behavior/{name}.md'
    if directory.exists() or directory.is_symlink() or behavior.exists() or any(s['name'] == name or s['dir'] == name or s['module'] == module for s in registered):
        raise ValueError(f'refusing to overwrite existing directory, behavior note or ledger name/module: {name}')
    if urlparse(args.spec_url).scheme != 'https':
        raise ValueError('--spec-url must be a public HTTPS specification URL')
    suffix = Path(args.spec_file or urlparse(args.spec_url).path).suffix.lower()
    suffix = suffix if suffix in ('.yaml', '.yml', '.json') else '.json'
    spec_file = f'{name}/spec/openapi{suffix}'
    files = ['moon.mod', 'README.md -> src/overview.mbt.md', 'CHANGELOG.md',
             'src/overview.mbt.md', 'src/moon.pkg', 'overlays/fix.yaml',
             'overlays/moonbit.yaml', f'spec/openapi{suffix}', 'spec/SOURCE.md']
    if args.dry_run:
        for file in files:
            print(f'create {name}/{file}')
        print(f'create docs/behavior/{name}.md\nappend sdks.toml; run tools/sdks.py sync\nrun census for {spec_file}')
        if args.generate:
            print(f'generate {name}/src/gen')
        return 0
    raw = Path(args.spec_file).read_bytes() if args.spec_file else urlopen(args.spec_url, timeout=60).read()
    # Parse only as data, using the generator's safe YAML/JSON loader.
    with tempfile.TemporaryDirectory() as tmp:
        spec = Path(tmp) / f'openapi{suffix}'
        spec.write_bytes(raw)
        doc = normalize_spec(spec, [])
        # Empty actions are accepted by normalize_spec; keep both overlay slots.
        empty_overlay = 'overlay: 1.0.0\ninfo:\n  title: SDK overlay\n  version: 1.0.0\nactions: []\n'
        overlay = Path(tmp) / 'empty.yaml'
        overlay.write_text(empty_overlay)
        normalize_spec(spec, [overlay])
    version = doc.get('openapi', '')
    if not isinstance(version, str) or not re.fullmatch(r'3\.[01]\.\d+', version):
        raise ValueError('scaffolding requires OpenAPI 3.0.x or 3.1.x; convert Swagger 2.0 first')
    servers = doc.get('servers') or []
    if not servers or not isinstance(servers[0].get('url'), str) or not servers[0]['url']:
        raise ValueError('servers[0].url is required for the base_url pin')
    auth = auth_pin(doc)
    versions = {re.search(r'"gaato/mttp_core@([^"\n]+)"', (ROOT / s['dir'] / 'moon.mod').read_text())[1]
                for s in registered if s['generator'] == 'openapi' and not s['dir'].startswith('fixtures/')}
    if len(versions) != 1:
        raise ValueError('existing SDKs disagree on the mttp_core dependency version')
    core_version = versions.pop()
    quote = json.dumps
    repo = 'https://github.com/gaato/mbt-sdk'
    contents = {
        'moon.mod': f'name = {quote(module)}\nversion = "0.1.0"\nlicense = "Apache-2.0"\nreadme = "README.md"\nrepository = "{repo}"\nsource = "src"\npreferred_target = "wasm-gc"\n\nimport {{\n  "gaato/mttp_core@{core_version}",\n}}\n',
        'CHANGELOG.md': '# Changelog\n\n## [Unreleased]\n\n- Scaffold generated API vocabulary.\n',
        'src/moon.pkg': '// The generated vocabulary is available in the gen package.\n',
        'src/overview.mbt.md': f'''# {module}

Generated API vocabulary for {name} in MoonBit. This scaffold provides request
builders and JSON types in `{module}/gen`; a client facade is pending.

## Install

```sh
moon add {module}
```

Import `{module}/gen` to use the generated operations. Prepare JSON values with
MoonBit's built-in JSON support:

```mbt check
///|
test {{
  let body : Json = {{ "example": true }}
  ignore(body)
}}
```

## Limits and errors

The caller supplies a transport and handles errors, retries and timeouts.
Non-JSON responses remain raw HTTP responses. The vocabulary supports wasm-gc,
JavaScript and native targets; transport support depends on the chosen backend.
See the [behavior survey]({repo}/blob/main/docs/behavior/{name}.md) for policy work
still to be completed and the [specification source]({args.spec_url}).
''',
        'overlays/fix.yaml': empty_overlay,
        'overlays/moonbit.yaml': empty_overlay,
        'spec/SOURCE.md': f'# openapi{suffix}\n\n- Source: {args.spec_url}\n- Fetched: {date.today().isoformat()}\n- sha256: {hashlib.sha256(raw).hexdigest()}\n- OpenAPI version: {version}\n',
    }
    for file, content in contents.items():
        path = directory / file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    (ROOT / spec_file).write_bytes(raw)
    (directory / 'README.md').symlink_to('src/overview.mbt.md')
    behavior.parent.mkdir(parents=True, exist_ok=True)
    behavior.write_text(f'''# {name} behavior survey

Date: {date.today().isoformat()}

## A — the server's contract

TODO: dated sources, rate limits, retries, idempotency and timeouts.

## B — the vendor's official SDK

TODO: pinned sources and official retry, timeout and rate-limit behavior.

## C — community libraries

TODO: sources and differences from A and B, if applicable.

## Our behavior and divergences

TODO: source per row, adopted behavior and reasons for divergences.
''')
    fields = dict(name=name, dir=name, module=module, generator='openapi', spec_file=spec_file,
                  spec_url=args.spec_url, spec_fetch='plain', include_all=True, derive_operation_ids=True,
                  package=f'{module}/gen', out=f'{name}/src/gen',
                  census_args=['--overlay', f'{name}/overlays/fix.yaml', '--overlay', f'{name}/overlays/moonbit.yaml'],
                  report_census_args=['--overlay', f'{name}/overlays/fix.yaml'],
                  offline_packages=[f'{name}/src', f'{name}/src/gen'], base_url=servers[0]['url'])
    lines = ['\n[[sdk]]']
    for key, value in fields.items():
        lines.append(f'{key} = {quote(value)}')
    if auth:
        lines.append('auth = { ' + ', '.join(f'{k} = {quote(v)}' for k, v in auth.items()) + ' }')
    lines.extend(['publish = false', 'spec_watch = false'])
    ledger_path.write_text(ledger + '\n'.join(lines) + '\n')
    sdks.sync(sdks.load(), False)
    census_run([str(ROOT / spec_file), name, '--overlay', str(directory / 'overlays/fix.yaml'), '--overlay', str(directory / 'overlays/moonbit.yaml')])
    if args.generate:
        return generate_run(['--spec', str(ROOT / spec_file), '--out', str(directory / 'src/gen'), '--package', f'{module}/gen',
                             '--include-all', '--derive-operation-ids', '--overlay', str(directory / 'overlays/fix.yaml'),
                             '--overlay', str(directory / 'overlays/moonbit.yaml')])
    return 0


def run(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('--spec-url', required=True)
    parser.add_argument('--spec-file')
    parser.add_argument('--module')
    parser.add_argument('--generate', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    try:
        return scaffold(args)
    except (ValueError, OSError, KeyError, GenerationError) as error:
        print(f'new_sdk: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(run())
