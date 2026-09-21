"""Overlay application, local-reference validation, closure collection, and allOf merging."""

from __future__ import annotations

import copy
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from tools import apply_overlay

from .diagnostics import Diagnostic, GenerationError


@dataclass(frozen=True)
class ClosureStats:
    schemas: int
    one_of_without_discriminator: int


def _pointer_join(pointer: str, part: str | int) -> str:
    return pointer + "/" + str(part).replace("~", "~0").replace("/", "~1")


def resolve_local(doc: dict[str, Any], ref: str) -> Any:
    if not ref.startswith("#/"):
        raise KeyError(ref)
    node: Any = doc
    for raw in ref[2:].split("/"):
        node = node[raw.replace("~1", "/").replace("~0", "~")]
    return node


def _merge_objects(parts: list[dict[str, Any]], base: dict[str, Any], pointer: str, doc: dict[str, Any], diagnostics: list[Diagnostic]) -> dict[str, Any]:
    result = {key: copy.deepcopy(value) for key, value in base.items() if key != "allOf"}
    properties = copy.deepcopy(result.get("properties", {}))
    required = list(result.get("required", []))
    for index, raw in enumerate(parts):
        part_pointer = _pointer_join(_pointer_join(pointer, "allOf"), index)
        try:
            part = resolve_local(doc, raw["$ref"]) if "$ref" in raw else raw
        except (KeyError, TypeError):
            diagnostics.append(Diagnostic(part_pointer, f"unresolved local $ref {raw.get('$ref')}", "fix the reference in overlays/fix.yaml"))
            continue
        part = merge_all_of(part, part_pointer, doc, diagnostics)
        if not isinstance(part, dict) or not (part.get("type") == "object" or "properties" in part):
            diagnostics.append(Diagnostic(part_pointer, "allOf member is not an object schema", "replace or remove the allOf member in overlays/fix.yaml"))
            continue
        for name, value in part.get("properties", {}).items():
            if name in properties and properties[name] != value:
                diagnostics.append(Diagnostic(_pointer_join(_pointer_join(part_pointer, "properties"), name), "allOf defines the same property differently", "resolve the property conflict in overlays/fix.yaml"))
            else:
                properties[name] = copy.deepcopy(value)
        for name in part.get("required", []):
            if name not in required:
                required.append(name)
        for key, value in part.items():
            if key in {"type", "properties", "required", "description", "title"}:
                continue
            if key not in result:
                result[key] = copy.deepcopy(value)
    result["type"] = "object"
    if properties:
        result["properties"] = properties
    if required:
        result["required"] = required
    return result


def merge_all_of(schema: Any, pointer: str, doc: dict[str, Any], diagnostics: list[Diagnostic]) -> Any:
    if isinstance(schema, list):
        return [merge_all_of(value, _pointer_join(pointer, index), doc, diagnostics) for index, value in enumerate(schema)]
    if not isinstance(schema, dict):
        return schema
    if "allOf" in schema:
        schema = _merge_objects(schema["allOf"], schema, pointer, doc, diagnostics)
    result: dict[str, Any] = {}
    for key, value in schema.items():
        if key == "$ref":
            result[key] = value
        else:
            result[key] = merge_all_of(value, _pointer_join(pointer, key), doc, diagnostics)
    return result


def normalize_spec(spec_path: str | Path, overlay_paths: list[str | Path]) -> dict[str, Any]:
    doc = apply_overlay.load(str(spec_path))
    overlay_problems: list[str] = []
    for path in overlay_paths:
        overlay_problems.extend(apply_overlay.apply(doc, apply_overlay.load(str(path)), str(path)))
    if overlay_problems:
        raise GenerationError([Diagnostic("/", problem, "fix the overlay action target or update") for problem in overlay_problems])
    # allOf is merged lazily while lowering the selected schema closure.  The
    # vendored document contains unrelated unsupported constructs, which must
    # not make a deliberately narrow generator slice fail.
    return doc


def closure_stats(doc: dict[str, Any], operation_id: str) -> ClosureStats:
    operation = None
    for path_item in doc.get("paths", {}).values():
        for candidate in path_item.values():
            if isinstance(candidate, dict) and candidate.get("operationId") == operation_id:
                operation = candidate
                break
    if operation is None:
        raise KeyError(operation_id)
    roots: list[dict[str, Any]] = []
    request = operation.get("requestBody", {}).get("content", {})
    roots.extend(media["schema"] for media in request.values() if isinstance(media, dict) and isinstance(media.get("schema"), dict))
    for response in operation.get("responses", {}).values():
        roots.extend(media["schema"] for media in response.get("content", {}).values() if isinstance(media, dict) and isinstance(media.get("schema"), dict))
    names: set[str] = set()
    visited_nodes: set[int] = set()
    one_of = 0

    def walk(node: Any) -> None:
        nonlocal one_of
        if isinstance(node, list):
            for item in node:
                walk(item)
            return
        if not isinstance(node, dict):
            return
        ref = node.get("$ref")
        if isinstance(ref, str) and ref.startswith("#/components/schemas/"):
            name = ref.rsplit("/", 1)[-1]
            if name not in names:
                names.add(name)
                walk(resolve_local(doc, ref))
            return
        identity = id(node)
        if identity in visited_nodes:
            return
        visited_nodes.add(identity)
        if "oneOf" in node and "discriminator" not in node:
            one_of += 1
        for value in node.values():
            walk(value)

    walk(roots)
    return ClosureStats(len(names), one_of)
