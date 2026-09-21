from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

import yaml

from tools.gen.diagnostics import GenerationError
from tools.gen.emit_moonbit import emit
from tools.gen.ir import IRBuilder, Newtype, Presence, StringEnum, Struct, UntaggedUnion
from tools.gen.main import run
from tools.gen.normalize import merge_all_of


def operation(*, request=None, response=None, operation_id="testOperation"):
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
    if request is not None:
        value["requestBody"] = {"required": True, "content": {"application/json": {"schema": request}}}
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

    def test_discriminator_and_bare_additional_properties_are_diagnostics(self):
        for schema, fragment in [
            ({"oneOf": [{"type": "string"}], "discriminator": {"propertyName": "type"}}, "discriminator"),
            ({"type": "object", "additionalProperties": True}, "x-moonbit-json"),
        ]:
            with self.subTest(fragment=fragment), self.assertRaises(GenerationError) as caught:
                IRBuilder(document(operation(request=schema)), "example/gen").build()
            self.assertIn(fragment, str(caught.exception))


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
            bad = {"type": "object", "additionalProperties": True}
            spec.write_text(yaml.safe_dump(document(operation(request=bad)), sort_keys=False), encoding="utf-8")
            code = run(["--spec", str(spec), "--out", str(out), "--package", "example/gen", "--ir-out", str(ir_out)])
            self.assertEqual(code, 2)
            self.assertFalse(out.exists())
            self.assertFalse(ir_out.exists())


if __name__ == "__main__":
    unittest.main()
