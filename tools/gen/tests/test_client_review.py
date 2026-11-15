"""Regressions for the five F2 public-facade review findings."""
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools import sdks
from tools.gen import main as generator
from tools.gen.client_layer import emit_client
from tools.gen.emit_moonbit import HEADER, emit
from tools.gen.ir import IRBuilder
from tools.gen.tests.test_client_layer import ledger
from tools.gen.tests.test_client_surface import surface_spec, operation

ROOT = Path(__file__).resolve().parents[3]


def review_spec():
    doc = surface_spec()
    doc['paths']['/search'] = {'get': operation('search', security=[])}
    doc['paths']['/public'] = {'servers': [{'url': 'https://data.example/v2'}],
                               'get': operation('public_data', security=[])}
    doc['paths']['/private'] = {'get': operation('private_get')}
    doc['paths']['/errors'] = {'get': operation('errors', responses={
        '200': {},
        'default': {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/DefaultProblem'}}}},
        '5XX': {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/RangeProblem'}}}},
        '4XX': {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/ClientProblem'}}}},
        '500': {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/ServerProblem'}}}},
        '503': {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/ServerProblem'}}}},
        '504': {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/ServerProblem'}}}},
    })}
    for name, field, kind in [('DefaultProblem', 'fallback', 'boolean'), ('RangeProblem', 'range', 'integer'),
                              ('ClientProblem', 'client', 'string'), ('ServerProblem', 'detail', 'string')]:
        doc['components']['schemas'][name] = {'type': 'object', 'properties': {field: {'type': kind}}, 'required': [field]}
    return doc


class ClientReviewTests(unittest.TestCase):
    def run_contract(self, source):
        doc = review_spec()
        ir = IRBuilder(doc, 'gaato/sample/gen', auth_headers={'authorization', 'x-api-key'}).build()
        sdk = ledger()
        sdk['base_url'] = 'https://api.example/v1'
        files = emit_client(doc, ir, sdk)
        files['contract_gen.mbt'] += source
        with tempfile.TemporaryDirectory(prefix='f2r-review-') as directory:
            root = Path(directory)
            (root / 'moon.mod').write_text('name = "gaato/sample"\nversion = "0.1.0"\nsource = "src"\nimport { "gaato/mttp_core@0.1.0" }\n')
            (root / '.mooncakes').symlink_to(ROOT / '.mooncakes', target_is_directory=True)
            generator._write(root / 'src/gen', generator._format(emit(ir)))
            generator._write(root / 'src', generator._format(files))
            result = subprocess.run(['moon', '-C', str(root), 'test', '--target', 'wasm-gc', '--deny-warn'], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which('moon'), 'MoonBit toolchain required')
    def test_absolute_url_inference_preserves_public_security_and_operation_bases(self):
        self.run_contract(ABSOLUTE_URLS)

    def test_legacy_fixture_vocabulary_regenerates_but_handwritten_files_are_protected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entries = [dict(dir='fixtures/gen/' + name, out='fixtures/gen/' + name + '/src', generator='openapi') for name in ('badhttp', 'petstore3')]
            with patch.object(generator, 'ROOT', root, create=True), patch.object(sdks, 'load', return_value=entries):
                for entry in entries:
                    with self.subTest(fixture=entry['dir']):
                        spec_file = root / 'spec.json'
                        doc = {'openapi': '3.1.0', 'paths': {'/items': {'get': operation('items', responses={'200': {'content': {'application/json': {'schema': {'type': 'object', 'properties': {'before': {'type': 'string'}}}}}}})}}}
                        spec_file.write_text(json.dumps(doc))
                        out = root / entry['out']
                        args = ['--spec', str(spec_file), '--out', str(out), '--package', 'gaato/sample']
                        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                            self.assertEqual(generator.run(args), 0)
                            before = (out / 'types.mbt').read_text()
                            doc['paths']['/items']['get']['responses']['200']['content']['application/json']['schema']['properties']['after'] = {'type': 'integer'}
                            doc['paths']['/changed'] = doc['paths'].pop('/items')
                            spec_file.write_text(json.dumps(doc))
                            self.assertEqual(generator.run(args + ['--check']), 1)
                            self.assertEqual((out / 'types.mbt').read_text(), before)
                            hand = out / 'notes.mbt'
                            hand.write_text(HEADER + '// hand-maintained despite header\n')
                            self.assertEqual(generator.run(args), 0)
                            self.assertNotEqual((out / 'types.mbt').read_text(), before)
                            self.assertIn('/changed', (out / 'operations.mbt').read_text())
                            self.assertTrue(hand.exists())
                            self.assertEqual(generator.run(args + ['--check']), 0)
                            (out / 'types.mbt').write_text('// handwritten replacement\n')
                            self.assertEqual(generator.run(args), 2)
                            self.assertEqual((out / 'types.mbt').read_text(), '// handwritten replacement\n')
                ordinary = root / 'unregistered/src'
                ordinary.mkdir(parents=True)
                (ordinary / 'types.mbt').write_text(HEADER + 'not a legacy fixture')
                self.assertEqual(generator._protected_conflicts(ordinary, {'types.mbt': HEADER + 'replacement'}), [str(ordinary / 'types.mbt')])

    @unittest.skipUnless(shutil.which('moon'), 'MoonBit toolchain required')
    def test_typed_5xx_errors_and_status_ranges_prefer_explicit_schemas(self):
        self.run_contract(SERVER_ERRORS)

    @unittest.skipUnless(shutil.which('moon'), 'MoonBit toolchain required')
    def test_next_urls_resolve_from_each_effective_page_without_cross_origin_auth(self):
        self.run_contract(NEXT_URLS)

    @unittest.skipUnless(shutil.which('moon'), 'MoonBit toolchain required')
    def test_pagination_and_text_diagnostics_are_bounded(self):
        self.run_contract(DIAGNOSTIC_BOUNDS)


ABSOLUTE_URLS = r'''
///|
test "review absolute public URLs and configured server bases" {
  let seen : Array[(@http.RequestHead, String?)] = []
  let backend = @client.from_fn((request, _) => {
    seen.push((request.head(), request.attributes.get(@client.operation_id)))
    @http.Response::new(200)
  })
  let sdk = Sample::new(backend, @sim.FakeClock::new(), auth=Bearer("secret"),
    server_urls={"https://data.example/v2": "https://override.example/proxy"})
  @driver.run_sync(() => {
    ignore(sdk.send(@http.Request::get("https://api.example/v1/search?query=test#ignored")))
    ignore(sdk.send(@http.Request::get("https://override.example/proxy/public?x=1")))
    ignore(sdk.send(@http.Request::get("https://api.example/v1/private")))
  })
  assert_eq(seen[0].1, Some("search"))
  assert_eq(seen[0].0.headers.get("authorization"), None)
  assert_eq(seen[1].1, Some("public_data"))
  assert_eq(seen[1].0.headers.get("authorization"), None)
  assert_eq(seen[2].1, Some("private_get"))
  assert_eq(seen[2].0.headers.get("authorization"), Some("Bearer secret"))
  let sdk = Sample::new(backend, @sim.FakeClock::new(), auth=Bearer("secret"), base_url="https://gateway.example/api/v3/")
  ignore(@driver.run_sync(() => sdk.send(@http.Request::get("https://gateway.example/api/v3/search?query=test"))))
  assert_eq(seen[3].1, Some("search"))
  assert_eq(seen[3].0.headers.get("authorization"), None)
}
'''

SERVER_ERRORS = r'''
///|
test "review explicit server errors and client/server status ranges" {
  for (status, body, expected) in [
    (500, b"{\"detail\":\"failed\"}", "ServerProblem"),
    (503, b"{\"detail\":\"busy\"}", "ServerProblem"),
    (504, b"{\"detail\":\"timeout\"}", "ServerProblem"),
    (501, b"{\"range\":501}", "RangeProblem"),
    (599, b"{\"range\":599}", "RangeProblem"),
    (400, b"{\"client\":\"bad\"}", "ClientProblem"),
    (499, b"{\"client\":\"bad\"}", "ClientProblem"),
  ] {
    let backend = @client.from_fn((_, _) => @http.Response::new(status,
      headers=@http.Headers::of([("x-error", "retained")]), body=Bytes(body)))
    let sdk = Sample::new(backend, @sim.FakeClock::new(), retry=@client.RetryPolicy::none())
    match @driver.run_sync(() => sdk.send(@http.Request::get("/errors"))) {
      Err(Http(failure)) => {
        assert_eq(failure.head.status, status)
        assert_eq(failure.head.headers.get("x-error"), Some("retained"))
        assert_eq(failure.body, body)
        let rendered = "\{Repr(failure.typed)}"
        assert_true(rendered.contains(expected), msg=rendered)
      }
      _ => fail("expected typed HTTP error")
    }
  }
}
'''

NEXT_URLS = r'''
///|
test "review query relative root relative parent and cross origin next URLs" {
  let seen : Array[@http.RequestHead] = []
  let bodies = [
    b"{\"results\":[1],\"next\":\"?cursor=second\"}",
    b"{\"results\":[1],\"next\":\"child?cursor=third\"}",
    b"{\"results\":[1],\"next\":\"/v1/elsewhere?cursor=fourth\"}",
    b"{\"results\":[1],\"next\":\"../final?cursor=fifth\"}",
    b"{\"results\":[1],\"next\":\"https://other.example/path?page=six\"}",
    b"{\"results\":[1],\"next\":\"?page=seven\"}",
    b"{\"results\":[1],\"next\":null}",
  ]
  let backend = @client.from_fn((request, _) => {
    seen.push(request.head())
    @http.Response::new(200, body=Bytes(bodies[seen.length() - 1]))
  })
  let sdk = Sample::new(backend, @sim.FakeClock::new(), auth=Bearer("secret"))
  let pages : @client.Paginator[Json, Failure] = sdk.paginate(@http.Request::get("/owners/example/items"), kind=NextUrl, items="results", next="next")
  @driver.run_sync(() => {
    for _ in 0..<7 { assert_true(pages.next_page() is Ok(Some(_))) }
    assert_true(pages.next_page() is Ok(None))
  })
  assert_eq(seen.map(head => head.url), [
    "https://api.example/v1/owners/example/items",
    "https://api.example/v1/owners/example/items?cursor=second",
    "https://api.example/v1/owners/example/child?cursor=third",
    "https://api.example/v1/elsewhere?cursor=fourth",
    "https://api.example/final?cursor=fifth",
    "https://other.example/path?page=six",
    "https://other.example/path?page=seven",
  ])
  for i, head in seen {
    assert_eq(head.headers.get("authorization"), if i < 5 { Some("Bearer secret") } else { None })
  }
}

///|
test "review next URL uses the final redirected page URL" {
  let seen : Array[String] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.url)
    if seen.length() == 1 {
      @http.Response::new(302, headers=@http.Headers::of([("location", "/v1/moved/current?first=1")]))
    } else {
      @http.Response::new(200, body=Bytes(if seen.length() == 2 {
        b"{\"results\":[1],\"next\":\"?cursor=done\"}"
      } else { b"{\"results\":[2],\"next\":null}" }))
    }
  })
  let sdk = Sample::new(backend, @sim.FakeClock::new())
  let pages : @client.Paginator[Json, Failure] = sdk.paginate(@http.Request::get("/start"), kind=NextUrl, items="results", next="next")
  @driver.run_sync(() => {
    assert_true(pages.next_page() is Ok(Some(_)))
    assert_true(pages.next_page() is Ok(Some(_)))
    assert_true(pages.next_page() is Ok(None))
  })
  assert_eq(seen[2], "https://api.example/v1/moved/current?cursor=done")
}
'''

DIAGNOSTIC_BOUNDS = r'''
///|
test "review malformed JSON and invalid pagination items retain bounded diagnostics" {
  let padded = String::make(@client.max_error_body + 257, ' ')
  for body in [@utf8.encode("invalid JSON" + padded), @utf8.encode("{\"results\":[{\"id\":\"wrong\"}],\"next\":null}" + padded)] {
    let backend = @client.from_fn((_, _) => @http.Response::new(200,
      headers=@http.Headers::of([("x-review", "retained")]), body=Bytes(body)))
    let sdk = Sample::new(backend, @sim.FakeClock::new())
    let pages = sdk.list_items_pages(owner_name="example", type_="example")
    match @driver.run_sync(() => pages.next_page()) {
      Err(Decode(@client.Deserialization(head, body=diagnostic, ..))) => {
        assert_eq(head.status, 200)
        assert_eq(head.headers.get("x-review"), Some("retained"))
        assert_eq(diagnostic.length(), @client.max_error_body)
        assert_eq(diagnostic, body[:@client.max_error_body].to_owned())
      }
      _ => fail("expected bounded pagination failure")
    }
  }
}

///|
test "review invalid UTF-8 retains bounded diagnostics" {
  let body = Bytes::make(@client.max_error_body + 257, b'\xff')
  let backend = @client.from_fn((_, _) => @http.Response::new(200,
    headers=@http.Headers::of([("x-review", "retained")]), body=Bytes(body)))
  let sdk = Sample::new(backend, @sim.FakeClock::new())
  match @driver.run_sync(() => sdk.read()) {
    Err(Decode(@client.Deserialization(head, body=diagnostic, ..))) => {
      assert_eq(head.status, 200)
      assert_eq(head.headers.get("x-review"), Some("retained"))
      assert_eq(diagnostic.length(), @client.max_error_body)
      assert_eq(diagnostic, body[:@client.max_error_body].to_owned())
    }
    _ => fail("expected bounded text failure")
  }
}
'''
