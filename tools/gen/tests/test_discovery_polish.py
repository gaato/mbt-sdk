"""Resource-name and protobuf JSON regressions; all HTTP calls are offline."""
import json
from pathlib import Path
import tempfile
import unittest

from tools.gen.discovery import convert_discovery
from tools.gen.ir import IRBuilder, include_all_operations
from tools.gen.emit_moonbit import emit
from tools.gen.client_layer import emit_client
from tools.gen.main import _format, _write
from tools.gen.tests.test_discovery import _install_and_test


def fixture():
    def get(identifier, path, parameter, pattern, response):
        return {'id': 'demo.' + identifier, 'path': path,
                'flatPath': 'v1/ignored/{ignoredId}', 'httpMethod': 'GET',
                'parameters': {parameter: {'type': 'string', 'location': 'path',
                    'required': True, 'pattern': pattern}}, 'response': {'$ref': response}}
    return {
        'kind': 'discovery#restDescription', 'name': 'demo', 'version': 'v1',
        'rootUrl': 'https://api.example/', 'servicePath': '',
        'parameters': {'key': {'type': 'string', 'location': 'query'}},
        'auth': {'oauth2': {'scopes': {}}},
        'schemas': {'Model': {'type': 'object', 'properties': {'name': {'type': 'string'}}},
                    'Empty': {'type': 'object'},
                    'List': {'type': 'object', 'properties': {'items': {'type': 'array', 'items': {'$ref': 'Model'}}, 'next': {'type': 'string'}}}},
        'resources': {'models': {'methods': {
            'get': get('models.get', 'v1/{+model}', 'model', '^models/[^/]+$', 'Model'),
            'delete': dict(get('models.delete', 'v1/{+name}', 'name', '^models/[^/]+$', 'Empty'), httpMethod='DELETE'),
            'nested': get('models.nested', 'v1/{+name}:read', 'name', '^projects/[a-z]+/models/[^/]+$', 'Model'),
            'list': {'id': 'demo.models.list', 'httpMethod': 'GET', 'path': 'v1/models',
                     'response': {'$ref': 'List'}},
        }}},
    }


class DiscoveryPolishTests(unittest.TestCase):
    def test_canonical_route_collisions_keep_the_original_wire_template(self):
        raw = fixture()
        duplicate = dict(raw['resources']['models']['methods']['get'])
        duplicate['id'] = 'demo.files.get'
        duplicate['parameters'] = {'model': {'type': 'string', 'location': 'path', 'pattern': '^files/[^/]+$'}}
        raw['resources']['files'] = {'methods': {'get': duplicate}}
        doc = convert_discovery(raw)
        include_all_operations(doc)
        ir = IRBuilder(doc, 'gaato/demo/gen').build()
        operations = {op.operation_id: op for op in ir.operations}
        self.assertEqual(operations['models_get'].path, '/v1/{model}')
        self.assertEqual(operations['files_get'].path, '/v1/{model}')
        self.assertNotEqual(operations['models_get'].source_path, operations['files_get'].source_path)
        self.assertEqual(len(ir.operations), 5)

    def test_fieldless_message_is_empty_but_an_arbitrary_object_is_not(self):
        raw = fixture()
        raw['schemas']['Empty']['additionalProperties'] = True
        doc = convert_discovery(raw)
        self.assertIn('200', doc['paths']['/v1/{name}']['delete']['responses'])

    def test_canonical_paths_patterns_empty_and_auth_scheme_names(self):
        doc = convert_discovery(fixture())
        op = doc['paths']['/v1/{model}']['get']
        self.assertEqual(op['parameters'][0]['name'], 'model')
        self.assertEqual(op['parameters'][0]['schema']['pattern'], '^models/[^/]+$')
        self.assertIn('204', doc['paths']['/v1/{name}']['delete']['responses'])
        self.assertEqual(list(doc['components']['securitySchemes']), ['ApiKey', 'ApiKeyInQuery', 'OAuthToken'])

    def test_generated_resource_validation_and_empty_pagination(self):
        doc = convert_discovery(fixture())
        doc['x-moonbit-nonraising-decoders'] = True
        for path in doc['paths'].values():
            for op in path.values():
                op['x-moonbit-name'] = op['operationId'].removeprefix('models_')
        doc['paths']['/v1/models']['get']['x-moonbit-paginate'] = {
            'kind': 'cursor', 'param': 'pageToken', 'items': 'items', 'next': 'next'}
        include_all_operations(doc)
        ir = IRBuilder(doc, 'gaato/demo/gen').build()
        sdk = {'name': 'demo', 'dir': 'demo', 'module': 'gaato/demo', 'out': 'demo/src/gen',
               'base_url': 'https://api.example', 'auth': {'kind': 'alternatives', 'schemes': [
                   {'kind': 'header', 'name': 'x-goog-api-key'}, {'kind': 'query', 'name': 'key'}, {'kind': 'bearer'}]}}
        with tempfile.TemporaryDirectory(prefix='discovery-polish-') as tmp:
            root = Path(tmp)
            (root / 'moon.mod').write_text('name = "gaato/demo"\nversion = "0.1.0"\nsource = "src"\nimport { "gaato/mttp_core@0.3.0" }\n')
            _write(root / 'src/gen', _format(emit(ir)))
            _write(root / 'src', _format(emit_client(doc, ir, sdk)))
            (root / 'src/polish_test.mbt').write_text(CONTRACT)
            result = _install_and_test(root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


CONTRACT = r'''///|
test "resource-name normalization validates before sending" {
  let seen : Array[String] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.url)
    @http.Response::new(200, body=Bytes(b"{}"))
  })
  let sdk = @demo.Demo::new(backend, @sim.FakeClock::new(), auth=ApiKey("offline"))
  @driver.run_sync(() => {
    assert_true(sdk.get(model="gemini-2.5-flash") is Ok(_))
    assert_true(sdk.get(model="models/gemini-2.5-flash") is Ok(_))
    for invalid in ["models/../cachedContents/x", "models/x?y", "models/x#y", "models/x&y", "models/x%2Fz", "models/x%2fz", "models/x:verb", "", " ", "models/ ", "models/x/y", "models/.", "models/..", "models/x\\y", "models/x\ny"] {
      assert_true(sdk.get(model=invalid) is Err(Validation(..)))
    }
    assert_true(sdk.nested(name="projects/abc/models/test") is Ok(_))
    assert_true(sdk.nested(name="test") is Err(Validation(..)))
    assert_true(sdk.nested(name="projects/123/models/test") is Err(Validation(..)))
    let deleted : Result[Unit, @demo.Failure] = sdk.delete(name="models/test")
    assert_true(deleted is Ok(_))
  })
  assert_eq(seen, ["https://api.example/v1/models/gemini-2.5-flash", "https://api.example/v1/models/gemini-2.5-flash", "https://api.example/v1/projects/abc/models/test:read", "https://api.example/v1/models/test"])
}
///|
test "protobuf omitted arrays skip empty pages but present invalid values fail" {
  let calls = Ref(0)
  let backend = @client.from_fn((_, _) => {
    calls.val += 1
    let body = match calls.val {
      1 => b"{\"next\":\"two\"}"
      2 => b"{\"items\":[{\"name\":\"models/test\"}],\"next\":\"three\"}"
      _ => b"{}"
    }
    @http.Response::new(200, body=Bytes(body))
  })
  let sdk = @demo.Demo::new(backend, @sim.FakeClock::new())
  @driver.run_sync(() => {
    let pages = sdk.list_pages()
    guard pages.next_page() is Ok(Some(items)) else { fail("expected nonempty page") }
    assert_eq(items[0].name, Some("models/test"))
    assert_true(pages.next_page() is Ok(None))
    assert_true(pages.next_page() is Ok(None))
  })
  assert_eq(calls.val, 3)
  for body in [b"{\"items\":null}", b"{\"items\":{}}", b"{\"items\":1}", b"{\"items\":\"bad\"}", b"null", b"[]"] {
    let backend = @client.from_fn((_, _) => @http.Response::new(200, body=Bytes(body)))
    let sdk = @demo.Demo::new(backend, @sim.FakeClock::new())
    assert_true(@driver.run_sync(() => sdk.list_pages().next_page()) is Err(Decode(_)))
  }
}
'''
