"""Regression fixtures for schema shapes and facade options used by product slices."""

import unittest

from tools.gen.tests.test_generator import declaration, document, operation
from tools.gen.client_layer import client_names, emit_client, paginator_item_type, scheme_auth, security_auth_choices
from tools.gen.diagnostics import GenerationError
from tools.gen.emit_moonbit import emit
from tools.gen.ir import IRBuilder, Presence, StringEnum, TaggedUnion, TypeRef
from tools.gen.normalize import merge_all_of
from tools.sdks import validate_auth, validate_retry


class EnvelopedSliceTests(unittest.TestCase):
    def test_tagged_union_keeps_required_only_shared_constraints(self):
        choices = [{"type": "object", "properties": {
            "kind": {"type": "string", "enum": [tag]}, "id": {"type": "string"},
        }} for tag in ("a", "b")]
        schema = {"oneOf": choices, "required": ["id"]}
        ir = IRBuilder(document(operation(response=schema)), "fixture/gen").build()
        result = declaration(ir, "TestOperationResponse")
        self.assertEqual(result.discriminator, "kind")
        for variant in result.variants:
            fields = {field.json_name: field for field in declaration(ir, variant.type.name).fields}
            self.assertEqual(fields["id"].presence, Presence.REQUIRED)

    def test_required_fields_by_tag_only_refine_the_response_branch(self):
        schemas = {
            tag: {"type": "object", "properties": {
                "kind": {"type": "string", "enum": [tag]},
                "comment": {"type": "string"},
            }, "required": ["kind"]}
            for tag in ("A", "B")
        }
        choices = [{"$ref": f"#/components/schemas/{tag}"} for tag in schemas]
        request = {"oneOf": choices, "required": ["comment"]}
        response = {
            "oneOf": choices,
            "x-moonbit-nullable-fields": ["comment"],
            "x-moonbit-required-fields-by-tag": {"B": ["comment"]},
        }
        ir = IRBuilder(document(operation(request=request, response=response), schemas), "fixture/gen").build()
        for name, expected in (
            ("TestOperationRequest", [Presence.REQUIRED, Presence.REQUIRED]),
            ("TestOperationResponse", [Presence.PRESENCE, Presence.NULLABLE_REQUIRED]),
        ):
            union = declaration(ir, name)
            actual = [
                next(field.presence for field in declaration(ir, variant.type.name).fields if field.json_name == "comment")
                for variant in union.variants
            ]
            self.assertEqual(actual, expected)

    def test_independent_union_intersections_are_diagnostics(self):
        def choices(key):
            return [{"type": "object", "properties": {key: {"type": "string", "enum": [tag]}}}
                    for tag in ("a", "b")]

        for first, second in (("oneOf", "oneOf"), ("oneOf", "anyOf")):
            with self.subTest(first=first, second=second):
                schema = {"allOf": [{first: choices("kind")}, {second: choices("state")}]}
                with self.assertRaisesRegex(GenerationError, "unsupported union intersection"):
                    IRBuilder(document(operation(response=schema)), "fixture/gen").build()

    def test_typed_wrappers_and_pagination_share_one_parsed_envelope(self):
        op = operation(response={"type": "object", "properties": {
            "result": {"type": "array", "items": {"type": "string"}},
        }})
        op["x-moonbit-paginate"] = {"kind": "page", "items": "result", "next": "meta.total_pages", "param": "page"}
        doc = document(op)
        doc["x-moonbit-envelope"] = {key: key for key in ("result", "success", "errors", "messages")}
        sdk = {"name": "fixture", "dir": "fixture", "out": "fixture/src/gen", "module": "example/fixture",
               "auth": {"kind": "none"}, "base_url": "https://fixture.example"}
        ir = IRBuilder(doc, "example/fixture/gen").build()
        files = emit_client(doc, ir, sdk)
        self.assertIn("self.call_envelope(request, @gen.test_operation_decode_json", files["operations_gen.mbt"])
        self.assertIn("self.read_envelope(request, operation~)", files["paginate_gen.mbt"])
        self.assertNotIn("@json.parse(@utf8.decode(reply.body))", files["paginate_gen.mbt"])
        failure_source = files["failures_gen.mbt"]
        self.assertEqual(failure_source.count("@json.parse"), 1)
        failure_constructor = failure_source.split("fn envelope_failure(", 1)[1]
        self.assertNotIn("envelope_json(body)", failure_constructor)

    def test_automatic_multipart_scans_parts_before_selecting_a_candidate(self):
        op = operation(request_content={"multipart/form-data": {"schema": {
            "type": "object", "required": ["file"], "properties": {"file": {"type": "string"}},
        }}})
        ir = IRBuilder(document(op), "fixture/gen", auto_multipart_boundary=True).build()
        source = emit(ir)["operations.mbt"]
        helper = source.split("fn multipart_with_boundary_(", 1)[1]
        scan, select = helper.split("for serial = 0UL", 1)
        self.assertIn("multipart_conflicts_(", scan)
        self.assertIn("conflicts.contains(serial)", select)
        self.assertNotIn("body.find", select)

    def test_single_member_all_of_retains_primitive_and_array_wire_shapes(self):
        doc = document(operation(), {
            "Counters": {"type": "array", "items": {"type": "integer"}},
            "Priority": {"type": "number"},
        })
        for component, extra, expected in [
            ("Counters", {"minLength": 1}, "array"),
            ("Priority", {"x-auditable": True}, "number"),
        ]:
            diagnostics = []
            wrapper = {"allOf": [{"$ref": f"#/components/schemas/{component}"}], **extra}
            actual = merge_all_of(wrapper, "/wrapper", doc, diagnostics)
            self.assertEqual(diagnostics, [])
            self.assertEqual(actual["type"], expected)

    def test_number_any_of_and_untyped_string_enum_lower_to_wire_types(self):
        payload = {"type": "object", "properties": {
            "value": {"type": "number", "anyOf": [
                {"type": "number", "minimum": 10}, {"type": "number", "enum": [1]},
            ]},
            "status": {"enum": ["active", "pending"]},
        }}
        ir = IRBuilder(document(operation(request=payload)), "fixture/gen").build()
        fields = declaration(ir, "TestOperationRequest").fields
        self.assertEqual(fields[0].type, TypeRef("Double"))
        self.assertIsInstance(declaration(ir, fields[1].type.name), StringEnum)

    def test_nested_inferred_tags_intersect_sibling_fields_and_encode_constructor_tag(self):
        def item(tag):
            return {"type": "object", "properties": {"kind": {"type": "string", "enum": [tag]}}}
        variant = {"anyOf": [{"oneOf": [item("a"), item("b")]}, {"oneOf": [item("c"), item("d")]}]}
        schema = {"allOf": [variant, {"type": "object", "properties": {"identifier": {"type": "string"}}, "required": ["identifier"]}]}
        ir = IRBuilder(document(operation(response=schema)), "fixture/gen").build()
        union = declaration(ir, "TestOperationResponse")
        self.assertIsInstance(union, TaggedUnion)
        self.assertEqual(union.discriminator, "kind")
        self.assertEqual([variant.tag for variant in union.variants], ["a", "b", "c", "d"])
        self.assertTrue(union.encode_inferred_tag)
        for variant in union.variants:
            self.assertIn("identifier", [field.json_name for field in declaration(ir, variant.type.name).fields])
        source = emit(ir)["types.mbt"]
        self.assertIn('encode_inferred_tag(@json.Json::Json(value), "kind", "a")', source)
        self.assertIn("Unknown(String, Json)", source)

    def test_configured_envelope_infers_the_numbered_page_item_type(self):
        envelope = {"type": "object", "properties": {"value": {"type": "array", "items": {"type": "string"}}}}
        op = operation(response=envelope)
        doc = document(op)
        doc["x-moonbit-envelope"] = {"result": "value", "success": "ok", "errors": "problems", "messages": "notes"}
        op["x-moonbit-paginate"] = {"kind": "page", "items": "value", "next": "meta.total_pages", "param": "page"}
        ir = IRBuilder(doc, "fixture/gen").build()
        operation_ir = ir.operations[0]
        self.assertEqual(operation_ir.response_envelope, "value")
        self.assertEqual(paginator_item_type(ir, operation_ir, op["x-moonbit-paginate"]), TypeRef("String"))
        self.assertIn('@sdkjson.field(fields, "value", path)', emit(ir)["operations.mbt"])

    def test_fern_method_names_keep_resource_and_http_verb(self):
        op = operation()
        op.update({"x-fern-sdk-group-name": "storage.buckets", "x-fern-sdk-method-name": "edit"})
        doc = document(op)
        doc["paths"] = {"/buckets/{id}": {"patch": op}}
        op["parameters"] = [{"name": "id", "in": "path", "required": True, "schema": {"type": "string"}}]
        doc["x-moonbit-operation-naming"] = "fern"
        ir = IRBuilder(doc, "fixture/gen").build()
        self.assertEqual(client_names(doc, ir), {"testOperation": "edit_storage_bucket"})

    def test_header_bundle_is_one_alternative_and_ledger_pins_its_members(self):
        bundle = {"type": "x-moonbit-header-bundle", "headers": {"login": "X-Login", "key": "X-Key"},
                  "x-moonbit-auth-variant": "LegacyCredential"}
        token = {"type": "http", "scheme": "bearer", "x-moonbit-auth-variant": "ApiToken"}
        doc = document(operation())
        doc["components"]["securitySchemes"] = {"pair": bundle, "token": token}
        doc["security"] = [{"token": []}, {"pair": []}]
        choices, found = security_auth_choices(doc)
        self.assertTrue(found)
        self.assertEqual(choices, [scheme_auth(token), scheme_auth(bundle)])
        validate_auth({"kind": "alternatives", "schemes": choices}, "fixture")
        with self.assertRaises(ValueError):
            validate_auth({**choices[1], "headers": {"login": "X-Key", "key": "x-key"}}, "fixture")
        doc["security"] = [{"token": [], "pair": []}]
        with self.assertRaisesRegex(ValueError, "AND authentication"):
            security_auth_choices(doc)

    def test_retry_guard_requires_explicit_method_and_status_sets(self):
        validate_retry({"guard_response_retries": [{"methods": ["POST"], "statuses": [429]}]}, "fixture")
        with self.assertRaises(ValueError):
            validate_retry({"guard_response_retries": [{"methods": ["POST"], "statuses": []}]}, "fixture")

    def test_namespace_stripping_keeps_collisions_and_rewrites_recursive_refs(self):
        def ref(name):
            return {"$ref": f"#/components/schemas/{name}"}

        schemas = {
            "dns_Node": {"type": "object", "properties": {"child": ref("dns_Node")}},
            "dns_Shared": {"type": "object", "properties": {"left": {"type": "string"}}},
            "zones_Shared": {"type": "object", "properties": {"right": {"type": "string"}}},
            "dns_Named": {"type": "object", "properties": {"value": {"type": "string"}}, "x-moonbit-type-name": "DnsLabel"},
        }
        response = {"type": "array", "items": {"type": "object", "properties": {
            "dns_wire_name": ref("dns_Node"),
            "left": ref("dns_Shared"),
            "right": ref("zones_Shared"),
            "named": ref("dns_Named"),
        }}}
        for components in (schemas, dict(reversed(list(schemas.items())))):
            doc = document(operation(response=response), components)
            doc["x-moonbit-strip-type-prefixes"] = ["dns", "zones"]
            builder = IRBuilder(doc, "fixture/gen")
            ir = builder.build()
            self.assertEqual(set(item.name for item in ir.declarations),
                             {"Node", "DnsShared", "ZonesShared", "DnsLabel", "TestOperationResponseItem"})
            self.assertEqual(declaration(ir, "Node").fields[0].type, TypeRef("named", name="Node"))
            wire_field = declaration(ir, "TestOperationResponseItem").fields[0]
            self.assertEqual((wire_field.json_name, wire_field.type.name), ("dns_wire_name", "Node"))
            self.assertEqual([note.pointer for note in builder.notes if "type prefix kept" in note.message],
                             ["/components/schemas/dns_Shared", "/components/schemas/zones_Shared"])

    def test_envelope_only_declarations_are_pruned_and_nullable_result_survives(self):
        envelope = {"type": "object", "properties": {
            "result": {"type": "object", "nullable": True, "x-moonbit-type-name": "Payload",
                       "properties": {"id": {"type": "string"}}},
            "meta": {"$ref": "#/components/schemas/Metadata"},
        }}
        doc = document(operation(response={"$ref": "#/components/schemas/Envelope"}), {
            "Envelope": envelope,
            "Metadata": {"type": "object", "properties": {"page": {"type": "integer"}}},
        })
        doc["x-moonbit-envelope"] = {key: key for key in ("result", "success", "errors", "messages")}
        ir = IRBuilder(doc, "fixture/gen").build()
        self.assertEqual([item.name for item in ir.declarations], ["Payload"])
        self.assertEqual(ir.operations[0].response_type, TypeRef("optional", item=TypeRef("named", name="Payload")))
        self.assertIn('other => Option::Some(@json.from_json(other, path~))', emit(ir)["operations.mbt"])
        self.assertIn('fields.get("result").unwrap_or(@json.Json::null())', emit(ir)["operations.mbt"])
        envelope["required"] = ["result"]
        required = IRBuilder(doc, "fixture/gen").build()
        self.assertIn('@sdkjson.field(fields, "result", path)', emit(required)["operations.mbt"])

    def test_multipart_facade_labels_parts_and_stream_requires_selected_sse(self):
        op = operation(request_content={"multipart/form-data": {"schema": {
            "type": "object", "required": ["file"], "properties": {
                "file": {"type": "string", "x-moonbit-parameter-name": "zone_file"},
            },
        }}})
        doc = document(op)
        sdk = {"name": "fixture", "dir": "fixture", "out": "fixture/src/gen", "module": "example/fixture",
               "auth": {"kind": "none"}, "base_url": "https://fixture.example"}
        ir = IRBuilder(doc, "example/fixture/gen", auto_multipart_boundary=True).build()
        vocabulary = emit(ir)["operations.mbt"]
        self.assertIn('Part::text("file", parameter_value(zone_file))', vocabulary)
        self.assertIn("multipart_conflicts_(bytes, prefix, conflicts)", vocabulary)
        files = emit_client(doc, ir, sdk)
        self.assertIn("zone_file~ : String", files["operations_gen.mbt"])
        self.assertNotIn("boundary :", files["operations_gen.mbt"])
        self.assertNotIn("Fixture::stream(", files["client_gen.mbt"])
        self.assertNotIn("gaato/mttp_core/sse", files["moon.pkg"])
        self.assertIn("Fixture::stream(", emit_client(doc, ir, {**sdk, "legacy_generic_stream": True})["client_gen.mbt"])
        op["responses"]["200"]["content"]["text/event-stream"] = {}
        self.assertIn("Fixture::stream(", emit_client(doc, ir, sdk)["client_gen.mbt"])
