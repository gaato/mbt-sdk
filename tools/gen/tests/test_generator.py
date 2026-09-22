from __future__ import annotations

import json
import io
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

import yaml

from tools.gen.diagnostics import GenerationError
from tools.gen.census import run as census_run
from tools.gen.emit_moonbit import emit
from tools.gen.ir import IRBuilder, Newtype, Presence, StringEnum, Struct, TaggedUnion, UntaggedUnion
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

    def test_optional_int64_emits_encoder_and_decoder_helpers(self):
        schema = {
            "type": "object",
            "properties": {"id": {"type": "integer", "format": "int64"}},
        }
        ir = IRBuilder(document(operation(response=schema)), "example/gen").build()
        source = emit(ir)["types.mbt"]
        self.assertIn("fn json_int64_to_json(", source)
        self.assertIn("fn decode_optional_int64(", source)

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

    def test_struct_constructors_require_values_and_default_optional_fields(self):
        schema = {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "nullable": {"type": "string", "nullable": True},
                "note": {"type": "string"},
                "maybe": {"type": "string", "nullable": True},
            },
            "required": ["id", "nullable"],
        }
        source = emit(IRBuilder(document(operation(request=schema)), "example/gen").build())["types.mbt"]
        self.assertIn("pub fn TestOperationRequest::new(", source)
        self.assertIn("id~ : String", source)
        self.assertIn("nullable? : String", source)
        self.assertIn("note? : String", source)
        self.assertIn("maybe? : String", source)
        self.assertIn("maybe: @sdkjson.Presence::from_option(maybe)", source)

    def test_struct_constructor_name_collision_is_a_diagnostic(self):
        schema = {
            "type": "object",
            "properties": {"new": {"type": "string"}},
        }
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(document(operation(request=schema)), "example/gen").build()
        self.assertIn("collides with constructor new", str(caught.exception))

    def test_operation_emits_decode_json_and_precise_missing_required_message(self):
        schema = {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
        }
        emitted = emit(IRBuilder(document(operation(response=schema)), "example/gen").build())
        operations = emitted["operations.mbt"]
        self.assertIn("pub fn test_operation_decode_json(", operations)
        self.assertIn("value : Json", operations)
        self.assertIn("raise @json.JsonDecodeError", operations)
        self.assertIn("required だが欠落: ", emitted["types.mbt"])

    def test_explicit_discriminator_emits_tagged_enum_and_keeps_tag_fields(self):
        schemas = {
            "Cat": {
                "type": "object",
                "properties": {"kind": {"type": "string", "const": "cat"}, "name": {"type": "string"}},
                "required": ["kind", "name"],
            },
            "Dog": {
                "type": "object",
                "properties": {"kind": {"type": "string", "enum": ["dog"]}, "name": {"type": "string"}},
                "required": ["kind", "name"],
            },
            "Pet": {
                "oneOf": [{"$ref": "#/components/schemas/Cat"}, {"$ref": "#/components/schemas/Dog"}],
                "discriminator": {
                    "propertyName": "kind",
                    "mapping": {"cat": "#/components/schemas/Cat", "dog": "#/components/schemas/Dog"},
                },
            },
        }
        ir = IRBuilder(document(operation(response={"$ref": "#/components/schemas/Pet"}), schemas), "example/gen").build()
        pet = declaration(ir, "Pet")
        self.assertIsInstance(pet, TaggedUnion)
        self.assertEqual([(item.name, item.tag) for item in pet.variants], [("Cat", "cat"), ("Dog", "dog")])
        self.assertIn("kind", [field.json_name for field in declaration(ir, "Cat").fields if field.constant is None])
        source = emit(ir)["types.mbt"]
        self.assertIn("Unknown(String, Json)", source)
        self.assertIn('other => Unknown(other, value)', source)

    def test_discriminator_without_mapping_uses_payload_constant_and_notes_inference(self):
        schemas = {
            "OddName": {
                "type": "object",
                "properties": {"type": {"type": "string", "enum": ["wire_tag"]}},
                "required": ["type"],
            },
            "Event": {
                "oneOf": [{"$ref": "#/components/schemas/OddName"}],
                "discriminator": {"propertyName": "type"},
            },
        }
        builder = IRBuilder(document(operation(response={"$ref": "#/components/schemas/Event"}), schemas), "example/gen")
        event = declaration(builder.build(), "Event")
        self.assertEqual(event.variants[0].tag, "wire_tag")
        self.assertTrue(any("mapping inferred" in note.message for note in builder.notes))

    def test_implicit_discriminator_supports_disjoint_value_sets(self):
        def object_schema(value):
            tag = {"type": "string", "enum": value if isinstance(value, list) else [value]}
            return {"type": "object", "properties": {"type": tag}, "required": ["type"]}

        good = {"oneOf": [object_schema("left"), object_schema("right")]}
        ir = IRBuilder(document(operation(response=good)), "example/gen").build()
        self.assertIsInstance(declaration(ir, "TestOperationResponse"), TaggedUnion)
        schemas = {
            "Comparison": object_schema(["eq", "ne", "gt"]),
            "Compound": object_schema(["and", "or"]),
            "Filter": {
                "oneOf": [
                    {"$ref": "#/components/schemas/Comparison"},
                    {"$ref": "#/components/schemas/Compound"},
                ]
            },
        }
        ir = IRBuilder(
            document(operation(response={"$ref": "#/components/schemas/Filter"}), schemas),
            "example/gen",
        ).build()
        filter_type = declaration(ir, "Filter")
        self.assertEqual(
            [(variant.name, variant.tags) for variant in filter_type.variants],
            [("Comparison", ("eq", "ne", "gt")), ("Compound", ("and", "or"))],
        )
        source = emit(ir)["types.mbt"]
        self.assertIn('"ne" => Comparison', source)
        self.assertIn('"or" => Compound', source)
        self.assertIn("Unknown(String, Json)", source)
        cases = [
            ([object_schema("same"), object_schema("same")], "indistinguishable required sets"),
            ([object_schema(["one", "two"]), object_schema(["two", "right"])], "no common single-value property"),
        ]
        for choices, message in cases:
            with self.subTest(choices=choices), self.assertRaises(GenerationError) as caught:
                IRBuilder(document(operation(response={"oneOf": choices})), "example/gen").build()
            self.assertIn(message, str(caught.exception))

    def test_colliding_tags_use_second_discriminator_and_composite_names(self):
        schemas = {
            "UserMessage": {
                "type": "object",
                "properties": {
                    "type": {"type": "string", "enum": ["message"]},
                    "role": {"type": "string", "const": "user"},
                    "content": {"type": "string"},
                },
                "required": ["type", "role", "content"],
            },
            "AssistantMessage": {
                "type": "object",
                "properties": {
                    "type": {"type": "string", "enum": ["message"]},
                    "role": {"type": "string", "const": "assistant"},
                    "content": {"type": "string"},
                },
                "required": ["type", "role", "content"],
            },
            "Item": {
                "oneOf": [
                    {"$ref": "#/components/schemas/UserMessage"},
                    {"$ref": "#/components/schemas/AssistantMessage"},
                ]
            },
        }
        ir = IRBuilder(
            document(operation(response={"$ref": "#/components/schemas/Item"}), schemas),
            "example/gen",
        ).build()
        item = declaration(ir, "Item")
        self.assertEqual(
            [(variant.name, variant.tag, variant.secondary_discriminator, variant.secondary_tag) for variant in item.variants],
            [
                ("MessageUser", "message", "role", "user"),
                ("MessageAssistant", "message", "role", "assistant"),
            ],
        )
        self.assertIn("role", [field.json_name for field in declaration(ir, "UserMessage").fields])
        source = emit(ir)["types.mbt"]
        self.assertIn('match obj.get("role")', source)
        self.assertIn('Some(String("assistant")) => MessageAssistant', source)
        self.assertIn("_ => Unknown(tag, value)", source)

    def test_rejected_second_discriminator_values_fall_back_to_required_sets(self):
        for roles in [
            (["shared"], ["shared"]),
            (["user", "system"], ["assistant"]),
        ]:
            schemas = {
                "Left": {
                    "type": "object",
                    "properties": {
                        "type": {"type": "string", "enum": ["message"]},
                        "role": {"type": "string", "enum": roles[0]},
                        "left": {"type": "string"},
                    },
                    "required": ["type", "left"],
                },
                "Right": {
                    "type": "object",
                    "properties": {
                        "type": {"type": "string", "enum": ["message"]},
                        "role": {"type": "string", "enum": roles[1]},
                        "right": {"type": "string"},
                    },
                    "required": ["type", "right"],
                },
                "Item": {
                    "oneOf": [
                        {"$ref": "#/components/schemas/Left"},
                        {"$ref": "#/components/schemas/Right"},
                    ]
                },
            }
            with self.subTest(roles=roles):
                builder = IRBuilder(
                    document(operation(response={"$ref": "#/components/schemas/Item"}), schemas),
                    "example/gen",
                )
                ir = builder.build()
                item = declaration(ir, "Item")
                self.assertEqual([variant.name for variant in item.variants], ["Left", "Right"])
                self.assertEqual(item.variants[0].secondary_discriminator, None)
                self.assertTrue(any("specification order" in note.message for note in builder.notes))

    def test_colliding_tag_required_sets_use_inclusion_order(self):
        schemas = {
            "Base": {
                "type": "object",
                "properties": {"type": {"type": "string", "enum": ["event"]}},
                "required": ["type"],
            },
            "Detailed": {
                "type": "object",
                "properties": {
                    "type": {"type": "string", "enum": ["event"]},
                    "detail": {"type": "string"},
                },
                "required": ["type", "detail"],
            },
            "Event": {
                "oneOf": [
                    {"$ref": "#/components/schemas/Base"},
                    {"$ref": "#/components/schemas/Detailed"},
                ]
            },
        }
        ir = IRBuilder(
            document(operation(response={"$ref": "#/components/schemas/Event"}), schemas),
            "example/gen",
        ).build()
        event = declaration(ir, "Event")
        self.assertEqual([variant.name for variant in event.variants], ["Detailed", "Base"])
        source = emit(ir)["types.mbt"]
        self.assertLess(source.index("Detailed(@json.from_json"), source.index("Base(@json.from_json"))

    def test_x_moonbit_order_resolves_equal_required_sets(self):
        schemas = {
            name: {
                "type": "object",
                "properties": {"type": {"type": "string", "enum": ["same"]}},
                "required": ["type"],
            }
            for name in ["First", "Second"]
        }
        schemas["Choice"] = {
            "oneOf": [
                {"$ref": "#/components/schemas/First"},
                {"$ref": "#/components/schemas/Second"},
            ]
        }
        doc = document(operation(response={"$ref": "#/components/schemas/Choice"}), schemas)
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(doc, "example/gen").build()
        self.assertIn("indistinguishable required sets", str(caught.exception))
        schemas["Choice"]["x-moonbit-order"] = ["Second", "First"]
        ir = IRBuilder(doc, "example/gen").build()
        self.assertEqual(
            [variant.name for variant in declaration(ir, "Choice").variants],
            ["Second", "First"],
        )

    def test_implicit_discriminator_flattens_refs_all_of_and_nested_unions(self):
        tagged = lambda value: {
            "type": "object",
            "properties": {"type": {"type": "string", "enum": [value]}},
            "required": ["type"],
        }
        schemas = {
            "Left": tagged("left"),
            "RightBase": tagged("right"),
            "Right": {
                "allOf": [
                    {"$ref": "#/components/schemas/RightBase"},
                    {"type": "object", "properties": {"value": {"type": "integer"}}},
                ]
            },
            "Nested": {
                "oneOf": [
                    {"$ref": "#/components/schemas/Left"},
                    {"$ref": "#/components/schemas/Right"},
                ]
            },
            "Outer": {
                "anyOf": [
                    {"$ref": "#/components/schemas/Nested"},
                    tagged("final"),
                ]
            },
        }
        ir = IRBuilder(document(operation(response={"$ref": "#/components/schemas/Outer"}), schemas), "example/gen").build()
        outer = declaration(ir, "Outer")
        self.assertIsInstance(outer, TaggedUnion)
        self.assertEqual([variant.tag for variant in outer.variants], ["left", "right", "final"])

    def test_nested_implicit_discriminator_still_rejects_duplicate_tags(self):
        tagged = lambda value: {
            "type": "object",
            "properties": {"type": {"type": "string", "enum": [value]}},
            "required": ["type"],
        }
        schemas = {
            "Nested": {"oneOf": [tagged("same"), tagged("other")]},
            "Outer": {
                "oneOf": [
                    {"$ref": "#/components/schemas/Nested"},
                    tagged("same"),
                ]
            },
        }
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(document(operation(response={"$ref": "#/components/schemas/Outer"}), schemas), "example/gen").build()
        self.assertIn("indistinguishable required sets", str(caught.exception))

    def test_implicit_discriminator_flattening_stops_at_recursive_refs(self):
        tagged = lambda value: {
            "type": "object",
            "properties": {"type": {"type": "string", "enum": [value]}},
            "required": ["type"],
        }
        schemas = {
            "Recursive": {
                "allOf": [
                    tagged("recursive"),
                    {
                        "type": "object",
                        "properties": {
                            "children": {
                                "type": "array",
                                "items": {"$ref": "#/components/schemas/Recursive"},
                            }
                        },
                    },
                ]
            },
            "Outer": {
                "oneOf": [
                    {"$ref": "#/components/schemas/Recursive"},
                    tagged("leaf"),
                ]
            },
        }
        ir = IRBuilder(
            document(operation(response={"$ref": "#/components/schemas/Outer"}), schemas),
            "example/gen",
        ).build()
        outer = declaration(ir, "Outer")
        self.assertIsInstance(outer, TaggedUnion)
        self.assertEqual([variant.tag for variant in outer.variants], ["recursive", "leaf"])

    def test_nullable_31_forms_are_normalized_for_fields(self):
        schema = {
            "type": "object",
            "properties": {
                "type_array": {"type": ["string", "null"]},
                "union_ref": {"anyOf": [{"$ref": "#/components/schemas/Value"}, {"type": "null"}]},
                "optional_union": {"oneOf": [{"type": "integer"}, {"type": "null"}]},
            },
            "required": ["type_array", "union_ref"],
        }
        schemas = {"Value": {"type": "string"}}
        ir = IRBuilder(document(operation(response=schema), schemas), "example/gen").build()
        fields = declaration(ir, "TestOperationResponse").fields
        self.assertEqual([field.type.moon_type() for field in fields], ["String", "String", "Int"])
        self.assertEqual(
            [field.presence for field in fields],
            [Presence.NULLABLE_REQUIRED, Presence.NULLABLE_REQUIRED, Presence.PRESENCE],
        )

    def test_empty_and_description_only_schemas_are_json_notes(self):
        for schema in [{}, {"description": "intentionally unconstrained"}]:
            with self.subTest(schema=schema):
                builder = IRBuilder(document(operation(request=schema)), "example/gen")
                ir = builder.build()
                self.assertEqual(ir.operations[0].request_type.moon_type(), "Json")
                self.assertIn("empty schema mapped to Json", builder.notes[0].message)

    def test_all_of_reference_wrapper_and_primitive_constraints(self):
        schemas = {"Name": {"type": "string"}}
        wrapped = {"allOf": [{"$ref": "#/components/schemas/Name"}], "description": "docs", "nullable": True}
        ir = IRBuilder(document(operation(response=wrapped), schemas), "example/gen").build()
        self.assertEqual(ir.operations[0].response_type.moon_type(), "String")
        same = {"allOf": [{"type": "integer", "minimum": 0}, {"type": "integer", "maximum": 10}]}
        ir = IRBuilder(document(operation(response=same)), "example/gen").build()
        self.assertEqual(ir.operations[0].response_type.moon_type(), "Int")
        different = {"allOf": [{"type": "integer"}, {"type": "string"}]}
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(document(operation(response=different)), "example/gen").build()
        self.assertIn("different types", str(caught.exception))

    def test_all_of_property_conflict_is_later_wins_note(self):
        schema = {
            "allOf": [
                {"type": "object", "properties": {"value": {"type": "string"}}},
                {"type": "object", "properties": {"value": {"type": "integer"}}},
            ]
        }
        builder = IRBuilder(document(operation(response=schema)), "example/gen")
        ir = builder.build()
        self.assertEqual(declaration(ir, "TestOperationResponse").fields[0].type.moon_type(), "Int")
        self.assertTrue(any("later definition" in note.message for note in builder.notes))

    def test_integer_enum_stays_int(self):
        schema = {"type": "integer", "enum": [1, 2, 3]}
        ir = IRBuilder(document(operation(request=schema)), "example/gen").build()
        self.assertEqual(ir.operations[0].request_type.moon_type(), "Int")

    def test_recursive_refs_allow_array_or_nullable_but_not_direct_required(self):
        safe_schemas = {
            "Tree": {
                "type": "object",
                "properties": {
                    "children": {"type": "array", "items": {"$ref": "#/components/schemas/Tree"}},
                    "next": {"anyOf": [{"$ref": "#/components/schemas/Tree"}, {"type": "null"}]},
                },
                "required": ["children", "next"],
            }
        }
        ir = IRBuilder(document(operation(response={"$ref": "#/components/schemas/Tree"}), safe_schemas), "example/gen").build()
        tree = declaration(ir, "Tree")
        self.assertEqual(tree.fields[0].type.moon_type(), "Array[Tree]")
        self.assertEqual(tree.fields[1].presence, Presence.NULLABLE_REQUIRED)
        bad_schemas = {
            "Node": {
                "type": "object",
                "properties": {"next": {"$ref": "#/components/schemas/Node"}},
                "required": ["next"],
            }
        }
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(document(operation(response={"$ref": "#/components/schemas/Node"}), bad_schemas), "example/gen").build()
        self.assertIn("direct recursive struct field", str(caught.exception))

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

    def test_deep_object_query_serializes_bracketed_map_keys(self):
        parameter = {
            "name": "filter",
            "in": "query",
            "required": False,
            "style": "deepObject",
            "explode": True,
            "schema": {
                "type": "object",
                "additionalProperties": {"type": "string"},
            },
        }
        ir = IRBuilder(
            document(operation(parameters=[parameter])),
            "example/gen",
        ).build()
        self.assertEqual(ir.operations[0].parameters[0].style, "deepObject")
        source = emit(ir)["operations.mbt"]
        self.assertIn('\"filter\" + "[" + key + "]"', source)
        self.assertIn("parameter_value(value)", source)

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
        ]
        for op, fragment in cases:
            with self.subTest(fragment=fragment), self.assertRaises(GenerationError) as caught:
                IRBuilder(document(op), "example/gen").build()
            self.assertIn(fragment, str(caught.exception))

    def test_multipart_request_emits_text_json_and_file_parts(self):
        schema = {
            "type": "object",
            "properties": {
                "file": {"type": "string", "format": "binary"},
                "images": {
                    "type": "array",
                    "items": {"type": "string", "format": "binary"},
                },
                "title": {"type": "string"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "metadata": {
                    "type": "object",
                    "properties": {"ok": {"type": "boolean"}},
                },
            },
            "required": ["file", "title"],
        }
        ir = IRBuilder(
            document(
                operation(
                    request_content={"multipart/form-data": {"schema": schema}}
                )
            ),
            "example/gen",
        ).build()
        fields = ir.operations[0].multipart_fields
        self.assertEqual(
            [(field.json_name, field.kind, field.required) for field in fields],
            [
                ("file", "file", True),
                ("images", "file_array", False),
                ("title", "text", True),
                ("tags", "text_array", False),
                ("metadata", "json", False),
            ],
        )
        generated = emit(ir)
        source = generated["operations.mbt"]
        self.assertIn("boundary : String", source)
        self.assertIn("@multipart.Part::file(\"file\", file_filename, file_content_type, file)", source)
        self.assertIn("@multipart.Part::text(\"title\", parameter_value(title))", source)
        self.assertIn("@multipart.Part::json(\"metadata\", value.to_json())", source)
        self.assertIn("@multipart.apply(request, parts, boundary)", source)
        self.assertIn('"gaato/sdk-runtime/multipart" @multipart', generated["moon.pkg"])

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
    def test_census_ops_selects_only_requested_operation_ids(self):
        doc = {
            "openapi": "3.1.0",
            "paths": {
                "/one": {"get": operation(operation_id="one")},
                "/two": {"get": operation(operation_id="two")},
            },
            "components": {"schemas": {}},
        }
        with tempfile.TemporaryDirectory() as directory:
            spec = Path(directory) / "spec.json"
            spec.write_text(json.dumps(doc), encoding="utf-8")
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                code = census_run([str(spec), "sample", "--ops", "two", "--expect-zero"])
        self.assertEqual(code, 0)
        self.assertIn("operations=1 diagnostics=0", stdout.getvalue())

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
