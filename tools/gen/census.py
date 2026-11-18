"""Measure generator diagnostics after including every operation in a spec."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import asdict, dataclass, field
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.gen.diagnostics import Diagnostic, GenerationError
from tools.gen.emit_moonbit import emit
from tools.gen.ir import IRBuilder, include_all_operations, include_operations
from tools.gen.normalize import normalize_spec


@dataclass(frozen=True)
class CensusResult:
    name: str
    spec: str
    operations: int
    diagnostics: int
    kinds: dict[str, int]
    notes: list[dict[str, str]]
    discovery: dict[str, object] | None = None
    details: list[dict[str, str]] = field(default_factory=list)
    compilation: str = 'not-requested'

    def to_dict(self) -> dict[str, object]:
        result = asdict(self)
        if self.discovery is None:
            result.pop("discovery")
        return result


def diagnostic_kind(diagnostic: Diagnostic) -> str:
    """Collapse data-dependent lists so the same reason shares one bucket."""
    return re.sub(r"\[[^\]]*\]", "[...]", diagnostic.reason)


def census(
    spec: str | Path, name: str, *, ops: set[str] | None = None, overlays: list[str] | None = None, client_layer: bool = False,
    compile: bool = False, sdk: dict | None = None, root: Path | None = None, selection: dict | None = None
) -> CensusResult:
    """Run the selected-operations generator census without writing files."""
    operations = 0
    diagnostics: list[Diagnostic] = []
    builder = None
    discovery = None
    compilation = 'not-requested' if not compile else 'skipped-diagnostics'
    try:
        if sdk and overlays is None:
            overlays = [str(p) for p in sorted((root / sdk['dir'] / 'overlays').glob('*.yaml'))]
        doc = normalize_spec(spec, list(overlays or []))
        if isinstance(doc.get("x-moonbit-discovery"), dict):
            discovery = dict(doc["x-moonbit-discovery"])
        if sdk:
            from tools.gen.selection import apply as select
            if sdk['include_all']:
                include_all_operations(doc)
            select(doc, sdk.get('selection'))
            operations = sum(op.get('x-moonbit-include') is True for item in doc.get('paths', {}).values() for method, op in item.items() if method in ('get', 'put', 'post', 'delete', 'options', 'head', 'patch', 'trace') and isinstance(op, dict))
        elif ops is None:
            operations = include_all_operations(doc)
        else:
            operations, missing = include_operations(doc, ops)
            if missing:
                raise ValueError(f"unknown operationId(s): {', '.join(sorted(missing))}")
        if selection is not None:
            from tools.gen.selection import apply as select
            operations = len(select(doc, selection))
        auth_headers = set()
        if sdk and sdk.get('client_layer') and sdk['out'] != sdk['dir'] + '/src':
            from tools.gen.client_layer import auth_choices, auth_header_names
            auth_headers = auth_header_names(auth_choices(sdk['auth']))
        has_client = bool(client_layer or sdk and sdk.get('client_layer'))
        builder = IRBuilder(doc, sdk['package'] if sdk else "census/generated", derive_operation_ids=sdk['derive_operation_ids'] if sdk else True, auth_headers=auth_headers,
                            auto_multipart_boundary=has_client and not (sdk or {}).get('legacy_multipart_boundary', False))
        ir = builder.build()
        emit(ir)
        if client_layer or sdk and sdk.get('client_layer'):
            from tools.gen.client_layer import error_ir, pagination_notes
            error_types, _ = error_ir(doc, ir)
            emit(error_types)
            builder.notes.extend(pagination_notes(doc, ir))
        if compile:
            diagnostics = compile_ir(doc, ir, sdk=sdk, root=root)
            compilation = 'failed' if diagnostics else 'passed'
    except GenerationError as error:
        diagnostics = error.diagnostics or [Diagnostic('/generated', 'generation or formatting failed before compilation', 'inspect generator/moonfmt output at the generated location')]
    kinds = Counter(diagnostic_kind(item) for item in diagnostics)
    return CensusResult(
        name=name,
        spec=str(spec),
        operations=operations,
        diagnostics=len(diagnostics),
        kinds=dict(kinds.most_common()),
        notes=[asdict(note) for note in builder.notes] if builder else [],
        discovery=discovery,
        details=[asdict(d) for d in diagnostics],
        compilation=compilation,
    )


def check_scratch(directory, doc=None):
    diagnostics = []
    update = subprocess.run(['moon', '-C', str(directory), 'update'], text=True, capture_output=True)
    if update.returncode:
        return [Diagnostic('/', 'scratch dependency resolution failed: ' + (update.stderr + update.stdout)[-4000:], 'check the sample module dependency pins')]
    result = subprocess.run(['moon', '-C', str(directory), 'check', '--target', 'wasm-gc', '--deny-warn', '--output-json'], text=True, capture_output=True)
    if result.returncode:
        for line in (result.stdout + '\n' + result.stderr).splitlines():
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if not isinstance(item, dict) or item.get('level') not in ('error', 'warning'):
                continue
            location = item.get('loc', item.get('location', {}))
            filename = item.get('path') or (location.get('path') or location.get('file', '') if isinstance(location, dict) else '')
            message = item.get('message', str(item))
            pointer = str(filename or '/generated')
            if str(directory) in pointer:
                pointer = pointer.replace(str(directory), '')
            if isinstance(location, dict):
                pointer += ':' + str(location.get('start', location))
            elif location:
                pointer += ':' + str(location)
            diagnostics.append(Diagnostic(pointer, 'compilation: ' + str(message), source_hint(doc, message, filename, location)))
        if not diagnostics:
            diagnostics.append(Diagnostic('/generated', 'compilation failed: ' + (result.stdout + result.stderr)[-8000:], 'inspect the generated location; add an overlay only if the schema itself needs correction'))
    return diagnostics


def source_hint(doc, message, filename=None, location=None):
    if doc:
        from tools.gen.ir import type_name
        if filename and isinstance(location, str):
            try:
                line = int(location.split(':', 1)[0])
                preceding = '\n'.join(Path(filename).read_text().splitlines()[:line])
                declarations = re.findall(r'(?:struct|enum|impl [^\n]*? for) (\w+)|pub fn (\w+)', preceding)
                if declarations:
                    message = str(message) + ' ' + ' '.join(declarations[-1])
            except (OSError, ValueError):
                pass
        for name in doc.get('components', {}).get('schemas', {}):
            if re.search(r'\b' + re.escape(type_name(name)) + r'\b', str(message)):
                return 'spec pointer /components/schemas/' + name.replace('~', '~0').replace('/', '~1')
    return 'generated code has no reliable source pointer; inspect the generated location'


def compile_ir(doc, ir, *, sdk=None, root=None):
    from tools.gen.main import _format, _write
    with tempfile.TemporaryDirectory(prefix='census-compile-') as temporary:
        directory = Path(temporary)
        if sdk:
            manifest = (root / sdk['dir'] / 'moon.mod').read_text()
        else:
            from tools import sdks
            repository = root or sdks.ROOT
            entries = sdks.load()
            entry = next(s for s in entries if s['generator'] in ('openapi', 'discovery'))
            manifest = (repository / entry['dir'] / 'moon.mod').read_text()
            dependency = re.search(r'"gaato/mttp_core@([^"\n]+)"', manifest)[1]
            manifest = f'name = "census/generated"\nversion = "0.1.0"\nsource = "src"\nimport {{ "gaato/mttp_core@{dependency}" }}\n'
        (directory / 'moon.mod').write_text(manifest)
        flat = sdk and sdk['out'] == sdk['dir'] + '/src'
        files = emit(ir)
        if sdk and sdk.get('client_layer'):
            from tools.gen.client_layer import emit_client
            facade = emit_client(doc, ir, sdk, files if flat else None)
            if flat:
                files.update(facade)
            else:
                _write(directory / 'src', _format(facade))
        _write(directory / ('src' if flat or not sdk else 'src/gen'), _format(files))
        return check_scratch(directory, doc)


def ledger_census(sdk, root, *, compile=True):
    if sdk['generator'] != 'custom':
        return census(root / sdk['spec_file'], sdk['name'], compile=compile, sdk=sdk, root=root)
    with tempfile.TemporaryDirectory(prefix='census-custom-') as temporary:
        directory = Path(temporary)
        (directory / 'moon.mod').write_text((root / sdk['dir'] / 'moon.mod').read_text())
        result = subprocess.run([sys.executable, str(root / sdk['command']), '--spec', str(root / sdk['spec_file']), '--out', str(directory / 'src/gen')], text=True, capture_output=True, cwd=root)
        diagnostics = ([Diagnostic('/generated', 'custom generation failed: ' + (result.stdout + result.stderr)[-8000:], 'inspect custom generator')] if result.returncode else check_scratch(directory) if compile else [])
        return CensusResult(sdk['name'], sdk['spec_file'], 0, len(diagnostics), dict(Counter(diagnostic_kind(d) for d in diagnostics)), [], details=[asdict(d) for d in diagnostics], compilation='failed' if diagnostics else 'passed' if compile else 'not-requested')


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("spec")
    result.add_argument("name")
    result.add_argument("--json", action="store_true", dest="as_json")
    result.add_argument("--expect-zero", action="store_true")
    result.add_argument("--derive-operation-ids", action="store_true")
    result.add_argument("--client-layer", action="store_true", help="also lower typed HTTP error bodies")
    result.add_argument('--compile', action='store_true', help='after a clean census, generate a scratch module and compile with denied warnings')
    result.add_argument('--sdk', help='use the actual ledger selection, overlays, facade and dependency pins')
    result.add_argument("--ops", help="comma-separated operationIds to include")
    result.add_argument("--overlay", action="append", default=[], help="overlay to apply first (repeatable)")
    return result


def run(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    ops = None
    if args.ops is not None:
        ops = {value.strip() for value in args.ops.split(",") if value.strip()}
        if not ops:
            parser().error("--ops requires at least one operationId")
    try:
        if args.sdk:
            from tools import sdks
            sdk = next((s for s in sdks.load() if s['name'] == args.sdk), None)
            if sdk is None:
                raise ValueError('unknown SDK: ' + args.sdk)
            result = ledger_census(sdk, sdks.ROOT, compile=args.compile)
        else:
            result = census(args.spec, args.name, ops=ops, overlays=args.overlay, client_layer=args.client_layer, compile=args.compile)
    except ValueError as error:
        parser().error(str(error))
    if args.as_json:
        import json

        print(json.dumps(result.to_dict(), ensure_ascii=False, sort_keys=True))
    else:
        print(f"== {result.name}: operations={result.operations} diagnostics={result.diagnostics} notes={len(result.notes)}")
        if result.discovery is not None:
            print(
                "  discovery: "
                f"schemas={result.discovery.get('schemas')} "
                f"methods={result.discovery.get('methods')} "
                f"resources={result.discovery.get('resources')} "
                f"revision={result.discovery.get('revision')}"
            )
        if result.diagnostics:
            print("  diagnostics:")
        for kind, count in list(result.kinds.items())[:12]:
            print(f"  {count:5d}  {kind}")
        for item in result.details:
            print(f"  {item['pointer']}: {item['reason']}; {item['overlay_hint']}")
        print(f'  compilation: {result.compilation}')
        if result.notes:
            print("  notes (non-failing):")
        for note in result.notes:
            print(f"  note: {note['pointer']}: {note['message']}")
    return 1 if args.expect_zero and result.diagnostics else 0


if __name__ == "__main__":
    raise SystemExit(run())
