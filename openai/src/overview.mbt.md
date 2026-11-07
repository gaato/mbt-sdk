# gaato/openai

An unofficial OpenAI API client for [MoonBit](https://www.moonbitlang.com/):
models, embeddings, Responses and Chat Completions, buffered and streaming,
with tool calling. Compatible servers are selected with `base_url`.
It uses [`gaato/mttp`](https://github.com/gaato/mttp), with a caller-supplied
`Backend` and `Clock`. The facade itself requires no async runtime.

> **Status**: unofficial and experimental. Minor releases may contain breaking
> changes; the
> [changelog](https://github.com/gaato/mbt-sdk/blob/main/openai/CHANGELOG.md)
> lists each one.

## Install

```sh
moon add gaato/openai
moon add gaato/mttp-net
moon add moonbitlang/async
```

## Usage

With `gaato/mttp-net/backend` imported as `@backend` and
`gaato/mttp-net/runtime` as `@runtime`, create the runtime adapters:

```mbt nocheck
///|
let backend = @backend.AsyncBackend::new(
  timeout_ms=600_000,
  connect_timeout_ms=5_000,
)

///|
let clock = @runtime.AsyncClock::new()

///|
let timer = @runtime.ClockTimer::new()
```

Then pass them to the client and send a request:

```mbt check
///|
/// Asks `model` one question and returns its answer.
pub async fn ask(
  backend : &@client.Backend,
  clock : &@clock.Clock,
  timer : &@clock.Timer,
  api_key~ : String,
  model~ : String,
) -> String {
  let openai = @openai.OpenAI::new(api_key~, backend, clock, timer~)
  let reply = openai.chat_completion(
    @openai.ChatRequest::new(model~, messages=[
      @openai.ChatMessage::user("Hello"),
    ]),
  )
  reply.text
}
```

Buffered responses are limited to 64 MiB by default. To change the limit,
construct an mttp `Client` with `RequestOptions.max_body_bytes` and pass it
to `from_client`. Streaming reads incrementally, with a 16 MiB per-event
limit. Limit failures raise `TransportError(TooLarge, ...)`. HTTP failures
raise `UnexpectedStatus` with the response head and body; invalid JSON or
schema mismatches raise `Deserialization`. `api_error` extracts API error
envelopes from HTTP failures. Callback errors propagate to the caller.

## Packages

| Package | What it is |
|---|---|
| `gaato/openai` | The `OpenAI` client and its request, response and event types |
| `gaato/openai/gen` | Types and operations generated from the vendored OpenAPI spec |

## Operations

The client has `list_models`, `retrieve_model`, `create_embeddings`,
`create_response`, `stream_response`, `chat_completion` and
`stream_chat_completion`. A request's `extra` map adds JSON fields the typed
request does not have.

## Streaming

`stream_response` and `stream_chat_completion` call a handler for each event
as it arrives:

```mbt check
///|
/// Streams a response, passing each piece of text to `on_text` as it arrives.
pub async fn stream_text(
  openai : @openai.OpenAI,
  model~ : String,
  on_text : (String) -> Unit,
) -> Unit {
  openai.stream_response(
    @openai.ResponseRequest::new(model~, input="Write a haiku about rivers."),
    event => if event is OutputTextDelta(text) { on_text(text) },
  )
}
```

`ToolCallAccumulator` reassembles streamed tool-call arguments. It grows with
what you feed it, so cap a stream by its events or bytes, and set a token
limit on the request.

## OpenAI-compatible servers

Pass `base_url` for a server that speaks the OpenAI API. Servers that
implement only Chat Completions take `ChatRequest` with `chat_completion` or
`stream_chat_completion`.

## Retries

Retries follow the official Python SDK: two retries of 408, 409, 429 and every
5xx, and of a timeout or network failure, for every method. That includes
`POST`, so a generation can run, and be billed, twice; pass
`retry=@client.RetryPolicy::conservative()` to retry a `POST` only on 429 and
on failures that prove nothing was sent. The server's `x-should-retry` is
obeyed, waits back off from 0.5 s to 8 s, and a `Retry-After` over two
minutes is raised rather than waited for.

## Timeouts

Each attempt defaults to 600 s. `total_timeout_ms` bounds the entire call,
including retries and their waits. A supplied timer controls cancellation;
otherwise mttp uses the supplied clock. Backend phase deadlines can finish
a call earlier; the example sets its exchange deadline to the same 600 s.
Streaming callbacks run after the attempt has been selected and are not
retried after delivery starts. Close the backend when its owner shuts down.

## Links

- [Changelog](https://github.com/gaato/mbt-sdk/blob/main/openai/CHANGELOG.md)
- [Repository](https://github.com/gaato/mbt-sdk)
- [Spec provenance](https://github.com/gaato/mbt-sdk/blob/main/openai/spec/SOURCE.md):
  where the vendored OpenAPI spec comes from

## License

Apache-2.0
