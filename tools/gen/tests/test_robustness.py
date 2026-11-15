from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from tools.gen.census import census
from tools.gen.diagnostics import GenerationError
from tools.gen.emit_moonbit import emit
from tools.gen.ir import IRBuilder
from tools.gen.normalize import normalize_spec
from test_generator import document, operation


class RobustnessTests(unittest.TestCase):
    def measure(self, doc):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'spec.json'
            path.write_text(json.dumps(doc))
            return census(path, 'inline')

    def diagnostics(self, doc):
        with self.assertRaises(GenerationError) as caught:
            IRBuilder(doc, 'example/gen').build()
        self.assertTrue(all(d.pointer.startswith('/') for d in caught.exception.diagnostics))
        self.assertGreater(self.measure(doc).diagnostics, 0)
        return str(caught.exception)

    def test_recursive_array_union_is_diagnosed(self):
        schema = {'anyOf': [{'type': 'string'}, {'type': 'array', 'items': {'$ref': '#/components/schemas/Recursive'}}, {'type': 'null'}]}
        doc = document(operation(request={'$ref': '#/components/schemas/Recursive'}), {'Recursive': schema})
        self.assertIn('/components/schemas/Recursive/anyOf', self.diagnostics(doc))

    def test_recursive_array_alias_is_diagnosed(self):
        doc = document(operation(request={'$ref': '#/components/schemas/Recursive'}), {
            'Recursive': {'type': 'array', 'items': {'$ref': '#/components/schemas/Recursive'}}})
        self.assertIn('recursive type alias', self.diagnostics(doc))

    def test_recursive_object_remains_supported(self):
        doc = document(operation(response={'$ref': '#/components/schemas/Node'}), {
            'Node': {'type': 'object', 'properties': {'children': {'type': 'array', 'items': {'$ref': '#/components/schemas/Node'}}}}})
        files = emit(IRBuilder(doc, 'example/gen').build())
        self.assertIn('Array[Node]', files['types.mbt'])
        self.assertEqual(self.measure(doc).diagnostics, 0)

    def test_missing_refs_and_mapping_targets_have_pointers(self):
        for schema, expected in [
            ({'$ref': '#/components/schemas/Missing'}, '/schema/$ref'),
            ({'$ref': '#/$defs/Missing'}, '/schema/$ref'),
            ({'oneOf': [{'type': 'object'}], 'discriminator': {'propertyName': 'kind', 'mapping': {'missing': '#/components/schemas/Missing'}}}, '/schema/discriminator/mapping/missing'),
        ]:
            with self.subTest(schema=schema):
                self.assertIn(expected, self.diagnostics(document(operation(request=schema))))

    def test_embedded_defs_are_explicitly_diagnosed(self):
        schema = {'$defs': {'Value': {'type': 'string'}}, 'type': 'object', 'properties': {'value': {'$ref': '#/$defs/Value'}}}
        self.assertIn('/properties/value/$ref', self.diagnostics(document(operation(request=schema))))

    def test_missing_parameter_and_multipart_refs_have_source_pointers(self):
        missing = {'$ref': '#/components/schemas/Missing'}
        parameter = {'name': 'filter', 'in': 'query', 'schema': missing}
        doc = document(operation(parameters=[parameter]))
        self.assertIn('/paths/~1test/post/parameters/0/schema/$ref', self.diagnostics(doc))
        doc = document(operation())
        doc['paths']['/test']['parameters'] = [parameter]
        self.assertIn('/paths/~1test/parameters/0/schema/$ref', self.diagnostics(doc))
        doc = document(operation(request_content={'multipart/form-data': {'schema': {
            'type': 'object', 'properties': {'metadata': missing},
        }}}))
        self.assertIn('/requestBody/content/multipart~1form-data/schema/properties/metadata/$ref', self.diagnostics(doc))

    def test_invalid_mapping_values_are_diagnostics_instead_of_crashes(self):
        for mapping in [[], {'bad': None}]:
            with self.subTest(mapping=mapping):
                doc = document(operation(request={'oneOf': [{'type': 'string'}],
                                                 'discriminator': {'propertyName': 'kind', 'mapping': mapping}}))
                self.assertIn('/discriminator/mapping', self.diagnostics(doc))

    def test_unmodelled_request_media_keep_raw_builders_and_emit_notes(self):
        baseline = emit(IRBuilder(document(operation()), 'example/gen').build())
        for kind in ['*/*', 'image/png', 'application/octet-stream', 'text/plain', 'application/vnd.api+json', 'application/x-www-form-urlencoded']:
            with self.subTest(kind=kind):
                doc = document(operation(request_content={kind: {'schema': {'type': 'string'}}}))
                result = self.measure(doc)
                self.assertEqual(result.diagnostics, 0)
                self.assertEqual(len(result.notes), 1)
                self.assertEqual(result.notes[0]['message'], f'request body {kind} is not modelled; the caller sets the body')
                self.assertTrue(result.notes[0]['pointer'].endswith('/content/' + kind.replace('/', '~1')))
                self.assertEqual(emit(IRBuilder(doc, 'example/gen').build()), baseline)

    def test_unmodelled_alternatives_leave_json_output_unchanged(self):
        content = {'application/json': {'schema': {'type': 'string'}}, 'application/xml': {'schema': {'type': 'string'}}}
        doc = document(operation(request_content=content))
        result = self.measure(doc)
        self.assertEqual(result.diagnostics, 0)
        self.assertIn('ignored alternative; using application/json', result.notes[0]['message'])
        baseline = document(operation(request={'type': 'string'}))
        self.assertEqual(emit(IRBuilder(doc, 'example/gen').build()), emit(IRBuilder(baseline, 'example/gen').build()))

    def test_json_request_without_schema_is_an_unmodelled_body_note(self):
        doc = document(operation(request_content={'application/json': {}}))
        result = self.measure(doc)
        self.assertEqual(result.diagnostics, 0)
        self.assertEqual(result.notes[0]['message'], 'request body application/json is not modelled; the caller sets the body')
        self.assertIsNone(IRBuilder(doc, 'example/gen').build().operations[0].request_type)

    def test_non_json_successes_are_non_failing_notes_and_raw_responses(self):
        for kind in ['text/event-stream', 'application/x-ndjson', 'application/stream+json', 'application/octet-stream', 'audio/wav', 'text/plain', '*/*', 'application/problem+json']:
            with self.subTest(kind=kind):
                doc = document(operation(responses={'200': {'content': {kind: {'schema': {'type': 'string'}}}}}))
                result = self.measure(doc)
                self.assertEqual(result.diagnostics, 0)
                self.assertEqual(len(result.notes), 1)
                self.assertIn('/responses/200/content/', result.notes[0]['pointer'])
                ir = IRBuilder(doc, 'example/gen').build()
                self.assertIsNone(ir.operations[0].response_type)
                self.assertIn('caller handles the response as @http.Response', emit(ir)['operations.mbt'])

    def test_json_and_stream_response_keeps_json_decoder_and_note(self):
        doc = document(operation(responses={'200': {'content': {
            'application/json': {'schema': {'type': 'string'}}, 'text/event-stream': {'schema': {'type': 'string'}}}}}))
        self.assertIsNotNone(IRBuilder(doc, 'example/gen').build().operations[0].response_type)
        self.assertEqual(len(self.measure(doc).notes), 1)

    def test_parameterized_json_request_and_response(self):
        doc = document(operation(request_content={'application/json; charset=utf-8': {'schema': {'$ref': '#/components/schemas/Input'}}},
                                 responses={'200': {'content': {'application/json; charset=utf-8': {'schema': {'type': 'string'}}}}}),
                       {'Input': {'type': 'object', 'properties': {'value': {'type': 'string'}}}})
        ir = IRBuilder(doc, 'example/gen').build()
        self.assertEqual(ir.operations[0].request_type.name, 'Input')
        self.assertEqual(ir.operations[0].response_type.kind, 'String')
        self.assertEqual(self.measure(doc).diagnostics, 0)

    def test_structured_json_alternative_does_not_change_response_lowering(self):
        doc = document(operation(responses={'200': {'content': {
            'application/json': {'schema': {'type': 'string'}},
            'application/problem+json; charset=utf-8': {'schema': {'type': 'object', 'properties': {'error': {'type': 'boolean'}}}},
        }}}))
        result = self.measure(doc)
        self.assertEqual(result.diagnostics, 0)
        self.assertEqual(len(result.notes), 1)
        baseline = document(operation(response={'type': 'string'}))
        self.assertEqual(emit(IRBuilder(doc, 'example/gen').build()), emit(IRBuilder(baseline, 'example/gen').build()))

    def test_versions_are_checked_before_reference_normalization(self):
        for field, version in [('swagger', '2.0'), ('openapi', '2.0'), ('openapi', '3.2.0'), ('openapi', '4.0.0'), ('openapi', '')]:
            with self.subTest(version=version):
                doc = document(operation(parameters=[{'$ref': '#/parameters/missing'}]))
                doc.pop('openapi')
                doc[field] = version
                result = self.measure(doc)
                self.assertEqual(result.diagnostics, 1)
                reason = next(iter(result.kinds))
                self.assertIn('Swagger 2.0 is not supported; convert to OpenAPI 3 first' if field == 'swagger' else 'unsupported OpenAPI version', reason)
        for version in ['3.0.3', '3.1.0']:
            doc = document(operation())
            doc['openapi'] = version
            self.assertEqual(self.measure(doc).diagnostics, 0)

    def test_empty_overlay_is_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'spec.json'
            path.write_text(json.dumps(document(operation())))
            overlay = Path(tmp) / 'empty.json'
            overlay.write_text(json.dumps({'overlay': '1.0.0', 'info': {'title': 'Empty', 'version': '1.0.0'}, 'actions': []}))
            self.assertEqual(normalize_spec(path, [overlay]), document(operation()))
