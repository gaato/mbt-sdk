"""Facade tests use inline specs and offline backends, never provider APIs."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools.gen.client_layer import emit_client, retry_source, security_auth_choices
from tools.gen.emit_moonbit import HEADER, emit
from tools.gen.ir import IRBuilder
from tools.gen.main import _differences, _format, _protected_conflicts, _write
from tools.gen.census import census
from tools import sdks


def spec():
    return {
        'openapi': '3.1.0', 'servers': [{'url': 'https://api.example'}],
        'security': [{'key': []}, {'bearer': []}, {'basic': []}, {'query': []}],
        'components': {'securitySchemes': {
            'key': {'type': 'apiKey', 'in': 'header', 'name': 'X-Api-Key'},
            'bearer': {'type': 'http', 'scheme': 'bearer'},
            'basic': {'type': 'http', 'scheme': 'basic'},
            'query': {'type': 'apiKey', 'in': 'query', 'name': 'api_key'},
        }},
        'paths': {
            '/items': {'servers': [{'url': 'https://data.example/v2'}], 'get': {
                'x-moonbit-include': True, 'operationId': 'items',
                'parameters': [{'name': 'X-Api-Key', 'in': 'header', 'required': True, 'schema': {'type': 'string'}}],
                'x-moonbit-paginate': {'kind': 'cursor', 'param': 'cursor', 'items': 'results', 'next': 'next'},
                'responses': {'200': {'content': {'application/json': {'schema': {'type': 'object', 'x-moonbit-json': True}}}},
                              'default': {'content': {'application/json': {'schema': {'type': 'object', 'properties': {'message': {'type': 'string'}}, 'required': ['message']}}}},
                              '400': {'content': {'application/json': {'schema': {'type': 'object', 'properties': {'code': {'type': 'integer'}}, 'required': ['code']}}}}},
            }},
            '/public': {'get': {'x-moonbit-include': True, 'operationId': 'public_get', 'security': [], 'responses': {'200': {}}}},
            '/raw': {'post': {'x-moonbit-include': True, 'operationId': 'raw', 'servers': [{'url': '/uploads'}],
                              'parameters': [{'name': 'Idempotency-Key', 'in': 'header', 'schema': {'type': 'string'}}],
                              'requestBody': {'content': {'application/octet-stream': {'schema': {'type': 'string', 'format': 'binary'}}}},
                              'responses': {'200': {'content': {'application/octet-stream': {}}}}}},
            '/sse': {'get': {'x-moonbit-include': True, 'operationId': 'events', 'responses': {'200': {'content': {'text/event-stream': {}}}}}},
            '/mixed': {'get': {'x-moonbit-include': True, 'operationId': 'mixed', 'responses': {'200': {'content': {'text/event-stream': {}, 'application/json': {'schema': {'type': 'object', 'x-moonbit-json': True}}}}}}},
        },
    }


def ledger(**kwargs):
    return dict(name='sample', dir='sample', module='gaato/sample', out='sample/src/gen',
                base_url='https://api.example', auth={'kind': 'alternatives', 'schemes': [
                    {'kind': 'header', 'name': 'X-Api-Key'}, {'kind': 'bearer'}, {'kind': 'basic'}, {'kind': 'query', 'name': 'api_key'},
                    {'kind': 'none'},
                ]}, idempotency_headers=['Idempotency-Key'], **kwargs)


def build(doc=None, **kwargs):
    doc = doc or spec()
    ir = IRBuilder(doc, 'gaato/sample/gen', auth_headers={'authorization', 'x-api-key'}).build()
    return emit_client(doc, ir, ledger(**kwargs)), ir


class ClientLayerTests(unittest.TestCase):
    def test_auth_kinds_and_redaction_and_signature_filter(self):
        files, ir = build()
        source = files['client_gen.mbt']
        for text in ['request.bearer(value)', 'request.basic(username, password)', 'request.set_header("X-Api-Key", value)', 'request.query("api_key", value)', 'credential_headers.push("x-api-key")']:
            self.assertIn(text, source)
        self.assertNotIn('x_api_key', files['operations_gen.mbt'])
        self.assertEqual(ir.operations[0].parameters, ())
        self.assertIn('"public_get" => (false, "")', source)
        self.assertIn('Query credentials appear in redirect history and observer URLs.', source)
        self.assertIn('from_client cannot enforce', source)

    def test_servers_retry_errors_raw_sse_pagination_and_bucket(self):
        files, _ = build()
        self.assertIn('https://data.example/v2', files['client_gen.mbt'])
        self.assertIn('server_urls.get(server)', files['client_gen.mbt'])
        self.assertIn('"sample" + ":" + operation', files['client_gen.mbt'])
        self.assertIn('@http.replay_safe, true', files['client_gen.mbt'])
        self.assertIn('Transport(@http.TransportError)', files['failures_gen.mbt'])
        self.assertIn('ErrorItems400', files['failures_gen.mbt'])
        self.assertLess(files['failures_gen.mbt'].index('head.status == 400'), files['failures_gen.mbt'].index('&& true'))
        self.assertIn('content_type~ : String', files['operations_gen.mbt'])
        self.assertIn('.body_bytes(body, content_type~)', files['operations_gen.mbt'])
        self.assertIn('Sample::events(', files['operations_gen.mbt'])
        self.assertIn('Sample::mixed_stream(', files['operations_gen.mbt'])
        self.assertIn('@client.from_head(head =>', files['client_gen.mbt'])
        self.assertIn('stop=event => stop(head, event)', files['client_gen.mbt'])
        self.assertIn('Sample::items_pages', files['paginate_gen.mbt'])
        self.assertIn('merge_query_params', files['paginate_gen.mbt'])
        self.assertIn('@client.RetryPolicy::conservative()', files['retry_gen.mbt'])

    def test_wrappers_off_keeps_generic_surface_and_paginators(self):
        files, _ = build(operation_wrappers=False, extra_imports=['moonbitlang/core/regex'])
        self.assertNotIn('operations_gen.mbt', files)
        self.assertIn('Sample::call(', files['client_gen.mbt'])
        self.assertIn('Sample::items_pages', files['paginate_gen.mbt'])
        self.assertIn('moonbitlang/core/regex', files['moon.pkg'])
        doc = spec()
        doc['paths']['/items']['get']['x-moonbit-paginate'] = {'kind': 'url', 'items': 'results', 'next': 'next'}
        files, _ = build(doc)
        self.assertIn('kind=NextUrl', files['paginate_gen.mbt'])

    def test_retry_table_and_validation(self):
        config = dict(retries=3, methods=['GET', 'POST'], statuses=[429, [500, 599]],
                      sent_failures='any', override_header='x-should-retry', retry_after='header',
                      retry_after_cap_ms='none', zero_means_backoff=True,
                      backoff_base_ms=500, backoff_max_ms=8000, jitter=[750, 1000])
        sdks.validate_retry(config, 'test')
        source = retry_source(config)
        for text in ['max_retries: 3', 'Listed([', 'Range(500, 599)', 'sent_failures: Any', 'Some("x-should-retry")', 'source: Header', 'cap: NoCap', 'zero_means_backoff: true', 'max_ms: 8000', 'lo=750, hi=1000']:
            self.assertIn(text, source)
        for invalid in [{'bogus': 3}, {'retries': -1}, {'methods': 'sometimes'}, {'retry_after_cap_ms': -1}, {'statuses': [[599, 500]]}, {'jitter': [1000, 750]}]:
            with self.assertRaises(ValueError):
                sdks.validate_retry(invalid, 'test')

    def test_rejects_unsupported_security_and_pagination(self):
        doc = spec()
        doc['paths']['/items']['get']['security'] = [{'key': [], 'basic': []}]
        with self.assertRaisesRegex(ValueError, 'AND authentication'):
            build(doc)
        doc = spec()
        doc['paths']['/items']['get']['x-moonbit-paginate']['kind'] = 'offset'
        with self.assertRaisesRegex(ValueError, 'invalid x-moonbit-paginate'):
            build(doc)

    def test_overlay_supplies_missing_auth_scheme(self):
        doc = spec()
        doc['x-moonbit-auth'] = doc['components'].pop('securitySchemes')
        files, _ = build(doc)
        self.assertIn('XApiKey(String)', files['client_gen.mbt'])

    def test_empty_security_requirement_keeps_anonymous_or_alternative(self):
        doc = {
            'openapi': '3.1.0',
            'servers': [{'url': 'https://api.example'}],
            'components': {'securitySchemes': {
                'token': {'type': 'http', 'scheme': 'bearer'},
            }},
            'paths': {'/items': {'get': {
                'x-moonbit-include': True,
                'operationId': 'items',
                'security': [{}, {'token': []}],
                'responses': {'200': {}},
            }}},
        }
        choices, saw_security = security_auth_choices(doc)
        self.assertTrue(saw_security)
        self.assertEqual(choices, [
            {'kind': 'none'},
            {'kind': 'bearer'},
        ])
        sdk = ledger()
        sdk['auth'] = {'kind': 'alternatives', 'schemes': choices}
        ir = IRBuilder(doc, 'gaato/sample/gen', auth_headers={'authorization', 'x-api-key'}).build()
        source = emit_client(doc, ir, sdk)['client_gen.mbt']
        self.assertIn('"items" => (match self.auth { Anonymous | Bearer(_) => true; _ => false }', source)

    def test_empty_security_array_is_anonymous_in_a_mixed_document(self):
        doc = {
            'openapi': '3.1.0',
            'servers': [{'url': 'https://api.example'}],
            'security': [{'token': []}],
            'components': {'securitySchemes': {
                'token': {'type': 'http', 'scheme': 'bearer'},
            }},
            'paths': {
                '/protected': {'get': {
                    'x-moonbit-include': True,
                    'operationId': 'protected',
                    'responses': {'200': {}},
                }},
                '/public': {'get': {
                    'x-moonbit-include': True,
                    'operationId': 'public',
                    'security': [],
                    'responses': {'200': {}},
                }},
            },
        }
        choices, saw_security = security_auth_choices(doc)
        self.assertTrue(saw_security)
        self.assertEqual(choices, [{'kind': 'bearer'}, {'kind': 'none'}])
        sdk = ledger()
        sdk['auth'] = {'kind': 'alternatives', 'schemes': choices}
        ir = IRBuilder(doc, 'gaato/sample/gen').build()
        source = emit_client(doc, ir, sdk)['client_gen.mbt']
        self.assertIn(
            '"protected" => (match self.auth { Bearer(_) => true; _ => false }',
            source,
        )
        self.assertIn('"public" => (false, "")', source)

    def test_error_schema_diagnostics_are_available_to_census(self):
        doc = spec()
        doc['paths']['/items']['get']['responses']['400']['content']['application/json']['schema'] = {'type': 'unsupported'}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'spec.json'
            path.write_text(json.dumps(doc))
            self.assertEqual(census(path, 'sample').diagnostics, 0)
            self.assertGreater(census(path, 'sample', client_layer=True).diagnostics, 0)

    def test_root_ownership_requires_both_name_and_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'src'
            root.mkdir()
            (root / 'old_gen.mbt').write_text(HEADER + 'old')
            (root / 'hand_gen.mbt').write_text('handwritten')
            (root / 'hand.mbt').write_text(HEADER + 'handwritten despite the header')
            self.assertEqual(_differences(root, {}), [str(root / 'old_gen.mbt')])
            self.assertEqual(_protected_conflicts(root, {'hand_gen.mbt': HEADER}), [str(root / 'hand_gen.mbt')])
            self.assertEqual(_protected_conflicts(root, {'hand.mbt': HEADER}), [str(root / 'hand.mbt')])
            _write(root, {})
            self.assertFalse((root / 'old_gen.mbt').exists())
            self.assertTrue((root / 'hand_gen.mbt').exists())
            self.assertTrue((root / 'hand.mbt').exists())
            other = Path(tmp) / 'elsewhere'
            other.mkdir()
            (other / 'old_gen.mbt').write_text(HEADER)
            _write(other, {})
            self.assertTrue((other / 'old_gen.mbt').exists())

    def test_behavior_gate_failure_and_explicit_deferral(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(sdks, 'ROOT', Path(tmp)):
            sdk = dict(name='sample', publish=False, client_layer=True)
            with self.assertRaisesRegex(ValueError, 'missing'):
                sdks.behavior_notes([sdk])
            path = Path(tmp) / 'docs/behavior/sample.md'
            path.parent.mkdir(parents=True)
            path.write_text('Surveyed 2026-11-15. TODO source review')
            with self.assertRaisesRegex(ValueError, 'TODO'):
                sdks.behavior_notes([sdk])
            path.write_text('Complete but no date')
            with self.assertRaisesRegex(ValueError, 'no survey date'):
                sdks.behavior_notes([sdk])
            path.write_text('Surveyed 2026-11-15. Complete fixture survey.')
            sdks.behavior_notes([sdk])
            sdks.behavior_notes([{**sdk, 'behavior_note': 'pending: separate researcher owns this survey'}])
            with self.assertRaisesRegex(ValueError, 'invalid behavior_note'):
                sdks.behavior_notes([{**sdk, 'publish': True, 'behavior_note': 'pending: separately assigned survey'}])

    @unittest.skipUnless(shutil.which('moon'), 'MoonBit toolchain is required for integration')
    def test_generated_alternative_auth_raw_sse_and_servers_execute_offline(self):
        files, ir = build()
        files['contract_gen.mbt'] += '''
///|
test "raw wrapper preserves upload bytes and marks caller idempotency key" {
  let backend = @client.from_fn((request, _) => {
    try! assert_eq(request.url, "https://api.example/uploads/raw")
    try! assert_eq(request.headers.get("content-type"), Some("application/octet-stream"))
    try! assert_eq(request.body, @http.Body::Bytes(b"upload"))
    try! assert_eq(request.attributes.get(@http.replay_safe), Some(true))
    @http.Response::new(200, body=Bytes(b"download"))
  })
  let sdk = Sample::new(backend, @sim.FakeClock::new())
  match @driver.run_sync(() => sdk.raw(b"upload", content_type="application/octet-stream", idempotency_key="unique")) {
    Ok(reply) => assert_eq(reply.body, b"download")
    _ => fail("raw wrapper failed")
  }
}
'''
        with tempfile.TemporaryDirectory(prefix='f2-client-') as tmp:
            tmp = Path(tmp)
            (tmp / 'moon.mod').write_text('name = "gaato/sample"\nversion = "0.1.0"\nsource = "src"\nimport { "gaato/mttp_core@0.1.0" }\n')
            # Moon owns this module's dependency directory. A repository symlink
            # is dangling on a fresh checkout and blocks Moon's mkdir with EEXIST.
            _write(tmp / 'src/gen', _format(emit(ir)))
            _write(tmp / 'src', _format(files))
            process = subprocess.run(['moon', '-C', str(tmp), 'test', '--target', 'wasm-gc'], text=True, capture_output=True)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            custom, _ = build(retry=dict(retries=1, methods='any', statuses=[429, [500, 599]],
                                        override_header='x-should-retry', retry_after='ms_then_header',
                                        retry_after_cap_ms=120000, zero_means_backoff=True,
                                        backoff_max_ms=8000, jitter=[750, 1000]))
            custom['contract_gen.mbt'] += '''
///|
test "custom retry honors override header and cap for POST" {
  let clock = @sim.FakeClock::new()
  let count = Ref(0)
  let backend = @client.from_fn((_, _) => {
    count.val += 1
    @http.Response::new(503, headers=@http.Headers::of([("x-should-retry", "false")]))
  })
  let sdk = Sample::new(backend, clock)
  ignore(@driver.run_sync(() => sdk.send(@http.Request::post("/contract-test"))))
  assert_eq(count.val, 1)
  let backend = @client.from_fn((_, _) => {
    count.val += 1
    @http.Response::new(503, headers=@http.Headers::of([("retry-after", "121")]))
  })
  let sdk = Sample::new(backend, clock)
  ignore(@driver.run_sync(() => sdk.send(@http.Request::post("/contract-test"))))
  assert_eq(count.val, 2)
  assert_eq(clock.slept(), [])
}
'''
            _write(tmp / 'src', _format(custom))
            process = subprocess.run(['moon', '-C', str(tmp), 'test', '--target', 'wasm-gc', '--deny-warn'], text=True, capture_output=True)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)


if __name__ == '__main__':
    unittest.main()
