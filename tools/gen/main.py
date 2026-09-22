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
    return result


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
                if generated:
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
        if not generated:
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
            if generated:
                path.unlink()
    for name, content in files.items():
        (out / name).write_text(content, encoding="utf-8")


def run(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    builder = None
    try:
        doc = normalize_spec(args.spec, args.overlay)
        if args.include_all:
            include_all_operations(doc)
        builder = IRBuilder(doc, args.package, derive_operation_ids=args.derive_operation_ids)
        ir = builder.build()
    except GenerationError as error:
        for diagnostic in error.diagnostics:
            print(diagnostic.format(), file=sys.stderr)
        if args.verbose and builder is not None:
            for note in sorted(builder.notes, key=lambda item: (item.pointer, item.message)):
                print(f"note: {note.pointer}: {note.message}", file=sys.stderr)
        return 2
    if args.verbose:
        for note in sorted(builder.notes, key=lambda item: (item.pointer, item.message)):
            print(f"note: {note.pointer}: {note.message}", file=sys.stderr)
    try:
        files = _format(emit(ir))
    except GenerationError:
        print("moonfmt failed; install the MoonBit toolchain before generating", file=sys.stderr)
        return 2
    out = Path(args.out)
    conflicts = _protected_conflicts(out, files)
    if conflicts:
        for path in conflicts:
            print(f"refusing to overwrite non-generated file: {path}", file=sys.stderr)
        return 2
    if args.ir_out:
        Path(args.ir_out).write_text(json.dumps(ir.to_dict(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    differences = _differences(out, files)
    if args.check:
        for path in differences:
            print(f"generated file differs: {path}", file=sys.stderr)
        return 1 if differences else 0
    _write(out, files)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
