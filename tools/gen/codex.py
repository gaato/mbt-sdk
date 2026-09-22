"""Generate the selected Codex app-server JSON Schema surface (no HTTP lowering).

The schema bundle is the unmodified output of `codex app-server
generate-json-schema`. The surface manifest explicitly pairs RPC requests and
responses: JSON Schema alone does not encode that relationship.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.gen.diagnostics import GenerationError
from tools.gen.emit_moonbit import HEADER, emit
from tools.gen.ir import ExternalUnion, ExternalVariant, IRBuilder, TypeRef, pascal_case, snake_case
from tools.gen.main import _differences, _format, _protected_conflicts, _write


def resolve(bundle: dict, ref: str) -> dict:
    if not ref.startswith("#/definitions/"):
        raise ValueError(f"unsupported schema reference: {ref}")
    value = bundle
    for part in ref[2:].split("/"):
        value = value[part.replace("~1", "/").replace("~0", "~")]
    if not isinstance(value, dict):
        raise ValueError(f"expected schema object: {ref}")
    return value


def method_params(bundle: dict, union: str, method: str) -> dict:
    matches = [v for v in bundle["definitions"][union]["oneOf"]
               if v["properties"]["method"].get("enum") == [method]]
    if len(matches) != 1:
        raise ValueError(f"{union}: expected one schema for {method!r}")
    return matches[0]["properties"]["params"]


class SchemaBuilder(IRBuilder):
    def __init__(self, bundle: dict, surface: dict):
        self.requests = []
        self.notifications = []
        self.server_requests = []
        roots: list[tuple[dict, str]] = []
        for key, union, target, in_usage, out_usage in (
            ("requests", "ClientRequest", self.requests, "request", "response"),
            ("server_requests", "ServerRequest", self.server_requests, "response", "request"),
        ):
            for method, response in surface[key].items():
                params = method_params(bundle, union, method)
                result = {"$ref": "#/definitions/" + response}
                roots.extend([(params, in_usage), (result, out_usage)])
                target.append((method, params, result))
        for method in surface["notifications"]:
            params = method_params(bundle, "ServerNotification", method)
            roots.append((params, "response"))
            self.notifications.append((method, params))

        # Only collect the transitive closure of the selected surface. Keep
        # request/response usage separate for the existing open-enum policy.
        reachable: dict[str, dict] = {}

        def collect(value: Any) -> None:
            if isinstance(value, list):
                for item in value:
                    collect(item)
            elif isinstance(value, dict):
                if "$ref" in value:
                    ref = value["$ref"]
                    if ref not in reachable:
                        reachable[ref] = resolve(bundle, ref)
                        collect(reachable[ref])
                for key, item in value.items():
                    if key not in ("default", "examples", "enum", "const"):
                        collect(item)

        for schema, _ in roots:
            collect(schema)
        names: dict[str, str] = {}
        used: set[str] = set()
        for ref in sorted(reachable, key=lambda r: ("/v2/" not in r, r)):
            name = ref.rsplit("/", 1)[-1]
            if name in used:
                name = "Rpc" + name
            if name in used:
                raise ValueError(f"schema name collision: {ref}")
            names[ref] = name
            used.add(name)

        def convert(value: Any) -> Any:
            if value is True:
                return {"nullable": True}
            if not isinstance(value, dict):
                raise ValueError(f"unsupported JSON Schema: {value!r}")
            result = {}
            for key, item in value.items():
                if key == "$schema":
                    continue
                if key == "$ref":
                    result[key] = "#/components/schemas/" + names[item]
                elif key == "properties":
                    result[key] = {k: convert(v) for k, v in item.items()}
                elif key in ("oneOf", "anyOf", "allOf"):
                    result[key] = [convert(v) for v in item]
                elif key == "items" or (key == "additionalProperties" and isinstance(item, dict)):
                    result[key] = convert(item)
                else:
                    result[key] = item
            if not (set(result) - {"description", "title", "default", "examples"}):
                result["nullable"] = True
            return result

        schemas = {names[ref]: convert(value) for ref, value in reachable.items()}
        super().__init__({"components": {"schemas": schemas}, "paths": {}}, "gaato/codex-protocol")
        self.roots = [(convert(s), u) for s, u in roots]
        self.requests = [(m, convert(p), convert(r)) for m, p, r in self.requests]
        self.notifications = [(m, convert(p)) for m, p in self.notifications]
        self.server_requests = [(m, convert(p), convert(r)) for m, p, r in self.server_requests]

    def discover(self):
        seen = set()
        for schema, usage in self.roots:
            self._walk_refs(schema, usage, seen)
        return []

    def type_of(self, schema: dict) -> str:
        return self.compile_component(schema["$ref"].rsplit("/", 1)[-1]).moon_type()

    def compile_type(self, schema, name, usage, pointer, **kwargs):
        if schema.get("format") in ("uint", "uint64"):
            return TypeRef("UInt64Number")
        if schema.get("format") == "uint32":
            return TypeRef("UInt")
        return super().compile_type(schema, name, usage, pointer, **kwargs)

    def _union_type(self, schema, name, usage, pointer):
        choices = schema.get("oneOf", schema.get("anyOf", []))
        # Serde's external enum representation: unit variants are strings;
        # payload variants are closed objects with exactly one required key.
        external = any(c.get("type") == "object" for c in choices) and all(
            (c.get("type") == "string" and isinstance(c.get("enum"), list)) or
            (c.get("type") == "object" and c.get("additionalProperties") is False
             and len(c.get("properties", {})) == 1
             and set(c.get("required", [])) == set(c["properties"]))
            for c in choices
        )
        if external:
            variants = []
            names = set()
            tags = set()
            for index, choice in enumerate(choices):
                entries = ((tag, None) for tag in choice["enum"]) if choice["type"] == "string" else choice["properties"].items()
                for tag, payload in entries:
                    variant = pascal_case(tag)
                    if variant in names or tag in tags or variant == "UnknownValue":
                        raise ValueError(f"{pointer}: external enum tag/name collision: {tag}")
                    names.add(variant)
                    tags.add(tag)
                    ref = None if payload is None else self.compile_type(payload, name + variant, usage, f"{pointer}/oneOf/{index}/properties/{tag}")
                    variants.append(ExternalVariant(variant, tag, ref))
            self._add_declaration(ExternalUnion(name, tuple(variants), schema.get("description", "")), pointer)
            return TypeRef("named", name=name)
        # `unknown` is a real Codex variant, distinct from the forward-compatible
        # fallback named Unknown in the shared emitter.
        schema = dict(schema)
        schema.setdefault("x-moonbit-variants", {"unknown": "KnownUnknown"})
        return super()._union_type(schema, name, usage, pointer)


def protocol(builder: SchemaBuilder) -> str:
    lines = [HEADER, '''///|
/// An unsigned 64-bit integer encoded as a JSON number, not a JSON string.
pub(all) struct UInt64Number {
  value : UInt64
} derive(Eq, @debug.Debug)

///|
pub extend UInt64Number with Eq::{equal, not_equal}

///|
pub extend UInt64Number with @debug.Debug::{to_repr}

///|
pub extend UInt64Number with ToJson::{to_json}

///|
pub impl ToJson for UInt64Number with fn to_json(self) {
  Json::number(self.value.to_double(), repr=self.value.to_string())
}

///|
pub extend UInt64Number with @json.FromJson::{from_json}

///|
pub impl @json.FromJson for UInt64Number with fn from_json(value, path) {
  guard value is Number(raw, repr~) else {
    raise @json.JsonDecodeError((path, "expected unsigned JSON integer"))
  }
  if repr is Some(text) && text.length() > 0 && text.iter().all(c => c >= '0' && c <= '9') {
    return { value: @json.from_json(text.to_json(), path~) }
  }
  if raw.is_nan() || raw < 0.0 || raw >= 18446744073709551616.0 {
    raise @json.JsonDecodeError((path, "unsigned JSON integer out of range"))
  }
  let value = raw.to_uint64()
  if value.to_double() != raw {
    raise @json.JsonDecodeError((path, "expected integral JSON number"))
  }
  { value }
}

///|
/// A typed client request. Send with the SDK Client::call method.
pub struct Call[T] {
  name : String
  params : Json
  decode : (Json) -> T raise @json.JsonDecodeError
}

///|
fn[T : @json.FromJson] decode_result(value : Json) -> T raise @json.JsonDecodeError {
  @json.from_json(value)
}
''']
    for method, params, result in builder.requests:
        lines.append(f'''///|
/// Creates a {method} request from generated protocol types.
pub fn {snake_case(method)}(params : {builder.type_of(params)}) -> Call[{builder.type_of(result)}] {{
  {{ name: {json.dumps(method)}, params: params.to_json(), decode: decode_result }}
}}
''')
    lines.append('///|\n/// Typed progress events; unselected or newer events retain their JSON.\npub(all) enum Event {')
    for method, params in builder.notifications:
        lines.append(f'  {pascal_case(method)}({builder.type_of(params)})')
    lines.append('  Unknown(String, Json?)\n}\n')
    lines.append('''///|
/// Decodes selected events strictly; unknown methods are lossless.
pub fn Event::decode(name : String, params : Json?) -> Event raise @json.JsonDecodeError {
  match name {''')
    for method, _ in builder.notifications:
        lines.append(f'    {json.dumps(method)} => {pascal_case(method)}(@json.from_json(params.unwrap_or(Json::null())))')
    lines.append('    _ => Unknown(name, params)\n  }\n}\n')
    return "\n".join(lines)


def run(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", default="codex-protocol/spec/schema.json")
    parser.add_argument("--surface", default="codex-protocol/spec/surface.json")
    parser.add_argument("--out", default="codex-protocol/src/gen")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    try:
        builder = SchemaBuilder(json.loads(Path(args.spec).read_text()), json.loads(Path(args.surface).read_text()))
        ir = builder.build()
        files = emit(ir)
        files.pop("operations.mbt")
        files["protocol.mbt"] = protocol(builder)
        files = _format(files)
    except GenerationError as error:
        for diagnostic in error.diagnostics:
            print(diagnostic.format(), file=sys.stderr)
        return 2
    except (KeyError, ValueError, TypeError) as error:
        print(f"Codex schema error: {error}", file=sys.stderr)
        return 2
    out = Path(args.out)
    for conflict in _protected_conflicts(out, files):
        print(f"refusing to overwrite non-generated file: {conflict}", file=sys.stderr)
        return 2
    if args.check:
        differences = _differences(out, files)
        for path in differences:
            print(f"generated file differs: {path}", file=sys.stderr)
        return int(bool(differences))
    _write(out, files)
    print(f"Codex: generated {len(ir.declarations)} declarations, {len(builder.requests)} calls, {len(builder.notifications)} events")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
