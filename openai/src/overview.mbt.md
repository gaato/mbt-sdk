# gaato/openai

An unofficial OpenAI API client for [MoonBit](https://www.moonbitlang.com/):
models, embeddings, Responses and Chat Completions, buffered and streaming,
with tool calling. It also works against OpenAI-compatible servers through
`base_url`. It is built on [`gaato/http`](https://mooncakes.io/docs/gaato/http)
and [`gaato/sdk-runtime`](https://mooncakes.io/docs/gaato/sdk-runtime) and
has no async runtime of its own: the caller supplies a `Transport` and a
`Clock`, for example from
[`gaato/http-async`](https://mooncakes.io/docs/gaato/http-async).

> **Status**: unofficial and experimental. Minor releases may contain breaking
> changes; the
> [changelog](https://github.com/gaato/mbt-sdk/blob/main/openai/CHANGELOG.md)
> lists each one.

## Install

```sh
moon add gaato/openai
moon add gaato/http-async
moon add moonbitlang/async
```

## Usage

Make a transport, a clock and a timer with `gaato/http-async`:

```mbt nocheck
///|
let transport = @http_async.AsyncTransport::new(
  timeout_ms=600_000,
  connect_timeout_ms=5_000,
  max_body_bytes=64 * 1024 * 1024,
)

///|
let clock = @http_async.AsyncClock::new()

///|
let timer = @http_async.ClockTimer::new()
```

Then pass them to the client and send a request:

```mbt check
///|
/// Asks `model` one question and returns its answer.
pub async fn ask(
  transport : &@http.Transport,
  clock : &@clock.Clock,
  timer : &@sync.Timer,
  api_key~ : String,
  model~ : String,
) -> String raise @runtime.SdkError {
  let openai = @openai.OpenAI::new(api_key~, transport, clock, timer~)
  let reply = openai.chat_completion(
    @openai.ChatRequest::new(model~, messages=[
      @openai.ChatMessage::user("Hello"),
    ]),
  )
  reply.text
}
```

Set `max_body_bytes` as above: the transport reads a buffered body whole
unless told otherwise, and this client cannot set it because the transport is
yours. 64 MiB is ample for API JSON; a longer reply fails with
`@runtime.Transport(Protocol(..))` rather than growing memory. Streaming calls
are not affected.

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
`retry=@runtime.RetryPolicy::conservative()` to retry a `POST` only on 429 and
on failures that prove nothing was sent. The server's `x-should-retry` is
obeyed, waits back off from 0.5 s to 8 s, and a `Retry-After` over two
minutes is raised rather than waited for.

## Timeouts

The official SDKs limit a call to 600 s, and connecting to 5 s. This module
has no clock of its own to enforce that, so pass a timer, as above:
`ClockTimer` from `gaato/http-async` limits each attempt to `timeout_ms`
(600 s by default), and `total_timeout_ms` limits the whole call, retries and
their waits included. Give the transport the same limits, as above:
`AsyncTransport`'s own exchange timeout defaults to 30 s, which would cut a
long generation off before the 600 s limit is reached. Without a timer, only
the transport's timeouts apply.

## Links

- [Changelog](https://github.com/gaato/mbt-sdk/blob/main/openai/CHANGELOG.md)
- [Repository](https://github.com/gaato/mbt-sdk)
- [Spec provenance](https://github.com/gaato/mbt-sdk/blob/main/openai/spec/SOURCE.md):
  where the vendored OpenAPI spec comes from

## License

Apache-2.0
