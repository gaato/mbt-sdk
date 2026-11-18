"""Compile regressions for wire variants that shadow prelude constructors."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from tools.gen.emit_moonbit import emit
from tools.gen.ir import IRBuilder
from tools.gen.main import _format, _write
from tools.gen.client_layer import emit_client
from test_client_layer import ledger
from test_generator import document, operation


RESERVED = ('None', 'Some', 'Json', 'Result', 'Ok', 'Err', 'Unit')


class ReservedVariantTests(unittest.TestCase):
    def test_legal_builtin_named_types_are_qualified_in_facade_signatures(self):
        doc = document(operation(request={'$ref': '#/components/schemas/Json'},
                                 response={'$ref': '#/components/schemas/Result'}), {
            name: {'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text']}
            for name in ['Json', 'Result']})
        # Use the existing new-module opt-in for the pinned compiler's generic
        # async raise? callback linker limitation (also used by Gemini).
        doc['x-moonbit-nonraising-decoders'] = True
        ir = IRBuilder(doc, 'gaato/sample/gen').build()
        sdk = ledger()
        sdk['auth'] = {'kind': 'bearer'}
        files = emit_client(doc, ir, sdk)
        self.assertIn('body : @gen.Json', files['operations_gen.mbt'])
        self.assertIn('Result[@gen.Result, Failure]', files['operations_gen.mbt'])
        files['contract_gen.mbt'] += '''
///|
test "domain types sharing builtin names" {
  let backend = @client.from_fn((_, _) => @http.Response::new(200, body=@http.Body::Bytes(b"{\\"text\\":\\"reply\\"}")))
  let sdk = Sample::new(backend, @sim.FakeClock::new())
  let result = @driver.run_sync(() => sdk.test_operation(@gen.Json::new(text="body")))
  match result {
    Result::Ok(value) => assert_eq(value.text, "reply")
    Result::Err(_) => fail("unexpected SDK failure")
  }
}
'''
        with tempfile.TemporaryDirectory(prefix='f8-named-facade-') as temporary:
            root = Path(temporary)
            (root / 'moon.mod').write_text('name = "gaato/sample"\nversion = "0.1.0"\nsource = "src"\nimport { "gaato/mttp_core@0.3.0" }\n')
            _write(root / 'src/gen', _format(emit(ir)))
            _write(root / 'src', _format(files))
            for args in [['update'], ['check', '--target', 'wasm-gc', '--deny-warn'], ['test', '--target', 'wasm-gc', '--deny-warn']]:
                result = subprocess.run(['moon', '-C', temporary, *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def check_round_trip(self, schema, schemas=None):
        parameters = [{'name': 'filter', 'in': 'query', 'schema': {'type': 'string'}}]
        doc = document(operation(response=schema, parameters=parameters), schemas)
        # The measurements failed with multiple unions exporting Json(payload):
        # the generic parameter helper has no expected type for Json(value).
        doc['paths']['/other'] = {'post': operation(
            operation_id='otherOperation', response=schema, parameters=parameters)}
        ir = IRBuilder(doc, 'gaato/sample/gen').build()
        response = next(item for item in ir.declarations if item.name == 'TestOperationResponse')
        files = emit(ir)
        for name in RESERVED:
            self.assertIn('TestOperationResponse::' + name, files['types.mbt'])
        self.assertIn('@json.Json::Json(value)', files['operations.mbt'])
        files['reserved_wbtest.mbt'] = '''///|
test "reserved wire constructors round trip" {
  for raw in ["None", "Some", "Json", "Result", "Ok", "Err", "Unit"] {
    let wire : Json = ''' + ('@json.Json::Json(raw)' if schema.get('type') == 'string' else '{ "kind": raw, "value": "payload" }') + '''
    let decoded : TestOperationResponse = @json.from_json(wire)
    assert_eq(decoded.to_json(), wire)
  }
}
'''
        with tempfile.TemporaryDirectory(prefix='f8-reserved-') as directory:
            root = Path(directory)
            (root / 'moon.mod').write_text(
                'name = "gaato/sample"\nversion = "0.1.0"\nsource = "src"\n'
                'import { "gaato/mttp_core@0.3.0" }\n')
            _write(root / 'src/gen', _format(files))
            # Resolve each sample's own dependencies: a workspace cache must not
            # let a sample accidentally compile against a different dependency.
            for command in [
                ['moon', '-C', str(root), 'update'],
                ['moon', '-C', str(root), 'check', '--target', 'wasm-gc', '--deny-warn'],
                ['moon', '-C', str(root), 'test', '--target', 'wasm-gc', '--deny-warn'],
            ]:
                process = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual([variant.name for variant in response.variants],
                         list(RESERVED))

    def test_string_enum_reserved_variants_compile_and_run(self):
        self.check_round_trip({'type': 'string', 'enum': list(RESERVED)})

    def test_tagged_union_reserved_variants_compile_and_run(self):
        schemas = {
            name + 'Payload': {
                'type': 'object',
                'properties': {'kind': {'type': 'string', 'enum': [name]},
                               'value': {'type': 'string'}},
                'required': ['kind', 'value'],
            }
            for name in RESERVED
        }
        self.check_round_trip({
            'oneOf': [{'$ref': '#/components/schemas/' + name + 'Payload'} for name in RESERVED],
            'discriminator': {'propertyName': 'kind'},
            'x-moonbit-variants': list(RESERVED),
        }, schemas)
