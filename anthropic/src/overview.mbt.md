# gaato/anthropic

An unofficial Anthropic Messages API client for
[MoonBit](https://www.moonbitlang.com/): messages, streaming, tool use, token
counting and Models. Compatible servers are selected with `base_url`.
It uses [`gaato/mttp`](https://github.com/gaato/mttp), with a caller-supplied
`Backend` and `Clock`. The facade itself requires no async runtime.

> **Status**: unofficial and experimental. Minor releases may contain breaking
> changes; the
> [changelog](https://github.com/gaato/mbt-sdk/blob/main/anthropic/CHANGELOG.md)
> lists each one with a migration note.

## Install

```sh
moon add gaato/anthropic
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

Then pass them to the client and send a message:

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
  let client = @anthropic.Anthropic::new(
    api_key~,
    backend,
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
twice; pass `retry=@client.RetryPolicy::conservative()` to retry a `POST`
only on 429 and on failures that prove nothing was sent. The server's
`x-should-retry` is obeyed, waits back off from 0.5 s to 8 s, and a
`Retry-After` is waited out however long it is, so bound the call with
`total_timeout_ms` as above: a wait that would outlast it is not begun.

## Timeouts

Each attempt defaults to 600 s. `total_timeout_ms` bounds the entire call,
including retries and their waits. A supplied timer controls cancellation;
otherwise mttp uses the supplied clock. Backend phase deadlines can finish
a call earlier; the example sets its exchange deadline to the same 600 s.
Streaming callbacks run after the attempt has been selected and are not
retried after delivery starts. Close the backend when its owner shuts down.

## Links

- [Changelog](https://github.com/gaato/mbt-sdk/blob/main/anthropic/CHANGELOG.md)
- [Repository](https://github.com/gaato/mbt-sdk)
- [Spec provenance](https://github.com/gaato/mbt-sdk/blob/main/anthropic/spec/SOURCE.md)
  and [generation overlays](https://github.com/gaato/mbt-sdk/blob/main/anthropic/overlays/moonbit.yaml)
- [Migrating from 0.1.0](https://github.com/gaato/mbt-sdk/blob/main/docs/anthropic-0.2.0.md#migration-from-010)

## License

Apache-2.0
