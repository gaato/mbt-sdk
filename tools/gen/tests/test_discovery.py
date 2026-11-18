"""Google Discovery adapter tests use small inline documents and offline clients."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

from tools.gen.census import census
from tools.gen.client_layer import emit_client
from tools.gen.discovery import convert_discovery, convert_schema, watch_equal
from tools.gen.emit_moonbit import emit
from tools.gen.ir import IRBuilder, include_all_operations
from tools.gen.main import _format, _write
from tools.gen.normalize import normalize_spec
from tools.gen.diagnostics import GenerationError


def schema_fixture():
    return {
        "kind": "discovery#restDescription",
        "discoveryVersion": "v1",
        "name": "demo",
        "version": "v1",
        "revision": "20261116",
        "rootUrl": "https://api.example/",
        "servicePath": "",
        "parameters": {
            "key": {"type": "string", "location": "query"},
            "fields": {"type": "string", "location": "query"},
        },
        "schemas": {
            "Payload": {
                "type": "object",
                "properties": {
                    "signed": {"type": "string", "format": "int64"},
                    "unsigned": {"type": "string", "format": "uint64"},
                    "mode": {
                        "type": "string",
                        "enum": ["FAST", "SAFE"],
                        "enumDescriptions": ["Fast mode.", "Safe mode."],
                        "readOnly": True,
                        "annotations": {"required": ["demo.models.generateContent"]},
                    },
                    "metadata": {
                        "type": "object",
                        "additionalProperties": {"type": "any"},
                    },
                },
                "required": ["signed", "unsigned"],
            },
            "Envelope": {
                "type": "object",
                "properties": {
                    "payload": {"$ref": "Payload", "description": "Wrapped payload."}
                },
            },
        },
        "resources": {
            "models": {
                "methods": {
                    "generateContent": {
                        "id": "demo.models.generateContent",
                        "path": "v1/{+name}:generateContent",
                        "httpMethod": "POST",
                        "parameterOrder": ["name"],
                        "parameters": {
                            "name": {
                                "type": "string",
                                "location": "path",
                                "required": True,
                            },
                            "labels": {
                                "type": "string",
                                "location": "query",
                                "repeated": True,
                            },
                        },
                        "request": {"$ref": "Payload"},
                        "response": {"$ref": "Envelope"},
                    },
                    "streamGenerateContent": {
                        "id": "demo.models.streamGenerateContent",
                        "path": "v1/{+name}:streamGenerateContent",
                        "httpMethod": "POST",
                        "parameters": {
                            "name": {"type": "string", "location": "path", "required": True}
                        },
                        "request": {"$ref": "Payload"},
                        "response": {"$ref": "Envelope"},
                    },
                    "upload": {
                        "id": "demo.models.upload",
                        "path": "v1/files",
                        "httpMethod": "POST",
                        "supportsMediaUpload": True,
                        "mediaUpload": {"protocols": {"resumable": {"path": "/upload/v1/files"}}},
                        "supportsMediaDownload": True,
                    },
                },
                "resources": {
                    "operations": {
                        "methods": {
                            "get": {
                                "id": "demo.models.operations.get",
                                "flatPath": "v1/models/{modelsId}/operations/{operationsId}",
                                "path": "v1/{+name}",
                                "httpMethod": "GET",
                                "parameterOrder": ["name"],
                                "parameters": {
                                    "name": {
                                        "type": "string",
                                        "location": "path",
                                        "required": True,
                                        "pattern": "^models/[^/]+/operations/[^/]+$",
                                    },
                                },
                                "response": {"$ref": "Envelope"},
                            }
                        }
                    }
                },
            }
        },
    }


def integer_wire_fixture():
    return {
        "kind": "discovery#restDescription",
        "discoveryVersion": "v1",
        "name": "wire",
        "version": "v1",
        "rootUrl": "https://api.example/",
        "servicePath": "",
        "schemas": {
            "WirePayload": {
                "type": "object",
                "properties": {
                    "signedValues": {
                        "type": "array",
                        "items": {"type": "string", "format": "int64"},
                    },
                    "unsignedByName": {
                        "type": "object",
                        "additionalProperties": {
                            "type": "string",
                            "format": "uint64",
                        },
                    },
                    "nested": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "additionalProperties": {
                                "type": "array",
                                "items": {"type": "string", "format": "int64"},
                            },
                        },
                    },
                },
                "required": ["signedValues", "unsignedByName", "nested"],
            },
        },
        "resources": {
            "numbers": {
                "methods": {
                    "scalar": {
                        "id": "wire.numbers.scalar",
                        "path": "v1/scalar",
                        "httpMethod": "POST",
                        "request": {"type": "string", "format": "int64"},
                        "response": {"type": "string", "format": "int64"},
                    },
                    "nested": {
                        "id": "wire.numbers.nested",
                        "path": "v1/nested",
                        "httpMethod": "POST",
                        "parameterOrder": ["limit"],
                        "parameters": {
                            "limit": {
                                "type": "string",
                                "format": "uint64",
                                "location": "query",
                                "required": True,
                            },
                        },
                        "request": {"$ref": "WirePayload"},
                        "response": {"$ref": "WirePayload"},
                    },
                },
            },
        },
    }


def _install_and_test(root: Path):
    installed = subprocess.run(
        ["moon", "-C", str(root), "update"],
        text=True,
        capture_output=True,
    )
    if installed.returncode != 0:
        return installed
    return subprocess.run(
        ["moon", "-C", str(root), "test", "--target", "wasm-gc", "--deny-warn"],
        text=True,
        capture_output=True,
    )


class DiscoveryAdapterTests(unittest.TestCase):
    def test_annotated_optional_recursive_reference_keeps_reference_edge(self):
        raw = integer_wire_fixture()
        raw['schemas'] = {'Node': {'type': 'object', 'properties': {
            'child': {'$ref': 'Node', 'annotations': {'required': ['wire.numbers.scalar']}},
        }}}
        raw['resources']['numbers']['methods'] = {'scalar': {
            'id': 'wire.numbers.scalar', 'path': 'node', 'httpMethod': 'GET',
            'response': {'$ref': 'Node'},
        }}
        for description in (None, 'Optional recursive child.'):
            with self.subTest(description=description):
                child = raw['schemas']['Node']['properties']['child']
                if description is not None:
                    child['description'] = description
                doc = convert_discovery(raw)
                converted = doc['components']['schemas']['Node']['properties']['child']
                self.assertEqual(converted['$ref'], '#/components/schemas/Node')
                self.assertEqual(converted['x-moonbit-required'], ['wire.numbers.scalar'])
                self.assertNotIn('allOf', converted)
                include_all_operations(doc)
                ir = IRBuilder(doc, 'gaato/demo/gen').build()
                node = next(item for item in ir.declarations if item.name == 'Node')
                self.assertEqual(node.fields[0].type.moon_type(), 'Node')
                self.assertEqual(node.fields[0].presence.value, 'optional')

    def test_schema_refs_docs_any_required_and_integer_extensions(self):
        doc = convert_discovery(schema_fixture())
        payload = doc["components"]["schemas"]["Payload"]
        self.assertEqual(payload["properties"]["signed"]["x-moonbit-int-string"], "int64")
        self.assertEqual(payload["properties"]["unsigned"]["x-moonbit-int-string"], "uint64")
        self.assertTrue(payload["properties"]["metadata"]["additionalProperties"]["x-moonbit-json"])
        mode = payload["properties"]["mode"]
        self.assertTrue(mode["readOnly"])
        self.assertEqual(mode["x-moonbit-required"], ["demo.models.generateContent"])
        self.assertIn("FAST: Fast mode.", mode["description"])
        wrapped = doc["components"]["schemas"]["Envelope"]["properties"]["payload"]
        self.assertEqual(wrapped["allOf"][0]["$ref"], "#/components/schemas/Payload")
        self.assertEqual(wrapped["description"], "Wrapped payload.")

    def test_nested_naming_canonical_path_repeated_globals_auth_and_media_notes(self):
        doc = convert_discovery(schema_fixture())
        flat = doc["paths"]["/v1/{name}"]["get"]
        self.assertEqual(flat["operationId"], "models_operations_get")
        self.assertEqual(
            [item["name"] for item in flat["parameters"]],
            ["name"],
        )
        self.assertEqual(flat["parameters"][0]["schema"]["pattern"], "^models/[^/]+/operations/[^/]+$")
        generate = doc["paths"]["/v1/{name}:generateContent"]["post"]
        self.assertEqual(generate["operationId"], "models_generate_content")
        self.assertTrue(generate["parameters"][0]["x-moonbit-path-segments"])
        self.assertEqual(generate["parameters"][1]["schema"]["type"], "array")
        self.assertTrue(generate["parameters"][1]["explode"])
        self.assertEqual({item["name"] for item in generate["parameters"]}, {"name", "labels"})
        schemes = doc["components"]["securitySchemes"]
        self.assertEqual(list(schemes), ["ApiKey", "ApiKeyInQuery"])
        self.assertEqual(schemes["ApiKey"]["name"], "x-goog-api-key")
        self.assertEqual(doc["security"][0], {"ApiKey": []})
        upload = doc["paths"]["/v1/files"]["post"]
        self.assertIn("resumable", upload["x-moonbit-media-upload"]["protocols"])
        self.assertTrue(upload["x-moonbit-media-download"])
        include_all_operations(doc)
        builder = IRBuilder(doc, "gaato/demo/gen")
        builder.build()
        self.assertEqual(sum("media upload" in note.message for note in builder.notes), 1)
        self.assertEqual(sum("media download" in note.message for note in builder.notes), 1)

    def test_optional_global_parameters_are_census_notes_and_method_overrides_survive(self):
        raw = schema_fixture()
        method = raw["resources"]["models"]["methods"]["generateContent"]
        method["parameters"]["fields"] = {
            "type": "string",
            "location": "query",
            "description": "Method override.",
        }
        converted = convert_discovery(raw)
        operation = converted["paths"]["/v1/{name}:generateContent"]["post"]
        self.assertEqual(
            [item["name"] for item in operation["parameters"]],
            ["name", "labels", "fields"],
        )
        self.assertEqual(operation["parameters"][-1]["description"], "Method override.")

        with tempfile.TemporaryDirectory() as tmp:
            spec = Path(tmp) / "discovery.json"
            spec.write_text(json.dumps(raw), encoding="utf-8")
            notes = census(spec, "demo").notes
        self.assertTrue(any(
            note["pointer"] == "/parameters"
            and "fields" in note["message"]
            and "key" in note["message"]
            and "operation signatures" in note["message"]
            for note in notes
        ))

    def test_required_non_auth_global_parameter_is_a_pointer_diagnostic(self):
        raw = schema_fixture()
        raw["parameters"]["fields"]["required"] = True
        with self.assertRaises(GenerationError) as caught:
            convert_discovery(raw)
        self.assertEqual(len(caught.exception.diagnostics), 1)
        self.assertEqual(caught.exception.diagnostics[0].pointer, "/parameters/fields")
        self.assertIn(
            "required Discovery top-level parameter",
            caught.exception.diagnostics[0].reason,
        )

    def test_path_uses_spec_parameter_names_despite_flat_path(self):
        raw = schema_fixture()
        method = raw["resources"]["models"]["methods"]["generateContent"]
        method["path"] = "v1/{parent}/items/{item}"
        method["flatPath"] = "v1/parents/{parentsId}/items/{itemsId}"
        method["parameterOrder"] = ["parent", "item"]
        # Reversed object insertion order must not swap the template's arguments.
        method["parameters"] = {
            "item": {"type": "string", "location": "path", "description": "ITEM"},
            "parent": {"type": "string", "location": "path", "description": "PARENT"},
        }
        operation = convert_discovery(raw)["paths"]["/v1/{parent}/items/{item}"]["post"]
        self.assertEqual([item["name"] for item in operation["parameters"]], ["parent", "item"])
        self.assertEqual([item["description"] for item in operation["parameters"]], ["PARENT", "ITEM"])

    def test_oauth_scopes_become_per_method_security_and_documentation(self):
        raw = schema_fixture()
        scope = "https://www.googleapis.com/auth/example.read"
        raw["auth"] = {"oauth2": {"scopes": {scope: {"description": "Read examples."}}}}
        raw["resources"]["models"]["methods"]["generateContent"]["scopes"] = [scope]
        doc = convert_discovery(raw)
        oauth = doc["components"]["securitySchemes"]["OAuthToken"]
        self.assertEqual(oauth["type"], "oauth2")
        self.assertEqual(oauth["flows"]["authorizationCode"]["scopes"][scope], "Read examples.")
        generate = doc["paths"]["/v1/{name}:generateContent"]["post"]
        self.assertEqual(generate["security"], [
            {"ApiKey": []},
            {"ApiKeyInQuery": []},
            {"OAuthToken": [scope]},
        ])
        self.assertIn(f"OAuth scope `{scope}`: Read examples.", generate["description"])
        include_all_operations(doc)
        ir = IRBuilder(doc, "gaato/demo/gen", auth_headers={"x-goog-api-key"}).build()
        self.assertIn(f"OAuth scope `{scope}`: Read examples.", emit(ir)["operations.mbt"])
        client = emit_client(doc, ir, {
            "name": "demo", "dir": "demo", "module": "gaato/demo",
            "out": "demo/src/gen", "base_url": "https://api.example",
            "auth": {"kind": "alternatives", "schemes": [
                {"kind": "header", "name": "x-goog-api-key"},
                {"kind": "query", "name": "key"},
                {"kind": "bearer"},
            ]},
        })
        self.assertIn("OAuthToken(_) => true", "\n".join(client.values()))
        without_key = schema_fixture()
        without_key["parameters"].pop("key")
        without_key["auth"] = raw["auth"]
        without_key["resources"]["models"]["methods"]["generateContent"]["scopes"] = [scope]
        oauth_only = convert_discovery(without_key)
        self.assertEqual(
            oauth_only["paths"]["/v1/{name}:generateContent"]["post"]["security"],
            [{"OAuthToken": [scope]}],
        )

    def test_operation_string_integer_request_emits_its_helpers(self):
        doc = convert_discovery(integer_wire_fixture())
        include_all_operations(doc)
        sources = emit(IRBuilder(doc, "gaato/demo/gen").build())
        self.assertIn("fn json_string_int64_to_json", sources["types.mbt"])
        self.assertIn(
            ".body_json(json_string_int64_to_json(body))",
            sources["operations.mbt"],
        )

    def test_container_string_integer_codecs_are_recursive(self):
        doc = convert_discovery(integer_wire_fixture())
        include_all_operations(doc)
        sources = emit(IRBuilder(doc, "gaato/demo/gen").build())
        self.assertIn("json_custom_array_to_json(", sources["types.mbt"])
        self.assertIn("json_custom_map_to_json(", sources["types.mbt"])
        self.assertIn("decode_custom_array(", sources["types.mbt"])
        self.assertIn("decode_custom_map(", sources["types.mbt"])

    def test_uint64_facade_signature_uses_the_core_type(self):
        doc = convert_discovery(integer_wire_fixture())
        include_all_operations(doc)
        ir = IRBuilder(doc, "gaato/demo/gen").build()
        files = emit_client(doc, ir, {
            "name": "demo", "dir": "demo", "module": "gaato/demo",
            "out": "demo/src/gen", "base_url": "https://api.example",
            "auth": {"kind": "header", "name": "x-api-key"},
        })
        self.assertIn("limit~ : UInt64", files["operations_gen.mbt"])
        self.assertNotIn("@gen.UInt64", files["operations_gen.mbt"])

    def test_overlay_marks_typed_sse_and_header_auth(self):
        raw = schema_fixture()
        with tempfile.TemporaryDirectory() as tmp:
            spec = Path(tmp) / "discovery.json"
            overlay = Path(tmp) / "stream.yaml"
            spec.write_text(json.dumps(raw), encoding="utf-8")
            overlay.write_text(yaml.safe_dump({
                "overlay": "1.0.0",
                "info": {"title": "stream", "version": "1"},
                "actions": [{
                    "target": "$['paths']['/v1/{name}:streamGenerateContent']['post']",
                    "update": {"x-moonbit-stream": "sse"},
                }],
            }, sort_keys=False), encoding="utf-8")
            doc = normalize_spec(spec, [overlay])
        include_all_operations(doc)
        ir = IRBuilder(doc, "gaato/demo/gen", auth_headers={"x-goog-api-key"}).build()
        files = emit_client(doc, ir, {
            "name": "demo", "dir": "demo", "module": "gaato/demo",
            "out": "demo/src/gen", "base_url": "https://api.example",
            "auth": {"kind": "alternatives", "schemes": [
                {"kind": "header", "name": "x-goog-api-key"},
                {"kind": "query", "name": "key"},
            ]},
        })
        source = files["operations_gen.mbt"]
        self.assertIn("Demo::models_stream_generate_content(", source)
        self.assertIn("receive : async (@gen.Envelope) -> Unit", source)
        self.assertIn('.query("alt", "sse")', source)
        self.assertIn("models_stream_generate_content_decode(", source)
        self.assertIn("@utf8.encode(event.data)", source)
        self.assertIn('request.credential("x-goog-api-key", value)', files["client_gen.mbt"])

    def test_census_and_watch_and_version_rejection(self):
        raw = schema_fixture()
        with tempfile.TemporaryDirectory() as tmp:
            spec = Path(tmp) / "discovery.json"
            spec.write_text(json.dumps(raw), encoding="utf-8")
            result = census(spec, "demo")
            self.assertEqual(result.operations, 4)
            self.assertEqual(result.diagnostics, 0)
            self.assertEqual(result.discovery["schemas"], 2)
            swagger = Path(tmp) / "swagger.json"
            swagger.write_text('{"swagger":"2.0","paths":{}}')
            with self.assertRaisesRegex(GenerationError, "Swagger 2.0"):
                normalize_spec(swagger, [])
            other = Path(tmp) / "other.json"
            other.write_text('{"hello":"world"}')
            with self.assertRaisesRegex(GenerationError, "unsupported OpenAPI version"):
                normalize_spec(other, [])
        newer = json.loads(json.dumps(raw))
        newer.update(revision="20261117", etag="new")
        self.assertTrue(watch_equal(raw, newer, generator="discovery"))
        newer["schemas"]["Payload"]["description"] = "changed"
        self.assertFalse(watch_equal(raw, newer, generator="discovery"))


@unittest.skipUnless(shutil.which("moon"), "MoonBit toolchain is required for integration")
class DiscoveryGeneratedMoonTests(unittest.TestCase):
    def test_field_discriminated_oneof_round_trip(self):
        doc = convert_discovery(schema_fixture())
        doc['x-moonbit-nonraising-decoders'] = True
        doc['security'] = [{'ApiKey': []}]
        doc['components']['schemas'] = {
            'TextPart': {'type': 'object', 'properties': {'text': {'type': 'string'}, 'thoughtSignature': {'type': 'string'}}, 'required': ['text']},
            'FilePart': {'type': 'object', 'properties': {'fileData': {'type': 'string'}, 'thoughtSignature': {'type': 'string'}}, 'required': ['fileData']},
            'Part': {'oneOf': [{'$ref': '#/components/schemas/TextPart'}, {'$ref': '#/components/schemas/FilePart'}], 'x-moonbit-discriminator-fields': ['text', 'fileData']},
        }
        doc['paths'] = {'/part': {'post': {'operationId': 'part', 'requestBody': {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/Part'}}}}, 'responses': {'200': {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/Part'}}}}}}}}
        include_all_operations(doc)
        ir = IRBuilder(doc, 'gaato/demo/gen').build()
        with tempfile.TemporaryDirectory(prefix='field-oneof-') as tmp:
            root = Path(tmp)
            (root / 'moon.mod').write_text('name = "gaato/demo"\nversion = "0.1.0"\nsource = "src"\nimport { "gaato/mttp_core@0.3.0" }\n')
            _write(root / 'src/gen', _format(emit(ir)))
            _write(root / 'src', _format(emit_client(doc, ir, {
                'name': 'demo', 'dir': 'demo', 'module': 'gaato/demo',
                'out': 'demo/src/gen', 'base_url': 'https://api.example',
                'auth': {'kind': 'header', 'name': 'x-goog-api-key'},
            })))
            (root / 'src/callback_test.mbt').write_text('''///|
test "typed facade with a concrete nonraising decoder effect links externally" {
  let backend = @client.from_fn((_, _) => @http.Response::new(200, body=Bytes(b"{\\"text\\":\\"hello\\"}")))
  let sdk = @demo.Demo::new(backend, @sim.FakeClock::new())
  let body : @gen.Part = Text(@gen.TextPart::new(text="hello"))
  assert_true(@driver.run_sync(() => sdk.part(body)) is Ok(_))
}
''')
            (root / 'src/gen/part_wbtest.mbt').write_text('''///|
test "strict field oneof" {
  let part : Part = Text(TextPart::new(text="hello", thought_signature="c2ln"))
  assert_eq(Json(part), {"text": "hello", "thoughtSignature": "c2ln"})
  assert_eq(part_decode_json(Json(part)), part)
  let invalids : Array[Json] = [{}, {"text": "hello", "fileData": "uri"}, {"text": Json::null()}]
  for invalid in invalids {
    assert_true((try Some(part_decode_json(invalid)) catch { _ => None }) is None)
  }
}
''')
            process = _install_and_test(root)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_string_integer_missing_default(self):
        doc = convert_discovery(integer_wire_fixture())
        doc['components']['schemas'] = {'Defaults': {
            'type': 'object', 'required': ['values'], 'properties': {
                'values': {'type': 'array', 'items': {'type': 'string', 'x-moonbit-int-string': 'uint64'},
                           'default': [], 'x-moonbit-default-on-missing': True},
            },
        }}
        doc['paths'] = {'/defaults': {'get': {'operationId': 'defaults', 'responses': {
            '200': {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/Defaults'}}}},
        }}}}
        include_all_operations(doc)
        ir = IRBuilder(doc, 'gaato/demo/gen').build()
        with tempfile.TemporaryDirectory(prefix='discovery-default-') as tmp:
            root = Path(tmp)
            (root / 'moon.mod').write_text('name = "gaato/demo"\nversion = "0.1.0"\nsource = "src"\nimport { "gaato/mttp_core@0.3.0" }\n')
            _write(root / 'src/gen', _format(emit(ir)))
            (root / 'src/gen/default_wbtest.mbt').write_text('''///|
test "string integer array missing defaults and present validation" {
  assert_eq(defaults_decode_json({}).values, [])
  assert_eq(defaults_decode_json({ "values": ["18446744073709551615"] }).values, [18446744073709551615UL])
  assert_true((try Some(defaults_decode_json({ "values": ["bad"] })) catch { _ => None }) is None)
  assert_true((try Some(defaults_decode_json({ "values": Json::null() })) catch { _ => None }) is None)
}
''')
            process = _install_and_test(root)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_string_integer_error_contract_sample(self):
        from tools.gen.tests.test_client_layer import ledger
        doc = convert_discovery(integer_wire_fixture())
        doc['security'] = [{'bearer': []}]
        doc['components']['securitySchemes'] = {'bearer': {'type': 'http', 'scheme': 'bearer'}}
        doc['paths'] = {'/error': {'get': {'operationId': 'error', 'responses': {
            '200': {}, '429': {'content': {'application/json': {'schema': {
                'type': 'object', 'required': ['quota'], 'properties': {
                    'quota': {'type': 'string', 'x-moonbit-int-string': 'uint64'},
                },
            }}}},
        }}}}
        include_all_operations(doc)
        ir = IRBuilder(doc, 'gaato/sample/gen').build()
        with tempfile.TemporaryDirectory(prefix='discovery-error-sample-') as tmp:
            root = Path(tmp)
            (root / 'moon.mod').write_text('name = "gaato/sample"\nversion = "0.1.0"\nsource = "src"\nimport { "gaato/mttp_core@0.3.0" }\n')
            _write(root / 'src/gen', _format(emit(ir)))
            _write(root / 'src', _format(emit_client(doc, ir, ledger())))
            process = _install_and_test(root)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_custom_only_nullable_fields_pass_deny_warn(self):
        raw = integer_wire_fixture()
        raw['schemas'] = {'NullableNumber': {
            'type': 'object', 'properties': {
                'value': {'type': 'string', 'format': 'int64', 'nullable': True},
            }, 'required': ['value'],
        }}
        raw['resources']['numbers']['methods'] = {'scalar': {
            'id': 'wire.numbers.scalar', 'path': 'nullable', 'httpMethod': 'GET',
            'response': {'$ref': 'NullableNumber'},
        }}
        doc = convert_discovery(raw)
        include_all_operations(doc)
        ir = IRBuilder(doc, 'gaato/demo/gen').build()
        with tempfile.TemporaryDirectory(prefix='discovery-nullable-') as tmp:
            root = Path(tmp)
            (root / 'moon.mod').write_text(
                'name = "gaato/demo"\nversion = "0.1.0"\nsource = "src"\n'
                'import { "gaato/mttp_core@0.3.0" }\n')
            _write(root / 'src/gen', _format(emit(ir)))
            (root / 'src/gen/nullable_wbtest.mbt').write_text(r'''///|
test "custom-only required nullable string integer" {
  let null_value = numbers_scalar_decode_json({ "value": Json::null() })
  assert_eq(null_value.value, None)
  assert_eq(Json(null_value).stringify(), "{\"value\":null}")
  let value = numbers_scalar_decode_json({ "value": "16" })
  assert_eq(value.value, Some(16L))
  assert_eq(Json(value).stringify(), "{\"value\":\"16\"}")
}
''')
            check = subprocess.run(['moon', '-C', str(root), 'check', '--target', 'wasm-gc', '--deny-warn'], text=True, capture_output=True)
            self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
            process = _install_and_test(root)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_response_only_string_integer_codecs_are_strict(self):
        raw = integer_wire_fixture()
        raw['schemas'] = {}
        methods = {}
        tests = []
        for kind, literal in [('int64', '16L'), ('uint64', '16UL')]:
            scalar = {'type': 'string', 'format': kind}
            shapes = [
                ('scalar', scalar, 'Json::string(text)', literal),
                ('array', {'type': 'array', 'items': scalar}, 'Json::array([Json::string(text)])', '[' + literal + ']'),
                ('map', {'type': 'object', 'additionalProperties': scalar}, 'Json::object({ "value": Json::string(text) })', '{ "value": ' + literal + ' }'),
                ('nested', {'type': 'array', 'items': {'type': 'object', 'additionalProperties': scalar}}, 'Json::array([Json::object({ "value": Json::string(text) })])', '[{ "value": ' + literal + ' }]'),
            ]
            for shape, response, value, expected in shapes:
                name = kind + '_' + shape
                methods[name] = {'id': 'wire.numbers.' + name, 'path': name, 'httpMethod': 'GET', 'response': response}
                decode = 'numbers_' + name + '_decode'
                tests.append('''///|
test "strict response ''' + name + '''" {
  let head : @http.ResponseHead = { status: 201, headers: @http.Headers::of([("x-request-id", "strict-response")]) }
  let text = "16"
  let valid = ''' + value + '''
  assert_eq(''' + decode + '''_json(valid), ''' + expected + ''')
  assert_true(''' + decode + '''(head, @utf8.encode(valid.stringify())) is Ok(_))
  for text in ["0x10", "1_000"] {
    let invalid = ''' + value + '''
    try {
      ignore(''' + decode + '''_json(invalid))
    } catch {
      _ => ()
    } noraise {
      _ => fail("expected strict parsed-response failure")
    }
    let bytes = @utf8.encode(invalid.stringify())
    match ''' + decode + '''(head, bytes) {
      Err(@client.Deserialization(actual_head, body~, ..)) => {
        assert_eq(actual_head.status, 201)
        assert_eq(actual_head.headers.get("x-request-id"), Some("strict-response"))
        assert_eq(body, bytes)
      }
      _ => fail("expected strict buffered-response failure")
    }
  }
}
''')
        raw['resources']['numbers']['methods'] = methods
        doc = convert_discovery(raw)
        include_all_operations(doc)
        ir = IRBuilder(doc, 'gaato/demo/gen').build()
        with tempfile.TemporaryDirectory(prefix='discovery-response-') as tmp:
            root = Path(tmp)
            (root / 'moon.mod').write_text(
                'name = "gaato/demo"\nversion = "0.1.0"\nsource = "src"\n'
                'import { "gaato/mttp_core@0.3.0" }\n')
            _write(root / 'src/gen', _format(emit(ir)))
            (root / 'src/gen/response_wbtest.mbt').write_text('\n'.join(tests))
            process = _install_and_test(root)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_numeric_uint32_full_range_round_trip(self):
        raw = integer_wire_fixture()
        method = raw['resources']['numbers']['methods']['scalar']
        method['request'] = method['response'] = {'type': 'integer', 'format': 'uint32'}
        doc = convert_discovery(raw)
        doc['paths'] = {'/v1/scalar': doc['paths']['/v1/scalar']}
        include_all_operations(doc)
        ir = IRBuilder(doc, 'gaato/demo/gen').build()
        self.assertEqual(ir.operations[0].request_type.moon_type(), 'UInt32')
        self.assertEqual(ir.operations[0].response_type.moon_type(), 'UInt32')
        with tempfile.TemporaryDirectory(prefix='discovery-uint32-') as tmp:
            root = Path(tmp)
            (root / 'moon.mod').write_text(
                'name = "gaato/demo"\nversion = "0.1.0"\nsource = "src"\n'
                'import { "gaato/mttp_core@0.3.0" }\n')
            _write(root / 'src/gen', _format(emit(ir)))
            (root / 'src/gen/uint32_wbtest.mbt').write_text(r'''///|
test "Discovery uint32 keeps its full numeric range" {
  for value in [0U, 2147483648U, 4294967295U] {
    let request = numbers_scalar_request(value)
    let body = request.body.as_bytes().unwrap()
    assert_eq(@utf8.decode(body), value.to_string())
    assert_eq(numbers_scalar_decode_json(@json.parse(@utf8.decode(body))), value)
  }
}
''')
            process = _install_and_test(root)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_union_only_string_integer_helpers_and_round_trip(self):
        for kind in ('int64', 'uint64'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(prefix='discovery-union-') as tmp:
                raw = integer_wire_fixture()
                doc = convert_discovery(raw)
                doc['components']['schemas'] = {}
                method = doc['paths']['/v1/scalar']['post']
                union = {'oneOf': [convert_schema({'type': 'string', 'format': kind}), {'type': 'boolean'}]}
                method['requestBody']['content']['application/json']['schema'] = union
                method['responses']['200']['content']['application/json']['schema'] = union
                doc['paths'] = {'/v1/scalar': doc['paths']['/v1/scalar']}
                include_all_operations(doc)
                ir = IRBuilder(doc, 'gaato/demo/gen').build()
                root = Path(tmp)
                (root / 'moon.mod').write_text(
                    'name = "gaato/demo"\nversion = "0.1.0"\nsource = "src"\n'
                    'import { "gaato/mttp_core@0.3.0" }\n')
                _write(root / 'src/gen', _format(emit(ir)))
                response = ir.operations[0].response_type.moon_type()
                values = ['-9223372036854775808', '9223372036854775807'] if kind == 'int64' else ['0', '18446744073709551615']
                (root / 'src/gen/union_wbtest.mbt').write_text('''///|
test "union string integers retain wire encoding" {
  for text in ''' + json.dumps(values) + ''' {
    let wire = Json::string(text)
    let value : ''' + response + ''' = @json.from_json(wire)
    assert_eq(Json(value).stringify(), wire.stringify())
  }
  let value : ''' + response + ''' = @json.from_json(Json::boolean(true))
  assert_eq(Json(value).stringify(), "true")
}
''')
                process = _install_and_test(root)
                self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_reserved_path_and_string_integer_round_trip_and_failures(self):
        doc = convert_discovery(schema_fixture())
        doc['components']['schemas']['Payload']['properties']['count'] = convert_schema(
            {'type': 'integer', 'format': 'uint32'})
        # Keep the executable fixture narrow while exercising both request and codecs.
        doc["paths"] = {"/v1/{name}:generateContent": doc["paths"]["/v1/{name}:generateContent"]}
        include_all_operations(doc)
        ir = IRBuilder(doc, "gaato/demo/gen").build()
        with tempfile.TemporaryDirectory(prefix="discovery-gen-") as tmp:
            root = Path(tmp)
            (root / "moon.mod").write_text(
                'name = "gaato/demo"\nversion = "0.1.0"\nsource = "src"\n'
                'import { "gaato/mttp_core@0.3.0" }\n',
                encoding="utf-8",
            )
            _write(root / "src/gen", _format(emit(ir)))
            (root / "src/gen/discovery_wbtest.mbt").write_text(r'''///|
fn assert_payload_decode_fails(text : String) -> Unit raise {
  try {
    let _value : Payload = @json.from_json(@json.parse(text))
  } catch {
    _ => ()
  } noraise {
    _ => fail("expected string-integer decode failure")
  }
}

///|
test "reserved path and Discovery string integers" {
  let payload = Payload::new(
    signed=-9223372036854775808L,
    unsigned=18446744073709551615UL,
    count=4294967295U,
  )
  let request = models_generate_content_request(
    "models/team/gemini-x",
    payload,
  )
  assert_eq(request.url, "/v1/models/team/gemini-x:generateContent")
  let encoded = Json(payload).stringify()
  assert_eq(
    encoded,
    "{\"signed\":\"-9223372036854775808\",\"unsigned\":\"18446744073709551615\",\"count\":4294967295}",
  )
  let decoded : Payload = @json.from_json(@json.parse(encoded))
  assert_eq(decoded.signed, -9223372036854775808L)
  assert_eq(decoded.unsigned, 18446744073709551615UL)
  assert_eq(decoded.count, Some(4294967295U))
  assert_payload_decode_fails("{\"signed\":1,\"unsigned\":\"0\"}")
  assert_payload_decode_fails("{\"signed\":\"nope\",\"unsigned\":\"0\"}")
  assert_payload_decode_fails("{\"signed\":\"9223372036854775808\",\"unsigned\":\"0\"}")
  assert_payload_decode_fails("{\"signed\":\"0\",\"unsigned\":\"-1\"}")
  assert_payload_decode_fails("{\"signed\":\"0\",\"unsigned\":\"18446744073709551616\"}")
}
''', encoding="utf-8")
            process = _install_and_test(root)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_typed_sse_facade_preserves_decode_failure_head(self):
        doc = convert_discovery(schema_fixture())
        stream_path = "/v1/{name}:streamGenerateContent"
        doc["paths"] = {stream_path: doc["paths"][stream_path]}
        doc["paths"][stream_path]["post"]["x-moonbit-stream"] = "sse"
        include_all_operations(doc)
        ir = IRBuilder(doc, "gaato/demo/gen", auth_headers={"x-goog-api-key"}).build()
        client = emit_client(doc, ir, {
            "name": "demo", "dir": "demo", "module": "gaato/demo",
            "out": "demo/src/gen", "base_url": "https://api.example",
            "auth": {"kind": "alternatives", "schemes": [
                {"kind": "header", "name": "x-goog-api-key"},
                {"kind": "query", "name": "key"},
            ]},
        })
        with tempfile.TemporaryDirectory(prefix="discovery-client-") as tmp:
            root = Path(tmp)
            (root / "moon.mod").write_text(
                'name = "gaato/demo"\nversion = "0.1.0"\nsource = "src"\n'
                'import { "gaato/mttp_core@0.3.0" }\n',
                encoding="utf-8",
            )
            _write(root / "src/gen", _format(emit(ir)))
            _write(root / "src", _format(client))
            (root / 'src/sse_wbtest.mbt').write_text(r'''///|
test "typed SSE failures preserve response status headers and event bytes" {
  let backend = @client.from_fn((_, _) => @http.Response::new(
    201,
    headers=@http.Headers::of([("x-request-id", "stream-request")]),
    body=Bytes(b"data: nope\n\n"),
  ))
  let sdk = Demo::new(backend, @sim.FakeClock::new(), auth=ApiKey("test"))
  let payload = @gen.Payload::new(signed=0L, unsigned=0UL)
  match @driver.run_sync(() => sdk.models_stream_generate_content(
    name="models/demo", payload, _ => fail("unexpected event"),
  )) {
    Err(Decode(@client.Deserialization(head, body~, ..))) => {
      assert_eq(head.status, 201)
      assert_eq(head.headers.get("x-request-id"), Some("stream-request"))
      assert_eq(body, b"nope")
    }
    _ => fail("expected SSE decode failure")
  }
}
''')
            process = _install_and_test(root)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_operation_and_recursive_string_integer_codecs_compile_and_run(self):
        doc = convert_discovery(integer_wire_fixture())
        include_all_operations(doc)
        ir = IRBuilder(doc, "gaato/demo/gen").build()
        client = emit_client(doc, ir, {
            "name": "demo", "dir": "demo", "module": "gaato/demo",
            "out": "demo/src/gen", "base_url": "https://api.example",
            "auth": {"kind": "header", "name": "x-api-key"},
        })
        with tempfile.TemporaryDirectory(prefix="discovery-wire-") as tmp:
            root = Path(tmp)
            (root / "moon.mod").write_text(
                'name = "gaato/demo"\nversion = "0.1.0"\nsource = "src"\n'
                'import { "gaato/mttp_core@0.3.0" }\n',
                encoding="utf-8",
            )
            _write(root / "src/gen", _format(emit(ir)))
            _write(root / "src", _format(client))
            (root / "src/gen/discovery_wire_wbtest.mbt").write_text(r'''///|
test "operation and recursive Discovery string integers" {
  let scalar = numbers_scalar_request(-9223372036854775808L)
  assert_eq(
    @utf8.decode(scalar.body.as_bytes().unwrap()),
    "\"-9223372036854775808\"",
  )
  assert_eq(
    numbers_scalar_decode_json(Json::string("9223372036854775807")),
    9223372036854775807L,
  )
  let payload = WirePayload::new(
    signed_values=[-9223372036854775808L, 9223372036854775807L],
    unsigned_by_name={ "max": 18446744073709551615UL },
    nested=[{ "deep": [-1L, 2L] }],
  )
  let encoded = Json(payload).stringify()
  assert_eq(
    encoded,
    "{\"signedValues\":[\"-9223372036854775808\",\"9223372036854775807\"],\"unsignedByName\":{\"max\":\"18446744073709551615\"},\"nested\":[{\"deep\":[\"-1\",\"2\"]}]}",
  )
  let decoded : WirePayload = @json.from_json(@json.parse(encoded))
  assert_eq(decoded.signed_values[0], -9223372036854775808L)
  assert_eq(decoded.unsigned_by_name["max"], 18446744073709551615UL)
  assert_eq(decoded.nested[0]["deep"], [-1L, 2L])
  let request = numbers_nested_request(18446744073709551615UL, payload)
  assert_eq(request.url, "/v1/nested?limit=18446744073709551615")
  assert_eq(@utf8.decode(request.body.as_bytes().unwrap()), encoded)
}
''', encoding="utf-8")
            process = _install_and_test(root)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)


if __name__ == "__main__":
    unittest.main()
