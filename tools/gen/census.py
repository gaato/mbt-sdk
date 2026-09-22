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
from tools.gen.ir import IRBuilder, include_all_operations
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


def census(spec: str | Path, name: str) -> CensusResult:
    """Run the all-operations generator census without writing output files."""
    doc = normalize_spec(spec, [])
    operations = include_all_operations(doc)
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
    return result


def run(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    result = census(args.spec, args.name)
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
