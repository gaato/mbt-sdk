# mbt-sdk

[![CI](https://github.com/gaato/mbt-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/gaato/mbt-sdk/actions/workflows/ci.yml)
[![Live compat](https://github.com/gaato/mbt-sdk/actions/workflows/live-compat.yml/badge.svg)](https://github.com/gaato/mbt-sdk/actions/workflows/live-compat.yml)
[![Canary](https://github.com/gaato/mbt-sdk/actions/workflows/canary.yml/badge.svg)](https://github.com/gaato/mbt-sdk/actions/workflows/canary.yml)
[![Spec watch](https://github.com/gaato/mbt-sdk/actions/workflows/spec-watch.yml/badge.svg)](https://github.com/gaato/mbt-sdk/actions/workflows/spec-watch.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/gaato/mbt-sdk)
[![License](https://img.shields.io/github/license/gaato/mbt-sdk)](LICENSE)

A foundation for writing and *keeping alive* API SDKs in [MoonBit](https://www.moonbitlang.com/). Unofficial SDKs in small languages tend to ship once and rot; this repository is organised so that the two things that rot an SDK — upstream API changes and language changes — are each absorbed in one place.

Status: experimental. The HTTP, runtime and API modules are published on [mooncakes](https://mooncakes.io/); the JSON-RPC and Codex modules are not published yet.

## Modules

| Module | mooncakes | What it is | Depends on |
|---|---|---|---|
| `gaato/http` | [![mooncakes](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fmooncakes.io%2Fapi%2Fv0%2Fmodules%2Fgaato%2Fhttp&query=%24.version&label=mooncakes&prefix=v)](https://mooncakes.io/docs/gaato/http) | Sans-IO HTTP vocabulary: `Request`, `Response`, `Headers`, the `Transport` and `BodyStream` traits, middleware, a `Clock` trait, an incremental WHATWG-conformant SSE parser, and a scripted `FakeTransport` / `FakeClock` for tests | nothing (runs on wasm-gc, wasm, js, native) |
| `gaato/http-async` | [![mooncakes](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fmooncakes.io%2Fapi%2Fv0%2Fmodules%2Fgaato%2Fhttp-async&query=%24.version&label=mooncakes&prefix=v)](https://mooncakes.io/docs/gaato/http-async) | `AsyncTransport` (with a small keep-alive pool per origin) and `AsyncClock` over `moonbitlang/async` (native and js) | `gaato/http`, `moonbitlang/async` |
| `gaato/jsonrpc` | unpublished | Sans-IO JSON-RPC 2.0 vocabulary: `Message`, `RequestId`, `RpcError`, strict (`"jsonrpc":"2.0"`) and bare (codex app-server) envelopes, NDJSON encoding, an incremental `LineFramer` | nothing (runs on wasm-gc, wasm, js, native) |
| `gaato/jsonrpc-async` | unpublished | Bidirectional `Connection` over any `moonbitlang/async` reader/writer pair, plus `spawn_child` for JSON-RPC over a child process's stdio (native); the base for ACP and codex app-server clients | `gaato/jsonrpc`, `moonbitlang/async` |
| `gaato/codex-protocol` | unpublished | Codex app-server v2 types, typed calls and events generated from a pinned CLI JSON Schema | `gaato/sdk-runtime` (JSON helpers only) |
| `gaato/codex-app-server` | unpublished | Initialized Codex connections, native stdio sessions, progress events and explicit approval/user-input handlers; [usage and scope](codex-app-server/README.md) | `gaato/codex-protocol`, `gaato/jsonrpc-async`, `moonbitlang/async` |
| `gaato/sdk-runtime` | [![mooncakes](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fmooncakes.io%2Fapi%2Fv0%2Fmodules%2Fgaato%2Fsdk-runtime&query=%24.version&label=mooncakes&prefix=v)](https://mooncakes.io/docs/gaato/sdk-runtime) | API-agnostic client runtime: error taxonomy, `Retry-After` / `retry-after-ms`, backoff, retry policy, rate limiting, pagination, auth, tri-state JSON fields, open enums, multipart writer | `gaato/http` |
| `gaato/openai` | [![mooncakes](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fmooncakes.io%2Fapi%2Fv0%2Fmodules%2Fgaato%2Fopenai&query=%24.version&label=mooncakes&prefix=v)](https://mooncakes.io/docs/gaato/openai) | First consumer: a stable hand-written facade for models, embeddings, Responses, and Chat Completions (buffered and streaming), backed by types and operations generated from the vendored OpenAPI spec | `gaato/http`, `gaato/sdk-runtime` |
| `gaato/anthropic` | [![mooncakes](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fmooncakes.io%2Fapi%2Fv0%2Fmodules%2Fgaato%2Fanthropic&query=%24.version&label=mooncakes&prefix=v)](https://mooncakes.io/docs/gaato/anthropic) | Second consumer: Anthropic-compatible messages (buffered and streaming), including open content blocks and stream events | `gaato/http`, `gaato/sdk-runtime` |
| `runtime-tests/` | — | Unpublished. Executes the async behaviour of the modules above (a module without an async runtime cannot run `async test`) | everything |

HTTP SDK modules never import an async runtime: the caller passes a `Transport` and a `Clock`. That keeps them portable and makes retry, rate-limit and streaming logic testable with fakes and a fake clock. The Codex SDK keeps generated protocol types portable and puts connection/process ownership in a separate async module.

```moonbit
let transport = @http_async.AsyncTransport::new()
let clock = @http_async.AsyncClock::new()
let openai = @openai.OpenAI::new(api_key~, transport, clock)
openai.stream_response(@openai.ResponseRequest::new(model="gpt-5.6-sol", input="Hello"), event => {
  if event is OutputTextDelta(text) { print(text) }
})
```

For OpenAI-compatible servers that implement Chat Completions, use `ChatRequest` with `chat_completion` or `stream_chat_completion`. The opt-in live suite also accepts `OPENAI_COMPAT_BASE_URL` and `OPENAI_COMPAT_MODEL`; `OPENAI_COMPAT_API_KEY` is optional for local servers.

## Generation pipeline

```
openai/spec/openai.yaml → overlays/fix.yaml → overlays/moonbit.yaml → normalise → IR → openai/src/gen/*.mbt
      (vendored)          (upstream errors)     (x-moonbit-* hints)       tools/gen (Python)
```

- Overlays follow the [OpenAPI Overlay Specification](https://spec.openapis.org/overlay/latest.html). `tools/apply_overlay.py` fails on actions that match nothing or change nothing, so stale corrections surface instead of silently doing nothing.
- The generator supports JSON and multipart request bodies, form and deep-object query parameters, and tagged unions including disjoint tag-value sets. It refuses unsupported shapes (with a JSON pointer and an overlay annotation) instead of silently degrading to `Json`.
- Generated code is committed; users do not need Python.
- Codex uses `codex-protocol/spec/schema.json` → selected JSON Schema reference closure → shared IR/emitter → `codex-protocol/src/gen`. The schema is pinned to CLI 0.155.1; regeneration is offline and is covered by the same `--check` gate.

```fish
scripts/generate.sh          # apply overlays and regenerate
scripts/generate.sh --check  # CI: fail if the committed output is stale
scripts/gates.sh             # every check and test (native tests open loopback sockets)
scripts/conformance.sh       # opt-in: the SSE parser, transport and runtime against https://badhttp.dev
scripts/live.sh              # opt-in: live API tests; remote providers need keys, local ones need the servers below
scripts/compat-servers.sh    # start Ollama (qwen2.5:0.5b, accepts tools) + a LiteLLM proxy speaking Anthropic /v1/messages; prints the *_COMPAT_* env
```

`scripts/gates.sh` defines the validation suite, including target checks, tests, generation checks, formatting, and `moon info`. It accepts `--no-native-tests` when loopback sockets are unavailable and `--no-js` when Node is unavailable; those options skip coverage. Public interfaces (`pkg.generated.mbti`) are committed alongside the source and regenerated with `moon info` after API changes.

`scripts/live.sh` reads provider settings from the environment or `~/.config/mbt-sdk/env`. Remote tests make actual provider requests and may incur charges. Providers without keys are skipped; `MBT_SDK_ENV=/dev/null` disables loading the settings file.

## Automation

- `ci.yml` — gates on a pinned toolchain image (`ghcr.io/gaato/moonbit:<version>`).
- `canary.yml` — the same gates daily on `:latest`; red here with green CI means the language moved.
- `spec-watch.yml` — daily upstream spec check; on change it re-vendors, regenerates, runs the gates and opens a PR.
- `live-compat.yml` — the live suite against local, key-free OpenAI- and Anthropic-compatible servers (Ollama + LiteLLM, always their latest release, so a change in either shows up here). Remote providers skip without keys.

Design notes (Japanese): `docs/design.md` (M1), `docs/design-m2.md`, `docs/design-m3.md`, `docs/design-m4.md`, `docs/design-m5.md`, `docs/design-m6.md`, `docs/design-m7.md`. Release procedure: `docs/release.md`.

## License

Apache-2.0.
