# gaato/openai

Unofficial OpenAI API client for MoonBit: models, embeddings, Responses and Chat Completions (buffered and streaming, with tool calling), on `gaato/http` and `gaato/sdk-runtime`. Types and operations are generated from the vendored OpenAPI spec; the hand-written facade stays stable across regenerations.

Works against OpenAI-compatible servers through `base_url`. The caller supplies a `Transport` and a `Clock`, for example `gaato/http-async`.

```moonbit
let transport = @http_async.AsyncTransport::new(max_body_bytes=64 * 1024 * 1024)
let clock = @http_async.AsyncClock::new()
let openai = @openai.OpenAI::new(api_key~, transport, clock)
let reply = openai.chat_completion(@openai.ChatRequest::new(
  model="gpt-5.6-sol",
  messages=[@openai.ChatMessage::user("Hello")],
))
```

Set `max_body_bytes` as above: the transport is unbounded unless told otherwise, and this client cannot set it because the transport is yours. 64 MiB is ample for API JSON; a longer reply fails with `@runtime.Transport(Protocol(..))` rather than growing memory. Streaming calls are not affected.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk
