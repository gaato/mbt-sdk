# gaato/openai

An unofficial OpenAI API client for [MoonBit](https://www.moonbitlang.com/):
models, embeddings, Responses and Chat Completions, buffered and streaming,
with tool calling. Compatible servers are selected with `base_url`.
It uses [`gaato/mttp_core`](https://github.com/gaato/mttp), with a caller-supplied
`Backend` and `Clock`. The facade itself requires no async runtime.

> **Status**: unofficial and experimental. Minor releases may contain breaking
> changes; the
> [changelog](https://github.com/gaato/mbt-sdk/blob/main/openai/CHANGELOG.md)
> lists each one.

## Install

```sh
moon add gaato/openai
moon add gaato/mttp
```

An app adds these two modules. A library that wraps this SDK adds
`gaato/openai` and `gaato/mttp_core`, whose `Backend` and `rt.Clock` it takes
from its caller, instead of `gaato/mttp`.

## Usage

`gaato/mttp` supplies the real network, the clock and the timer; no
experimental opt-in is needed:

```mbt nocheck
///|
let client = @openai.OpenAI::new(
  api_key~,
  @mttp.backend(),
  @mttp.clock(),
  timer=@mttp.timer(),
)
```

The function below takes the same three values as parameters, so it also runs
against a fake `Backend` in tests. To send a request:

```mbt check
///|
/// Asks `model` one question and returns its answer.
pub async fn ask(
  backend : &@http.Backend,
  clock : &@rt.Clock,
  timer : &@rt.Timer,
  api_key~ : String,
  model~ : String,
) -> Result[String, @openai.OpenAIFailure] {
  let openai = @openai.OpenAI::new(api_key~, backend, clock, timer~)
  let reply = openai.chat_completion(
    @openai.ChatRequest::new(model~, messages=[
      @openai.ChatMessage::user("Hello"),
    ]),
  )
  match reply {
    Ok(reply) => Ok(reply.text)
    Err(error) => Err(error)
  }
}
```

Buffered responses are limited to 64 MiB by default. To change the limit,
construct an mttp `Client` with `max_body_bytes` and pass it
to `from_client`. Streaming reads incrementally, with a 16 MiB per-event
limit. Limit failures raise `TransportError(TooLarge, ...)`. HTTP and decode
failures return `Err(Response(ResponseFailure))`, preserving the received head
and bounded diagnostic body. Input checks return `Err(Validation(message))`.
An error envelope inside HTTP 200 or a Chat Completions stream returns
`Err(Api(head, error, body~))`; the stream stops and delivered events are not
retried. Numeric error codes are exposed as strings.
`api_error` extracts a provider error envelope from an `OpenAIFailure` value.
Transport failures and unknown callback exceptions remain raised errors;
cancellation remains a signal.

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
) -> Result[Unit, @openai.OpenAIFailure] {
  openai.stream_response(
    @openai.ResponseRequest::new(model~, input="Write a haiku about rivers."),
    event => if event is OutputTextDelta(text) { on_text(text) },
  )
}
```

`ToolCallAccumulator` reassembles streamed tool-call arguments. It grows with
what you feed it, so cap a stream by its events or bytes, and set a token
limit on the request.

## Compatible providers

Pass `base_url` for a server that speaks the OpenAI API. Servers that
implement only Chat Completions take `ChatRequest` with `chat_completion` or
`stream_chat_completion`.

| Provider | `base_url` | Documented SDK endpoints and caveats |
|---|---|---|
| [DeepSeek](https://api-docs.deepseek.com/) | `https://api.deepseek.com` (no `/v1`) | Chat, streaming, Responses, models list. No embeddings or `retrieve_model`. Model timestamps may be absent. |
| [DashScope / Qwen](https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope) | `https://{WorkspaceId}.{region}.maas.aliyuncs.com/compatible-mode/v1` | Chat, streaming, Responses, embeddings. Model list/retrieval are not documented. Keys belong to a region; match the key, workspace and endpoint. |
| [Zhipu](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction) / [Z.AI](https://docs.z.ai/api-reference/introduction) | `https://open.bigmodel.cn/api/paas/v4` or `https://api.z.ai/api/paas/v4` | Chat, streaming, embeddings. Responses and model list/retrieval are not documented. The international service and Coding Plan use different account/endpoint configurations. |
| [Moonshot / Kimi](https://platform.kimi.com/docs/guide/migrating-from-openai-to-kimi) | `https://api.moonshot.cn/v1` or `https://api.moonshot.ai/v1` | Chat, streaming, Responses, models list. No documented embeddings or model retrieval. Match the account's service domain. |
| [OpenRouter](https://openrouter.ai/docs/api-reference/overview) | `https://openrouter.ai/api/v1` | Chat, streaming, Responses, embeddings, models list. `retrieve_model` uses OpenAI's path and cannot call OpenRouter's different single-model endpoint. |
| [Ollama](https://docs.ollama.com/api/openai-compatibility) | `http://localhost:11434/v1` | Chat, streaming, Responses, embeddings, model list/retrieval. Local Ollama ignores the key; pass any nonempty string. Responses is stateless. |

For DashScope, replace `{region}` with the region from your workspace:
`cn-beijing`, `ap-southeast-1`, `us-east-1`, `cn-hongkong`,
`ap-northeast-1` or `eu-central-1`. Legacy bases include
`https://dashscope.aliyuncs.com/compatible-mode/v1` (Beijing),
`https://dashscope-intl.aliyuncs.com/compatible-mode/v1` (Singapore), and
`https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1` (Hong Kong).
Use the workspace's current Responses endpoint; the legacy
`/api/v2/apps/protocols/compatible-mode/v1/responses` path is deprecated.

For example, selecting a provider needs no different client:

```mbt check
///|
pub fn deepseek_client(
  backend : &@http.Backend,
  clock : &@rt.Clock,
  api_key~ : String,
) -> @openai.OpenAI {
  @openai.OpenAI::new(
    api_key~,
    backend,
    clock,
    base_url="https://api.deepseek.com",
  )
}
```

Endpoint availability and parameter support depend on the provider and model;
the table describes provider documentation, not live certification.
Use `ChatRequest.extra` for provider options such as `enable_thinking` or
`thinking`. Providers may restrict temperature, tool choices or streaming tools;
Ollama does not implement `tool_choice`. Embeddings accept float arrays only;
`prompt_tokens=None` means the provider did not report that count.

Thinking providers can return `ChatCompletion.reasoning_content`; streaming
delivers `ReasoningDelta` pieces that you can concatenate. Return that reasoning
with the assistant turn, especially with DeepSeek tools or Zhipu thinking
history enabled:

```mbt check
///|
pub fn assistant_turn(reply : @openai.ChatCompletion) -> @openai.ChatMessage {
  @openai.ChatMessage::assistant_tool_calls(
    reply.tool_calls,
    content=reply.text,
    reasoning_content?=reply.reasoning_content,
  )
}
```

Use `ChatMessage::assistant` for turns without tool calls. Missing reasoning
remains `None`; no empty reasoning is fabricated. Additional headers, such as
OpenRouter attribution headers, can be configured with an mttp `Client` passed
to `OpenAI::from_client`.

## Retries

Retries follow the official Python SDK: two retries of 408, 409, 429 and every
5xx, and of a timeout or network failure, for every method. That includes
`POST`, so a generation can run, and be billed, twice; pass
`retry=@client.RetryPolicy::conservative()` to retry a `POST` only when a
failure proves nothing was sent, unless replay safety is explicit. The server's `x-should-retry` is
obeyed, waits back off from 0.5 s to 8 s, and a `Retry-After` over two
minutes returns the last failure instead of waiting.
Recognized non-transient quota, insufficient-balance or disabled-account 429
codes stop immediately, including `insufficient_quota` and Zhipu's
`1113`, `1308`, `1310`. This also applies to custom clients and overrides
`x-should-retry: true` for those codes. Unknown codes keep the configured
policy; free-text error messages are not used to guess retryability.

## Timeouts

Each attempt defaults to 600 s. A configured `total_timeout_ms` requires a
`timer` and covers admission, retries, waits and streaming callbacks.
Expiry initiates cancellation; necessary cleanup may finish afterwards.
Backend phase deadlines can finish a call earlier. The example sets a
5-second connect deadline; the SDK passes the attempt budget in SendOptions.
Streaming callbacks run after the attempt has been selected and are not
retried after delivery starts. Close the backend when its owner shuts down.

## Links

- [Changelog](https://github.com/gaato/mbt-sdk/blob/main/openai/CHANGELOG.md)
- [Repository](https://github.com/gaato/mbt-sdk)
- [Spec provenance](https://github.com/gaato/mbt-sdk/blob/main/openai/spec/SOURCE.md):
  where the vendored OpenAPI spec comes from

## License

Apache-2.0
