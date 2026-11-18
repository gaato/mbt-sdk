# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonpath-rfc9535>=0.1", "pyyaml>=6"]
# ///
"""Generate the selected MoonBit OpenAPI slice."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.gen.diagnostics import GenerationError
from tools.gen.emit_moonbit import HEADER, emit
from tools.gen.ir import IRBuilder, include_all_operations
from tools.gen.normalize import normalize_spec

ROOT = Path(__file__).resolve().parents[2]


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--spec", required=True)
    result.add_argument("--overlay", action="append", default=[])
    result.add_argument("--out", required=True)
    result.add_argument("--package", required=True)
    result.add_argument("--check", action="store_true")
    result.add_argument("--ir-out")
    result.add_argument("--derive-operation-ids", action="store_true")
    result.add_argument("--include-all", action="store_true")
    result.add_argument("--verbose", action="store_true")
    result.add_argument("--client-sdk", help="Opt-in ledger entry for root-package client generation")
    result.add_argument('--sdk', help='Ledger entry supplying operation selection (also for vocabulary-only SDKs)')
    return result


def _owned_name(out: Path, name: str) -> bool:
    if (out.name == 'gen' and out.parent.name == 'src') or (out.name == 'src' and name.endswith('_gen.mbt')):
        return True
    if name not in {'types.mbt', 'operations.mbt'} or not out.resolve().is_relative_to(ROOT):
        return False
    # Flat vocabulary outputs predate the facade suffix convention. The ledger
    # identifies their owners without granting other root files that exception.
    from tools import sdks
    return any(sdk['generator'] in ('openapi', 'discovery') and sdk['out'] == sdk['dir'] + '/src'
               and (ROOT / sdk['out']).resolve() == out.resolve() for sdk in sdks.load())


def _differences(out: Path, files: dict[str, str]) -> list[str]:
    differences: list[str] = []
    for name, content in files.items():
        path = out / name
        if not path.exists() or path.read_text(encoding="utf-8") != content:
            differences.append(str(path))
    if out.exists():
        for path in sorted(out.iterdir()):
            if path.is_file() and path.name not in files:
                try:
                    generated = path.read_text(encoding="utf-8").startswith(HEADER.rstrip("\n"))
                except UnicodeDecodeError:
                    generated = False
                if generated and _owned_name(out, path.name):
                    differences.append(str(path))
    return differences


def _protected_conflicts(out: Path, files: dict[str, str]) -> list[str]:
    conflicts: list[str] = []
    for name, content in files.items():
        path = out / name
        if not path.exists() or path.read_text(encoding="utf-8") == content:
            continue
        try:
            generated = path.read_text(encoding="utf-8").startswith(HEADER.rstrip("\n"))
        except UnicodeDecodeError:
            generated = False
        if not generated or not (_owned_name(out, name) or name == 'moon.pkg'):
            conflicts.append(str(path))
    return conflicts


def _format(files: dict[str, str]) -> dict[str, str]:
    formatted = dict(files)
    for name, content in files.items():
        if not name.endswith(".mbt"):
            continue
        try:
            process = subprocess.run(
                ["moonfmt", "-", "-file-type", "mbt"],
                input=content,
                text=True,
                capture_output=True,
                check=False,
            )
        except FileNotFoundError as error:
            raise GenerationError([]) from error
        if process.returncode != 0:
            print(process.stderr, file=sys.stderr, end="")
            raise GenerationError([])
        formatted[name] = process.stdout
    return formatted


def _write(out: Path, files: dict[str, str]) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for path in sorted(out.iterdir()):
        if path.is_file() and path.name not in files:
            try:
                generated = path.read_text(encoding="utf-8").startswith(HEADER.rstrip("\n"))
            except UnicodeDecodeError:
                generated = False
            if generated and _owned_name(out, path.name):
                path.unlink()
    for name, content in files.items():
        path = out / name
        if not path.exists() or path.read_text(encoding="utf-8") != content:
            path.write_text(content, encoding="utf-8")


def run(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    builder = None
    sdk = None
    try:
        doc = normalize_spec(args.spec, args.overlay)
        if args.include_all:
            include_all_operations(doc)
        if args.sdk or args.client_sdk:
            from tools import sdks
            from tools.gen.selection import apply as select
            sdk = next(s for s in sdks.load() if s['name'] == (args.sdk or args.client_sdk))
            select(doc, sdk.get('selection'))
        auth_headers = set()
        if args.client_sdk:
            from tools import sdks
            from tools.gen.client_layer import auth_choices, auth_header_names
            sdk = next(s for s in sdks.load() if s['name'] == args.client_sdk)
            if not sdk.get('client_layer'):
                raise ValueError('client layer is not enabled in the ledger')
            if sdk['out'] != sdk['dir'] + '/src':
                auth_headers = auth_header_names(auth_choices(sdk['auth']))
        builder = IRBuilder(doc, args.package, derive_operation_ids=args.derive_operation_ids, auth_headers=auth_headers,
                            auto_multipart_boundary=bool(args.client_sdk and not sdk.get('legacy_multipart_boundary')))
        ir = builder.build()
    except GenerationError as error:
        for diagnostic in error.diagnostics:
            print(diagnostic.format(), file=sys.stderr)
        if args.verbose and builder is not None:
            for note in sorted(builder.notes, key=lambda item: (item.pointer, item.message)):
                print(f"note: {note.pointer}: {note.message}", file=sys.stderr)
        return 2
    except (ValueError, StopIteration) as error:
        print(f'client ledger: {error}', file=sys.stderr)
        return 2
    if args.verbose:
        for note in sorted(builder.notes, key=lambda item: (item.pointer, item.message)):
            print(f"note: {note.pointer}: {note.message}", file=sys.stderr)
    out = Path(args.out)
    outputs = {out: emit(ir)}
    if args.client_sdk:
        from tools.gen.client_layer import emit_client, pagination_notes
        try:
            root = Path(sdk['dir']) / 'src'
            legacy = outputs[out] if root == out else None
            facade = emit_client(doc, ir, sdk, legacy)
            for note in pagination_notes(doc, ir):
                print(f'note: {note.pointer}: {note.message}', file=sys.stderr)
            if root == out:
                outputs[out].update(facade)
            else:
                outputs[root] = facade
        except (ValueError, GenerationError) as error:
            print(f'client layer: {error}', file=sys.stderr)
            return 2
    try:
        outputs = {path: _format(files) for path, files in outputs.items()}
    except GenerationError:
        print("moonfmt failed; install the MoonBit toolchain before generating", file=sys.stderr)
        return 2
    conflicts = [name for path, files in outputs.items() for name in _protected_conflicts(path, files)]
    if conflicts:
        for path in conflicts:
            print(f"refusing to overwrite non-generated file: {path}", file=sys.stderr)
        return 2
    if args.ir_out:
        Path(args.ir_out).write_text(json.dumps(ir.to_dict(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    differences = [name for path, files in outputs.items() for name in _differences(path, files)]
    if args.check:
        for path in differences:
            print(f"generated file differs: {path}", file=sys.stderr)
        return 1 if differences else 0
    for path, files in outputs.items():
        _write(path, files)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
