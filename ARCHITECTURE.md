# Architecture

This repository generates and maintains API SDKs and a Codex app-server client.
HTTP infrastructure lives in [mttp](https://github.com/gaato/mttp).

## Layers

| Layer | Modules | Responsibility |
|---|---|---|
| Applications | consumer code | Backend, clock, timer and credentials |
| SDKs | openai, anthropic, github | Generated API vocabulary and vendor policy |
| Codex | codex-protocol, codex-app-server | Generated protocol and initialized sessions |
| RPC | jsonrpc, jsonrpc-async | Portable messages/framing and runtime connections |
| External HTTP | gaato/mttp_core, gaato/mttp | Vocabulary, engines and client policy; I/O |

The SDKs depend on `gaato/mttp_core`, with no runtime dependency.
They accept `&Backend`, `&rt.Clock` and optionally `&rt.Timer`. Their clients
use mttp RequestPlan/ResponsePlan, Result-based response failures, admission
tokens, retries, SSE and pagination. Immutable Headers and Request builders
return new values. Uploads use mttp multipart bodies.

OpenAI and Anthropic keep their Stainless retry presets and facade validation
inside their own packages. GitHub owns its primary/secondary rate-limit and
GraphQL conditions, using the generic mttp limiter and typed retry callback.
TransportError and user callback exceptions keep their effect identity.

`gaato/mttp/backend.AsyncBackend` supplies I/O. Content decoding is an
explicit `gaato/mttp/codings.Decompress` wrapper. Backends take
SendOptions for each attempt; response bodies belong to their consumer.

## Generation

Pinned specs under each module's `spec/` pass through overlays, normalization,
IR and `tools/gen/emit_moonbit.py`. Generated code is committed under `src/gen`;
users need no Python. The generator stays in Python so language changes do not
also break the tool that regenerates the SDKs. Unknown shapes are rejected with
overlay locations rather than silently degraded to Json. The census documents
intentional raw Json surfaces.

Generated request functions return http.Request. Successful response decoders
take ResponseHead and Bytes and return Result with mttp_core/client.ResponseFailure. JSON
model helpers come from mttp_core/jsonkit. Codex generation uses the same model
emitter without an HTTP dependency.

## Runtime connections

jsonrpc-async and codex-app-server import `moonbitlang/core/async`, with exact
experimental package opt-ins. BinaryReader/BinaryWriter, TaskGroup and process
ownership are visible in their APIs; generated protocol types remain portable.
The two async runtimes are never linked into one program. Standalone repository
maintenance scripts still use their pinned script-runtime imports; they are
separate executables and do not enter any module's dependency graph.

## Validation

`scripts/gates.sh` checks supported targets, runs tests, generator unit tests,
regeneration checks, formatting, interfaces, spec censuses, bounds and docs.
Portable SDK integration suites use http/sim and http/driver. Native integration
also uploads multipart streams and replays recorded badhttp responses offline.
Conformance checks URL, cookies, SSE and JSON-RPC as external consumers.
Generic HTTP/client suites now belong to mttp. Coverage measures the local
hand-written JSON-RPC and Codex connection modules.

Opt-in live tests remain outside gates and require credentials or compatible
servers. See [live-tests.md](docs/live-tests.md), [CONTRACT.md](CONTRACT.md),
[RESOURCE_BOUNDS.md](RESOURCE_BOUNDS.md) and [TEST_COVERAGE.md](TEST_COVERAGE.md).
