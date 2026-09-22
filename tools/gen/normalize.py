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


def _merge_objects(
    parts: list[dict[str, Any]],
    base: dict[str, Any],
    pointer: str,
    doc: dict[str, Any],
    diagnostics: list[Diagnostic],
    notes: list[tuple[str, str]] | None = None,
) -> dict[str, Any]:
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
        part = merge_all_of(part, part_pointer, doc, diagnostics, notes)
        if not isinstance(part, dict) or not (part.get("type") == "object" or "properties" in part):
            diagnostics.append(Diagnostic(part_pointer, "allOf member is not an object schema", "replace or remove the allOf member in overlays/fix.yaml"))
            continue
        for name, value in part.get("properties", {}).items():
            if name in properties and properties[name] != value:
                if notes is not None:
                    notes.append(
                        (
                            _pointer_join(_pointer_join(part_pointer, "properties"), name),
                            "allOf property conflict resolved with the later definition",
                        )
                    )
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


def merge_all_of(
    schema: Any,
    pointer: str,
    doc: dict[str, Any],
    diagnostics: list[Diagnostic],
    notes: list[tuple[str, str]] | None = None,
) -> Any:
    if isinstance(schema, list):
        return [
            merge_all_of(value, _pointer_join(pointer, index), doc, diagnostics, notes)
            for index, value in enumerate(schema)
        ]
    if not isinstance(schema, dict):
        return schema
    if "allOf" in schema:
        schema = _merge_objects(schema["allOf"], schema, pointer, doc, diagnostics, notes)
    result: dict[str, Any] = {}
    for key, value in schema.items():
        if key == "$ref":
            result[key] = value
        else:
            result[key] = merge_all_of(
                value,
                _pointer_join(pointer, key),
                doc,
                diagnostics,
                notes,
            )
    return result


def normalize_spec(spec_path: str | Path, overlay_paths: list[str | Path]) -> dict[str, Any]:
    doc = apply_overlay.load(str(spec_path))
    overlay_problems: list[str] = []
    for path in overlay_paths:
        overlay_problems.extend(apply_overlay.apply(doc, apply_overlay.load(str(path)), str(path)))
    if overlay_problems:
        raise GenerationError([Diagnostic("/", problem, "fix the overlay action target or update") for problem in overlay_problems])
    _resolve_parameter_refs(doc)
    # allOf is merged lazily while lowering the selected schema closure.  The
    # vendored document contains unrelated unsupported constructs, which must
    # not make a deliberately narrow generator slice fail.
    return doc


def _resolve_parameter_refs(doc: dict[str, Any]) -> None:
    """Resolve local parameter references at path and operation level in place."""
    diagnostics: list[Diagnostic] = []
    methods = {"get", "put", "post", "delete", "options", "head", "patch", "trace"}

    def resolve_parameter(parameter: Any, item_pointer: str, seen: set[str]) -> Any:
        if not isinstance(parameter, dict) or "$ref" not in parameter:
            return parameter
        ref = parameter.get("$ref")
        if not isinstance(ref, str) or not ref.startswith("#/components/parameters/"):
            diagnostics.append(Diagnostic(item_pointer, f"unsupported parameter $ref {ref}", "use a local components.parameters reference"))
            return parameter
        if ref in seen:
            diagnostics.append(Diagnostic(item_pointer, f"recursive parameter $ref {ref}", "break the parameter reference cycle"))
            return parameter
        try:
            target = resolve_local(doc, ref)
        except (KeyError, TypeError):
            diagnostics.append(Diagnostic(item_pointer, f"unresolved local parameter $ref {ref}", "fix the reference in overlays/fix.yaml"))
            return parameter
        if not isinstance(target, dict):
            diagnostics.append(Diagnostic(item_pointer, f"parameter $ref {ref} does not resolve to an object", "fix the referenced parameter"))
            return parameter
        resolved = resolve_parameter(copy.deepcopy(target), item_pointer, seen | {ref})
        if not isinstance(resolved, dict):
            return resolved
        # OpenAPI 3.1 permits summary/description siblings on Reference
        # Objects.  Keeping arbitrary siblings would silently change the
        # parameter contract, so only those documentation fields overlay.
        for key in ("summary", "description"):
            if key in parameter:
                resolved[key] = copy.deepcopy(parameter[key])
        return resolved

    def resolve_list(parameters: Any, pointer: str) -> list[Any]:
        if not isinstance(parameters, list):
            return parameters
        result: list[Any] = []
        for index, parameter in enumerate(parameters):
            item_pointer = _pointer_join(pointer, index)
            result.append(resolve_parameter(parameter, item_pointer, set()))
        return result

    for path, path_item in doc.get("paths", {}).items():
        if not isinstance(path_item, dict):
            continue
        path_pointer = _pointer_join("/paths", path)
        if "parameters" in path_item:
            path_item["parameters"] = resolve_list(path_item["parameters"], _pointer_join(path_pointer, "parameters"))
        for method, operation in path_item.items():
            if method not in methods or not isinstance(operation, dict) or "parameters" not in operation:
                continue
            operation["parameters"] = resolve_list(
                operation["parameters"],
                _pointer_join(_pointer_join(path_pointer, method), "parameters"),
            )
    if diagnostics:
        raise GenerationError(diagnostics)


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
