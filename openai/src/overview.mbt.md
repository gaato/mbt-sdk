# gaato/openai

An unofficial OpenAI API client for MoonBit. It sends Responses and Chat
Completions requests, buffered or streamed, with function tools; creates
embeddings; and lists and retrieves models. Through `base_url`, the same client
talks to other servers that implement the OpenAI API, such as Ollama,
OpenRouter or DeepSeek.

The client does no I/O of its own. It sends through an HTTP `Backend` and reads
time from a `Clock` that you pass in, so it builds for every MoonBit target and
a test can hand it a fake backend. `gaato/mttp` supplies the real ones.

Not affiliated with OpenAI. A minor release can change the API; the
[changelog](https://github.com/gaato/moonbit-sdks/blob/main/openai/CHANGELOG.md)
lists every change.

What it does not cover:

- OpenAI endpoints other than the ones above, such as images, audio, files,
  batches or the Realtime API.
- Image, audio or file inputs. Chat message content and Responses input are
  plain strings, and `extra` cannot replace them.
- Base64 embeddings. Vectors are decoded from JSON number arrays.

## Install

```sh
moon add gaato/openai
moon add gaato/mttp
```

An application imports `gaato/openai` and `gaato/mttp`. A library that wraps
this client adds `gaato/mttp_core` instead of `gaato/mttp`, and takes the
backend and clock from its caller.

## Ask a question

`ask` sends one question and returns the reply's text:

```mbt check
///|
pub async fn ask(
  client : @openai.OpenAI,
  model : String,
  question : String,
) -> Result[String, @openai.OpenAIFailure] {
  let request = @openai.ChatRequest::new(model~, messages=[
    @openai.ChatMessage::user(question),
  ])
  match client.chat_completion(request) {
    Ok(reply) => Ok(reply.text)
    Err(failure) => Err(failure)
  }
}
```

A native command-line program around it imports `gaato/openai`, `gaato/mttp`,
`moonbitlang/core/env` and `moonbitlang/core/debug` in its `moon.pkg`. Set
`OPENAI_API_KEY` and `OPENAI_MODEL`, and `OPENAI_BASE_URL` for a compatible
server, then run `moon run <package> --target native -- "What is a lunar eclipse?"`.

```mbt nocheck
///|
fn main {
  guard @env.args() is [_, question] else {
    println("Pass one quoted question.")
    @env.exit(2)
  }
  guard @env.get_env_var("OPENAI_API_KEY") is Some(api_key) &&
    @env.get_env_var("OPENAI_MODEL") is Some(model) else {
    println("Set OPENAI_API_KEY and OPENAI_MODEL.")
    @env.exit(2)
  }
  @mttp.run(async fn() {
    let backend = @mttp.backend()
    defer backend.close()
    let openai = @openai.OpenAI::new(
      api_key~,
      backend,
      @mttp.clock(),
      timer=@mttp.timer(),
      base_url?=@env.get_env_var("OPENAI_BASE_URL"),
    )
    match ask(openai, model, question) {
      Ok(text) => println(text)
      Err(failure) => {
        println(@debug.to_string(failure))
        @env.exit(1)
      }
    }
  })
}
```

Build one `OpenAI` value and reuse it for every call. To keep a conversation
going, pass the earlier `ChatMessage::system`, `user` and `assistant` turns in
`messages` with each request.

## Stream text as it arrives

```mbt check
///|
/// Streams a response, passing each piece of text to `on_text` as it arrives.
pub async fn stream_text(
  openai : @openai.OpenAI,
  model~ : String,
  on_text : (String) -> Unit,
) -> Result[Unit, @openai.OpenAIFailure] {
  openai.stream_response(
    @openai.ResponseRequest::new(model~, input="Write a haiku about rivers."),
    event => if event is OutputTextDelta(text) { on_text(text) },
  )
}
```

The callback receives every `ResponseEvent`; this one keeps only the text.
`stream_chat_completion` takes the same `ChatRequest` as `chat_completion` and
delivers `ChatEvent`s: `Delta` text, `ReasoningDelta`, `ToolCallDelta`,
`Finished` and `Usage`. Feed each `ToolCallDelta` to a `ToolCallAccumulator`,
including its `extra` map, and call `finish()` for the complete `ToolCall`s.
The call returns when the stream ends, which can happen without a `Finished`
event. Event, status and finish-reason enums keep unknown values and are
`#non_exhaustive`, so a `match` on them needs a `_` arm.

## Let the model call your function

Here the application supplies `stock_for`, which looks up a product by SKU and
returns its availability as text. The model either answers at once or asks for
lookups; each result goes back with its call's ID, and the second reply is the
answer.

```mbt check
///|
pub async fn answer_with_stock(
  client : @openai.OpenAI,
  model : String,
  question : String,
  stock_for : (String) -> String,
) -> Result[String, @openai.OpenAIFailure] {
  let tools = [
    @openai.ToolDef::new(
      name="lookup_stock",
      description="Look up availability for a product SKU",
      parameters={
        "type": "object",
        "properties": { "sku": { "type": "string" } },
        "required": ["sku"],
      },
    ),
  ]
  let messages = [@openai.ChatMessage::user(question)]
  let first = match
    client.chat_completion(@openai.ChatRequest::new(model~, messages~, tools~)) {
    Ok(reply) => reply
    Err(failure) => return Err(failure)
  }
  if first.tool_calls.is_empty() {
    return Ok(first.text)
  }
  // The assistant turn goes back first, with any reasoning the server sent.
  messages.push(
    @openai.ChatMessage::assistant_tool_calls(
      first.tool_calls,
      content=first.text,
      reasoning_content?=first.reasoning_content,
    ),
  )
  for call in first.tool_calls {
    let args = Some(call.arguments_json()) catch { _ => None }
    let result = match (call.name, args) {
      ("lookup_stock", Some({ "sku": String(sku), .. })) => stock_for(sku)
      _ => "Lookup failed: expected lookup_stock with a string sku."
    }
    messages.push(
      @openai.ChatMessage::tool(tool_call_id=call.id, content=result),
    )
  }
  // `tool_choice="none"` asks for the answer instead of another lookup.
  let request = @openai.ChatRequest::new(
    model~,
    messages~,
    tools~,
    tool_choice="none",
  )
  match client.chat_completion(request) {
    Ok(reply) => Ok(reply.text)
    Err(failure) => Err(failure)
  }
}
```

`ToolCall.arguments` is the model's raw text; `arguments_json()` parses it and
raises if it is not JSON. `assistant_tool_calls` also sends back each call's
`extra` fields, such as Gemini's thought signatures.

With the Responses API, pass `tools` to `ResponseRequest::new`, read
`Response.tool_calls`, and send the results in a new request with
`previous_response_id=first.id` and `.with_tool_outputs([(call.id, output)])`.
That request still sends its `input` as a user message beside the outputs.

## Other operations

`list_models()`, `retrieve_model(id)` and
`create_embeddings(@openai.EmbeddingRequest::new(model~, input=[...]))` return
`Model`s and an `EmbeddingResponse` whose `data[i].embedding` is an
`Array[Double]`. `ChatCompletion.raw` and `Response.raw` keep the full JSON for
fields the typed view leaves out.

`extra` on `ChatRequest`, `ResponseRequest` and `EmbeddingRequest` adds JSON
fields to the request body for provider options. A key the request type
manages itself, such as `model`, `messages`, `input`, `tools` or `stream`,
returns a `Validation` failure, even when its typed option is unset.
`OpenAI::new` also takes `organization` and `project`, sent as the
`openai-organization` and `openai-project` headers.

## Failures

Every call returns a `Result`, and raises only for failures outside the API:

| Outcome | Meaning |
|---|---|
| `Err(Validation(message))` | Refused before sending: a colliding `extra` key, an API key that is not a valid header value (surrounding whitespace, for one), base64 embeddings. |
| `Err(Api(head, error, body~))` | The server returned an error envelope, on any HTTP status including 200, or inside a stream. `api_error(failure)` returns its `ApiErrorBody` (`message`, `type_`, `param`, `code`, with numeric codes as strings). At most 1 MiB of the body is kept. |
| `Err(Response(failure))` | Any other unexpected status, or a body that does not decode. |
| raised `TransportError` | The network failed, a deadline passed, or a body went over its limit (`TooLarge`). |
| raised by your callback | An error your stream callback raises stops the stream and reaches the caller. |

In a Responses stream, a `data:` frame of `type: "error"` reaches the callback
as `ResponseEvent::Error`, and the call can still return `Ok(())` when the
stream ends; match `Error` if the caller must know. A frame named
`event: error`, or an error envelope in either kind of stream, stops delivery
and returns `Err(Api(...))`.

## Retries, deadlines and limits

| Setting (on `OpenAI::new`) | Default |
|---|---|
| `retry` | 2 retries on 408, 409, 429, every 5xx, timeouts and network failures, for every method, **POST included**. Waits back off from 0.5 s to 8 s; `x-should-retry` is obeyed; a `Retry-After` over 2 minutes returns the failure instead of waiting. |
| `timeout_ms` | 600 s for each attempt, and for each read while streaming. |
| `total_timeout_ms` | None. Bounds the whole call, retries, waits and stream callbacks included. Needs `timer=`; without one the call raises `InvalidRequest`. |
| `max_body_bytes` | 64 MiB for a buffered response. |
| Stream events | 16 MiB for each event. |

The default follows OpenAI's official Python SDK, so a retried generation can
run, and be billed, twice. `retry=@mttp.RetryPolicy::conservative()` retries a
POST only when the failure proves the request was not sent, and
`@mttp.RetryPolicy::none()` turns retries off. A 429 whose body carries a
quota, balance or disabled-account code (`insufficient_quota`, for one) stops
at once, even under `x-should-retry: true`. A stream is never retried once its
callback has received an event.

The API key travels in `authorization`, which is marked as a credential. A
redirect strips it when the host, port or scheme changes, except for a
same-host HTTP port 80 to HTTPS port 443 upgrade, and HTTPS to HTTP is refused
by default. Debug output of an `OpenAI` value hides it.

For other headers or client settings, build an mttp `Client` with
`@mttp.client(...)` and pass it to `OpenAI::from_client`. That client's own
retry, timeout and limit settings then apply instead of the defaults above,
and no `authorization` is added, so put `"Bearer <key>"` in its headers.

## OpenAI-compatible servers

Pass the server's API root as `base_url` to `OpenAI::new`. The SDK's tests
replay responses built from each provider's documentation, not recorded from
live servers, for the endpoints listed below. An endpoint not listed is
untested with that provider; its documentation says whether it exists, and
support varies by model.

| Provider | `base_url` | Tested | SDK handling |
|---|---|---|---|
| [Ollama](https://docs.ollama.com/api/openai-compatibility) | `http://localhost:11434/v1` | chat, streaming, Responses, embeddings, models, `retrieve_model` | Reads `reasoning` as `reasoning_content`. |
| [OpenRouter](https://openrouter.ai/docs/api-reference/overview) | `https://openrouter.ai/api/v1` | chat, streaming, Responses, embeddings, models | Numeric error codes and errors in HTTP 200 become `Api`. |
| [DeepSeek](https://api-docs.deepseek.com/) | `https://api.deepseek.com` (no `/v1`) | chat, streaming, Responses, models | `Model.created` can be `None`. |
| [Gemini](https://aistudio.google.com/docs/openai) | `https://generativelanguage.googleapis.com/v1beta/openai` | chat, streaming, tool calls, embeddings | Errors wrapped in a JSON array; an omitted embedding `index` reads as 0. |
| [Moonshot / Kimi](https://platform.kimi.com/docs/guide/migrating-from-openai-to-kimi) | `https://api.moonshot.ai/v1` | chat, streaming, Responses, models | |
| [Zhipu](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction) | `https://open.bigmodel.cn/api/paas/v4` | chat, streaming, embeddings | Quota codes `1113`, `1308` and `1310` stop retries. |
| [DashScope / Qwen](https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope) | your region's `compatible-mode/v1` URL | chat, streaming, Responses, embeddings | `prompt_tokens` can be `None`. |
| [Voyage AI](https://docs.voyageai.com/reference/embeddings-api) | `https://api.voyageai.com/v1` | embeddings | Integer vectors decode; a string `detail` error becomes the `Api` message. |

Provider options go in `extra`, for example `{ "input_type": "query" }` on a
Voyage `EmbeddingRequest`. Thinking models return
`ChatCompletion.reasoning_content` and stream `ReasoningDelta` pieces; send the
reasoning back with the assistant turn, as the tool example does, when the
provider asks for it.

## Packages

| Package | What it is |
|---|---|
| `gaato/openai` | The `OpenAI` client and its request, response and event types |
| `gaato/openai/gen` | Request builders, decoders and wire types for the same operations, generated from OpenAI's OpenAPI spec |

## Links

- [Changelog](https://github.com/gaato/moonbit-sdks/blob/main/openai/CHANGELOG.md)
- [Repository](https://github.com/gaato/moonbit-sdks)
- [Spec provenance](https://github.com/gaato/moonbit-sdks/blob/main/openai/spec/SOURCE.md)

## License

Apache-2.0
