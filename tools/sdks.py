#!/usr/bin/env python3
"""SDK registration, shell queries and synchronization. Ledger parsing uses tomllib.

Pin checks reuse the generator's existing YAML loader in its Python environment;
no new parser or dependency is introduced. All paths are repository-relative.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
STRINGS = 'name dir module generator spec_file spec_url spec_fetch package out'.split()
BOOLS = 'include_all derive_operation_ids publish spec_watch'.split()
ARRAYS = 'census_args offline_packages'.split()
OPTIONAL = {'command', 'report_census_args', 'base_url', 'auth', 'base_url_reason',
            'base_url_spec', 'auth_reason', 'auth_spec', 'client_layer', 'extra_imports',
            'operation_wrappers', 'retry', 'idempotency_headers', 'behavior_note', 'server_urls',
            'timeout_ms', 'total_timeout_ms', 'selection', 'rate_limit_prefix', 'legacy_generic_stream',
            'legacy_multipart_boundary'}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def validate_sdk(sdk, seen=None):
    """Validate one ledger entry without requiring its files to exist yet."""
    label = sdk.get('name', '<unnamed>')
    require(not set(sdk) - set(STRINGS + BOOLS + ARRAYS) - OPTIONAL,
            f'{label}: unknown keys: {set(sdk) - set(STRINGS + BOOLS + ARRAYS) - OPTIONAL}')
    for key in STRINGS + BOOLS + ARRAYS:
        typ = str if key in STRINGS else bool if key in BOOLS else list
        require(type(sdk.get(key)) is typ, f'{label}: {key} must be {typ.__name__}')
        if typ is str:
            require('\n' not in sdk[key], f'{label}: {key} must be single-line')
    for key in ARRAYS + ['report_census_args']:
        require(isinstance(sdk.get(key, []), list) and all(isinstance(v, str) and '\n' not in v for v in sdk.get(key, [])),
                f'{label}: {key} must contain single-line strings')
    # Reporting includes all operations when no separate flags are supplied.
    sdk.setdefault('report_census_args', [])
    sdk.setdefault('client_layer', False)
    require(type(sdk['client_layer']) is bool, f'{label}: client_layer must be boolean')
    require(type(sdk.get('operation_wrappers', True)) is bool, f'{label}: operation_wrappers must be boolean')
    require(type(sdk.get('legacy_generic_stream', False)) is bool, f'{label}: legacy_generic_stream must be boolean')
    require(type(sdk.get('legacy_multipart_boundary', False)) is bool, f'{label}: legacy_multipart_boundary must be boolean')
    for key in ('extra_imports', 'idempotency_headers', 'server_urls'):
        require(isinstance(sdk.get(key, []), list) and all(isinstance(v, str) and v.strip() for v in sdk.get(key, [])), f'{label}: invalid {key}')
    if sdk['client_layer']:
        require('base_url' in sdk and 'auth' in sdk, f'{label}: client_layer needs base_url and auth pins')
    validate_retry(sdk.get('retry'), label)
    from tools.gen.selection import validate as validate_selection
    validate_selection(sdk.get('selection'))
    require('selection' not in sdk or sdk['generator'] != 'custom', f'{label}: custom generators do not support HTTP selections')
    for key in ('timeout_ms', 'total_timeout_ms'):
        if key in sdk:
            require(type(sdk[key]) is int and 0 < sdk[key] <= 2147483647, f'{label}: invalid {key}')
    require(re.fullmatch(r'[a-z][a-z0-9_-]*', label), f'invalid SDK name: {label}')
    if seen is not None:
        for key, values in seen.items():
            require(sdk[key] not in values, f'{label}: duplicate {key}: {sdk[key]}')
            values.add(sdk[key])
    require(sdk['generator'] in ('openapi', 'discovery', 'custom'), f'{label}: invalid generator')
    require(sdk['spec_fetch'] in ('plain', 'gzip'), f'{label}: invalid spec_fetch')
    require(not sdk['spec_watch'] or (sdk['generator'] in ('openapi', 'discovery') and sdk['spec_url'].startswith('https://')),
            f'{label}: spec_watch needs an OpenAPI or Discovery HTTPS source')
    for key in ('base_url', 'base_url_reason', 'auth_reason', 'base_url_spec', 'rate_limit_prefix'):
        if key in sdk:
            require(isinstance(sdk[key], str) and sdk[key].strip(), f'{label}: {key} must be nonempty')
    if 'auth' in sdk:
        validate_auth(sdk['auth'], label)
    for key in ('base_url', 'auth'):
        require((key + '_reason' in sdk) == (key + '_spec' in sdk), f'{label}: {key} override needs both reason and spec baseline')
    if 'auth_spec' in sdk:
        require(isinstance(sdk['auth_spec'], dict), f'{label}: auth_spec must be a table')
    return label


def load():
    data = tomllib.loads((ROOT / 'sdks.toml').read_bytes().decode())
    require(set(data) == {'sdk'} and isinstance(data['sdk'], list), 'expected [[sdk]] tables only')
    require(data['sdk'], 'the SDK ledger must not be empty')
    seen = {key: set() for key in ('name', 'dir', 'module', 'out')}
    for sdk in data['sdk']:
        label = validate_sdk(sdk, seen)
        for key in ('dir', 'out', 'spec_file'):
            relative = Path(sdk[key])
            require(not relative.is_absolute() and '..' not in relative.parts and str(relative) == sdk[key],
                    f'{label}: {key} must be a canonical repository-relative path')
            path = ROOT / sdk[key]
            require(path.resolve().is_relative_to(ROOT) and (key == 'out' or path.exists()), f'{label}: missing or invalid {key}: {sdk[key]}')
        # All consumers, including symlink spellings, must group on the same
        # physical vendored source and its single adjacent provenance file.
        sdk['spec_file'] = str((ROOT / sdk['spec_file']).resolve().relative_to(ROOT))
        require((ROOT / sdk['dir']).is_dir(), f'{label}: dir must be a directory')
        mod = (ROOT / sdk['dir'] / 'moon.mod').read_bytes().decode()
        require(re.search(r'^name = "' + re.escape(sdk['module']) + '"$', mod, re.M), f'{label}: moon.mod name mismatch')
        if sdk['generator'] == 'custom':
            require(isinstance(sdk.get('command'), str) and (ROOT / sdk['command']).is_file(), f'{label}: missing custom command')
    sources = {}
    locations = {}
    for sdk in data['sdk']:
        source = str((ROOT / sdk['spec_file']).resolve())
        metadata = tuple(sdk[key] for key in ('spec_url', 'spec_fetch', 'generator'))
        require(source not in sources or sources[source] == metadata,
                f'{sdk["name"]}: shared spec has contradictory source metadata')
        sources[source] = metadata
        if sdk['generator'] != 'custom':
            require(sdk['spec_url'] not in locations or locations[sdk['spec_url']] == source,
                    f'{sdk["name"]}: duplicate vendored source; share one spec_file instead')
            locations[sdk['spec_url']] = source
    return data['sdk']


def spec_groups(sdks):
    groups = {}
    for sdk in sdks:
        group = groups.setdefault(sdk['spec_file'], [])
        group.append(sdk)
    return [dict(provider=members[0]['name'], generator=members[0]['generator'],
                 spec_file=Path(path).name, spec_path=path, spec_url=members[0]['spec_url'],
                 spec_fetch=members[0]['spec_fetch'], modules=[s['name'] for s in members], dirs=[s['dir'] for s in members])
            for path, members in groups.items() if any(s['spec_watch'] for s in members)]


def validate_auth(auth, label):
    require(isinstance(auth, dict), f'{label}: invalid auth')
    kind = auth.get('kind')
    require(kind in ('none', 'bearer', 'basic', 'header', 'query', 'header_bundle', 'alternatives'), f'{label}: invalid auth kind')
    if kind == 'alternatives':
        require(set(auth) == {'kind', 'schemes'} and isinstance(auth['schemes'], list) and len(auth['schemes']) >= 2, f'{label}: invalid auth alternatives')
        for scheme in auth['schemes']:
            require(scheme.get('kind') != 'alternatives', f'{label}: nested auth alternatives')
            validate_auth(scheme, label)
    else:
        keys = {'kind'} | ({'name'} if kind in ('header', 'query') else {'headers'} if kind == 'header_bundle' else set())
        require(set(auth) - {'variant'} == keys, f'{label}: unknown/missing auth keys')
        if 'variant' in auth:
            require(isinstance(auth['variant'], str) and re.fullmatch(r'[A-Z][A-Za-z0-9]*', auth['variant']), f'{label}: invalid auth variant')
        if kind in ('header', 'query'):
            require(isinstance(auth['name'], str) and auth['name'].strip(), f'{label}: empty auth name')
        if kind == 'header_bundle':
            headers = auth['headers']
            require(isinstance(headers, dict) and len(headers) >= 2 and
                    all(re.fullmatch(r'[a-z][a-z0-9_]*', field) and isinstance(header, str) and
                        re.fullmatch(r"[!#$%&'*+.\^_`|~0-9A-Za-z-]+", header)
                        for field, header in headers.items()) and
                    len({header.lower() for header in headers.values()}) == len(headers),
                    f'{label}: invalid auth header bundle')


def validate_retry(retry, label):
    if retry is None:
        return
    allowed = {'retries', 'methods', 'statuses', 'status_overrides', 'sent_failures', 'unprocessed_failures', 'override_header', 'retry_after', 'retry_after_cap_ms', 'retry_after_cap', 'zero_means_backoff', 'backoff_base_ms', 'backoff_max_ms', 'jitter', 'guard_response_retries'}
    require(isinstance(retry, dict) and not set(retry) - allowed, f'{label}: unknown retry fields')
    for key in ('retries', 'backoff_base_ms', 'backoff_max_ms'):
        if key in retry:
            require(type(retry[key]) is int and 0 <= retry[key] <= 2147483647, f'{label}: invalid retry {key}')
    for key in ('methods', 'sent_failures'):
        value = retry.get(key, 'idempotent')
        require(value in ('idempotent', 'any', 'never') if isinstance(value, str) else isinstance(value, list) and all(v in ('GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS', 'TRACE', 'POST', 'PATCH') for v in value), f'{label}: invalid retry {key}')
    for status in retry.get('statuses', []):
        require((type(status) is int and 100 <= status <= 599) or (isinstance(status, list) and len(status) == 2 and all(type(s) is int for s in status) and 100 <= status[0] <= status[1] <= 599), f'{label}: invalid retry status')
    for field in ('status_overrides', 'guard_response_retries'):
        require(isinstance(retry.get(field, []), list), f'{label}: {field} must be an array')
        for rule in retry.get(field, []):
            require(isinstance(rule, dict) and set(rule) == {'methods', 'statuses'} and
                    isinstance(rule['methods'], list) and bool(rule['methods']) and
                    isinstance(rule['statuses'], list) and bool(rule['statuses']),
                    f'{label}: {field} requires methods and statuses arrays')
            validate_retry(rule, label)
    require(retry.get('retry_after', 'ms_then_header') in ('ignore', 'header', 'ms_then_header'), f'{label}: invalid retry_after')
    cap = retry.get('retry_after_cap_ms', 60000)
    require(cap == 'none' or type(cap) is int and 0 <= cap <= 2147483647, f'{label}: invalid retry cap')
    require(retry.get('retry_after_cap', 'stop') in ('stop', 'backoff'), f'{label}: invalid retry cap mode')
    jitter = retry.get('jitter', [800, 1200])
    require(jitter in ('none', 'full') if isinstance(jitter, str) else isinstance(jitter, list) and len(jitter) == 2 and all(type(v) is int for v in jitter) and 0 <= jitter[0] <= jitter[1] <= 2147483647, f'{label}: invalid jitter')
    for key in ('unprocessed_failures', 'zero_means_backoff'):
        require(type(retry.get(key, False)) is bool, f'{label}: invalid retry {key}')
    if 'override_header' in retry:
        require(isinstance(retry['override_header'], str) and retry['override_header'].strip(), f'{label}: invalid override_header')


def behavior_notes(sdks):
    for sdk in sdks:
        if not (sdk['publish'] or sdk['client_layer']):
            continue
        deferred = sdk.get('behavior_note', '')
        if deferred:
            require(not sdk['publish'] and deferred.startswith('pending: ') and len(deferred) > 15, f'{sdk["name"]}: invalid behavior_note deferral')
            print(f'{sdk["name"]}: behavior survey explicitly deferred: {deferred}')
            continue
        path = ROOT / 'docs/behavior' / (sdk['name'] + '.md')
        require(path.is_file(), f'{sdk["name"]}: behavior note missing: {path}')
        text = path.read_text()
        require(not re.search(r'\bTODO\b', text, re.I), f'{sdk["name"]}: behavior note contains TODO')
        require(re.search(r'(?i)survey(?:ed| date)?[^\n]*\b\d{4}-\d{2}-\d{2}\b', text), f'{sdk["name"]}: behavior note has no survey date')


def marked(text, marker, body):
    begin, end = f'<!-- BEGIN sdks: {marker} -->', f'<!-- END sdks: {marker} -->'
    pattern = re.escape(begin) + r'.*?' + re.escape(end)
    require(len(re.findall(pattern, text, re.S)) == 1, f'missing/duplicate markers: {marker}')
    return re.sub(pattern, lambda _: begin + '\n' + body + '\n' + end, text, flags=re.S)


def entries(text, pattern, wanted):
    """Replace SDK entries in place, preserving every non-SDK byte."""
    found = set()
    def replace(match):
        value = match.group(1)
        if value in wanted:
            if value in found:
                return ''
            found.add(value)
            return wanted[value]
        return match.group(0)
    text = re.sub(pattern, replace, text, flags=re.M)
    return text, found


def sync(sdks, check):
    registered = {s['dir'] for s in sdks}
    members = set(re.findall(r'^  "([^"]+)",', (ROOT / 'moon.work').read_text(), re.M))
    for directory in ROOT.iterdir():
        generated = directory / 'src/gen'
        if directory.name in registered or not directory.is_dir():
            continue
        # The generator-owned header distinguishes SDKs from handwritten modules.
        owned = generated.is_dir() and any(p.is_file() and p.read_bytes().startswith(b'// GENERATED by tools/gen') for p in generated.iterdir())
        manifest = directory / 'moon.mod'
        # Also catch a removed factory scaffold before its first generation:
        # gaato/<directory> with mttp_core as its sole external dependency.
        factory = False
        if directory.name in members and manifest.is_file():
            mod = manifest.read_text()
            deps = re.findall(r'"([^"\n]+@[^"\n]+)"', mod)
            factory = (f'name = "gaato/{directory.name}"' in mod and len(deps) == 1
                       and deps[0].startswith('gaato/mttp_core@'))
        if owned or factory:
            raise ValueError(f'{directory.name}: registered SDK missing from sdks.toml')
    for sdk in sdks:
        source = ROOT / sdk['spec_file']
        source = source.parent / 'SOURCE.md'
        if sdk['generator'] in ('openapi', 'discovery'):
            text = source.read_text()
            match = re.search(r'^-?\s*Source:\s*(.*?)\s*$', text, re.M)
            require(match is not None and match[1] == sdk['spec_url'],
                    f'{sdk["name"]}: SOURCE.md Source line disagrees with spec_url')
    changes = []
    def update(file, new):
        path = ROOT / file
        if path.read_bytes().decode() != new:
            changes.append(file)
            if not check:
                path.write_bytes(new.encode())
    # Existing SDK entries are replaced in their slots; append new members only.
    work = (ROOT / 'moon.work').read_bytes().decode()
    wanted = {s['dir']: f'  "{s["dir"]}",\n' for s in sdks}
    work, found = entries(work, r'^  "([^"]+)",\n', wanted)
    missing = ''.join(v for k, v in wanted.items() if k not in found)
    work = work.replace('\n]', '\n' + missing + ']', 1)
    update('moon.work', work)
    # Integration tests import HTTP SDKs and badhttp today, not every fixture.
    runtime = (ROOT / 'runtime-tests/moon.mod').read_bytes().decode()
    imports = {}
    for s in sdks:
        if any(p.startswith('runtime-tests/') for p in s['offline_packages']):
            version = re.search(r'^version = "([^"]+)"$', (ROOT / s['dir'] / 'moon.mod').read_bytes().decode(), re.M)[1]
            imports[s['module']] = f'  "{s["module"]}@{version}",\n'
    runtime, found = entries(runtime, r'^  "([^"@]+)@[^"\n]+",\n', imports)
    runtime = runtime.replace('\n}', '\n' + ''.join(v for k, v in imports.items() if k not in found) + '}', 1)
    update('runtime-tests/moon.mod', runtime)
    published = [s for s in sdks if s['publish']]
    config = json.loads((ROOT / 'scripts/docs_audit.json').read_bytes().decode())
    config.update(modules=[s['dir'] for s in published], generated=[s['out'] for s in published])
    update('scripts/docs_audit.json', json.dumps(config, indent=2) + '\n')
    # Preserve human-authored descriptions; registration adds a generic row.
    readme = (ROOT / 'README.md').read_bytes().decode()
    pattern = r'\| .*? \| .*? \| .*? \|'
    block = re.search(r'<!-- BEGIN sdks: modules -->(.*?)<!-- END sdks: modules -->', readme, re.S)
    require(block, 'README.md: missing module markers')
    old_rows = re.findall(pattern, block[1])
    rows = []
    unpublished = ' (not published yet)'
    for s in sdks:
        if s['dir'].startswith('fixtures/'):
            continue
        row = next((r for r in old_rows if f'[{s["module"]}]' in r or f'| {s["module"]} |' in r), None)
        cells = row.split('|')[2:4] if row else [' Generated API vocabulary ', ' mttp_core ']
        purpose = cells[0].rstrip().removesuffix(unpublished)
        cells[0] = purpose + ('' if s['publish'] else unpublished) + ' '
        label = f'[{s["module"]}]({s["dir"]}/README.md)' if (ROOT / s['dir'] / 'README.md').is_file() else s['module']
        rows.append(f'| {label} |' + '|'.join(cells) + '|')
    extras = [r for r in old_rows if not any(s['module'] in r for s in sdks) and not r.startswith(('| Module |', '|---'))]
    update('README.md', marked(readme, 'modules', '\n'.join(['| Module | Purpose | Dependencies |', '|---|---|---|'] + rows + extras)))
    arch = (ROOT / 'ARCHITECTURE.md').read_bytes().decode()
    layer = '| SDKs | ' + ', '.join(s['name'] + ('' if s['publish'] else unpublished) for s in sdks if s['generator'] in ('openapi', 'discovery') and not s['dir'].startswith('fixtures/')) + ' | Generated API vocabulary and vendor policy |'
    block = re.search(r'<!-- BEGIN sdks: http-layer -->(.*?)<!-- END sdks: http-layer -->', arch, re.S)
    require(block, 'ARCHITECTURE.md: missing layer markers')
    layers = re.sub(r'^\| SDKs \|.*$', lambda _: layer, block[1].strip(), flags=re.M)
    custom = [s['dir'] for s in sdks if s['generator'] == 'custom']
    custom_labels = [s['dir'] + ('' if s['publish'] else unpublished) for s in sdks if s['generator'] == 'custom']
    def codex_layer(match):
        extras = [m.strip() for m in match[1].split(',') if m.strip().removesuffix(unpublished) not in custom]
        return '| Codex | ' + ', '.join(custom_labels + extras) + ' |'
    layers = re.sub(r'^\| Codex \| (.*?) \|', codex_layer, layers, flags=re.M)
    update('ARCHITECTURE.md', marked(arch, 'http-layer', layers))
    release = (ROOT / 'docs/release.md').read_bytes().decode()
    body = 'Published modules (ledger order): ' + ', '.join(f'`{s["dir"]}`' for s in published) + '.\n\n'
    body += 'Generated modules kept unpublished: ' + ', '.join(f'`{s["dir"]}`' for s in sdks if not s['publish']) + '.'
    update('docs/release.md', marked(release, 'publish', body))
    for file in changes:
        print(f'{file}: ledger-derived content differs' if check else f'synced {file}', file=sys.stderr)
    pins(sdks)
    return bool(changes) if check else False


def pins(sdks):
    for sdk in sdks:
        if sdk['generator'] not in ('openapi', 'discovery') or not ({'base_url', 'auth'} & sdk.keys()):
            continue
        spec = ROOT / sdk['spec_file']
        if spec.suffix == '.json':
            doc = json.loads(spec.read_bytes().decode())
            if sdk['generator'] == 'discovery':
                from tools.gen.discovery import convert_discovery
                doc = convert_discovery(doc)
        else:
            # Reuse the already-required generator environment for YAML only.
            py = [sys.executable]
            code = 'import json,sys,yaml; d=yaml.load(open(sys.argv[1]), Loader=getattr(yaml,"CSafeLoader",yaml.SafeLoader)); print(json.dumps({**{k: d[k] for k in ("servers", "security", "paths") if k in d}, "components": {"securitySchemes": d.get("components", {}).get("securitySchemes", {})}}))'
            try:
                output = subprocess.check_output(py + ['-c', code, str(spec)], text=True, cwd=ROOT, stderr=subprocess.PIPE)
            except subprocess.CalledProcessError as error:
                if "ModuleNotFoundError: No module named 'yaml'" in error.stderr:
                    command = 'uv run --with pyyaml --with jsonpath-rfc9535 python tools/sdks.py sync'
                    raise ValueError(f'PyYAML is unavailable; run: {command}' + (' --check' if '--check' in sys.argv else '')) from None
                print(error.stderr, file=sys.stderr, end='')
                raise
            doc = json.loads(output)
        from tools.gen.selection import selected_document
        identities = None
        if sdk.get('selection') is not None:
            from tools.gen.normalize import normalize_spec
            overlays = sorted((ROOT / sdk['dir'] / 'overlays').glob('*.yaml'))
            identities = normalize_spec(spec, overlays)
        doc = selected_document(doc, sdk.get('selection'), identities=identities)
        if 'base_url' in sdk:
            servers = doc.get('servers') or [{}]
            actual = servers[0].get('url')
            expected = sdk.get('base_url_spec', sdk['base_url'])
            require(actual == expected, f'{sdk["name"]}: base_url pin {expected!r} disagrees with servers[0].url {actual!r}; review the host change (a deliberate override needs base_url_reason and base_url_spec)')
        if sdk.get('client_layer'):
            from tools.gen.ir import HTTP_METHODS
            override_urls = set()
            for item in doc.get('paths', {}).values():
                for value in [item] + [op for method, op in item.items() if method in HTTP_METHODS and isinstance(op, dict)]:
                    override_urls.update(server['url'] for server in value.get('servers', []))
            require(override_urls == set(sdk.get('server_urls', [])), f'{sdk["name"]}: path/operation servers changed; review and pin server_urls: {sorted(override_urls)}')
        if 'auth' in sdk:
            schemes = doc.get('components', {}).get('securitySchemes', {})
            require(isinstance(schemes, dict) and all(isinstance(s, dict) for s in schemes.values()), f'{sdk["name"]}: invalid securitySchemes; review authentication')
            if 'auth_reason' in sdk:
                ok = schemes == sdk['auth_spec']
            else:
                from tools.gen.client_layer import auth_choices, scheme_auth, security_auth_choices
                choices = auth_choices(sdk['auth'])
                required_auth, saw_security = security_auth_choices(doc)
                actual_auth = required_auth if saw_security else [scheme_auth(s) for s in schemes.values()]
                ok = (not schemes and choices == [{'kind': 'none'}]) or bool(schemes) and all(a in choices for a in actual_auth) and all(a in actual_auth for a in choices if a['kind'] != 'none')
            require(ok, f'{sdk["name"]}: auth pin disagrees with securitySchemes {schemes!r}; review authentication (a deliberate override needs auth_reason and auth_spec)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='cmd', required=True)
    listing = sub.add_parser('list')
    listing.add_argument('--publish', action='store_true')
    listing.add_argument('--spec-watch', action='store_true')
    listing.add_argument('--generator', choices=['openapi', 'discovery', 'custom'])
    get = sub.add_parser('get')
    get.add_argument('name')
    get.add_argument('field')
    sub.add_parser('matrix')
    census_parser = sub.add_parser('census')
    census_parser.add_argument('names', nargs='*')
    census_parser.add_argument('--compile', action='store_true')
    census_parser.add_argument('--json', action='store_true')
    syncing = sub.add_parser('sync')
    syncing.add_argument('--check', action='store_true')
    sub.add_parser('behavior-check')
    args = parser.parse_args()
    sdks = load()
    if args.cmd == 'list':
        print('\n'.join(s['name'] for s in sdks if (not args.publish or s['publish']) and (not args.spec_watch or s['spec_watch']) and (not args.generator or s['generator'] == args.generator)))
    elif args.cmd == 'get':
        sdk = next((s for s in sdks if s['name'] == args.name), None)
        require(sdk is not None, f'unknown SDK: {args.name}')
        require(args.field in sdk, f'{args.name}: no field {args.field}')
        value = sdk[args.field]
        print('\n'.join(value) if isinstance(value, list) else json.dumps(value) if isinstance(value, (bool, dict)) else value)
    elif args.cmd == 'matrix':
        print(json.dumps({'include': spec_groups(sdks)}))
    elif args.cmd == 'behavior-check':
        behavior_notes(sdks)
    elif args.cmd == 'census':
        from tools.gen.census import ledger_census
        require(not set(args.names) - {s['name'] for s in sdks}, 'unknown census SDK name')
        results = [ledger_census(sdk, ROOT, compile=args.compile) for sdk in sdks if not args.names or sdk['name'] in args.names]
        if args.json:
            print(json.dumps([result.to_dict() for result in results]))
        else:
            for result in results:
                print(f'{result.name}: operations={result.operations} diagnostics={result.diagnostics} compilation={result.compilation}')
                for diagnostic in result.details:
                    print(f'  {diagnostic["pointer"]}: {diagnostic["reason"]}; {diagnostic["overlay_hint"]}')
        return int(any(result.diagnostics for result in results))
    else:
        return int(sync(sdks, args.check))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f'sdks: {error}', file=sys.stderr)
        sys.exit(1)
