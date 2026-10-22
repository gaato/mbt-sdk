# gaato/anthropic

An unofficial Anthropic Messages API client for
[MoonBit](https://www.moonbitlang.com/): buffered and streaming messages, open
content blocks and stream events, tool use, token counting, and Models. It
also works against Anthropic-compatible servers through `base_url`. It is
built on [`gaato/http`](https://mooncakes.io/docs/gaato/http) and
[`gaato/sdk-runtime`](https://mooncakes.io/docs/gaato/sdk-runtime) and has no
async runtime of its own: the caller supplies a `Transport` and a `Clock`, for
example from [`gaato/http-async`](https://mooncakes.io/docs/gaato/http-async).

> **Status**: unofficial and experimental. Minor releases may contain breaking
> changes; the
> [changelog](https://github.com/gaato/mbt-sdk/blob/main/anthropic/CHANGELOG.md)
> lists each one with a migration note.

## Install

```sh
moon add gaato/anthropic
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

Then pass them to the client and send a message:

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
  let client = @anthropic.Anthropic::new(
    api_key~,
    transport,
    clock,
    timer~,
    total_timeout_ms=900_000,
  )
  let reply = client.create_message(
    @anthropic.MessageRequest::new(model~, max_tokens=1024, messages=[
      @anthropic.Message::user("Hello"),
    ]),
  )
  reply.text()
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
| `gaato/anthropic` | The `Anthropic` client, `MessageRequest`, `MessageResponse`, `MessageEvent`, and tool helpers |
| `gaato/anthropic/gen` | Request and response types and operations generated from the official Python SDK's OpenAPI document |

## Operations

The client has `create_message`, `stream_message`, `count_tokens`,
`list_models` and `retrieve_model`. Beta APIs, batches, files and other
endpoints are not included.

- `MessageRequest` takes typed input blocks, tool choice (the `tool_choice_*`
  helpers build the common ones), thinking, output configuration and
  metadata; its `extra` map adds fields it does not type.
- `create_message_params` and `stream_message_params` take the generated
  `CreateMessageParams`, for the whole request vocabulary.
- A `MessageResponse` keeps both the generated `message` and the original
  `raw` JSON. `Message::from_response` turns it into the assistant turn of the
  next request, and `tool_uses()` lists the tool calls it asks for.
- `client.paginate_models(limit=100).collect(max=1000)` collects up to 1000
  models across pages.

## Streaming

`stream_message` calls a handler for each `MessageEvent` as it arrives:

```mbt check
///|
/// Streams a message, passing each piece of text to `on_text` as it arrives.
pub async fn stream_text(
  client : @anthropic.Anthropic,
  model~ : String,
  on_text : (String) -> Unit,
) -> Unit {
  client.stream_message(
    @anthropic.MessageRequest::new(model~, max_tokens=1024, messages=[
      @anthropic.Message::user("Write a haiku about rivers."),
    ]),
    event => if event is TextDelta(text~, ..) { on_text(text) },
  )
}
```

`ToolUseAccumulator` reassembles streamed tool arguments. It grows with what
you feed it, so cap a stream by its events or bytes, and set `max_tokens`.

## Retries

Retries follow the official Python SDK: two retries of 408, 409, 429 and every
5xx (529 overloaded included), and of a timeout or network failure, for every
method. That includes `POST`, so a message can be generated, and billed,
twice; pass `retry=@runtime.RetryPolicy::conservative()` to retry a `POST`
only on 429 and on failures that prove nothing was sent. The server's
`x-should-retry` is obeyed, waits back off from 0.5 s to 8 s, and a
`Retry-After` is waited out however long it is, so bound the call with
`total_timeout_ms` as above: a wait that would outlast it is not begun.

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

- [Changelog](https://github.com/gaato/mbt-sdk/blob/main/anthropic/CHANGELOG.md)
- [Repository](https://github.com/gaato/mbt-sdk)
- [Spec provenance](https://github.com/gaato/mbt-sdk/blob/main/anthropic/spec/SOURCE.md)
  and [generation overlays](https://github.com/gaato/mbt-sdk/blob/main/anthropic/overlays/moonbit.yaml)
- [Migrating from 0.1.0](https://github.com/gaato/mbt-sdk/blob/main/docs/anthropic-0.2.0.md#migration-from-010)

## License

Apache-2.0
