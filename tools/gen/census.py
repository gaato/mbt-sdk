"""Measure generator diagnostics after including every operation in a spec."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
import re
import sys

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

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


def diagnostic_kind(diagnostic: Diagnostic) -> str:
    """Collapse data-dependent lists so the same reason shares one bucket."""
    return re.sub(r"\[[^\]]*\]", "[...]", diagnostic.reason)


def census(spec: str | Path, name: str, *, ops: set[str] | None = None) -> CensusResult:
    """Run the selected-operations generator census without writing files."""
    doc = normalize_spec(spec, [])
    if ops is None:
        operations = include_all_operations(doc)
    else:
        operations, missing = include_operations(doc, ops)
        if missing:
            raise ValueError(f"unknown operationId(s): {', '.join(sorted(missing))}")
    diagnostics: list[Diagnostic] = []
    try:
        ir = IRBuilder(doc, "census/generated", derive_operation_ids=True).build()
        emit(ir)
    except GenerationError as error:
        diagnostics = error.diagnostics
    kinds = Counter(diagnostic_kind(item) for item in diagnostics)
    return CensusResult(
        name=name,
        spec=str(spec),
        operations=operations,
        diagnostics=len(diagnostics),
        kinds=dict(kinds.most_common()),
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("spec")
    result.add_argument("name")
    result.add_argument("--json", action="store_true", dest="as_json")
    result.add_argument("--expect-zero", action="store_true")
    result.add_argument("--derive-operation-ids", action="store_true")
    result.add_argument("--ops", help="comma-separated operationIds to include")
    return result


def run(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    ops = None
    if args.ops is not None:
        ops = {value.strip() for value in args.ops.split(",") if value.strip()}
        if not ops:
            parser().error("--ops requires at least one operationId")
    try:
        result = census(args.spec, args.name, ops=ops)
    except ValueError as error:
        parser().error(str(error))
    if args.as_json:
        import json

        print(json.dumps(result.to_dict(), ensure_ascii=False, sort_keys=True))
    else:
        print(f"== {result.name}: operations={result.operations} diagnostics={result.diagnostics}")
        for kind, count in list(result.kinds.items())[:12]:
            print(f"  {count:5d}  {kind}")
    return 1 if args.expect_zero and result.diagnostics else 0


if __name__ == "__main__":
    raise SystemExit(run())
