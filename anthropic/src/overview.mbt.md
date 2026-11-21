# gaato/anthropic

Call Anthropic's Messages API from MoonBit: send a message, stream text as it
arrives, and let the model call your own functions with the results carried
into the next turn. The client also counts input tokens and lists or retrieves
models. `base_url` selects a server that implements the same API.

The client does no I/O of its own. It sends through an HTTP `Backend` and reads
time from a `Clock` that you pass in, so it builds for every MoonBit target and
a test can hand it a fake backend. `gaato/mttp` supplies the real ones.

Unofficial, and not affiliated with Anthropic. A minor release can change the
API; the
[changelog](https://github.com/gaato/moonbit-sdks/blob/main/anthropic/CHANGELOG.md)
lists each change.

What it does not cover: the beta APIs, message batches and the Files API.

## Install

```sh
moon add gaato/anthropic
moon add gaato/mttp
```

An application imports `gaato/anthropic` and `gaato/mttp`. `gaato/mttp`
supplies the network, the clock and the timer the client needs. A library that
wraps this SDK adds `gaato/mttp_core` instead, and takes those three from its
caller, so its tests can use a fake backend.

## A complete program

`answer` sends one question and returns the reply's text:

```mbt check
///|
pub async fn answer(
  client : @anthropic.Anthropic,
  model : String,
  question : String,
) -> Result[String, @anthropic.AnthropicFailure] {
  let request = @anthropic.MessageRequest::new(model~, max_tokens=1024, messages=[
    @anthropic.Message::user(question),
  ])
  match client.create_message(request) {
    Ok(message) => Ok(message.text())
    Err(failure) => Err(failure)
  }
}
```

A command-line program builds the client once, from mttp's backend, clock and
timer, and closes the backend when it is done. Import `gaato/mttp`,
`moonbitlang/core/env` and `moonbitlang/core/debug` in its `moon.pkg`:

```mbt nocheck
///|
fn main {
  @mttp.run(async fn() {
    guard @env.get_env_var("ANTHROPIC_API_KEY") is Some(api_key) else {
      println("Set ANTHROPIC_API_KEY")
      return
    }
    guard @env.get_env_var("ANTHROPIC_MODEL") is Some(model) else {
      println("Set ANTHROPIC_MODEL to a model your account can use")
      return
    }
    let backend = @mttp.backend()
    defer backend.close()
    let client = @anthropic.Anthropic::new(
      api_key~,
      backend,
      @mttp.clock(),
      timer=@mttp.timer(),
    )
    match answer(client, model, "Write a haiku about rivers.") {
      Ok(text) => println(text)
      Err(failure) => println(@debug.to_string(failure))
    }
  })
}
```

Run it with `moon run . --target native`. Build one `Anthropic` value and reuse
it, so calls share connections. A system prompt goes in
`MessageRequest::new(system=...)`. To keep a conversation, pass the earlier
`Message::user` and `Message::assistant` turns in `messages` with each request.

`Message::user_blocks` takes content blocks from `gaato/anthropic/gen` instead
of a string, so a user turn can carry images (base64, URL or file ID) and PDF
or plain-text documents beside its text.

## Stream text as it arrives

```mbt check
///|
/// Streams a message, passing each piece of text to `on_text` as it arrives.
pub async fn stream_text(
  client : @anthropic.Anthropic,
  model~ : String,
  on_text : (String) -> Unit,
) -> Result[Unit, @anthropic.AnthropicFailure] {
  client.stream_message(
    @anthropic.MessageRequest::new(model~, max_tokens=1024, messages=[
      @anthropic.Message::user("Write a haiku about rivers."),
    ]),
    event => if event is TextDelta(text~, ..) { on_text(text) },
  )
}
```

The callback receives every `MessageEvent`. For a streamed tool call,
`ToolUseAccumulator` joins the partial JSON arguments. It grows with what you
feed it, so bound the stream as well as `max_tokens`.

## Let the model call your function

Give the model a tool definition, and supply the function in your application.
This example allows one stock lookup, then asks for a final reply. If the model
answers immediately, or asks the user for a SKU, the first message goes
straight back to the caller.

```mbt check
///|
pub async fn answer_with_stock(
  client : @anthropic.Anthropic,
  model : String,
  question : String,
  stock_for : (String) -> String,
) -> Result[@anthropic.MessageResponse, @anthropic.AnthropicFailure] {
  let tool = @anthropic.ToolDef::new(
    name="lookup_stock",
    description="Look up availability for a product SKU",
    input_schema={
      "type": "object",
      "properties": { "sku": { "type": "string" } },
      "required": ["sku"],
    },
  )
  let user = @anthropic.Message::user(question)
  let request = @anthropic.MessageRequest::new(
    model~,
    max_tokens=1024,
    messages=[user],
    tools=[tool],
    tool_choice=@anthropic.tool_choice_auto(disable_parallel_tool_use=true),
  )
  let first = match client.create_message(request) {
    Ok(reply) => reply
    Err(failure) => return Err(failure)
  }
  guard first.tool_uses() is [(id, name, input)] else { return Ok(first) }
  let result = match (name, input) {
    ("lookup_stock", { "sku": String(sku), .. }) =>
      @anthropic.Message::tool_result(tool_use_id=id, content=stock_for(sku))
    _ =>
      @anthropic.Message::tool_result(
        tool_use_id=id,
        content="Expected lookup_stock with a string SKU.",
        is_error=true,
      )
  }
  client.create_message(
    @anthropic.MessageRequest::new(
      model~,
      max_tokens=1024,
      tools=[tool],
      tool_choice=@anthropic.tool_choice_none(),
      messages=[user, @anthropic.Message::from_response(first), result],
    ),
  )
}
```

Read `text()` from the returned message. The second request carries the
original user message, the assistant's whole tool-use turn
(`Message::from_response`) and a result with the matching `tool_use_id`.
Keeping only the assistant's text would lose the tool-use block, and the API
would refuse the result.

## Other operations

The client also has `count_tokens`, `list_models`, `retrieve_model` and
`paginate_models`. `MessageRequest` takes thinking, output configuration,
metadata and stop sequences, and its `extra` map adds fields it does not type.
`create_message_params` and `stream_message_params` take the generated
`CreateMessageParams` from `gaato/anthropic/gen` for the whole request
vocabulary. `auth_header=Bearer` sends the key as `authorization: Bearer` for
gateways that expect it, with `base_url` set to the gateway's root.

## Failures, retries and deadlines

A call returns `Err` for a failure the server reported, and raises for a
failure to reach it:

- `Err(Validation(...))`: invalid input, caught before sending.
- `Err(Response(...))`: an HTTP or decoding failure. `api_error(failure)`
  extracts Anthropic's error envelope from it.
- Raised `TransportError`: the network failed, a deadline expired, or a body
  passed its limit.

| Setting | Default | Notes |
| --- | --- | --- |
| Retries | 2, on 408, 409, 429, 5xx (529 overloaded included), timeouts and network failures, **POST included**; `x-should-retry` is obeyed | As in Anthropic's official Python SDK. A retried message can be billed twice. `retry=@mttp.RetryPolicy::conservative()` retries a POST only when nothing was sent. |
| `Retry-After` | Waited out, however long | Bound the call with `total_timeout_ms`: a wait that would outlast it is not begun. |
| `timeout_ms` | 600 s per attempt | Needs `timer=`. |
| `total_timeout_ms` | none | Needs `timer=`. Covers retries, waits and stream callbacks. |
| Buffered body | 64 MiB | `max_body_bytes=` |
| Stream event | 16 MiB each | |

Once a stream has started delivering events, it is never replayed.

The SDK marks `x-api-key` and `authorization` as credentials on each request,
including with `from_client`. A redirect strips them when the host, port or
scheme changes, except for a same-host HTTP port 80 to HTTPS port 443 upgrade.
HTTPS to HTTP is refused by default.

## Packages

| Package | What it is |
|---|---|
| `gaato/anthropic` | The `Anthropic` client, `MessageRequest`, `MessageResponse`, `MessageEvent` and tool helpers |
| `gaato/anthropic/gen` | Types and operations generated from the official Python SDK's OpenAPI document |

## Links

- [Changelog](https://github.com/gaato/moonbit-sdks/blob/main/anthropic/CHANGELOG.md)
- [Repository](https://github.com/gaato/moonbit-sdks)
- [Spec provenance](https://github.com/gaato/moonbit-sdks/blob/main/anthropic/spec/SOURCE.md)

## License

Apache-2.0
