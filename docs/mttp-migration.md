# SDK migration to mttp

This is the first migration stage: generated request builders and decoders,
and the OpenAI, Anthropic and GitHub facades, now use `gaato/mttp`. Generated
endpoint definitions are a separate, opt-in later stage. The generator remains
Python; generated files are regenerated through `scripts/generate.sh`.

Keep a sibling `gaato/mttp` checkout while these dependencies are unpublished;
`moon.work` includes its `mttp` and `mttp-net` modules. Published consumer
manifests depend on the core only. Applications choose a runtime backend.

## API changes

| Previous API | Replacement |
|---|---|
| `gaato/http`, `gaato/sdk-runtime` | `gaato/mttp/model`, `gaato/mttp/client` |
| `Transport`, `send` plus `send_stream` | One `Backend.send` returning a response whose body may stream |
| `http-async.AsyncTransport` | `mttp-net/backend.AsyncBackend` |
| `http-async.AsyncClock`, `ClockTimer`, `SemaphoreGate` | `mttp-net/runtime` equivalents |
| Generated `decode(Response)` | Generated `decode(ResponseHead, Bytes)` |
| `Headers.new/from_array`, mutable header updates | `Headers.empty/of`, updates return a new value |
| `Request.http_method`, `json_body` | `Request.meth`, `body_json` |
| `SdkError.Status`, `RateLimited` | `ResponseError.UnexpectedStatus(head, body~)` |
| `SdkError.Decode` | `ResponseError.Deserialization(head, message~, body~)` |
| `SdkError.Config` | `InvalidRequest(message~)` |
| Wrapped transport errors | `model.TransportError` directly |
| `error.status()` | `client.status_of(error)` |
| Auth variants on Client | Default immutable headers on Client |

Facade operations propagate open errors so cancellation and callback failures
retain their original identity. Streaming callback parameters use the open
error type; wrap a named callback with a closed error type in a lambda.
Buffered decoders run inside the attempt reader; streaming delivery starts
after attempt selection and cannot be replayed after callbacks have run.

OpenAI and Anthropic still use their existing Stainless retry policies and
600-second attempt default. Their optional timer now selects the cancellation
implementation; omitting it uses the supplied clock. Buffered replies default
to 64 MiB and SSE events to 16 MiB. `from_client` accepts a Client with custom
request options, headers, timers and policy.

`GitHub.send` returns `Reply[Bytes]`. `call` and `paginator` accept the generated
two-argument decoder. `GitHub.new` takes `options`, `timer` and
`total_timeout_ms` instead of `Timeouts`. Its rate limiter and pacing remain
unchanged. GraphQL failures now use `GraphqlFailure(head, message~, body~)`;
this preserves HTTP 200 instead of inventing an HTTP error status for a
GraphQL rate limit. `graphql_errors` and `is_secondary_rate_limit` understand
that error. Query transient failures and primary/secondary rate limits are
still decided inside the attempt loop; transient mutation failures are not
retried. `graphql_response` still retains other partial-data envelopes.

Codex protocol generation uses `mttp/jsonkit`; its wire vocabulary is unchanged.
The legacy `http`, `http-async` and `sdk-runtime` implementations remain intact
for unmigrated consumers and their regression suites.

## Validation

Run `moon run scripts/mttp-check.mbtx` from the repository root for the scoped
migration gate. It checks all workspace targets, runs the SDK suites below,
then verifies formatting, interfaces, docs, bounds and generator output.

The generated fixture tests and facade tests run on native, wasm, wasm-gc and
JavaScript. Existing SDK behavioural tests retain their cases in `runtime-tests`
and use the test-only `sdk_mock` adapter over mttp's strict `BackendStub`.
These tests cover request bytes, headers, pagination, retries, rate limits,
stream splits, sentinel handling and close behaviour on native and JavaScript.
Live provider and badhttp suites are opt-in; checking them is not evidence of
an external service test run.
