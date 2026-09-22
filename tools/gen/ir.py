"""Dataclasses and OpenAPI-to-IR lowering for the MoonBit generator."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
import re
from typing import Any, Iterable

from .diagnostics import Diagnostic, GenerationError


class Presence(str, Enum):
    REQUIRED = "required"
    NULLABLE_REQUIRED = "nullable-required"
    OPTIONAL = "optional"
    PRESENCE = "presence"


@dataclass(frozen=True)
class TypeRef:
    kind: str
    name: str | None = None
    item: "TypeRef | None" = None

    def moon_type(self) -> str:
        if self.kind == "array":
            assert self.item is not None
            return f"Array[{self.item.moon_type()}]"
        if self.kind == "map":
            assert self.item is not None
            return f"Map[String, {self.item.moon_type()}]"
        return self.name or self.kind


@dataclass(frozen=True)
class Field:
    json_name: str
    moon_name: str
    type: TypeRef
    presence: Presence
    description: str = ""
    constant: Any | None = None


@dataclass(frozen=True)
class Struct:
    name: str
    fields: tuple[Field, ...]
    description: str = ""


@dataclass(frozen=True)
class EnumVariant:
    name: str
    value: str


@dataclass(frozen=True)
class StringEnum:
    name: str
    variants: tuple[EnumVariant, ...]
    open: bool
    description: str = ""


@dataclass(frozen=True)
class UnionVariant:
    name: str
    type: TypeRef
    shape: str


@dataclass(frozen=True)
class UntaggedUnion:
    name: str
    variants: tuple[UnionVariant, ...]
    description: str = ""


@dataclass(frozen=True)
class Newtype:
    name: str
    inner: TypeRef
    description: str = ""


Declaration = Struct | StringEnum | UntaggedUnion | Newtype


@dataclass(frozen=True)
class Parameter:
    json_name: str
    moon_name: str
    type: TypeRef
    location: str
    required: bool
    description: str = ""


@dataclass(frozen=True)
class Operation:
    operation_id: str
    moon_name: str
    method: str
    path: str
    parameters: tuple[Parameter, ...]
    request_type: TypeRef | None
    response_type: TypeRef | None
    description: str = ""


@dataclass(frozen=True)
class Note:
    pointer: str
    message: str


@dataclass(frozen=True)
class IR:
    package: str
    declarations: tuple[Declaration, ...]
    operations: tuple[Operation, ...]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


RESERVED = {
    "as",
    "async",
    "break",
    "catch",
    "const",
    "continue",
    "derive",
    "else",
    "enum",
    "fn",
    "for",
    "if",
    "impl",
    "in",
    "let",
    "loop",
    "match",
    "mut",
    "priv",
    "pub",
    "raise",
    "return",
    "struct",
    "suberror",
    "test",
    "trait",
    "try",
    "type",
    "using",
    "while",
    "with",
}


def snake_case(value: str) -> str:
    value = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", value)
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", value)
    value = re.sub(r"[^A-Za-z0-9]+", "_", value).strip("_").lower() or "value"
    return value + "_" if value in RESERVED else value


def pascal_case(value: str) -> str:
    words = re.findall(r"[A-Za-z0-9]+", re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", value))
    result = "".join(word[:1].upper() + word[1:] for word in words) or "Value"
    if result[0].isdigit():
        result = "Value" + result
    return result


def pointer_join(pointer: str, part: str | int) -> str:
    escaped = str(part).replace("~", "~0").replace("/", "~1")
    return pointer + "/" + escaped


def _nullable(schema: dict[str, Any]) -> bool:
    if schema.get("nullable") is True:
        return True
    return isinstance(schema.get("type"), list) and "null" in schema["type"]


def _without_nullable(schema: dict[str, Any]) -> dict[str, Any]:
    result = dict(schema)
    result.pop("nullable", None)
    if isinstance(result.get("type"), list):
        types = [item for item in result["type"] if item != "null"]
        result["type"] = types[0] if len(types) == 1 else types
    return result


def _primitive_shape(schema: dict[str, Any], resolve: callable) -> str | None:
    if "$ref" in schema:
        return _primitive_shape(resolve(schema["$ref"]), resolve)
    if "allOf" in schema:
        return "object"
    union = schema.get("oneOf") or schema.get("anyOf")
    if union:
        shapes = {_primitive_shape(item, resolve) for item in union}
        return shapes.pop() if len(shapes) == 1 else None
    kind = schema.get("type")
    if kind == "string":
        return "string"
    if kind in ("integer", "number"):
        return "number"
    if kind == "boolean":
        return "boolean"
    if kind == "object" or "properties" in schema:
        return "object"
    if kind == "array":
        item = _primitive_shape(schema.get("items", {}), resolve)
        return f"array:{item}" if item else None
    return None


def _shape_variant_name(schema: dict[str, Any], resolve: callable) -> str:
    if "$ref" in schema:
        return pascal_case(schema["$ref"].rsplit("/", 1)[-1])
    kind = schema.get("type")
    if kind == "string":
        return "Text"
    if kind == "integer":
        return "Int"
    if kind == "number":
        return "Number"
    if kind == "boolean":
        return "Bool"
    if kind == "object" or "properties" in schema:
        return "Object"
    if kind == "array":
        return _shape_variant_name(schema.get("items", {}), resolve) + "Array"
    return "Value"


class IRBuilder:
    def __init__(self, doc: dict[str, Any], package: str, *, derive_operation_ids: bool = False):
        self.doc = doc
        self.package = package
        self.derive_operation_ids = derive_operation_ids
        self.diagnostics: list[Diagnostic] = []
        self.notes: list[Note] = []
        self.declarations: list[Declaration] = []
        self.declaration_names: set[str] = set()
        self.component_usage: dict[str, set[str]] = {}
        self.component_pointers: dict[str, str] = {}
        self._building: set[str] = set()

    def resolve(self, ref: str) -> dict[str, Any]:
        if not ref.startswith("#/"):
            raise KeyError(ref)
        node: Any = self.doc
        for raw in ref[2:].split("/"):
            part = raw.replace("~1", "/").replace("~0", "~")
            node = node[part]
        if not isinstance(node, dict):
            raise TypeError(ref)
        return node

    def add_diag(self, pointer: str, reason: str, hint: str) -> None:
        self.diagnostics.append(Diagnostic(pointer, reason, hint))

    def add_note(self, pointer: str, message: str) -> None:
        note = Note(pointer, message)
        if note not in self.notes:
            self.notes.append(note)

    def _walk_refs(self, schema: Any, usage: str, seen: set[tuple[str, str]]) -> None:
        if isinstance(schema, list):
            for item in schema:
                self._walk_refs(item, usage, seen)
            return
        if not isinstance(schema, dict):
            return
        ref = schema.get("$ref")
        if ref:
            if not ref.startswith("#/components/schemas/"):
                self.add_diag("#", f"unsupported non-schema or external $ref {ref}", "replace it with a local components.schemas reference")
                return
            name = ref.rsplit("/", 1)[-1].replace("~1", "/").replace("~0", "~")
            self.component_usage.setdefault(name, set()).add(usage)
            self.component_pointers[name] = ref[1:]
            key = (name, usage)
            if key in seen:
                return
            seen.add(key)
            try:
                target = self.resolve(ref)
            except (KeyError, TypeError):
                self.add_diag(ref[1:], f"unresolved local $ref {ref}", "fix the $ref target in overlays/fix.yaml")
                return
            self._walk_refs(target, usage, seen)
            return
        for key in ("allOf", "oneOf", "anyOf"):
            self._walk_refs(schema.get(key, []), usage, seen)
        self._walk_refs(schema.get("items"), usage, seen)
        self._walk_refs(schema.get("additionalProperties") if isinstance(schema.get("additionalProperties"), dict) else None, usage, seen)
        for value in schema.get("properties", {}).values():
            self._walk_refs(value, usage, seen)

    def _operation_schemas(self, operation: dict[str, Any]) -> Iterable[tuple[dict[str, Any], str]]:
        body = operation.get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema")
        if isinstance(body, dict):
            yield body, "request"
        for response in operation.get("responses", {}).values():
            for media in response.get("content", {}).values():
                schema = media.get("schema")
                if isinstance(schema, dict):
                    yield schema, "response"

    @staticmethod
    def _parameters(path_item: dict[str, Any], operation: dict[str, Any]) -> list[dict[str, Any]]:
        """Return path parameters followed by operation overrides."""
        result: list[dict[str, Any]] = []
        positions: dict[tuple[Any, Any], int] = {}
        for parameter in [*path_item.get("parameters", []), *operation.get("parameters", [])]:
            if not isinstance(parameter, dict):
                continue
            key = (parameter.get("name"), parameter.get("in"))
            if key in positions:
                result[positions[key]] = parameter
            else:
                positions[key] = len(result)
                result.append(parameter)
        return result

    def discover(self) -> list[tuple[str, str, dict[str, Any], list[dict[str, Any]]]]:
        selected: list[tuple[str, str, dict[str, Any], list[dict[str, Any]]]] = []
        seen: set[tuple[str, str]] = set()
        for path, path_item in self.doc.get("paths", {}).items():
            for method, operation in path_item.items():
                if not isinstance(operation, dict) or operation.get("x-moonbit-include") is not True:
                    continue
                parameters = self._parameters(path_item, operation)
                selected.append((path, method, operation, parameters))
                for schema, usage in self._operation_schemas(operation):
                    self._walk_refs(schema, usage, seen)
                for parameter in parameters:
                    schema = parameter.get("schema")
                    if isinstance(schema, dict):
                        self._walk_refs(schema, "request", seen)
        return selected

    def _add_declaration(self, declaration: Declaration, pointer: str) -> None:
        if declaration.name in self.declaration_names:
            return
        self.declaration_names.add(declaration.name)
        self.declarations.append(declaration)

    def _enum_type(self, schema: dict[str, Any], name: str, usage: set[str], pointer: str) -> TypeRef:
        values = schema.get("enum", [])
        if not all(isinstance(value, str) for value in values):
            self.add_diag(pointer, "only string enums are supported", "add x-moonbit-json: true or correct the schema in overlays/fix.yaml")
            return TypeRef("Json")
        annotations = schema.get("x-moonbit-variants")
        variants: list[EnumVariant] = []
        used: set[str] = set()
        for index, value in enumerate(values):
            variant = annotations[index] if isinstance(annotations, list) and index < len(annotations) else pascal_case(value)
            variant = pascal_case(str(variant))
            if variant in used:
                self.add_diag(pointer_join(pointer, "enum"), f"enum variant name collision for {value!r}", "set x-moonbit-variants to unique names")
            used.add(variant)
            variants.append(EnumVariant(variant, value))
        self._add_declaration(StringEnum(name, tuple(variants), "response" in usage, schema.get("description", "")), pointer)
        return TypeRef("named", name=name)

    def _union_type(self, schema: dict[str, Any], name: str, usage: set[str], pointer: str) -> TypeRef:
        if "discriminator" in schema:
            self.add_diag(pointer_join(pointer, "discriminator"), "discriminator unions are not supported in M4a", "add x-moonbit-json: true only if raw JSON is intentional, or remove the operation from x-moonbit-include")
            return TypeRef("Json")
        key = "oneOf" if "oneOf" in schema else "anyOf"
        choices = schema[key]
        if key == "anyOf" and len(choices) == 2:
            resolved = [self.resolve(item["$ref"]) if "$ref" in item else item for item in choices]
            if all(item.get("type") == "string" for item in resolved) and any("enum" in item for item in resolved):
                return TypeRef("String")
        shapes = [_primitive_shape(choice, self.resolve) for choice in choices]
        if None in shapes or len(set(shapes)) != len(shapes):
            self.add_diag(pointer_join(pointer, key), f"untagged union candidates are not distinguishable by JSON shape: {shapes}", "set x-moonbit-json: true only if raw JSON is intentional, or narrow the included operation")
            return TypeRef("Json")
        annotations = schema.get("x-moonbit-variants")
        variants: list[UnionVariant] = []
        names: set[str] = set()
        for index, (choice, shape) in enumerate(zip(choices, shapes, strict=True)):
            suggested = annotations[index] if isinstance(annotations, list) and index < len(annotations) else _shape_variant_name(choice, self.resolve)
            variant_name = pascal_case(str(suggested))
            if variant_name in names:
                self.add_diag(pointer, f"union variant name collision: {variant_name}", "set x-moonbit-variants to unique names")
            names.add(variant_name)
            item_type = self.compile_type(choice, name + variant_name, usage, pointer_join(pointer_join(pointer, key), index))
            variants.append(UnionVariant(variant_name, item_type, shape or ""))
        self._add_declaration(UntaggedUnion(name, tuple(variants), schema.get("description", "")), pointer)
        return TypeRef("named", name=name)

    def _struct_type(self, schema: dict[str, Any], name: str, usage: set[str], pointer: str) -> TypeRef:
        additional = schema.get("additionalProperties")
        if additional is True or (schema.get("type") == "object" and not schema.get("properties") and additional is None):
            location = pointer_join(pointer, "additionalProperties") if additional is True else pointer
            self.add_note(location, "schema-less object mapped to Json")
            return TypeRef("Json")
        if isinstance(additional, dict):
            if schema.get("properties"):
                self.add_diag(
                    pointer_join(pointer, "additionalProperties"),
                    "properties and typed additionalProperties cannot coexist",
                    "split the fixed properties and map into separate schemas in overlays/fix.yaml",
                )
                return TypeRef("Json")
            item = self.compile_type(
                additional,
                name + "Value",
                usage,
                pointer_join(pointer, "additionalProperties"),
            )
            return TypeRef("map", item=item)
        required = set(schema.get("required", []))
        fields: list[Field] = []
        properties = schema.get("properties", {})
        for json_name, field_schema in properties.items():
            field_pointer = pointer_join(pointer_join(pointer, "properties"), json_name)
            nullable = _nullable(field_schema)
            values = field_schema.get("enum")
            if isinstance(values, list) and len(values) == 1:
                fields.append(Field(json_name, snake_case(json_name), TypeRef("constant"), Presence.REQUIRED if json_name in required else Presence.OPTIONAL, field_schema.get("description", ""), values[0]))
                continue
            if json_name in required:
                presence = Presence.NULLABLE_REQUIRED if nullable else Presence.REQUIRED
            else:
                presence = Presence.PRESENCE if nullable else Presence.OPTIONAL
            field_type = self.compile_type(_without_nullable(field_schema), name + pascal_case(json_name), usage, field_pointer)
            fields.append(Field(json_name, snake_case(json_name), field_type, presence, field_schema.get("description", "")))
        self._add_declaration(Struct(name, tuple(fields), schema.get("description", "")), pointer)
        return TypeRef("named", name=name)

    def compile_component(self, name: str) -> TypeRef:
        pointer = f"/components/schemas/{name.replace('~', '~0').replace('/', '~1')}"
        if name in self.declaration_names:
            return TypeRef("named", name=name)
        if name in self._building:
            self.add_diag(pointer, "recursive schemas are not supported in M4a", "remove the operation from x-moonbit-include or break the recursion with an explicit x-moonbit-json annotation")
            return TypeRef("Json")
        self._building.add(name)
        schema = self.doc["components"]["schemas"][name]
        result = self.compile_type(schema, pascal_case(name), self.component_usage.get(name, set()), pointer, named_component=True)
        self._building.remove(name)
        return result

    def compile_type(self, schema: dict[str, Any], name: str, usage: set[str], pointer: str, named_component: bool = False) -> TypeRef:
        if schema.get("x-moonbit-json") is True:
            return TypeRef("Json")
        if "$ref" in schema:
            ref = schema["$ref"]
            if not ref.startswith("#/components/schemas/"):
                self.add_diag(pointer_join(pointer, "$ref"), f"unsupported $ref {ref}", "use a local components.schemas reference")
                return TypeRef("Json")
            component = ref.rsplit("/", 1)[-1].replace("~1", "/").replace("~0", "~")
            return self.compile_component(component)
        if "allOf" in schema:
            from .normalize import merge_all_of

            merge_diagnostics: list[Diagnostic] = []
            schema = merge_all_of(schema, pointer, self.doc, merge_diagnostics)
            self.diagnostics.extend(merge_diagnostics)
        if "oneOf" in schema or "anyOf" in schema:
            return self._union_type(schema, name, usage, pointer)
        enum = schema.get("enum")
        if schema.get("type") == "string" and isinstance(enum, list) and len(enum) > 1:
            return self._enum_type(schema, name, usage, pointer)
        kind = schema.get("type")
        override = schema.get("x-moonbit-type")
        if named_component and kind in ("string", "integer", "number", "boolean") and override:
            inner_schema = dict(schema)
            inner_schema.pop("x-moonbit-type", None)
            inner = self.compile_type(inner_schema, name + "Value", usage, pointer)
            newtype_name = pascal_case(str(override)) if override not in ("Int64",) else pascal_case(name)
            self._add_declaration(Newtype(newtype_name, inner, schema.get("description", "")), pointer)
            return TypeRef("named", name=newtype_name)
        if kind == "string":
            return TypeRef(str(override) if override else "String")
        if kind == "integer":
            return TypeRef("Int64" if schema.get("format") == "int64" or override == "Int64" else "Int")
        if kind == "number":
            return TypeRef("Double")
        if kind == "boolean":
            return TypeRef("Bool")
        if kind == "array":
            items = schema.get("items")
            if not isinstance(items, dict):
                self.add_diag(pointer_join(pointer, "items"), "array has no item schema", "add items in overlays/fix.yaml or x-moonbit-json: true")
                return TypeRef("Json")
            return TypeRef("array", item=self.compile_type(items, name + "Item", usage, pointer_join(pointer, "items")))
        if kind == "object" or "properties" in schema or "additionalProperties" in schema:
            return self._struct_type(schema, name, usage, pointer)
        self.add_diag(pointer, f"unsupported schema construct (type={kind!r})", "add an explicit supported type or x-moonbit-json: true with justification")
        return TypeRef("Json")

    def _compile_operation(
        self,
        path: str,
        method: str,
        operation: dict[str, Any],
        raw_parameters: list[dict[str, Any]],
    ) -> Operation | None:
        operation_id = operation.get("operationId")
        pointer = f"/paths/{path.replace('~', '~0').replace('/', '~1')}/{method}"
        if not isinstance(operation_id, str):
            if self.derive_operation_ids:
                operation_id = derive_operation_id(method, path)
            else:
                self.add_diag(pointer, "included operation has no operationId", "add operationId in overlays/fix.yaml or pass --derive-operation-ids")
                return None
        parameters: list[Parameter] = []
        parameter_names: set[str] = set()
        for index, parameter in enumerate(raw_parameters):
            location = parameter.get("in")
            parameter_pointer = pointer_join(pointer_join(pointer, "parameters"), index)
            if location == "cookie":
                self.add_diag(parameter_pointer, "cookie parameters are not supported", "remove the operation from x-moonbit-include or model the Cookie header in handwritten code")
                continue
            if location not in {"path", "query", "header"}:
                self.add_diag(parameter_pointer, f"parameter location {location!r} is not supported", "remove the operation from x-moonbit-include or use path, query, or header")
                continue
            if location == "query":
                style = parameter.get("style", "form")
                explode = parameter.get("explode", True)
                if style != "form" or explode is not True:
                    self.add_diag(parameter_pointer, f"query parameter style={style!r}, explode={explode!r} is not supported", "use style: form with explode: true")
                    continue
            if location == "header":
                style = parameter.get("style", "simple")
                if style != "simple":
                    self.add_diag(parameter_pointer, f"header parameter style {style!r} is not supported", "use the default simple header style")
                    continue
                if str(parameter.get("name", "")).lower() in {"content-length", "host", "authorization"}:
                    self.add_diag(parameter_pointer, f"reserved header parameter {parameter.get('name')!r} conflicts with the runtime", "remove it and configure transport or runtime Auth instead")
                    continue
            schema = parameter.get("schema", {})
            if not isinstance(schema, dict):
                self.add_diag(pointer_join(parameter_pointer, "schema"), "parameter has no schema", "add a supported schema")
                continue
            moon_name = snake_case(str(parameter.get("name", "parameter")))
            if moon_name in parameter_names:
                self.add_diag(parameter_pointer, f"parameter name collision after MoonBit normalization: {moon_name}", "rename one parameter in an overlay")
                continue
            parameter_names.add(moon_name)
            param_type = self.compile_type(schema, pascal_case(operation_id) + pascal_case(parameter.get("name", "parameter")), {"request"}, pointer_join(parameter_pointer, "schema"))
            required = parameter.get("required") is True or location == "path"
            parameters.append(Parameter(parameter["name"], moon_name, param_type, location, required, parameter.get("description", "")))
        request_content = operation.get("requestBody", {}).get("content", {})
        request_schema = request_content.get("application/json", {}).get("schema")
        request_type = None
        if isinstance(request_schema, dict):
            request_pointer = pointer_join(pointer_join(pointer_join(pointer_join(pointer, "requestBody"), "content"), "application/json"), "schema")
            request_type = self.compile_type(request_schema, pascal_case(operation_id) + "Request", {"request"}, request_pointer)
        elif "application/x-www-form-urlencoded" in request_content:
            self.add_diag(pointer_join(pointer_join(pointer, "requestBody"), "content"), "application/x-www-form-urlencoded request bodies are not supported", "use application/json or remove the operation from x-moonbit-include")
        elif "multipart/form-data" in request_content:
            self.add_diag(pointer_join(pointer_join(pointer, "requestBody"), "content"), "multipart/form-data request bodies are not supported", "use handwritten multipart support or remove the operation from x-moonbit-include")
        response_schemas: list[tuple[dict[str, Any], str]] = []
        for status, response in operation.get("responses", {}).items():
            if str(status).startswith("2"):
                schema = response.get("content", {}).get("application/json", {}).get("schema")
                if isinstance(schema, dict):
                    response_pointer = pointer_join(pointer_join(pointer_join(pointer_join(pointer_join(pointer, "responses"), status), "content"), "application/json"), "schema")
                    response_schemas.append((schema, response_pointer))
        if not response_schemas:
            response_type = None
        else:
            response_type = self.compile_type(response_schemas[0][0], pascal_case(operation_id) + "Response", {"response"}, response_schemas[0][1])
            if any(schema != response_schemas[0][0] for schema, _ in response_schemas[1:]):
                self.add_diag(pointer_join(pointer, "responses"), "multiple distinct success response schemas are not supported", "make the success schemas consistent in overlays/fix.yaml")
        return Operation(operation_id, snake_case(operation_id), method.upper(), path, tuple(parameters), request_type, response_type, operation.get("summary", operation.get("description", "")))

    def build(self) -> IR:
        selected = self.discover()
        schemas = self.doc.get("components", {}).get("schemas", {})
        for name in schemas:
            if name in self.component_usage:
                self.compile_component(name)
        operations = [item for path, method, operation, parameters in selected if (item := self._compile_operation(path, method, operation, parameters)) is not None]
        if self.diagnostics:
            raise GenerationError(self.diagnostics)
        return IR(self.package, tuple(self.declarations), tuple(operations))


def derive_operation_id(method: str, path: str) -> str:
    """Derive a stable operation id from an HTTP method and path template."""
    return re.sub(r"[^A-Za-z0-9]+", "_", f"{method}_{path}").strip("_") or "operation"


HTTP_METHODS = {"get", "put", "post", "delete", "options", "head", "patch", "trace"}


def include_all_operations(doc: dict[str, Any]) -> int:
    """Mark every OpenAPI operation for generation and return its count."""
    count = 0
    for path_item in doc.get("paths", {}).values():
        if not isinstance(path_item, dict):
            continue
        for method, operation in path_item.items():
            if method.lower() not in HTTP_METHODS or not isinstance(operation, dict):
                continue
            operation["x-moonbit-include"] = True
            count += 1
    return count
