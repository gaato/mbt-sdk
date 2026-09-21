"""Structured diagnostics for unsupported OpenAPI constructs."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, order=True)
class Diagnostic:
    pointer: str
    reason: str
    overlay_hint: str

    def format(self) -> str:
        return f"{self.pointer}: {self.reason}; overlay: {self.overlay_hint}"


class GenerationError(Exception):
    """Raised after all diagnostics in the selected closure have been collected."""

    def __init__(self, diagnostics: list[Diagnostic]):
        self.diagnostics = sorted(set(diagnostics))
        super().__init__("\n".join(item.format() for item in self.diagnostics))
