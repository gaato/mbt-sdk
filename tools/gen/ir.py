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
class TaggedVariant:
    name: str
    tag: str
    type: TypeRef
    secondary_discriminator: str | None = None
    secondary_tag: str | None = None
    required_fields: tuple[str, ...] = ()


@dataclass(frozen=True)
class TaggedUnion:
    name: str
    discriminator: str
    variants: tuple[TaggedVariant, ...]
    description: str = ""


@dataclass(frozen=True)
class Newtype:
    name: str
    inner: TypeRef
    description: str = ""


Declaration = Struct | StringEnum | UntaggedUnion | TaggedUnion | Newtype


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
    "include",
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


def _split_nullable(schema: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    result = dict(schema)
    nullable = result.pop("nullable", None) is True
    result.pop("nullable", None)
    if isinstance(result.get("type"), list):
        types = [item for item in result["type"] if item != "null"]
        nullable = nullable or len(types) != len(result["type"])
        result["type"] = types[0] if len(types) == 1 else types
    if nullable and isinstance(result.get("enum"), list):
        result["enum"] = [item for item in result["enum"] if item is not None]
    for key in ("oneOf", "anyOf"):
        choices = result.get(key)
        if not isinstance(choices, list):
            continue
        non_null = [
            item
            for item in choices
            if not (isinstance(item, dict) and item.get("type") == "null")
        ]
        if len(non_null) == len(choices):
            continue
        nullable = True
        if len(non_null) == 1:
            replacement = dict(non_null[0])
            for sibling, value in result.items():
                if sibling not in {key, "discriminator", "type"} and sibling not in replacement:
                    replacement[sibling] = value
            result = replacement
        else:
            result[key] = non_null
        break
    return result, nullable


def _primitive_shape(schema: dict[str, Any], resolve: callable) -> str | None:
    schema, _ = _split_nullable(schema)
    if "$ref" in schema:
        return _primitive_shape(resolve(schema["$ref"]), resolve)
    if "$recursiveRef" in schema:
        return "object"
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
    if not (set(schema) - {"description", "title", "default", "example", "examples"}):
        return "any"
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


def _is_string_schema(schema: dict[str, Any], resolve: callable) -> bool:
    schema, _ = _split_nullable(schema)
    if "$ref" in schema:
        return _is_string_schema(resolve(schema["$ref"]), resolve)
    union = schema.get("oneOf") or schema.get("anyOf")
    if isinstance(union, list) and union:
        return all(isinstance(item, dict) and _is_string_schema(item, resolve) for item in union)
    return schema.get("type") == "string"


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
        self._building_stack: list[str] = []
        self._component_types: dict[str, TypeRef] = {}
        self._discriminator_fields: dict[str, set[str]] = {}

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

    def _dereference(self, schema: dict[str, Any]) -> dict[str, Any]:
        if "$ref" in schema:
            return self.resolve(schema["$ref"])
        return schema

    def _schema_nullable(self, schema: dict[str, Any], seen: set[str] | None = None) -> bool:
        _, nullable = _split_nullable(schema)
        if nullable:
            return True
        ref = schema.get("$ref")
        if isinstance(ref, str):
            visited = seen or set()
            if ref in visited:
                return False
            try:
                return self._schema_nullable(self.resolve(ref), visited | {ref})
            except (KeyError, TypeError):
                return False
        parts = schema.get("allOf")
        return isinstance(parts, list) and any(
            isinstance(part, dict) and self._schema_nullable(part, seen)
            for part in parts
        )

    def _properties(self, schema: dict[str, Any]) -> dict[str, Any] | None:
        """Collect object properties, using allOf's later-wins rule."""
        try:
            schema = self._dereference(schema)
        except (KeyError, TypeError):
            return None
        properties: dict[str, Any] = dict(schema.get("properties", {}))
        if "allOf" in schema:
            for part in schema["allOf"]:
                if not isinstance(part, dict):
                    return None
                nested = self._properties(part)
                if nested is None:
                    return None
                properties.update(nested)
        if schema.get("type") == "object" or "properties" in schema or "allOf" in schema:
            return properties
        return None

    def _expand_object_choices(
        self,
        schema: dict[str, Any],
        seen_refs: set[str] | None = None,
    ) -> list[dict[str, Any]] | None:
        """Flatten refs/allOf-wrapped nested object unions without guessing tags."""
        schema, _ = _split_nullable(schema)
        ref = schema.get("$ref")
        if isinstance(ref, str):
            visited = seen_refs or set()
            if ref in visited:
                # The recursive edge cannot reveal another finite union branch.
                # Keep it as an object candidate; asking _primitive_shape to
                # resolve it here would recurse through the same $ref forever.
                return [schema]
            try:
                target = self.resolve(ref)
            except (KeyError, TypeError):
                return None
            if "oneOf" in target or "anyOf" in target or "allOf" in target:
                expanded = self._expand_object_choices(target, visited | {ref})
                if expanded is not None and (
                    "oneOf" in target
                    or "anyOf" in target
                    or len(expanded) != 1
                    or expanded[0] != target
                ):
                    return expanded
            return [schema] if _primitive_shape(schema, self.resolve) == "object" else None
        union = schema.get("oneOf") or schema.get("anyOf")
        if isinstance(union, list):
            result: list[dict[str, Any]] = []
            for choice in union:
                if not isinstance(choice, dict):
                    return None
                expanded = self._expand_object_choices(choice, seen_refs)
                if expanded is None:
                    return None
                result.extend(expanded)
            return result
        parts = schema.get("allOf")
        if isinstance(parts, list):
            expanded_parts: list[tuple[int, list[dict[str, Any]]]] = []
            for index, part in enumerate(parts):
                if not isinstance(part, dict):
                    return None
                expanded = self._expand_object_choices(part, seen_refs)
                if expanded is not None and len(expanded) > 1:
                    expanded_parts.append((index, expanded))
            if len(expanded_parts) > 1:
                return None
            if len(expanded_parts) == 1:
                union_index, branches = expanded_parts[0]
                siblings = [part for index, part in enumerate(parts) if index != union_index]
                outer = {key: value for key, value in schema.items() if key != "allOf"}
                return [dict(outer, allOf=[branch, *siblings]) for branch in branches]
        return [schema] if _primitive_shape(schema, self.resolve) == "object" else None

    @staticmethod
    def _single_string_value(schema: Any) -> str | None:
        if not isinstance(schema, dict):
            return None
        schema, _ = _split_nullable(schema)
        if isinstance(schema.get("const"), str):
            return schema["const"]
        values = schema.get("enum")
        if isinstance(values, list) and len(values) == 1 and isinstance(values[0], str):
            return values[0]
        return None

    def _single_value_property(
        self,
        choices: list[dict[str, Any]],
        *,
        exclude: set[str] | None = None,
        require_unique: bool = False,
    ) -> tuple[str, list[str]] | None:
        properties = [self._properties(choice) for choice in choices]
        if any(item is None for item in properties):
            return None
        assert properties and all(item is not None for item in properties)
        first = properties[0]
        candidates = [name for name in first if name not in (exclude or set())]
        if "type" in candidates:
            candidates.remove("type")
            candidates.insert(0, "type")
        for property_name in candidates:
            values = [self._single_string_value(item.get(property_name)) for item in properties]
            if all(value is not None for value in values) and (
                not require_unique or len(set(values)) == len(values)
            ):
                return property_name, [value for value in values if value is not None]
        return None

    def _implicit_tags(self, choices: list[dict[str, Any]]) -> tuple[str, list[str]] | None:
        return self._single_value_property(choices, require_unique=False)

    def _required_fields(
        self,
        schema: dict[str, Any],
        seen_refs: set[str] | None = None,
    ) -> set[str] | None:
        ref = schema.get("$ref")
        if isinstance(ref, str):
            visited = seen_refs or set()
            if ref in visited:
                return set()
            try:
                return self._required_fields(self.resolve(ref), visited | {ref})
            except (KeyError, TypeError):
                return None
        required = {
            value for value in schema.get("required", []) if isinstance(value, str)
        }
        parts = schema.get("allOf")
        if isinstance(parts, list):
            for part in parts:
                if not isinstance(part, dict):
                    return None
                nested = self._required_fields(part, seen_refs)
                if nested is None:
                    return None
                required.update(nested)
        return required

    @staticmethod
    def _choice_name(choice: dict[str, Any], index: int) -> str:
        ref = choice.get("$ref")
        if isinstance(ref, str) and ref.startswith("#/components/schemas/"):
            return ref.rsplit("/", 1)[-1].replace("~1", "/").replace("~0", "~")
        return str(index)

    @staticmethod
    def _required_order(required: list[set[str]]) -> list[int]:
        """Stable topological order for strict-superset-before-subset edges."""
        remaining = list(range(len(required)))
        result: list[int] = []
        while remaining:
            ready = next(
                index
                for index in remaining
                if not any(
                    required[other] > required[index]
                    for other in remaining
                    if other != index
                )
            )
            result.append(ready)
            remaining.remove(ready)
        return result

    def _scan_discriminator_fields(self) -> None:
        """Mark component discriminator fields before declaration order matters."""
        seen: set[int] = set()

        def walk(schema: Any) -> None:
            if isinstance(schema, list):
                for item in schema:
                    walk(item)
                return
            if not isinstance(schema, dict):
                return
            identity = id(schema)
            if identity in seen:
                return
            seen.add(identity)
            choices = schema.get("oneOf") or schema.get("anyOf")
            if isinstance(choices, list) and all(isinstance(item, dict) for item in choices):
                expanded: list[dict[str, Any]] = []
                for choice in choices:
                    nested = self._expand_object_choices(choice)
                    if nested is None:
                        expanded = []
                        break
                    expanded.extend(nested)
                if expanded:
                    choices = expanded
                discriminator = schema.get("discriminator")
                property_name = discriminator.get("propertyName") if isinstance(discriminator, dict) else None
                if not isinstance(property_name, str):
                    implicit = self._implicit_tags(choices)
                    property_name = implicit[0] if implicit is not None else None
                if isinstance(property_name, str):
                    properties = [self._properties(choice) for choice in choices]
                    primary_values = [
                        self._single_string_value(item.get(property_name))
                        if item is not None
                        else None
                        for item in properties
                    ]
                    secondary_fields: set[str] = set()
                    for value in {item for item in primary_values if item is not None}:
                        indexes = [
                            index for index, item in enumerate(primary_values) if item == value
                        ]
                        if len(indexes) < 2:
                            continue
                        group = [choices[index] for index in indexes]
                        secondary = self._single_value_property(
                            group,
                            exclude={property_name},
                            require_unique=True,
                        )
                        if secondary is not None:
                            secondary_fields.add(secondary[0])
                    refs = [item.get("$ref") for item in choices]
                    mapping = discriminator.get("mapping") if isinstance(discriminator, dict) else None
                    if isinstance(mapping, dict):
                        refs.extend(mapping.values())
                    for ref in refs:
                        if isinstance(ref, str) and ref.startswith("#/components/schemas/"):
                            component = ref.rsplit("/", 1)[-1].replace("~1", "/").replace("~0", "~")
                            self._discriminator_fields.setdefault(component, set()).add(property_name)
                            self._discriminator_fields[component].update(secondary_fields)
            ref = schema.get("$ref")
            if isinstance(ref, str) and ref.startswith("#/components/schemas/"):
                try:
                    walk(self.resolve(ref))
                except (KeyError, TypeError):
                    pass
                return
            for value in schema.values():
                walk(value)

        for component in self.component_usage:
            schema = self.doc.get("components", {}).get("schemas", {}).get(component)
            walk(schema)

    def _walk_refs(self, schema: Any, usage: str, seen: set[tuple[str, str]]) -> None:
        if isinstance(schema, list):
            for item in schema:
                self._walk_refs(item, usage, seen)
            return
        if not isinstance(schema, dict):
            return
        if schema.get("x-moonbit-json") is True:
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

    def _tagged_union_type(
        self,
        schema: dict[str, Any],
        name: str,
        usage: set[str],
        pointer: str,
    ) -> TypeRef:
        key = "oneOf" if "oneOf" in schema else "anyOf"
        choices = schema[key]
        discriminator = schema.get("discriminator")
        mapping = discriminator.get("mapping") if isinstance(discriminator, dict) else None
        if not isinstance(mapping, dict):
            expanded: list[dict[str, Any]] = []
            for choice in choices:
                nested = self._expand_object_choices(choice)
                if nested is None:
                    expanded = []
                    break
                expanded.extend(nested)
            if expanded:
                choices = expanded
        entries: list[tuple[str, dict[str, Any], int]] = []
        if isinstance(discriminator, dict):
            property_name = discriminator.get("propertyName")
            if not isinstance(property_name, str) or not property_name:
                self.add_diag(
                    pointer_join(pointer, "discriminator"),
                    "discriminator propertyName must be a non-empty string",
                    "set discriminator.propertyName to the payload tag field",
                )
                return TypeRef("Json")
            if isinstance(mapping, dict):
                for index, (tag, ref) in enumerate(mapping.items()):
                    if not isinstance(tag, str) or not isinstance(ref, str) or not ref.startswith("#/components/schemas/"):
                        self.add_diag(
                            pointer_join(pointer_join(pointer, "discriminator"), "mapping"),
                            "discriminator mapping must contain local component schema references",
                            "map each string tag to #/components/schemas/<name>",
                        )
                        continue
                    entries.append((tag, {"$ref": ref}, index))
            elif mapping is not None:
                self.add_diag(
                    pointer_join(pointer_join(pointer, "discriminator"), "mapping"),
                    "discriminator mapping must be an object",
                    "map each string tag to a local component schema reference",
                )
            else:
                self.add_note(
                    pointer_join(pointer, "discriminator"),
                    "discriminator mapping inferred from component reference names",
                )
                for index, choice in enumerate(choices):
                    ref = choice.get("$ref") if isinstance(choice, dict) else None
                    if not isinstance(ref, str) or not ref.startswith("#/components/schemas/"):
                        self.add_diag(
                            pointer_join(pointer_join(pointer, key), index),
                            "discriminator without mapping requires local component $ref candidates",
                            "add discriminator.mapping or use local component schema references",
                        )
                        continue
                    properties = self._properties(choice)
                    tag = (
                        self._single_string_value(properties.get(property_name))
                        if properties is not None
                        else None
                    )
                    if tag is None:
                        tag = snake_case(ref.rsplit("/", 1)[-1].replace("~1", "/").replace("~0", "~"))
                    entries.append((tag, choice, index))
        else:
            implicit = self._implicit_tags(choices)
            if implicit is None:
                self.add_diag(
                    pointer_join(pointer, key),
                    f"object union has {len(choices)} candidates and no common single-value property",
                    "set x-moonbit-json: true only if raw JSON is intentional",
                )
                return TypeRef("Json")
            property_name, tags = implicit
            entries = [
                (tag, choice, index)
                for index, (tag, choice) in enumerate(zip(tags, choices, strict=True))
            ]

        groups: dict[str, list[int]] = {}
        for position, (tag, _, _) in enumerate(entries):
            groups.setdefault(tag, []).append(position)
        secondary: dict[int, tuple[str, str]] = {}
        required_fields: dict[int, tuple[str, ...]] = {}
        group_order: dict[str, list[int]] = {}
        order_hint = schema.get("x-moonbit-order")
        hint_names: list[str] | None = None
        if order_hint is not None:
            if not isinstance(order_hint, list) or not all(
                isinstance(item, str) for item in order_hint
            ):
                self.add_diag(
                    pointer_join(pointer, "x-moonbit-order"),
                    "x-moonbit-order must be an array of component schema names",
                    "list each colliding component schema once in decode order",
                )
            elif len(set(order_hint)) != len(order_hint):
                self.add_diag(
                    pointer_join(pointer, "x-moonbit-order"),
                    "x-moonbit-order contains duplicate entries",
                    "list each colliding component schema exactly once",
                )
            else:
                hint_names = order_hint
        for tag, positions in groups.items():
            if len(positions) < 2:
                group_order[tag] = positions
                continue
            group_choices = [entries[position][1] for position in positions]
            second = self._single_value_property(
                group_choices,
                exclude={property_name},
                require_unique=True,
            )
            if second is not None:
                second_name, second_values = second
                for position, value in zip(positions, second_values, strict=True):
                    secondary[position] = (second_name, value)
                group_order[tag] = positions
                continue
            required = [self._required_fields(choice) for choice in group_choices]
            if any(item is None for item in required):
                self.add_diag(
                    pointer,
                    f"tagged union discriminator value collision: {tag!r}",
                    "set x-moonbit-order to colliding component schema names",
                )
                group_order[tag] = positions
                continue
            concrete = [item for item in required if item is not None]
            names = [
                self._choice_name(entries[position][1], entries[position][2])
                for position in positions
            ]
            if hint_names is not None:
                missing = [name for name in names if name not in hint_names]
                unknown = [name for name in hint_names if name not in {
                    self._choice_name(choice, original_index)
                    for _, choice, original_index in entries
                }]
                if missing or unknown or len(set(names)) != len(names):
                    self.add_diag(
                        pointer_join(pointer, "x-moonbit-order"),
                        f"x-moonbit-order does not uniquely order tag {tag!r}",
                        "list every colliding local component schema name exactly once",
                    )
                    ordered = list(range(len(positions)))
                else:
                    ordered = sorted(
                        range(len(positions)),
                        key=lambda index: hint_names.index(names[index]),
                    )
            else:
                duplicates = len({frozenset(item) for item in concrete}) != len(concrete)
                if duplicates:
                    self.add_diag(
                        pointer,
                        f"tagged union discriminator value collision: {tag!r} has indistinguishable required sets",
                        "set x-moonbit-order to colliding component schema names, or x-moonbit-json: true as a last resort",
                    )
                ordered = self._required_order(concrete)
                if any(
                    not (left <= right or right <= left)
                    for index, left in enumerate(concrete)
                    for right in concrete[index + 1 :]
                ):
                    self.add_note(
                        pointer,
                        f"tag {tag!r} uses specification order for incomparable required sets",
                    )
            group_order[tag] = [positions[index] for index in ordered]
            for local_index, position in enumerate(positions):
                required_fields[position] = tuple(sorted(concrete[local_index]))

        ordered_positions: list[int] = []
        emitted_tags: set[str] = set()
        for tag, _, _ in entries:
            if tag not in emitted_tags:
                ordered_positions.extend(group_order[tag])
                emitted_tags.add(tag)

        annotations = schema.get("x-moonbit-variants")
        variants: list[TaggedVariant] = []
        names: set[str] = set()
        for position in ordered_positions:
            tag, choice, original_index = entries[position]
            properties = self._properties(choice)
            constant = self._single_string_value(properties.get(property_name)) if properties is not None else None
            if constant != tag:
                self.add_diag(
                    pointer_join(pointer_join(pointer, key), original_index),
                    f"discriminator field {property_name!r} must be const or a single-value string enum equal to {tag!r}",
                    "fix the payload discriminator property or mapping",
                )
            second_name, second_value = secondary.get(position, (None, None))
            if second_value is not None:
                suggested: Any = pascal_case(tag) + pascal_case(second_value)
            elif len(groups[tag]) > 1:
                choice_name = self._choice_name(choice, original_index)
                suggested = choice_name if not choice_name.isdigit() else f"{tag}_{int(choice_name) + 1}"
            else:
                suggested = tag
            if isinstance(annotations, list) and original_index < len(annotations):
                suggested = annotations[original_index]
            elif isinstance(annotations, dict):
                composite = f"{tag}:{second_value}" if second_value is not None else None
                choice_name = self._choice_name(choice, original_index)
                if composite is not None and composite in annotations:
                    suggested = annotations[composite]
                elif choice_name in annotations:
                    suggested = annotations[choice_name]
                elif len(groups[tag]) == 1 and tag in annotations:
                    suggested = annotations[tag]
            variant_name = pascal_case(str(suggested))
            if variant_name == "Unknown" or variant_name in names:
                self.add_diag(pointer, f"tagged union variant name collision: {variant_name}", "set x-moonbit-variants to unique names other than Unknown")
            names.add(variant_name)
            preserved = {property_name}
            if second_name is not None:
                preserved.add(second_name)
            item_type = self.compile_type(
                choice,
                name + variant_name,
                usage,
                pointer_join(pointer_join(pointer, key), original_index),
                preserve_constants=preserved,
            )
            variants.append(
                TaggedVariant(
                    variant_name,
                    tag,
                    item_type,
                    second_name,
                    second_value,
                    required_fields.get(position, ()),
                )
            )
        self._add_declaration(
            TaggedUnion(name, property_name, tuple(variants), schema.get("description", "")),
            pointer,
        )
        return TypeRef("named", name=name)

    def _union_type(self, schema: dict[str, Any], name: str, usage: set[str], pointer: str) -> TypeRef:
        key = "oneOf" if "oneOf" in schema else "anyOf"
        choices = schema[key]
        if "discriminator" in schema:
            return self._tagged_union_type(schema, name, usage, pointer)
        if key == "anyOf" and len(choices) == 2:
            resolved = [self.resolve(item["$ref"]) if "$ref" in item else item for item in choices]
            if all(item.get("type") == "string" for item in resolved) and any("enum" in item for item in resolved):
                return TypeRef("String")
        resolved_choices = [self.resolve(item["$ref"]) if "$ref" in item else item for item in choices]
        if all(_is_string_schema(item, self.resolve) for item in resolved_choices):
            enum_values: list[str] = []
            unconstrained = False
            for item in resolved_choices:
                normalized, _ = _split_nullable(item)
                if "oneOf" in normalized or "anyOf" in normalized:
                    unconstrained = True
                    break
                values = normalized.get("enum")
                if not isinstance(values, list):
                    unconstrained = True
                    break
                enum_values.extend(value for value in values if isinstance(value, str))
            if unconstrained:
                return TypeRef("String")
            combined = dict(schema)
            combined.pop("oneOf", None)
            combined.pop("anyOf", None)
            combined["type"] = "string"
            combined["enum"] = list(dict.fromkeys(enum_values))
            return self._enum_type(combined, name, usage, pointer)
        shapes = [_primitive_shape(choice, self.resolve) for choice in choices]
        object_indexes = [index for index, shape in enumerate(shapes) if shape == "object"]
        if len(object_indexes) == len(choices):
            return self._tagged_union_type(schema, name, usage, pointer)
        if len(object_indexes) > 1:
            object_choices: list[dict[str, Any]] = []
            for index in object_indexes:
                expanded = self._expand_object_choices(choices[index])
                object_choices.extend(expanded if expanded is not None else [choices[index]])
            object_schema: dict[str, Any] = {key: object_choices}
            annotations = schema.get("x-moonbit-variants")
            if isinstance(annotations, list):
                object_schema["x-moonbit-variants"] = [annotations[index] for index in object_indexes if index < len(annotations)]
            object_type = self._tagged_union_type(object_schema, name + "Object", usage, pointer)
            collapsed: list[tuple[dict[str, Any] | None, str | None, TypeRef | None, int]] = []
            emitted_object = False
            for index, (choice, shape) in enumerate(zip(choices, shapes, strict=True)):
                if shape == "object":
                    if not emitted_object:
                        collapsed.append((None, "object", object_type, index))
                        emitted_object = True
                else:
                    collapsed.append((choice, shape, None, index))
            if None not in [shape for _, shape, _, _ in collapsed] and len({shape for _, shape, _, _ in collapsed}) == len(collapsed):
                variants: list[UnionVariant] = []
                names: set[str] = set()
                for choice, shape, ready_type, original_index in collapsed:
                    suggested = "Object" if choice is None else _shape_variant_name(choice, self.resolve)
                    if isinstance(annotations, list) and original_index < len(annotations):
                        suggested = annotations[original_index]
                    variant_name = pascal_case(str(suggested))
                    if variant_name in names:
                        self.add_diag(pointer, f"union variant name collision: {variant_name}", "set x-moonbit-variants to unique names")
                    names.add(variant_name)
                    item_type = ready_type or self.compile_type(choice or {}, name + variant_name, usage, pointer_join(pointer_join(pointer, key), original_index))
                    variants.append(UnionVariant(variant_name, item_type, shape or ""))
                self._add_declaration(UntaggedUnion(name, tuple(variants), schema.get("description", "")), pointer)
                return TypeRef("named", name=name)
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

    def _struct_type(
        self,
        schema: dict[str, Any],
        name: str,
        usage: set[str],
        pointer: str,
        preserve_constants: set[str] | None = None,
    ) -> TypeRef:
        additional = schema.get("additionalProperties")
        if additional is True or (schema.get("type") == "object" and not schema.get("properties") and additional is None):
            location = pointer_join(pointer, "additionalProperties") if additional is True else pointer
            self.add_note(location, "schema-less object mapped to Json")
            return TypeRef("Json")
        if isinstance(additional, dict) and not additional:
            if schema.get("properties"):
                self.add_note(
                    pointer_join(pointer, "additionalProperties"),
                    "untyped additional properties are accepted on decode but not retained",
                )
            else:
                self.add_note(pointer_join(pointer, "additionalProperties"), "schema-less object mapped to Json")
                return TypeRef("Json")
        elif isinstance(additional, dict):
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
            if snake_case(json_name) == "new":
                self.add_diag(
                    field_pointer,
                    "generated struct field name collides with constructor new",
                    "rename the field with an overlay before generating constructors",
                )
            normalized_field, _ = _split_nullable(field_schema)
            nullable = self._schema_nullable(field_schema)
            values = normalized_field.get("enum")
            constant = normalized_field.get("const")
            single_value = constant if constant is not None else values[0] if isinstance(values, list) and len(values) == 1 else None
            if single_value is not None and json_name not in (preserve_constants or set()):
                fields.append(Field(json_name, snake_case(json_name), TypeRef("constant"), Presence.REQUIRED if json_name in required else Presence.OPTIONAL, field_schema.get("description", ""), single_value))
                continue
            if json_name in required:
                presence = Presence.NULLABLE_REQUIRED if nullable else Presence.REQUIRED
            else:
                presence = Presence.PRESENCE if nullable else Presence.OPTIONAL
            field_type = self.compile_type(normalized_field, name + pascal_case(json_name), usage, field_pointer)
            if field_type.moon_type() == name and field_type.kind != "array" and presence == Presence.REQUIRED:
                self.add_diag(
                    field_pointer,
                    "direct recursive struct field must be nullable or optional",
                    "make the field nullable/optional or place the recursive value behind an array",
                )
            fields.append(Field(json_name, snake_case(json_name), field_type, presence, field_schema.get("description", "")))
        self._add_declaration(Struct(name, tuple(fields), schema.get("description", "")), pointer)
        return TypeRef("named", name=name)

    def compile_component(self, name: str) -> TypeRef:
        pointer = f"/components/schemas/{name.replace('~', '~0').replace('/', '~1')}"
        if name in self._component_types:
            return self._component_types[name]
        if name in self._building:
            return TypeRef("named", name=pascal_case(name))
        self._building.add(name)
        self._building_stack.append(name)
        schema = self.doc["components"]["schemas"][name]
        result = self.compile_type(
            schema,
            pascal_case(name),
            self.component_usage.get(name, set()),
            pointer,
            named_component=True,
            preserve_constants=self._discriminator_fields.get(name),
        )
        self._building.remove(name)
        self._building_stack.pop()
        self._component_types[name] = result
        return result

    def compile_type(
        self,
        schema: dict[str, Any],
        name: str,
        usage: set[str],
        pointer: str,
        named_component: bool = False,
        preserve_constants: set[str] | None = None,
    ) -> TypeRef:
        schema, _ = _split_nullable(schema)
        if schema.get("x-moonbit-json") is True:
            return TypeRef("Json")
        if "$ref" in schema:
            ref = schema["$ref"]
            if not ref.startswith("#/components/schemas/"):
                self.add_diag(pointer_join(pointer, "$ref"), f"unsupported $ref {ref}", "use a local components.schemas reference")
                return TypeRef("Json")
            component = ref.rsplit("/", 1)[-1].replace("~1", "/").replace("~0", "~")
            return self.compile_component(component)
        if schema.get("$recursiveRef") == "#" and self._building_stack:
            component = next(
                (
                    candidate
                    for candidate in reversed(self._building_stack)
                    if self.doc["components"]["schemas"][candidate].get("$recursiveAnchor") is True
                ),
                self._building_stack[-1],
            )
            return TypeRef("named", name=pascal_case(component))
        if "allOf" in schema:
            from .normalize import merge_all_of

            parts = schema.get("allOf")
            siblings = set(schema) - {"allOf", "description", "nullable", "title", "default", "example", "examples"}
            annotation_keys = {"description", "nullable", "title", "default", "example", "examples", "required"}
            if isinstance(parts, list):
                substantive = [part for part in parts if isinstance(part, dict) and (set(part) - annotation_keys)]
                annotations = [part for part in parts if isinstance(part, dict) and not (set(part) - annotation_keys)]
            else:
                substantive = []
                annotations = []
            if len(substantive) == 1 and "$ref" in substantive[0] and not siblings:
                target = self.resolve(substantive[0]["$ref"])
                target_required = set(target.get("required", []))
                annotation_required = set().union(*(set(part.get("required", [])) for part in annotations))
                if annotation_required.issubset(target_required):
                    return self.compile_type(substantive[0], name, usage, pointer, named_component=named_component, preserve_constants=preserve_constants)
            resolved_parts: list[dict[str, Any]] = []
            for part in parts if isinstance(parts, list) else []:
                if not isinstance(part, dict):
                    resolved_parts = []
                    break
                try:
                    resolved_parts.append(_split_nullable(self._dereference(part))[0])
                except (KeyError, TypeError):
                    resolved_parts = []
                    break
            primitive_kinds = [part.get("type") for part in resolved_parts]
            primitive_names = {"string", "integer", "number", "boolean"}
            if resolved_parts and all(isinstance(kind, str) and kind in primitive_names for kind in primitive_kinds):
                if len(set(primitive_kinds)) == 1:
                    combined: dict[str, Any] = {}
                    for part in resolved_parts:
                        combined.update(part)
                    combined.update({key: value for key, value in schema.items() if key != "allOf"})
                    schema = combined
                else:
                    self.add_diag(pointer_join(pointer, "allOf"), "allOf primitive members have different types", "make all primitive members use the same type")
                    return TypeRef("Json")
            else:
                merge_diagnostics: list[Diagnostic] = []
                merge_notes: list[tuple[str, str]] = []
                schema = merge_all_of(schema, pointer, self.doc, merge_diagnostics, merge_notes)
                self.diagnostics.extend(merge_diagnostics)
                for note_pointer, message in merge_notes:
                    self.add_note(note_pointer, message)
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
            return self._struct_type(schema, name, usage, pointer, preserve_constants)
        if not (set(schema) - {"description", "title", "default", "example", "examples"}):
            self.add_note(pointer, "empty schema mapped to Json")
            return TypeRef("Json")
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
        self._scan_discriminator_fields()
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


def include_operations(doc: dict[str, Any], operation_ids: set[str]) -> tuple[int, set[str]]:
    """Include only the requested operationIds and return count plus missing ids."""
    found: set[str] = set()
    for path_item in doc.get("paths", {}).values():
        if not isinstance(path_item, dict):
            continue
        for method, operation in path_item.items():
            if method.lower() not in HTTP_METHODS or not isinstance(operation, dict):
                continue
            operation.pop("x-moonbit-include", None)
            operation_id = operation.get("operationId")
            if operation_id in operation_ids:
                operation["x-moonbit-include"] = True
                found.add(operation_id)
    return len(found), operation_ids - found
