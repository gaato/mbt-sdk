# Changelog

All notable changes to `gaato/openai` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

`spec-watch.yml` releases this module when a new upstream spec changes the
generated code. Such a release carries one entry naming the spec; the API
change itself is the diff of `src/gen/pkg.generated.mbti`.

## [Unreleased]

### Added

- **Provider options on embedding requests.** `EmbeddingRequest::new` accepts
  `extra?` for JSON parameters such as Voyage's `input_type` and
  `output_dimension`. Keys managed by the SDK produce a validation failure.
  Add `extra: {}` to existing `EmbeddingRequest` record literals.

### Changed

- **Chat decodes omitted stream finish reasons and default-valued fields.**
  Content and usage can arrive together without a `Finished` event. Omitted
  choice and streamed tool-call indices decode as zero. A present usage
  object defaults omitted counts to zero. In `gaato/openai/gen`, buffered
  choice `finish_reason` is optional, streamed `finish_reason` uses
  `@sdkjson.Presence`, and both chat logprobs types' `content` and both token
  logprob types' `bytes` use `Presence`. Use `to_option()` to read those
  fields as options. Use `Absent` or `Null` to control their encoding.
- **Chat tool calls preserve provider metadata.** The `ToolCall.extra` map
  retains top-level extensions such as Gemini thought signatures and sends
  them back in assistant tool history. Supply `extra: {}` in record literals
  without metadata. `ChatEvent::ToolCallDelta` now carries `extra~`. Pass it
  to `ToolCallAccumulator::feed(extra~)` for streamed follow-ups.
- **Wrapped quota errors stop retries.** Singleton-array HTTP 429
  envelopes use the same retry classification as object envelopes.
- **Embeddings accept an omitted index or usage.** An omitted index decodes
  as zero because Gemini's ProtoJSON response can omit default-valued fields.
  `EmbeddingResponse.total_tokens` is now `Int32?`. Handle `None` as
  unreported and `Some(0)` as a reported zero. In `gaato/openai/gen`,
  `CreateEmbeddingResponse.usage` is now optional and its constructor accepts
  `usage?`. Handle `None` when no usage object was returned.
- **Chat accepts omitted assistant content and refusal log probabilities.**
  Missing or null assistant content yields empty buffered text and contributes
  no streamed text delta. In `gaato/openai/gen`, the buffered message's
  `content` and both chat logprobs types' `refusal` fields now use
  `@sdkjson.Presence`. Use `to_option()` to read them as before, and
  `Absent`, `Null` or `Value` in record literals. A constructor call that
  omits one of these arguments encodes no key. Use `Null` on the field to
  encode an explicit JSON null.
- **Recognized provider errors on any HTTP status** return
  `OpenAIFailure::Api` with the original response head and bounded raw body.
  Update status handling that matches only `Response(UnexpectedStatus(...))`
  to also inspect `Api`. The type signatures and retry decisions are unchanged.
- **Gemini compatibility.** The beta endpoint's single-element array of error
  envelopes is decoded, including numeric codes.
- **Voyage error messages.** On a rejected HTTP status, a top-level string
  `detail` yields `OpenAIFailure::Api` with the original response head and
  bounded raw body. The SDK leaves the provider code unset.
- Generated code now qualifies constructor references; no public API change.
- **Build with MoonBit 0.10.21 and mttp_core 0.3.0.** Invalid explicit header values, including surrounding whitespace, return validation failures before I/O.

### Fixed

- Missing token and alternate-token `logprob` values and citation offsets
  remain absent. The corresponding generated fields are options and the
  constructor arguments are optional. Explicit zero values are preserved.
- Request constructors and streamed tool-call accumulation copy nested
  JSON objects and arrays in `extra`, preserving metadata snapshots.
- `create_embeddings` rejects `encoding_format: "base64"` in `extra` before
  I/O. Embeddings returned as JSON number arrays remain supported.
- **The README's Timeouts no longer refer to an example that is not there.**
  It names the backend's phase deadlines (`connect_timeout_ms`,
  `read_timeout_ms` and the rest of its `ClientConfig`) instead.

### Security

- **Mark bearer credentials on each request.** The mark also enables redirect stripping and curl redaction with a caller-owned Client.

## [0.10.0] - 2026-11-15

### Changed

- **Compatible provider decoding.** Responses accepts omitted tool options,
  nullable request echoes and usage breakdowns. `gaato/openai/gen.Model.created`
  is now `Int64?`; handle `None` when a provider omits its timestamp. The facade's
  `Model.created` was already optional. Generated Responses fields also become
  optional; handle omission rather than assuming OpenAI request echoes.
- **Embedding prompt usage is optional.** `EmbeddingResponse.prompt_tokens`
  and its generated counterpart are now `Int32?`; `None` means unreported,
  not zero. Embeddings still use float arrays.
- **Chat messages retain reasoning.** `ChatMessage` and `ChatCompletion` gain
  `reasoning_content : String?`. Record literals must supply this field.
  Pass it to `ChatMessage::assistant` or `assistant_tool_calls` when returning
  an assistant turn to a provider that requires thinking history.
- **Non-transient 429 errors stop retries.** Recognized quota, balance and
  disabled-account codes stop immediately; transient or unknown codes retain
  the configured HTTP retry policy.

### Added

- Numeric API error codes are exposed as strings by `api_error`.
- `OpenAIFailure::Api(head, error, body~)` represents an error envelope in an
  HTTP 200 body or a mid-stream Chat Completions error. Update exhaustive
  failure matches for this case. The original response head and bounded
  diagnostic body are retained, and streaming stops without replaying delivery.
- Compatible-provider setup and endpoint caveats for DeepSeek, DashScope,
  Zhipu/Z.AI, Moonshot, OpenRouter and Ollama.

## [0.9.0] - 2026-11-12

### Changed

- **Build on gaato/mttp_core 0.1.** gaato/mttp 0.2, the HTTP library without I/O that this SDK builds on, is renamed gaato/mttp_core, and gaato/mttp is now the module an app adds (formerly gaato/mttp_async). `::new` takes `&@mttp_core.Backend`, the same type as before under the new name, and the request and response types are gaato/mttp_core's. Apps pass `@mttp.backend()`, `@mttp.clock()` and `timer=@mttp.timer()` from gaato/mttp 0.3: in moon.mod, replace `"gaato/mttp@0.2.0"` with `"gaato/mttp_core@0.1.0"` (or drop it if no package imports it) and then `"gaato/mttp_async@0.1.0"` with `"gaato/mttp@0.3.0"`, in that order; [gaato/mttp's changelog](https://github.com/gaato/mttp/blob/main/mttp/CHANGELOG.md) has the whole table.

## [0.8.0] - 2026-11-12

### Changed

- **Build on gaato/mttp 0.2 instead of gaato/http.** `::new` takes an `&@mttp.Backend`, and the request and response types are gaato/mttp's. Apps pass `@mttp_async.backend()`, `@mttp_async.clock()` and `timer=@mttp_async.timer()` from gaato/mttp_async 0.1. gaato/http and gaato/http-async are no longer dependencies.

## [0.7.0] - 2026-11-10

### Changed

- **Use gaato/http 0.6 and gaato/mttp for requests, retries and streaming.**
  Vendor retry defaults and attempt budgets are retained. Migration: supply
  Backend and http/rt ports, handle Result[T, OpenAIFailure], and use
  mttp/jsonkit.Presence. TransportError and user callback exceptions remain
  effects. Generated decoders now take ResponseHead and Bytes and return
  Result[T, ResponseFailure]. Buffered bodies default to 64 MiB; total call
  deadlines require Timer and include streaming callbacks.

- **HTTP infrastructure is supplied by mttp.** This repository no longer
  ships the HTTP implementation or the former shared runtime.
- **The README has sections and compile-checked examples.** Install, usage that sends a request, and sections on operations, streaming, compatible servers, retries and timeouts; the examples no longer name a specific model.

## [0.6.0] - 2026-10-19

### Changed

- **Depends on `gaato/http` 0.4.1 and `gaato/sdk-runtime` 0.7.0.** The
  retry policy and the new timeouts come from them. Migration: update the
  `gaato/http` and `gaato/sdk-runtime` imports alongside this module, and
  follow `gaato/sdk-runtime`'s changelog where you build a `RetryPolicy`.
- **Retries follow the official SDK (`openai-python`), POST included.**
  `OpenAI::new` now defaults to `RetryPolicy::stainless(cap=StopAbove(120000))`
  of `gaato/sdk-runtime`: two retries of 408, 409, 429 and every 5xx, and of
  a timeout or network failure after the request was sent, for every method.
  A `POST` such as a response or an embedding is therefore resent after a
  5xx or a timeout, as the official SDK does, and the model may generate (and
  bill) it twice. The server's `x-should-retry: true`/`false` overrides the
  status rules; the backoff runs from 0.5 s to 8 s, shortened by up to a
  quarter (it was 0.5 s to 30 s, ±20 %); a `Retry-After` over 120 s is raised
  instead of waited for (the limit was 60 s), and one of 0 means the backoff.
  Migration: pass `retry=@runtime.RetryPolicy::conservative()` to keep the
  old behaviour, which retries a `POST` only on 429 and on failures that
  prove nothing was sent. A policy built as `{ ..RetryPolicy::default(),
  max_retries: n }` no longer compiles; write
  `@runtime.RetryPolicy::stainless(cap=StopAbove(120000)).with_max_retries(n)`
  (or `conservative().with_max_retries(n)`), and follow `gaato/sdk-runtime`'s
  changelog for the rest of `RetryPolicy`.

### Added

- **`OpenAI::new(timer?, timeout_ms?, total_timeout_ms?)` limits calls in
  time.** With a `@sync.Timer` such as `gaato/http-async`'s `ClockTimer`,
  each attempt is limited to `timeout_ms` (600 s, the official default) and,
  when given, the whole call, retries and waits included, to
  `total_timeout_ms`. An attempt that runs out is retried like any timeout.
  Without a timer nothing changes and only the transport's timeouts apply;
  `AsyncTransport` defaults to 30 s, so raise its `timeout_ms` too (see the
  README).

## [0.5.0] - 2026-10-19

### Changed

- **`FinishReason`, `ChatEvent`, `ResponseStatus`, `ResponseEvent` and every
  enum in `gaato/openai/gen` are `#non_exhaustive`.** A value the API adds
  can then become a constructor in a patch release, including the
  regenerations made when the vendored spec changes. Until this module
  maps such a value, it still arrives as `Unknown(..)` or `Other(..)` with
  its wire value, as it did before. Migration: a `match` on one of these
  types ends with `TypeName::.. => …` after the existing constructors.

## [0.4.0] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.3.0 and `gaato/sdk-runtime` 0.4.0.** `HttpError` now says which phase of an exchange failed (`Timeout(phase~, ms~)`, `Network(phase~, ..)`, `Proxy(status~, ..)`), `Request.body` is a `Body` that may stream, and `Client` never resends a stream body a transport has read. Migration: update the `gaato/http` and `gaato/sdk-runtime` imports alongside this module, and follow their changelogs where you match `HttpError` or read `Request.body`.

## [0.3.1] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.2.1 and `gaato/sdk-runtime` 0.3.1.** Streams
  now count an event's `event` and `id` lines toward its 16 MiB bound and
  are parsed 64 KiB at a time, an error keeps at most 1 MiB of its body, and
  a server cannot hold a rate-limit bucket for more than an hour.

## [0.3.0] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.2.0 and `gaato/sdk-runtime` 0.3.0.** A
  streamed event larger than 16 MiB now fails the stream with
  `HttpError::Protocol` instead of being buffered without limit. Migration:
  update the `gaato/http` and `gaato/sdk-runtime` imports alongside this
  one.

## [0.2.1] - 2026-10-15

### Changed

- **Generated operations percent-encode with `gaato/http`'s URL helpers**
  instead of a private copy; the encoding is unchanged. Depends on
  `gaato/http` 0.1.1 and `gaato/sdk-runtime` 0.2.2.

## [0.2.0] - 2026-09-25

### Changed

- **Built on `gaato/sdk-runtime` 0.2.** `OpenAI::from_client` takes a 0.2
  `Client`, and `SdkError` and `RetryPolicy` are the 0.2 types.
  Migration: depend on `gaato/sdk-runtime` 0.2 if you name its types; see
  its changelog for the `RateLimiter` and `Paginator` changes.

### Added

- **Every generated type derives `Eq` and `Debug`.**

## [0.1.0] - 2026-09-22

### Added

- Initial release: models, embeddings, Responses and Chat Completions
  (buffered and streaming, with tool calling and a typed `reasoning_effort`),
  with types and operations generated from the vendored OpenAPI spec behind a
  hand-written facade. Works against OpenAI-compatible servers through
  `base_url`.
