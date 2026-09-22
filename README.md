# mbt-sdk

A foundation for writing and *keeping alive* API SDKs in [MoonBit](https://www.moonbitlang.com/). Unofficial SDKs in small languages tend to ship once and rot; this repository is organised so that the two things that rot an SDK — upstream API changes and language changes — are each absorbed in one place.

Status: experimental, unpublished. Module names are provisional.

## Modules

| Module | What it is | Depends on |
|---|---|---|
| `gaato/http` | Sans-IO HTTP vocabulary: `Request`, `Response`, `Headers`, the `Transport` and `BodyStream` traits, middleware, a `Clock` trait, an incremental WHATWG-conformant SSE parser, and a scripted `FakeTransport` / `FakeClock` for tests | nothing (runs on wasm-gc, wasm, js, native) |
| `gaato/http-async` | `AsyncTransport` and `AsyncClock` over `moonbitlang/async` (native and js) | `gaato/http`, `moonbitlang/async` |
| `gaato/sdk-runtime` | API-agnostic client runtime: error taxonomy, `Retry-After` / `retry-after-ms`, backoff, retry policy, rate limiting, pagination, auth, tri-state JSON fields, open enums, multipart writer | `gaato/http` |
| `gaato/openai` | First consumer: a stable hand-written facade for models, embeddings, Responses, and Chat Completions (buffered and streaming), backed by types and operations generated from the vendored OpenAPI spec | `gaato/http`, `gaato/sdk-runtime` |
| `gaato/anthropic` | Second consumer: Anthropic-compatible messages (buffered and streaming), including open content blocks and stream events | `gaato/http`, `gaato/sdk-runtime` |
| `runtime-tests/` | Unpublished. Executes the async behaviour of the modules above (a module without an async runtime cannot run `async test`) | everything |

SDK modules never import an async runtime: the caller passes a `Transport` and a `Clock`. That keeps them portable and makes retry, rate-limit and streaming logic testable with fakes and a fake clock.

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

```sh
scripts/generate.sh          # apply overlays and regenerate
scripts/generate.sh --check  # CI: fail if the committed output is stale
scripts/gates.sh             # every check and test (native tests open loopback sockets)
scripts/conformance.sh       # opt-in: the SSE parser, transport and runtime against https://badhttp.dev
scripts/live.sh              # opt-in: OpenAI and OpenRouter live API tests (never a gate)
```

## Automation

- `ci.yml` — gates on a pinned toolchain image (`ghcr.io/gaato/moonbit:<version>`).
- `canary.yml` — the same gates daily on `:latest`; red here with green CI means the language moved.
- `spec-watch.yml` — daily upstream spec check; on change it re-vendors, regenerates, runs the gates and opens a PR.

Design notes (Japanese): `docs/design.md` (M1), `docs/design-m2.md`, `docs/design-m3.md`, `docs/design-m4.md`, `docs/design-m5.md`. Release procedure: `docs/release.md`. Conventions for coding agents: `AGENTS.md`.

## License

Apache-2.0.
