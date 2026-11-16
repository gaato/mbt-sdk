"""The unpublished facade should be convenient without changing vocabulary APIs."""
import copy
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tools.gen.client_layer import CLIENT_METHOD_NAMES, client_names, pagination_notes
from tools.gen.emit_moonbit import emit
from tools.gen.ir import IRBuilder
from tools.gen.main import _format, _write
from tools.gen.census import census
from tools.gen.tests.test_client_layer import build, spec
from tools import sdks


def operation(name, **kwargs):
    return {'operationId': name, 'x-moonbit-include': True, 'responses': {'204': {}}, **kwargs}


def surface_spec():
    doc = spec()
    doc['components']['schemas'] = {
        'Item': {'type': 'object', 'properties': {'id': {'type': 'integer'}}, 'required': ['id']},
        'Problem': {'type': 'object', 'properties': {'detail': {'type': 'string'}}, 'required': ['detail']},
        'OtherProblem': {'type': 'object', 'properties': {'code': {'type': 'integer'}}, 'required': ['code']},
    }
    error = {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/Problem'}}}}
    other = {'content': {'application/json': {'schema': {'$ref': '#/components/schemas/OtherProblem'}}}}
    doc['paths'] = {
        '/owners/{owner-name}/items': {'get': operation('list_items_owners__owner_name__items_get',
            parameters=[
                {'in': 'path', 'name': 'owner-name', 'required': True, 'schema': {'type': 'string'}},
                {'in': 'query', 'name': 'type', 'required': True, 'schema': {'type': 'string'}},
                {'in': 'query', 'name': 'cursor', 'schema': {'type': 'string'}},
            ],
            responses={
                '200': {'content': {'application/json': {'schema': {
                    'type': 'object', 'properties': {
                        'results': {'type': 'array', 'items': {'$ref': '#/components/schemas/Item'}},
                        'next': {'type': ['string', 'null']},
                    }, 'required': ['results'],
                }}}}, '400': error, '404': error, 'default': other,
            }, **{'x-moonbit-paginate': {'kind': 'cursor', 'param': 'cursor', 'items': 'results', 'next': 'next'}})},
        '/remove/{id}': {'delete': operation('remove_remove__id__delete',
            parameters=[{'in': 'path', 'name': 'id', 'required': True, 'schema': {'type': 'integer'}}],
            responses={'204': {}, '400': error})},
        '/text': {'get': operation('read_text_get', responses={'200': {'content': {'text/plain': {'schema': {'type': 'string'}}}}})},
        '/binary': {'get': operation('download_binary_get', responses={'200': {'content': {'application/octet-stream': {}}}})},
        '/write/{id}': {'post': operation('write_write__id__post',
            parameters=[{'in': 'path', 'name': 'id', 'required': True, 'schema': {'type': 'integer'}}],
            requestBody={'content': {'application/json': {'schema': {'$ref': '#/components/schemas/Item'}}}})},
    }
    return doc


class ClientSurfaceTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('moon'), 'MoonBit toolchain is required for integration')
    def test_helper_operation_names_compile_and_execute(self):
        doc = spec()
        doc['paths'] = {}
        calls = []
        for helper in sorted(CLIENT_METHOD_NAMES):
            doc['paths']['/direct/' + helper] = {'get': operation(helper)}
            doc['paths']['/override/' + helper] = {'get': operation(
                'lookup_' + helper, **{'x-moonbit-name': helper})}
            calls.extend([helper + '_operation', 'lookup_' + helper])
        files, ir = build(doc)
        names = client_names(doc, ir)
        for helper in CLIENT_METHOD_NAMES:
            self.assertEqual(names[helper], helper + '_operation')
            self.assertEqual(names['lookup_' + helper], 'lookup_' + helper)
        checks = '\n'.join('    assert_true(sdk.' + name + '() is Ok(_))' for name in calls)
        files['contract_gen.mbt'] += '''
///|
test "operations cannot shadow client helpers" {
  let seen : Array[String] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.url)
    @http.Response::new(204)
  })
  let sdk = Sample::new(backend, @sim.FakeClock::new())
  @driver.run_sync(() => {
''' + checks + '''
  })
  assert_eq(seen.length(), ''' + str(len(calls)) + ''')
}
'''
        with tempfile.TemporaryDirectory(prefix='helper-collisions-') as tmp:
            root = Path(tmp)
            (root / 'moon.mod').write_text(
                'name = "gaato/sample"\nversion = "0.1.0"\nsource = "src"\n'
                'import { "gaato/mttp_core@0.1.0" }\n')
            _write(root / 'src/gen', _format(emit(ir)))
            _write(root / 'src', _format(files))
            process = subprocess.run(
                ['moon', '-C', str(root), 'test', '--target', 'wasm-gc', '--deny-warn'],
                text=True, capture_output=True)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_exact_fastapi_suffix_and_collision_fallback_and_override(self):
        doc = {'openapi': '3.1.0', 'paths': {
            '/v1/models': {'get': operation('list_v1_models_get')},
            '/v1/jobs': {'get': operation('list_v1_jobs_get')},
            '/v1/models/{model_id}': {'get': operation('get_model_v1_models__model_id__get')},
            '/v1/model-name.ext': {'get': operation('fetch_v1_model_name_ext_get')},
            '/v1/other': {'get': operation('function_v1_other_post')},
            '/v1/override': {'get': operation('old_v1_override_get', **{'x-moonbit-name': 'lookup'})},
        }}
        ir = IRBuilder(doc, 'gaato/sample/gen').build()
        names = client_names(doc, ir)
        self.assertEqual(names['list_v1_models_get'], 'list_v1_models_get')
        self.assertEqual(names['list_v1_jobs_get'], 'list_v1_jobs_get')
        self.assertEqual(names['get_model_v1_models__model_id__get'], 'get_model')
        self.assertEqual(names['fetch_v1_model_name_ext_get'], 'fetch')
        self.assertEqual(names['function_v1_other_post'], 'function_v1_other_post')
        self.assertEqual(names['old_v1_override_get'], 'lookup')
        # A forced name wins over an implicit short name; two forced names fail.
        doc['paths']['/v1/override']['get']['x-moonbit-name'] = 'get_model'
        self.assertEqual(client_names(doc, ir)['get_model_v1_models__model_id__get'], 'get_model_v1_models_model_id_get')
        doc['paths']['/v1/models/{model_id}']['get']['x-moonbit-name'] = 'get_model'
        with self.assertRaisesRegex(ValueError, 'collision'):
            client_names(doc, ir)

    def test_error_variants_are_per_schema_and_keep_http_operation(self):
        files, _ = build(surface_spec())
        source = files['failures_gen.mbt']
        enum = source.split('pub(all) enum ErrorBody {')[1].split('}')[0]
        self.assertEqual(enum.strip().splitlines(), ['Problem(Problem)', '  OtherProblem(OtherProblem)'])
        self.assertIn('operation : String', source)
        self.assertIn('#non_exhaustive\npub(all) enum ErrorBody', source)
        self.assertIn('Http({ operation, head, body,', files['client_gen.mbt'])
        doc = surface_spec()
        inline = {'type': 'object', 'properties': {'message': {'type': 'string'}}}
        responses = doc['paths']['/owners/{owner-name}/items']['get']['responses']
        responses['400']['content']['application/json']['schema'] = inline
        responses['404'] = copy.deepcopy(responses['400'])
        files, _ = build(doc)
        self.assertEqual(files['failures_gen.mbt'].count('pub(all) struct ErrorListItems'), 1)

    def test_typed_paginator_builds_first_request_with_labelled_parameters(self):
        files, ir = build(surface_spec())
        source = files['paginate_gen.mbt']
        self.assertIn('Sample::list_items_pages(self : Sample, owner_name~ : String, type_~ : String, cursor? : String)', source)
        self.assertIn('-> @client.Paginator[@gen.Item, Failure]', source)
        self.assertIn('let first = @gen.list_items_owners_owner_name_items_get_request(owner_name, type_, cursor?)', source)
        self.assertIn('kind=PageKind::Cursor("cursor")', source)
        self.assertIn('kind~ : PageKind', source)
        self.assertEqual(pagination_notes(surface_spec(), ir), [])
        files, _ = build(surface_spec(), operation_wrappers=False)
        self.assertNotIn('operations_gen.mbt', files)
        self.assertIn('Paginator[@gen.Item, Failure]', files['paginate_gen.mbt'])

    def test_json_fallback_has_a_census_note(self):
        doc = spec()
        _, ir = build(doc)
        self.assertEqual(len(pagination_notes(doc, ir)), 1)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'spec.json'
            path.write_text(json.dumps(doc))
            notes = census(path, 'sample', client_layer=True).notes
            self.assertTrue(any('items fall back to Json' in note['message'] for note in notes))

    def test_labelled_paths_positional_body_unit_text_and_binary(self):
        files, ir = build(surface_spec())
        source = files['operations_gen.mbt']
        self.assertIn('Sample::remove(self : Sample, id~ : Int32) -> Result[Unit, Failure]', source)
        self.assertIn('Sample::read(self : Sample) -> Result[String, Failure]', source)
        self.assertIn('Sample::download(self : Sample) -> Result[@client.Reply[Bytes], Failure]', source)
        self.assertIn('Sample::write(self : Sample, id~ : Int32, body : @gen.Item)', source)
        self.assertIn('match decode_text(', source)
        self.assertIn('invalid UTF-8 response body', source)
        # The lower-level builder names and positional arguments are unchanged.
        self.assertIn('pub fn remove_remove_id_delete_request(id : Int32)', emit(ir)['operations.mbt'])

    def test_provider_timeout_and_retry_override_are_validated_and_emitted(self):
        replicate = next(s for s in sdks.load() if s['name'] == 'replicate')
        retry = replicate['retry']
        sdks.validate_retry(retry, 'replicate')
        self.assertEqual(retry['status_overrides'], [{'methods': ['POST'], 'statuses': [429]}])
        files, _ = build(surface_spec(), retry=retry, timeout_ms=70000, total_timeout_ms=90000)
        self.assertIn('timeout_ms~ : Int32 = 70000', files['client_gen.mbt'])
        self.assertIn('total_timeout_ms~ : Int32 = 90000', files['client_gen.mbt'])
        self.assertIn('default per-attempt timeout is 70000 ms', files['client_gen.mbt'])
        self.assertIn('total_ms=total_timeout_ms', files['client_gen.mbt'])
        self.assertIn('BackoffAbove(60000)', files['retry_gen.mbt'])
        for invalid in [{'status_overrides': 'POST'}, {'status_overrides': [{'methods': 'any', 'statuses': [429]}]}, {'status_overrides': [{'methods': ['BOGUS'], 'statuses': [429]}]}]:
            with self.assertRaises(ValueError):
                sdks.validate_retry(invalid, 'test')

    @unittest.skipUnless(shutil.which('moon'), 'MoonBit toolchain required')
    def test_polished_surface_executes_and_replicate_policy_matches_contract(self):
        sdk = next(s for s in sdks.load() if s['name'] == 'replicate')
        files, ir = build(surface_spec(), retry=sdk['retry'], timeout_ms=70000)
        files['contract_gen.mbt'] += SURFACE_CONTRACT
        with tempfile.TemporaryDirectory(prefix='f2b-surface-') as tmp:
            tmp = Path(tmp)
            (tmp / 'moon.mod').write_text('name = "gaato/sample"\nversion = "0.1.0"\nsource = "src"\nimport { "gaato/mttp_core@0.1.0" }\n')
            _write(tmp / 'src/gen', _format(emit(ir)))
            _write(tmp / 'src', _format(files))
            process = subprocess.run(['moon', '-C', str(tmp), 'test', '--target', 'wasm-gc', '--deny-warn'], text=True, capture_output=True)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)


SURFACE_CONTRACT = r'''
///|
test "typed operation paginator builds first request and preserves decode failures" {
  let seen : Array[String] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.url)
    let body = match seen.length() {
      1 => b"{\"results\":[{\"id\":1}],\"next\":\"second\"}"
      2 => b"{\"results\":[{\"id\":\"wrong\"}],\"next\":null}"
      _ => b"{\"results\":[{\"id\":2}],\"next\":null}"
    }
    @http.Response::new(200, body=Bytes(body))
  })
  let sdk = Sample::new(backend, @sim.FakeClock::new())
  let pages = sdk.list_items_pages(owner_name="a/b", type_="example")
  @driver.run_sync(() => {
    match pages.next_page() {
      Ok(Some([item])) => assert_eq(item.id, 1)
      _ => fail("typed first page failed")
    }
    assert_true(pages.next_page() is Err(Decode(_)))
    match pages.next_page() {
      Ok(Some([item])) => assert_eq(item.id, 2)
      _ => fail("typed retry page failed")
    }
    assert_true(pages.next_page() is Ok(None))
  })
  assert_eq(seen[0], "https://api.example/owners/a%2Fb/items?type=example")
  assert_eq(seen[1], seen[2])
  assert_true(seen[1].contains("cursor=second"))
}

///|
test "Unit consumes body" {
  let driver = @driver.Driver::new()
  let source = @sim.Feed::bytes(driver, [b"unexpected body"])
  let backend = @client.from_fn((_, _) => @http.Response::new(204, body=Stream(@http.StreamBody::new(source))))
  let sdk = Sample::new(backend, @sim.FakeClock::new())
  assert_true(driver.run(() => sdk.remove(id=1)) is Ok(_))
  assert_eq(source.closes(), 1)
}

///|
test "text decoding preserves bytes on invalid UTF-8" {
  for bytes in [b"hello", b"\xff"] {
    let backend = @client.from_fn((_, _) => @http.Response::new(200, body=Bytes(bytes)))
    let sdk = Sample::new(backend, @sim.FakeClock::new())
    match @driver.run_sync(() => sdk.read()) {
      Ok(value) => assert_eq(value, "hello")
      Err(Decode(@client.Deserialization(head, body~, ..))) => {
        assert_eq(head.status, 200)
        assert_eq(body, b"\xff")
      }
      _ => fail("wrong text failure")
    }
  }
}

///|
test "per-status method union does not let POST retry 5xx or transport failures" {
  for verb in ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "POST", "TRACE", "PATCH"] {
    for status in [429, 500, 502, 503, 504, 400] {
      let count = Ref(0)
      let clock = @sim.FakeClock::new()
      let backend = @client.from_fn((_, _) => {
        count.val += 1
        @http.Response::new(if count.val == 1 { status } else { 200 })
      })
      let sdk = Sample::new(backend, clock)
      ignore(@driver.run_sync(() => sdk.send(@http.Request::new(@http.Method::parse(verb), "/contract-test"))))
      let safe = verb != "POST" && verb != "TRACE" && verb != "PATCH"
      let retryable = (safe && status != 400) || (verb == "POST" && status == 429)
      assert_eq(count.val, if retryable { 2 } else { 1 })
    }
  }
  for phase in [@http.Phase::Dial, @http.Phase::Body] {
    let count = Ref(0)
    let backend = @client.from_fn((_, _) => {
      count.val += 1
      raise @http.TransportError(kind=Network, phase~, detail="offline")
    })
    let sdk = Sample::new(backend, @sim.FakeClock::new())
    ignore(@driver.run_sync(() => sdk.send(@http.Request::post("/contract-test"))))
    assert_eq(count.val, 1)
  }
}

///|
test "Replicate retry count header handling and bounded proportional backoff" {
  for delay in ["1", "61"] {
    let count = Ref(0)
    let clock = @sim.FakeClock::new()
    let backend = @client.from_fn((_, _) => {
      count.val += 1
      @http.Response::new(429, headers=@http.Headers::of([("retry-after", delay), ("x-should-retry", "false")]))
    })
    let sdk = Sample::new(backend, clock)
    ignore(@driver.run_sync(() => sdk.send(@http.Request::post("/contract-test"))))
    assert_eq(count.val, 6)
    assert_eq(clock.slept().length(), 5)
    for i, slept in clock.slept() {
      if delay == "1" { assert_eq(slept, 1000) } else {
        let base = 500 << i
        assert_true(slept >= base * 9 / 10 && slept <= base * 11 / 10)
      }
    }
  }
}
'''
