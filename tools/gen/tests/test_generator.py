from __future__ import annotations

import json
import io
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stderr

import yaml

from tools.gen.diagnostics import GenerationError
from tools.gen.emit_moonbit import emit
from tools.gen.ir import IRBuilder, Newtype, Presence, StringEnum, Struct, UntaggedUnion
from tools.gen.main import run
from tools.gen.normalize import merge_all_of, normalize_spec


def operation(*, request=None, response=None, operation_id="testOperation", parameters=None, responses=None, request_content=None):
    value = {
        "operationId": operation_id,
        "x-moonbit-include": True,
        "responses": {
            "200": {
                "content": {
                    "application/json": {
                        "schema": response or {"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"]}
                    }
                }
            }
        },
    }
    if responses is not None:
        value["responses"] = responses
    if parameters is not None:
        value["parameters"] = parameters
    if request is not None:
        value["requestBody"] = {"required": True, "content": {"application/json": {"schema": request}}}
    if request_content is not None:
        value["requestBody"] = {"required": True, "content": request_content}
    return value


def document(op, schemas=None):
    return {
        "openapi": "3.0.0",
        "paths": {"/test": {"post": op}},
        "components": {"schemas": schemas or {}},
    }


def declaration(ir, name):
    return next(item for item in ir.declarations if item.name == name)


class IRTests(unittest.TestCase):
    def test_presence_mapping_has_all_four_cases(self):
        schema = {
            "type": "object",
            "properties": {
                "required_value": {"type": "string"},
                "required_nullable": {"type": "string", "nullable": True},
                "optional_value": {"type": "string"},
                "optional_nullable": {"type": "string", "nullable": True},
            },
            "required": ["required_value", "required_nullable"],
        }
        ir = IRBuilder(document(operation(request=schema)), "example/gen").build()
        request = declaration(ir, "TestOperationRequest")
        self.assertIsInstance(request, Struct)
        self.assertEqual(
            [field.presence for field in request.fields],
            [Presence.REQUIRED, Presence.NULLABLE_REQUIRED, Presence.OPTIONAL, Presence.PRESENCE],
        )

    def test_all_of_merges_object_properties_and_required(self):
        doc = document(operation(), {"Base": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}})
        diagnostics = []
        merged = merge_all_of(
            {"allOf": [{"$ref": "#/components/schemas/Base"}, {"type": "object", "properties": {"count": {"type": "integer"}}, "required": ["count"]}]},
            "/schema",
            doc,
            diagnostics,
        )
        self.assertEqual(diagnostics, [])
        self.assertEqual(list(merged["properties"]), ["id", "count"])
        self.assertEqual(merged["required"], ["id", "count"])

    def test_enum_open_closed_and_both(self):
        schemas = {
            "RequestOnly": {"type": "string", "enum": ["one", "two"]},
            "ResponseOnly": {"type": "string", "enum": ["one", "two"]},
            "Both": {"type": "string", "enum": ["one", "two"]},
        }
        doc = {
            "openapi": "3.0.0",
            "paths": {
                "/request": {"post": operation(request={"$ref": "#/components/schemas/RequestOnly"}, operation_id="requestOnly")},
                "/response": {"get": operation(response={"$ref": "#/components/schemas/ResponseOnly"}, operation_id="responseOnly")},
                "/both": {"post": operation(request={"$ref": "#/components/schemas/Both"}, response={"$ref": "#/components/schemas/Both"}, operation_id="both")},
            },
            "components": {"schemas": schemas},
        }
        ir = IRBuilder(doc, "example/gen").build()
        self.assertFalse(declaration(ir, "RequestOnly").open)
        self.assertTrue(declaration(ir, "ResponseOnly").open)
        self.assertTrue(declaration(ir, "Both").open)
        self.assertIn("Unknown(String)", emit(ir)["types.mbt"])

    def test_single_value_enum_is_elided_but_encoded(self):
        schema = {"type": "object", "properties": {"object": {"type": "string", "enum": ["thing"]}, "id": {"type": "string"}}, "required": ["object", "id"]}
        ir = IRBuilder(document(operation(request=schema)), "example/gen").build()
        request = declaration(ir, "TestOperationRequest")
        self.assertEqual([field.moon_name for field in request.fields if field.constant is None], ["id"])
        self.assertIn('.field("object", "thing")', emit(ir)["types.mbt"])

    def test_untagged_union_distinguishable_and_not_distinguishable(self):
        good = {"oneOf": [{"type": "string"}, {"type": "array", "items": {"type": "integer"}}]}
        ir = IRBuilder(document(operation(request=good)), "example/gen").build()
        union = declaration(ir, "TestOperationRequest")
        self.assertIsInstance(union, UntaggedUnion)
        self.assertEqual([variant.shape for variant in union.variants], ["string", "array:number"])
        bad = {"oneOf": [{"type": "integer"}, {"type": "number"}]}
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(document(operation(request=bad)), "example/gen").build()
        self.assertIn("not distinguishable", str(caught.exception))

    def test_any_of_string_and_string_enum_folds_to_string(self):
        schema = {"anyOf": [{"type": "string"}, {"type": "string", "enum": ["known"]}]}
        ir = IRBuilder(document(operation(request=schema)), "example/gen").build()
        self.assertEqual(ir.operations[0].request_type.moon_type(), "String")
        self.assertFalse(any(isinstance(item, StringEnum) for item in ir.declarations))

    def test_named_primitive_expands_without_annotation_and_newtypes_with_it(self):
        schemas = {
            "Plain": {"type": "string"},
            "Annotated": {"type": "string", "x-moonbit-type": "AnnotatedId"},
            "Envelope": {
                "type": "object",
                "properties": {"plain": {"$ref": "#/components/schemas/Plain"}, "annotated": {"$ref": "#/components/schemas/Annotated"}},
                "required": ["plain", "annotated"],
            },
        }
        ir = IRBuilder(document(operation(response={"$ref": "#/components/schemas/Envelope"}), schemas), "example/gen").build()
        envelope = declaration(ir, "Envelope")
        self.assertEqual([field.type.moon_type() for field in envelope.fields], ["String", "AnnotatedId"])
        self.assertIsInstance(declaration(ir, "AnnotatedId"), Newtype)
        self.assertFalse(any(item.name == "Plain" for item in ir.declarations))

    def test_int64_format_and_annotation(self):
        schema = {"type": "object", "properties": {"formatted": {"type": "integer", "format": "int64"}, "annotated": {"type": "integer", "x-moonbit-type": "Int64"}}, "required": ["formatted", "annotated"]}
        ir = IRBuilder(document(operation(response=schema)), "example/gen").build()
        response = declaration(ir, "TestOperationResponse")
        self.assertEqual([field.type.moon_type() for field in response.fields], ["Int64", "Int64"])
        self.assertIn("fn json_int64(", emit(ir)["types.mbt"])

    def test_explicit_json_escape_hatch(self):
        schema = {"type": "object", "additionalProperties": True, "x-moonbit-json": True}
        ir = IRBuilder(document(operation(request=schema)), "example/gen").build()
        self.assertEqual(ir.operations[0].request_type.moon_type(), "Json")

    def test_emission_is_byte_deterministic(self):
        schema = {"type": "object", "properties": {"z": {"type": "integer"}, "a": {"type": "string"}}, "required": ["z", "a"]}
        first = emit(IRBuilder(document(operation(request=schema)), "example/gen").build())
        second = emit(IRBuilder(document(operation(request=schema)), "example/gen").build())
        self.assertEqual(first, second)
        self.assertLess(first["types.mbt"].index("z : Int"), first["types.mbt"].index("a : String"))

    def test_discriminator_is_still_a_diagnostic(self):
        schema = {"oneOf": [{"type": "string"}], "discriminator": {"propertyName": "type"}}
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(document(operation(request=schema)), "example/gen").build()
        self.assertIn("discriminator", str(caught.exception))

    def test_schema_less_objects_are_json_with_a_verbose_note(self):
        for schema in [
            {"type": "object"},
            {"type": "object", "additionalProperties": True},
        ]:
            with self.subTest(schema=schema):
                builder = IRBuilder(document(operation(request=schema)), "example/gen")
                ir = builder.build()
                self.assertEqual(ir.operations[0].request_type.moon_type(), "Json")
                self.assertEqual(len(builder.notes), 1)
                self.assertIn("mapped to Json", builder.notes[0].message)

    def test_query_required_optional_array_enum_and_percent_encoding(self):
        parameters = [
            {"name": "q", "in": "query", "required": True, "schema": {"type": "string"}},
            {"name": "limit", "in": "query", "schema": {"type": "integer"}},
            {"name": "tag", "in": "query", "required": True, "style": "form", "explode": True, "schema": {"type": "array", "items": {"type": "string"}}},
            {"name": "mode", "in": "query", "schema": {"type": "string", "enum": ["fast", "safe"]}},
        ]
        ir = IRBuilder(document(operation(parameters=parameters)), "example/gen").build()
        enum = declaration(ir, "TestOperationMode")
        self.assertIsInstance(enum, StringEnum)
        self.assertFalse(enum.open)
        source = emit(ir)["operations.mbt"]
        self.assertIn("q : String", source)
        self.assertIn("tag : Array[String]", source)
        self.assertIn("limit? : Int", source)
        self.assertIn("mode? : TestOperationMode", source)
        self.assertIn('append_query(url, "tag", parameter_value(value))', source)
        self.assertIn('url + separator + percent_encode(name) + "=" + percent_encode(value)', source)
        self.assertIn("for byte in @utf8.encode(value)", source)
        self.assertIn("output.push(b'%')", source)
        # UTF-8 byte encoding plus unreserved-only passthrough covers spaces,
        # Japanese text, ampersands, and equals signs uniformly.
        self.assertIn("byte == b'~'", source)

    def test_header_parameter_is_labelled_and_stringified(self):
        parameters = [
            {"name": "X-Count", "in": "header", "required": True, "schema": {"type": "integer"}},
            {"name": "X-Probe", "in": "header", "schema": {"type": "boolean"}},
        ]
        source = emit(IRBuilder(document(operation(parameters=parameters)), "example/gen").build())["operations.mbt"]
        self.assertIn("x_count : Int", source)
        self.assertIn("x_probe? : Bool", source)
        self.assertIn('request.header("X-Count", parameter_value(x_count))', source)
        self.assertIn('request.header("X-Probe", parameter_value(value))', source)

    def test_parameter_ref_is_resolved_during_normalization(self):
        doc = document(operation(parameters=[{"$ref": "#/components/parameters/Limit"}]))
        doc["components"]["parameters"] = {
            "Limit": {"name": "limit", "in": "query", "schema": {"type": "integer"}}
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "spec.yaml"
            path.write_text(yaml.safe_dump(doc, sort_keys=False), encoding="utf-8")
            normalized = normalize_spec(path, [])
        parameter = normalized["paths"]["/test"]["post"]["parameters"][0]
        self.assertNotIn("$ref", parameter)
        self.assertEqual(parameter["name"], "limit")
        ir = IRBuilder(normalized, "example/gen").build()
        self.assertEqual(ir.operations[0].parameters[0].type.moon_type(), "Int")

    def test_request_only_operation_omits_decode(self):
        responses = {"default": {"content": {"application/json": {"schema": {"type": "object"}}}}}
        ir = IRBuilder(document(operation(responses=responses)), "example/gen").build()
        self.assertIsNone(ir.operations[0].response_type)
        source = emit(ir)["operations.mbt"]
        self.assertIn("caller handles the response as @http.Response", source)
        self.assertNotIn("test_operation_decode", source)

    def test_typed_map_uses_map_json_traits_for_round_trip(self):
        schema = {"type": "object", "additionalProperties": {"type": "integer"}}
        ir = IRBuilder(document(operation(request=schema, response=schema)), "example/gen").build()
        operation_ir = ir.operations[0]
        self.assertEqual(operation_ir.request_type.moon_type(), "Map[String, Int]")
        self.assertEqual(operation_ir.response_type.moon_type(), "Map[String, Int]")
        source = emit(ir)["operations.mbt"]
        self.assertIn("body : Map[String, Int]", source)
        self.assertIn("-> Map[String, Int] raise @runtime.SdkError", source)

    def test_properties_and_typed_map_are_a_diagnostic(self):
        schema = {
            "type": "object",
            "properties": {"fixed": {"type": "string"}},
            "additionalProperties": {"type": "integer"},
        }
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(document(operation(request=schema)), "example/gen").build()
        self.assertIn("cannot coexist", str(caught.exception))

    def test_unsupported_parameter_and_body_forms_are_diagnostics(self):
        cases = [
            (operation(parameters=[{"name": "session", "in": "cookie", "schema": {"type": "string"}}]), "cookie"),
            (operation(parameters=[{"name": "q", "in": "query", "style": "deepObject", "schema": {"type": "string"}}]), "deepObject"),
            (operation(parameters=[{"name": "Authorization", "in": "header", "schema": {"type": "string"}}]), "reserved header"),
            (operation(request_content={"application/x-www-form-urlencoded": {"schema": {"type": "object"}}}), "urlencoded"),
            (operation(request_content={"multipart/form-data": {"schema": {"type": "object"}}}), "multipart"),
        ]
        for op, fragment in cases:
            with self.subTest(fragment=fragment), self.assertRaises(GenerationError) as caught:
                IRBuilder(document(op), "example/gen").build()
            self.assertIn(fragment, str(caught.exception))

    def test_json_body_wins_when_form_is_an_alternative(self):
        content = {
            "application/json": {"schema": {"type": "string"}},
            "application/x-www-form-urlencoded": {"schema": {"type": "string"}},
        }
        ir = IRBuilder(document(operation(request_content=content)), "example/gen").build()
        self.assertEqual(ir.operations[0].request_type.moon_type(), "String")

    def test_missing_operation_id_requires_explicit_derivation(self):
        doc = document(operation(operation_id=None))
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(doc, "example/gen").build()
        self.assertIn("--derive-operation-ids", str(caught.exception))
        ir = IRBuilder(doc, "example/gen", derive_operation_ids=True).build()
        self.assertEqual(ir.operations[0].operation_id, "post_test")


class CLITests(unittest.TestCase):
    def test_check_exit_codes_and_ir_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spec = root / "spec.yaml"
            out = root / "out"
            ir_out = root / "ir.json"
            spec.write_text(yaml.safe_dump(document(operation()), sort_keys=False), encoding="utf-8")
            args = ["--spec", str(spec), "--out", str(out), "--package", "example/gen"]
            self.assertEqual(run(args + ["--check"]), 1)
            self.assertFalse(out.exists())
            self.assertEqual(run(args + ["--ir-out", str(ir_out)]), 0)
            before = {path.name: path.read_bytes() for path in out.iterdir()}
            self.assertEqual(run(args), 0)
            self.assertEqual(before, {path.name: path.read_bytes() for path in out.iterdir()})
            self.assertEqual(run(args + ["--check"]), 0)
            self.assertEqual(json.loads(ir_out.read_text())["package"], "example/gen")
            (out / "types.mbt").write_text("stale\n", encoding="utf-8")
            self.assertEqual(run(args + ["--check"]), 2)
            self.assertEqual(run(args), 2)
            self.assertEqual((out / "types.mbt").read_text(), "stale\n")

    def test_diagnostic_exit_code_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spec = root / "spec.yaml"
            out = root / "out"
            ir_out = root / "ir.json"
            bad = {
                "type": "object",
                "properties": {"fixed": {"type": "string"}},
                "additionalProperties": {"type": "integer"},
            }
            spec.write_text(yaml.safe_dump(document(operation(request=bad)), sort_keys=False), encoding="utf-8")
            code = run(["--spec", str(spec), "--out", str(out), "--package", "example/gen", "--ir-out", str(ir_out)])
            self.assertEqual(code, 2)
            self.assertFalse(out.exists())
            self.assertFalse(ir_out.exists())

    def test_verbose_prints_schema_less_json_note(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spec = root / "spec.yaml"
            out = root / "out"
            spec.write_text(yaml.safe_dump(document(operation(request={"type": "object"})), sort_keys=False), encoding="utf-8")
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                code = run(["--spec", str(spec), "--out", str(out), "--package", "example/gen", "--verbose"])
            self.assertEqual(code, 0)
            self.assertIn("note:", stderr.getvalue())
            self.assertIn("schema-less object mapped to Json", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
