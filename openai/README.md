# gaato/openai

Unofficial OpenAI API client for MoonBit: models, embeddings, Responses and Chat Completions (buffered and streaming, with tool calling), on `gaato/http` and `gaato/sdk-runtime`. Types and operations are generated from the vendored OpenAPI spec; the hand-written facade stays stable across regenerations.

Works against OpenAI-compatible servers through `base_url`. The caller supplies a `Transport` and a `Clock`, for example `gaato/http-async`.

```moonbit
let transport = @http_async.AsyncTransport::new(
  timeout_ms=600_000,
  connect_timeout_ms=5_000,
  max_body_bytes=64 * 1024 * 1024,
)
let clock = @http_async.AsyncClock::new()
let openai = @openai.OpenAI::new(api_key~, transport, clock, timer=@http_async.ClockTimer::new())
let reply = openai.chat_completion(@openai.ChatRequest::new(
  model="gpt-5.6-sol",
  messages=[@openai.ChatMessage::user("Hello")],
))
```

Set `max_body_bytes` as above: the transport is unbounded unless told otherwise, and this client cannot set it because the transport is yours. 64 MiB is ample for API JSON; a longer reply fails with `@runtime.Transport(Protocol(..))` rather than growing memory. Streaming calls are not affected.

Retries follow the official Python SDK: two retries of 408, 409, 429 and every 5xx, and of a timeout or network failure, for every method. That includes `POST`, so a generation can run, and be billed, twice; pass `retry=@runtime.RetryPolicy::conservative()` to retry a `POST` only on 429 and on failures that prove nothing was sent. The server's `x-should-retry` is obeyed, waits back off from 0.5 s to 8 s, and a `Retry-After` over two minutes is raised rather than waited for.

The official SDKs limit a call to 600 s, and connecting to 5 s. This module has no clock of its own to enforce that, so pass a timer, as above: `ClockTimer` from `gaato/http-async` limits each attempt to `timeout_ms` (600 s by default), and `total_timeout_ms` limits the whole call, retries and their waits included. Give the transport the same limits, as above: `AsyncTransport`'s own exchange timeout defaults to 30 s, which would cut a long generation off before the 600 s limit is reached. Without a timer, only the transport's timeouts apply.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk
