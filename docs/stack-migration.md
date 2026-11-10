# HTTP stack migration

The SDKs now use gaato/http 0.6, gaato/http-async 0.6 and gaato/mttp 0.1.
The former shared runtime and the HTTP implementation directories have been
retired from this repository. HTTP engine/client tests and ledgers live in
[mttp](https://github.com/gaato/mttp).

## Calls and failures

Request builders return http.Request. Headers are immutable: retain the result
of set/add/remove. A request's method is Method (`meth`), and Body distinguishes
Empty, Bytes and a one-reader stream. Use body_json/body_bytes/body_stream.

Generated successful-response decoders take ResponseHead and Bytes and return
Result[T, mttp/client.ResponseFailure]. Pair them with a buffered response plan
or pass them to GitHub.call. JSON model helpers and Presence come from
mttp/jsonkit. No schema pins changed in this migration.

Facade calls return Result with OpenAIFailure, AnthropicFailure or GitHubFailure.
HTTP/deserialization failures retain real status, headers and bounded bytes.
Input validation is a value. TransportError, cancellation and user callback
exceptions remain effects. GraphQL failures retain both HTTP metadata and the
envelope, including partial data.

## Backend and policy

Supply &http.Backend and &http/rt.Clock. AsyncBackend is in
gaato/http-async/backend; clocks, Timer and gates are in http-async/runtime.
Content decoding uses the explicit codings.Decompress wrapper. Backends receive
SendOptions per attempt. A response owns its body and must be consumed or closed.

SDK vendor presets remain SDK-owned. OpenAI/Anthropic use their separate server
delay caps and 600-second attempt budget. GitHub keeps primary/secondary limit
and GraphQL rules, pacing and resource-keyed windows. Its default retry rule
retains 429 for every method; mttp's generic conservative preset restricts
429 to idempotent requests. A total deadline requires
Timer and includes admission, retry waits and streaming callbacks. A streaming
callback runs once after attempt selection and is never retried.

Mttp Paginator failures are values. SSE uses mttp/sse (through client.as_sse in
the facades); uploads use mttp/multipart. SDK-local helpers retained here are
vendor presets, validation, generated-model conversion, bounded response
diagnostics and GraphQL interpretation. They do not implement HTTP scheduling,
body framing, retry loops, timers, rate-limit state machines or parsers.

## Runtime connections

JSON-RPC and Codex sessions use moonbitlang/core/async. TaskGroup has no type
parameter, streams are BinaryReader/BinaryWriter and process output settings
are values. Opt in to the exact experimental packages imported by the calling
package. Never combine the two async runtimes in one executable.

Standalone maintenance scripts remain separate executables on their pinned
script-runtime imports, including the shared docs auditor. They do not add a
runtime dependency to any published module.

## Verification

Gates select local packages for formatting, interfaces and tests, so a local
workspace dependency remains read-only. Live and badhttp network suites are
compiled but never executed by gates; the recorded badhttp suite runs offline.
Generic client/limiter/multipart suites are owned by mttp; portable SDK tests
here use http/sim and http/driver.

Earlier SDK/generator design notes under docs are historical implementation
records. Current contracts and runnable examples are the repository contract,
module overviews and generated interfaces.
