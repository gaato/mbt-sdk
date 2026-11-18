"""Measurement-derived failures: exercise generated code, not only the IR."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from tools.gen.census import census
from tools.gen.diagnostics import GenerationError
from tools.gen.emit_moonbit import emit
from tools.gen.ir import IRBuilder, Presence, RESERVED_TYPES, TaggedUnion, type_name
from tools.gen.main import _format, _write
from tools.gen.normalize import merge_all_of
from test_generator import document, operation


class F8RobustnessTests(unittest.TestCase):
    def sample(self, doc, source, *, executable=False):
        ir = IRBuilder(doc, 'gaato/sample/gen').build()
        files = emit(ir)
        if not executable:
            files['regression_wbtest.mbt'] = source
        with tempfile.TemporaryDirectory(prefix='f8-shapes-') as directory:
            root = Path(directory)
            (root / 'moon.mod').write_text('name = "gaato/sample"\nversion = "0.1.0"\nsource = "src"\nimport { "gaato/mttp_core@0.3.0" }\n')
            _write(root / 'src/gen', _format(files))
            if executable:
                (root / 'src/main').mkdir()
                (root / 'src/main/moon.pkg').write_text('import { "gaato/sample/gen", "moonbitlang/core/json" }\noptions("is-main": true)\n')
                (root / 'src/main/main.mbt').write_text(source)
            for args in [['update'], ['check', '--target', 'wasm-gc', '--deny-warn'],
                         ['run', 'src/main', '--target', 'wasm-gc'] if executable else ['test', '--target', 'wasm-gc', '--deny-warn']]:
                result = subprocess.run(['moon', '-C', directory, *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return ir

    def test_builtin_type_names_remain_legal_and_unrenamed(self):
        schemas = {name: {'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text']}
                   for name in ['Json', 'Result', 'None', 'Some', 'Ok', 'Err', 'Map', 'Ref', *sorted(RESERVED_TYPES)]}
        doc = document(operation(response={'type': 'object', 'properties': {
            name.lower(): {'$ref': '#/components/schemas/' + name} for name in schemas},
            'required': ['json', 'result']}), schemas)
        ir = self.sample(doc, '''///|
test "builtin type names" {
  let value : TestOperationResponse = @json.from_json({ "json": { "text": "j" }, "result": { "text": "r" } })
  assert_eq(value.json.text, "j")
  assert_eq(value.result.text, "r")
}
''')
        self.assertTrue({type_name(name) for name in schemas}.issubset({d.name for d in ir.declarations}))

    def test_legal_array_type_compiles_and_runs_in_external_consumer(self):
        # The pinned moon test driver itself imports a package's Array name
        # without qualification. An executable tests our emitted library while
        # keeping that unrelated compiler-generated driver out of the program.
        doc = document(operation(response={'$ref': '#/components/schemas/Array'}), {
            'Array': {'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text']}})
        self.sample(doc, '''///|
fn main raise {
  let value : @gen.Array = @json.from_json({ "text": "array" })
  assert_eq(value.text, "array")
}
''', executable=True)

    def test_keyword_fields_and_url_parameter_compile_and_execute(self):
        schema = {'type': 'object', 'properties': {name: {'type': 'string'} for name in ['true', 'false', '~', '', '1st']},
                  'required': ['true', 'false', '~', '', '1st']}
        doc = document(operation(response=schema, parameters=[
            {'name': 'url', 'in': 'query', 'required': True, 'schema': {'type': 'string'}},
            {'name': 'request', 'in': 'header', 'schema': {'type': 'string'}},
        ]))
        self.sample(doc, '''///|
test "invalid identifiers and url local" {
  let wire : Json = { "true": "t", "false": "f", "~": "tilde", "": "empty", "1st": "first" }
  let decoded : TestOperationResponse = @json.from_json(wire)
  assert_eq(decoded.true_, "t")
  assert_eq(decoded.false_, "f")
  assert_eq(decoded.to_json(), wire)
  assert_eq(test_operation_request("example", request="header").url, "/test?url=example")
}
''')

    def test_cyclic_allof_is_a_diagnostic_in_census_and_generation(self):
        doc = document(operation(response={'$ref': '#/components/schemas/Cycle'}), {
            'Cycle': {'allOf': [{'$ref': '#/components/schemas/Cycle'}, {'type': 'object', 'properties': {'id': {'type': 'string'}}}]}})
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(doc, 'gaato/sample/gen').build()
        self.assertIn('cyclic allOf', str(caught.exception))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'spec.json'
            path.write_text(json.dumps(doc))
            self.assertGreater(census(path, 'cycle').diagnostics, 0)

    def test_nonobject_allof_wrapper_keeps_documentation(self):
        schemas = {'Strings': {'type': 'array', 'items': {'type': 'string'}}}
        wrapper = {'allOf': [{'$ref': '#/components/schemas/Strings'}], 'description': 'Failure details.', 'example': ['x']}
        doc = document(operation(response={'type': 'object', 'properties': {'errors': wrapper}, 'required': ['errors']}), schemas)
        diagnostics = []
        normalized = merge_all_of(doc['paths']['/test']['post']['responses']['200']['content']['application/json']['schema'], '/schema', doc, diagnostics)
        self.assertEqual(diagnostics, [])
        self.assertEqual(normalized['properties']['errors']['description'], 'Failure details.')
        self.assertEqual(normalized['properties']['errors']['type'], 'array')
        self.sample(doc, '''///|
test "array allOf wrapper" {
  let value : TestOperationResponse = @json.from_json({ "errors": ["a", "b"] })
  assert_eq(value.errors, ["a", "b"])
}
''')

    def test_form_explode_false_arrays_join_once_and_escape(self):
        params = [{'name': name, 'in': 'query', 'required': required, 'style': 'form', 'explode': False,
                   'schema': {'type': 'array', 'items': {'type': 'string'}}} for name, required in [('ids', True), ('optional', False)]]
        self.sample(document(operation(parameters=params)), '''///|
test "comma joined arrays" {
  assert_eq(test_operation_request(["a", "b"]).url, "/test?ids=a%2Cb")
  assert_eq(test_operation_request([], optional=["x y", "z"]).url, "/test?ids=&optional=x%20y%2Cz")
}
''')

    def test_nullable_single_ref_unions_compile_and_round_trip(self):
        ref = {'$ref': '#/components/schemas/Item'}
        properties = {}
        for key in ('anyOf', 'oneOf'):
            properties[key + '_single'] = {key: [ref], 'nullable': True}
            properties[key + '_null'] = {key: [ref, {'type': 'null'}]}
            properties[key + '_marker'] = {key: [ref, {'nullable': True}]}
        doc = document(operation(response={'type': 'object', 'properties': properties, 'required': list(properties)}), {
            'Item': {'type': 'object', 'properties': {'id': {'type': 'string'}}, 'required': ['id']}})
        ir = self.sample(doc, '''///|
test "nullable single ref" {
  let wire : Json = { "anyOf_single": null, "anyOf_null": { "id": "a" }, "anyOf_marker": null,
                     "oneOf_single": { "id": "b" }, "oneOf_null": null, "oneOf_marker": null }
  let value : TestOperationResponse = @json.from_json(wire)
  assert_eq(value.to_json(), wire)
}
''')
        response = next(d for d in ir.declarations if d.name == 'TestOperationResponse')
        self.assertTrue(all(f.presence == Presence.NULLABLE_REQUIRED for f in response.fields))

    def test_nullable_single_ref_with_explicit_discriminator_keeps_public_union(self):
        schema = {'type': 'object', 'properties': {'prediction': {
            'anyOf': [{'$ref': '#/components/schemas/PredictionContent'}], 'nullable': True,
            'discriminator': {'propertyName': 'kind', 'mapping': {'content': '#/components/schemas/PredictionContent'}},
        }}}
        doc = document(operation(response=schema), {'PredictionContent': {
            'type': 'object', 'properties': {'kind': {'type': 'string', 'enum': ['content']}, 'id': {'type': 'string'}},
            'required': ['kind', 'id']}})
        ir = self.sample(doc, '''///|
test "explicit discriminator retains the wrapper" {
  let wire : Json = { "prediction": { "kind": "content", "id": "x" } }
  let value : TestOperationResponse = @json.from_json(wire)
  assert_eq(value.to_json(), wire)
}
''')
        wrapper = next(d for d in ir.declarations if d.name == 'TestOperationResponsePrediction')
        self.assertIsInstance(wrapper, TaggedUnion)

    def test_raw_json_nullable_ref_array_keeps_json_null_values(self):
        ref = {'$ref': '#/components/schemas/Item'}
        properties = {}
        for key in ('anyOf', 'oneOf'):
            for suffix, choices, nullable in [('single', [ref], True),
                                              ('null', [ref, {'type': 'null'}], False),
                                              ('marker', [ref, {'nullable': True}], False)]:
                properties[key + '_' + suffix] = {'type': 'array', 'items': {
                    key: choices, 'nullable': nullable, 'x-moonbit-json': True}}
        doc = document(operation(response={'type': 'object', 'properties': properties,
                                           'required': list(properties)}), {
            'Item': {'type': 'object', 'properties': {'id': {'type': 'string'}}, 'required': ['id']}})
        ir = self.sample(doc, '''///|
test "raw JSON nullable ref array" {
  let wire : Json = { "anyOf_single": [null, { "arbitrary": 1 }], "anyOf_null": [null],
                     "anyOf_marker": [null], "oneOf_single": [null], "oneOf_null": [null],
                     "oneOf_marker": [null] }
  let value : TestOperationResponse = @json.from_json(wire)
  let items : Array[Json] = value.any_of_single
  let json_null : Json = null
  assert_eq(items[0], json_null)
  assert_eq(value.to_json(), wire)
}
''')
        response = next(d for d in ir.declarations if d.name == 'TestOperationResponse')
        self.assertTrue(all(f.type.moon_type() == 'Array[Json]' for f in response.fields))
