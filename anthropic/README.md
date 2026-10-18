# gaato/anthropic

Unofficial Anthropic Messages API client for MoonBit: buffered and streaming messages, open content blocks and stream events, tool use, on `gaato/http` and `gaato/sdk-runtime`. Works against Anthropic-compatible servers through `base_url`. The caller supplies a `Transport` and a `Clock`, for example `gaato/http-async`:

```moonbit
let transport = @http_async.AsyncTransport::new(max_body_bytes=64 * 1024 * 1024)
let client = @anthropic.Anthropic::new(api_key~, transport, @http_async.AsyncClock::new())
```

Set `max_body_bytes`: the transport reads a buffered body whole unless told otherwise, and this client cannot set it because the transport is yours. 64 MiB is ample for API JSON; a longer reply fails with `@runtime.Transport(Protocol(..))` rather than growing memory. Streaming calls are not affected.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk

Request and response types in `gaato/anthropic/gen` are generated from the official Python SDK's vendored `scripts/mock-spec.json.gz`. The selected API surface is Messages (buffered and streaming), token counting, and Models (list and retrieve). Beta APIs, batches, files, and other endpoints are not included. See [spec provenance](spec/SOURCE.md) and [generation overlays](overlays/moonbit.yaml).

The facade exposes `create_message`, `stream_message`, `count_tokens`, `list_models`, and `retrieve_model`. Use `client.paginate_models(limit=100).collect(max=1000)` to collect up to 1000 models across pages automatically. `MessageRequest` accepts typed input blocks, tool choice, thinking, output configuration, and metadata. Use `create_message_params` or `stream_message_params` with generated `CreateMessageParams` for the wider request vocabulary. Responses retain both the generated `message` and original `raw` JSON.

Migration from 0.1.0's handwritten API:

- `base_url` now names the server root because generated paths include `/v1`. For OpenRouter use `https://openrouter.ai/api`; remove a trailing `/v1` from other compatible server roots.
- `InputContent::Blocks` now takes generated `InputContentBlock` values. Unknown block kinds can be represented with `InputContentBlock::Unknown`.
- Stop reasons, usage, and message delta values use generated types. Nullable optional metadata uses `gaato/sdk-runtime/json.Presence` to distinguish absent, null, and present values.
- `ContentBlock::Thinking` now contains both `thinking` and `signature`; `MessageEvent::MessageDelta` contains generated `delta` and `usage` values. `tool_choice` accepts a generated `ToolChoice`; the `tool_choice_auto`, `tool_choice_any`, `tool_choice_none`, and `tool_choice_tool` helpers construct common choices.

The opt-in official API tests cover model listing/retrieval, token counting, buffered/streaming Messages, a tool-result round trip, streamed tool arguments, and buffered/streaming thinking with signatures. Set `ANTHROPIC_API_KEY` and run `scripts/live.sh --filter 'live Anthropic official *'` from the repository root. They use Haiku 4.5 with small output limits (thinking requests allow 1,536 output tokens, including a 1,024-token thinking budget). They skip when the key is absent; a skipped run is not evidence of compatibility with the official service.
