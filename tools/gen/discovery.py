"""Convert Google Discovery REST descriptions to the generator's OpenAPI subset.

The adapter deliberately stops at an in-memory OpenAPI document.  Normalization,
IR lowering, and emission therefore have one implementation for both inputs.
"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import re
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.gen.ir import snake_case
from tools.gen.diagnostics import Diagnostic, GenerationError


DISCOVERY_KIND = "discovery#restDescription"
VOLATILE_TOP_LEVEL = frozenset({"revision", "etag", "generatedDate", "updated"})
_TEMPLATE = re.compile(r"\{(\+)?([^}]+)\}")
_AUTH_GLOBAL_PARAMETERS = frozenset({"key", "access_token", "oauth_token"})


def is_discovery(doc: Any) -> bool:
    """Return whether a decoded JSON value is a Google Discovery document."""
    return isinstance(doc, dict) and (
        doc.get("kind") == DISCOVERY_KIND or isinstance(doc.get("discoveryVersion"), str)
    )


def _extensions(value: dict[str, Any]) -> dict[str, Any]:
    return {
        key: copy.deepcopy(item)
        for key, item in value.items()
        if key.startswith("x-moonbit-")
    }


def _enum_description(schema: dict[str, Any], description: str) -> str:
    values = schema.get("enum")
    docs = schema.get("enumDescriptions")
    if not (
        isinstance(values, list)
        and isinstance(docs, list)
        and len(values) == len(docs)
        and all(isinstance(item, str) for item in docs)
    ):
        return description
    lines = [f"{value}: {doc}" for value, doc in zip(values, docs, strict=True)]
    suffix = "Enum values: " + "; ".join(lines)
    return (description.rstrip() + "\n\n" + suffix).strip()


def convert_schema(raw: Any) -> dict[str, Any]:
    """Convert one Discovery schema, retaining Google-only semantics as extensions."""
    if not isinstance(raw, dict):
        raise ValueError("Discovery schema must be an object")
    ref = raw.get("$ref")
    if ref is not None:
        if not isinstance(ref, str) or not ref:
            raise ValueError("Discovery $ref must be a non-empty schema id")
        target = {"$ref": "#/components/schemas/" + ref.replace("~", "~0").replace("/", "~1")}
        siblings = {
            key: copy.deepcopy(value)
            for key, value in raw.items()
            if key not in {"$ref", "description", "annotations"}
            and key.startswith("x-moonbit-")
        }
        description = raw.get("description")
        annotations = raw.get("annotations")
        metadata = {}
        if isinstance(annotations, dict) and "required" in annotations:
            metadata["x-moonbit-required"] = copy.deepcopy(annotations["required"])
        # Method-scoped required annotations do not change the referenced type.
        # Keep the reference edge intact so recursive components are not expanded.
        if not siblings and (description is None or metadata):
            return {**target, **metadata, **({"description": description} if isinstance(description, str) else {})}
        result: dict[str, Any] = {"allOf": [target], **siblings}
        if isinstance(description, str):
            result["description"] = description
        result.update(metadata)
        return result

    result = _extensions(raw)
    description = raw.get("description", "")
    if isinstance(description, str) and (description or "enumDescriptions" in raw):
        result["description"] = _enum_description(raw, description)
    kind = raw.get("type")
    if kind == "any":
        result["x-moonbit-json"] = True
    elif isinstance(kind, str):
        result["type"] = kind
    if kind == "string" and raw.get("format") in {"int64", "uint64"}:
        # Discovery carries these integers as JSON strings.  The extension is
        # intentionally required so an ordinary OpenAPI string/int64 remains a String.
        result["x-moonbit-int-string"] = raw["format"]
    for key in (
        "format", "default", "pattern", "minimum", "maximum", "minLength",
        "maxLength", "minItems", "maxItems", "minProperties", "maxProperties",
        "readOnly", "deprecated", "nullable", "title", "example",
    ):
        if key in raw:
            result[key] = copy.deepcopy(raw[key])
    if isinstance(raw.get("enum"), list):
        result["enum"] = copy.deepcopy(raw["enum"])
    if isinstance(raw.get("enumDescriptions"), list):
        result["x-moonbit-enum-descriptions"] = copy.deepcopy(raw["enumDescriptions"])
    if isinstance(raw.get("enumDeprecated"), list):
        result["x-google-enum-deprecated"] = copy.deepcopy(raw["enumDeprecated"])
    if "items" in raw:
        result["items"] = convert_schema(raw["items"])
    properties = raw.get("properties")
    if isinstance(properties, dict):
        result["properties"] = {
            name: convert_schema(value) for name, value in properties.items()
        }
    additional = raw.get("additionalProperties")
    if isinstance(additional, dict):
        result["additionalProperties"] = convert_schema(additional)
    elif isinstance(additional, bool):
        result["additionalProperties"] = additional
    required = raw.get("required")
    if isinstance(required, list):
        result["required"] = copy.deepcopy(required)
    annotations = raw.get("annotations")
    if isinstance(annotations, dict) and "required" in annotations:
        # Discovery's value is normally a list of method ids, so it cannot be
        # represented by OpenAPI's schema-wide required array.
        result["x-moonbit-required"] = copy.deepcopy(annotations["required"])
    return result


def operation_id(method_id: str) -> str:
    """Drop the service prefix and snake-case the remaining resource/method path.

    ``generativelanguage.models.generateContent`` therefore becomes
    ``models_generate_content``.  Discovery ids include the full nested resource
    path, so this stays stable when HTTP paths or parameter spellings change.
    """
    parts = method_id.split(".")
    return snake_case("_".join(parts[1:] if len(parts) > 1 else parts))


def _parameter_schema(raw: dict[str, Any]) -> dict[str, Any]:
    schema = convert_schema({
        key: value
        for key, value in raw.items()
        if key not in {"location", "required", "repeated", "description"}
    })
    if raw.get("repeated") is True:
        schema = {"type": "array", "items": schema}
    return schema


def _path_mapping(
    raw: dict[str, Any],
    original: list[str],
    selected: list[str],
) -> dict[str, list[str]]:
    if not raw.get("flatPath"):
        return {name: [name] for name in selected}
    if len(original) == len(selected):
        return {
            source: [target]
            for source, target in zip(original, selected, strict=True)
        }

    # A canonical resource-name parameter may expand to several flat ids.  Keep
    # parameters whose names survive the flattening paired with themselves, then
    # assign every remaining flat id only when there is one unambiguous source.
    mapping = {name: [name] for name in original if name in selected}
    remaining_sources = [name for name in original if name not in mapping]
    remaining_targets = [name for name in selected if name not in mapping]
    if len(remaining_sources) != 1:
        raise ValueError(
            "Discovery flatPath cannot be mapped unambiguously to path parameters"
        )
    mapping[remaining_sources[0]] = remaining_targets
    return mapping


def _convert_method(raw: dict[str, Any]) -> tuple[str, str, dict[str, Any]]:
    method_id = raw.get("id")
    if not isinstance(method_id, str) or not method_id:
        raise ValueError("Discovery method has no id")
    selected_path = raw.get("flatPath") or raw.get("path")
    if not isinstance(selected_path, str) or not selected_path:
        raise ValueError(f"Discovery method {method_id} has no path")
    original_path_names = [
        match.group(2)
        for match in _TEMPLATE.finditer(str(raw.get("path", selected_path)))
    ]
    selected_path_names = [match.group(2) for match in _TEMPLATE.finditer(selected_path)]
    mapping = _path_mapping(raw, original_path_names, selected_path_names)
    reserved = {
        match.group(2) for match in _TEMPLATE.finditer(selected_path) if match.group(1)
    }
    path = _TEMPLATE.sub(lambda match: "{" + match.group(2) + "}", selected_path)
    if not path.startswith("/"):
        path = "/" + path

    parameters = raw.get("parameters", {})
    if not isinstance(parameters, dict):
        raise ValueError(f"Discovery method {method_id} parameters must be an object")
    order = raw.get("parameterOrder", [])
    ordered = [name for name in order if name in parameters] if isinstance(order, list) else []
    ordered.extend(name for name in parameters if name not in ordered)
    converted_parameters: list[dict[str, Any]] = []

    def convert_parameter(name: str, converted_name: str) -> dict[str, Any]:
        parameter = parameters[name]
        if not isinstance(parameter, dict):
            raise ValueError(f"Discovery method {method_id} parameter {name} must be an object")
        location = parameter.get("location", "query")
        schema = _parameter_schema(parameter)
        if len(mapping.get(name, [])) > 1:
            # A regex for the full canonical name does not constrain one
            # flattened id and would reject valid individual arguments.
            schema.pop("pattern", None)
        item: dict[str, Any] = {
            "name": converted_name,
            "in": location,
            "required": location == "path" or parameter.get("required") is True,
            "schema": schema,
        }
        if isinstance(parameter.get("description"), str):
            item["description"] = parameter["description"]
        if parameter.get("repeated") is True and location == "query":
            item.update(style="form", explode=True)
        if converted_name in reserved:
            item["x-moonbit-path-segments"] = True
        return item

    # Path arguments are always ordered by the selected template. Discovery's
    # parameters member is a JSON object and therefore is not an ordering source.
    source_for_target = {
        target: source
        for source, targets in mapping.items()
        for target in targets
    }
    for target in selected_path_names:
        source = source_for_target.get(target)
        parameter = parameters.get(source) if source is not None else None
        if not isinstance(parameter, dict) or parameter.get("location") != "path":
            raise ValueError(
                f"Discovery method {method_id} path parameter {target} has no definition"
            )
        converted_parameters.append(convert_parameter(source, target))

    # parameterOrder remains authoritative for non-path arguments. Parameters
    # omitted from it retain document order, which has no positional meaning.
    for name in ordered:
        parameter = parameters[name]
        if isinstance(parameter, dict) and parameter.get("location", "query") == "path":
            continue
        converted_parameters.append(convert_parameter(name, name))
    emitted_path_names = [
        item["name"] for item in converted_parameters if item["in"] == "path"
    ]
    if set(emitted_path_names) != set(selected_path_names):
        raise ValueError(
            f"Discovery method {method_id} flat path parameters do not match its template"
        )

    operation: dict[str, Any] = {
        "operationId": operation_id(method_id),
        "x-google-method-id": method_id,
        "parameters": converted_parameters,
        "responses": {},
        **_extensions(raw),
    }
    if isinstance(raw.get("description"), str):
        operation["description"] = raw["description"]
    request = raw.get("request")
    if isinstance(request, dict):
        operation["requestBody"] = {
            "required": True,
            "content": {"application/json": {"schema": convert_schema(request)}},
        }
    response = raw.get("response")
    if isinstance(response, dict):
        operation["responses"]["200"] = {
            "description": "Successful response",
            "content": {"application/json": {"schema": convert_schema(response)}},
        }
    else:
        operation["responses"]["204"] = {"description": "Successful response"}
    if raw.get("supportsMediaUpload") is True:
        operation["x-moonbit-media-upload"] = copy.deepcopy(raw.get("mediaUpload", {}))
    if raw.get("supportsMediaDownload") is True:
        operation["x-moonbit-media-download"] = True
    http_method = str(raw.get("httpMethod", "GET")).lower()
    return path, http_method, operation


def _resource_count(resources: Any) -> int:
    if not isinstance(resources, dict):
        return 0
    return sum(
        1 + _resource_count(resource.get("resources"))
        for resource in resources.values()
        if isinstance(resource, dict)
    )


def _walk_methods(resources: Any):
    if not isinstance(resources, dict):
        return
    for resource in resources.values():
        if not isinstance(resource, dict):
            continue
        methods = resource.get("methods", {})
        if isinstance(methods, dict):
            for method in methods.values():
                if isinstance(method, dict):
                    yield method
        yield from _walk_methods(resource.get("resources"))


def convert_discovery(doc: dict[str, Any]) -> dict[str, Any]:
    """Convert a complete Discovery document to OpenAPI 3.0.3."""
    if not is_discovery(doc):
        raise ValueError("not a Google Discovery REST description")
    schemas = doc.get("schemas", {})
    if not isinstance(schemas, dict):
        raise ValueError("Discovery schemas must be an object")
    methods = []
    top_methods = doc.get("methods", {})
    if isinstance(top_methods, dict):
        methods.extend(item for item in top_methods.values() if isinstance(item, dict))
    methods.extend(_walk_methods(doc.get("resources", {})))
    globals_ = doc.get("parameters", {})
    if not isinstance(globals_, dict):
        raise ValueError("Discovery top-level parameters must be an object")
    global_diagnostics: list[Diagnostic] = []
    optional_global_parameters: list[str] = []
    for name, parameter in globals_.items():
        pointer = "/parameters/" + str(name).replace("~", "~0").replace("/", "~1")
        if not isinstance(name, str) or not isinstance(parameter, dict):
            raise ValueError(f"Discovery top-level parameter {name!r} must be an object")
        if parameter.get("required") is True:
            if name not in _AUTH_GLOBAL_PARAMETERS:
                global_diagnostics.append(Diagnostic(
                    pointer,
                    "required Discovery top-level parameter cannot be omitted from operation signatures",
                    "move the requirement to each affected method or provide a handwritten facade",
                ))
        else:
            optional_global_parameters.append(name)
    if global_diagnostics:
        raise GenerationError(global_diagnostics)
    optional_global_parameters.sort()
    has_key = "key" in globals_
    auth = doc.get("auth", {})
    oauth = auth.get("oauth2") if isinstance(auth, dict) else None
    if oauth is not None and not isinstance(oauth, dict):
        raise ValueError("Discovery auth.oauth2 must be an object")
    declared_scopes: dict[str, str] = {}
    if oauth is not None:
        raw_scopes = oauth.get("scopes", {})
        if not isinstance(raw_scopes, dict):
            raise ValueError("Discovery auth.oauth2.scopes must be an object")
        for scope, metadata in raw_scopes.items():
            if not isinstance(scope, str) or not isinstance(metadata, dict):
                raise ValueError("Discovery OAuth scopes must map strings to objects")
            description = metadata.get("description", "")
            declared_scopes[scope] = description if isinstance(description, str) else ""

    paths: dict[str, dict[str, Any]] = {}
    operation_ids: set[str] = set()
    for method in methods:
        path, verb, operation = _convert_method(method)
        if oauth is not None:
            method_scopes = method.get("scopes", [])
            if not (
                isinstance(method_scopes, list)
                and all(isinstance(scope, str) for scope in method_scopes)
            ):
                raise ValueError(f"Discovery method {method['id']} scopes must be strings")
            security = []
            if has_key:
                security.extend([
                    {"googleApiKeyHeader": []},
                    {"googleApiKeyQuery": []},
                ])
            security.append({"googleOAuth2": copy.deepcopy(method_scopes)})
            operation["security"] = security
            if method_scopes:
                scope_docs = " ".join(
                    f"OAuth scope `{scope}`: "
                    f"{declared_scopes.get(scope) or 'No description in Discovery.'}"
                    for scope in method_scopes
                )
                operation["description"] = " ".join(
                    part for part in (operation.get("description", ""), scope_docs) if part
                )
        identifier = operation["operationId"]
        if identifier in operation_ids:
            # Dropping the service prefix should normally remain unique.  Keep
            # a deterministic full-id fallback for unusual Discovery documents.
            identifier = snake_case(str(method["id"]))
            operation["operationId"] = identifier
        if identifier in operation_ids:
            raise ValueError(f"duplicate Discovery method id after normalization: {method['id']}")
        operation_ids.add(identifier)
        if verb in paths.setdefault(path, {}):
            raise ValueError(f"duplicate Discovery route: {verb.upper()} {path}")
        paths[path][verb] = operation

    root = str(doc.get("rootUrl", ""))
    service = str(doc.get("servicePath", ""))
    server = (root.rstrip("/") + "/" + service.strip("/")).rstrip("/")
    if not server:
        raise ValueError("Discovery rootUrl/servicePath do not form a server URL")
    title = doc.get("title") or doc.get("name") or "Google Discovery API"
    version = doc.get("version") or "unknown"
    result: dict[str, Any] = {
        "openapi": "3.0.3",
        "info": {"title": str(title), "version": str(version)},
        "servers": [{"url": server}],
        "paths": paths,
        "components": {
            "schemas": {name: convert_schema(schema) for name, schema in schemas.items()},
            "securitySchemes": {},
        },
        "x-moonbit-discovery": {
            "revision": doc.get("revision"),
            "schemas": len(schemas),
            "methods": len(methods),
            "resources": _resource_count(doc.get("resources", {})),
            "optionalGlobalParameters": optional_global_parameters,
        },
    }
    if has_key:
        schemes = result["components"]["securitySchemes"]
        # Header is first because it keeps credentials out of URLs and is the
        # documented Gemini recommendation; query `key` remains an alternative.
        schemes["googleApiKeyHeader"] = {
            "type": "apiKey", "in": "header", "name": "x-goog-api-key",
        }
        schemes["googleApiKeyQuery"] = {
            "type": "apiKey", "in": "query", "name": "key",
        }
        if oauth is None:
            result["security"] = [
                {"googleApiKeyHeader": []},
                {"googleApiKeyQuery": []},
            ]
    if oauth is not None:
        result["components"]["securitySchemes"]["googleOAuth2"] = {
            "type": "oauth2",
            "description": (
                "The caller supplies an already obtained Google OAuth 2.0 bearer "
                "access token; this SDK does not implement an OAuth flow."
            ),
            "flows": {
                "authorizationCode": {
                    "authorizationUrl": "https://accounts.google.com/o/oauth2/v2/auth",
                    "tokenUrl": "https://oauth2.googleapis.com/token",
                    "scopes": copy.deepcopy(declared_scopes),
                },
            },
        }
    return result


def comparable_document(doc: Any, *, generator: str) -> Any:
    """Return the watch-comparison value, ignoring only Discovery churn fields."""
    value = copy.deepcopy(doc)
    if generator == "discovery" and is_discovery(value):
        for key in VOLATILE_TOP_LEVEL:
            value.pop(key, None)
    return value


def watch_equal(old: Any, new: Any, *, generator: str) -> bool:
    return comparable_document(old, generator=generator) == comparable_document(
        new, generator=generator
    )


def _load(path: str) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def run(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    revision = sub.add_parser("revision")
    revision.add_argument("spec")
    compare = sub.add_parser("watch-equal")
    compare.add_argument("old")
    compare.add_argument("new")
    args = parser.parse_args(argv)
    if args.command == "revision":
        doc = _load(args.spec)
        if not is_discovery(doc):
            parser.error("revision requires a Discovery document")
        print(doc.get("revision", ""))
        return 0
    old, new = _load(args.old), _load(args.new)
    return 0 if watch_equal(old, new, generator="discovery") else 1


if __name__ == "__main__":
    raise SystemExit(run())
