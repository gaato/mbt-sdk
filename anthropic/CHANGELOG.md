# Changelog

All notable changes to `gaato/anthropic` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the
version is 0.x, a minor release (0.x → 0.y) may contain breaking changes; a
patch release never does. Every breaking change is listed with a migration
note.

`spec-watch.yml` releases this module when a new upstream spec changes the
generated code. Such a release carries one entry naming the spec; the API
change itself is the diff of `src/gen/pkg.generated.mbti`. Generated types
are `pub(all)`, so a new field breaks struct literals and a new variant
breaks exhaustive matches: build values with `::new`, whose new arguments
are optional unless the field is required, and keep a wildcard arm.

## [Unreleased]

## [0.15.0] - 2026-11-10

### Changed

- **Use gaato/http 0.6 and gaato/mttp for requests, retries and streaming.**
  Vendor retry defaults, the API version and the generated vocabulary are
  retained. Migration: supply Backend and http/rt ports, handle
  Result[T, AnthropicFailure], and use mttp/jsonkit.Presence. Generated
  decoders now take ResponseHead and Bytes and return Result[T, ResponseFailure].
  TransportError and user callback exceptions remain effects. Buffered bodies
  default to 64 MiB; total call deadlines require Timer and include callbacks.

## [0.14.0] - 2026-11-09

### Changed

- **Regenerated from the upstream spec fetched 2026-11-09** (sha256 `3fc8060329f5`). The public API changed; see the `pkg.generated.mbti` diff.

## [0.13.0] - 2026-11-07

### Changed

- **Builds on `gaato/http` 0.5.0**, whose cookie jar, Retry-After and Link parsing follow RFC 6265bis-22, RFC 9110 and RFC 8288 more closely; see its CHANGELOG.
- **The README has sections and compile-checked examples.** The usage example now sends a message. The migration notes from 0.1.0 moved to docs/anthropic-0.2.0.md in the repository and the live-test procedure to docs/live-tests.md. Each re-exported generated type has its own doc comment.
- **Regenerated from the upstream spec fetched 2026-11-07** (sha256 `d5be78f1f9a8`), which follows API version 2026-10-21. The public API changed; see the `pkg.generated.mbti` diff. `@gen.InputMessage` is now `@gen.InputMessageUnion`, with one type per role (`UserInputMessage`, `AssistantInputMessage`, `SystemInputMessage`), and `CreateMessageParams` no longer has `temperature`, `top_p` or `top_k`.
- **`Anthropic::new` and `Anthropic::from_client` send `anthropic-version: 2026-10-21` by default**, as the official SDKs do from their releases for this version (Python 2.0.0, TypeScript 1.0.0); the default was `2023-06-01`. Besides removing the sampling parameters, this version returns 400 for a `document` block directly in an `assistant` message and for a `text` block with non-empty `citations` in a `user` message; see https://platform.claude.com/docs/en/api/migration-2026-10-21. Migration: send documents in a user message and drop citations from user text blocks, or pass `version="2023-06-01"` to keep the old behaviour.
- **`MessageRequest` no longer has `temperature`.** API version 2026-10-21 removed `temperature`, `top_p` and `top_k`, and returns 400 for a request that sends any of them; Claude 4.7 and later models already accepted only the defaults. Migration: drop `temperature=`. A request that relies on a non-default value on an older model can still send it with `extra={ "temperature": ... }` and `version="2023-06-01"`, but the generated `CreateMessageParams` no longer models it.

### Added

- **`Role::System` and `Message::system(text)`** send a mid-conversation system message (`role: "system"` in `messages`), which must directly follow a user turn and which only some models accept; see https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages. A system message takes only text, so a non-text block in one is sent as it is and the API rejects it. `Role` is `#non_exhaustive`, so a `match` on it already has a wildcard arm.

## [0.12.0] - 2026-10-20

### Changed

- **Regenerated from the upstream spec fetched 2026-10-20** (sha256 `54b53c574d01`). The public API changed; see the `pkg.generated.mbti` diff.

## [0.11.0] - 2026-10-19

### Changed

- **Depends on `gaato/http` 0.4.1 and `gaato/sdk-runtime` 0.7.0.** The
  retry policy and the new timeouts come from them. Migration: update the
  `gaato/http` and `gaato/sdk-runtime` imports alongside this module, and
  follow `gaato/sdk-runtime`'s changelog where you build a `RetryPolicy`.
- **Retries follow the official SDK (`anthropic-sdk-python`), POST and 529
  included.** `Anthropic::new` now defaults to
  `RetryPolicy::stainless(cap=NoCap)` of `gaato/sdk-runtime`: two retries of
  408, 409, 429 and every 5xx, and of a timeout or network failure after the
  request was sent, for every method. `529 overloaded_error`, which was never
  retried, now is. A message (`POST /v1/messages`) is therefore resent after
  a 5xx or a timeout, as the official SDK does, and the model may generate
  (and bill) it twice. The server's `x-should-retry: true`/`false` overrides
  the status rules; the backoff runs from 0.5 s to 8 s, shortened by up to a
  quarter (it was 0.5 s to 30 s, ±20 %); and a `Retry-After` is waited out
  however long it is (a wait over 60 s used to be raised), so a call can now
  wait as long as the server says: set `total_timeout_ms` to bound it.
  Migration: pass `retry=@runtime.RetryPolicy::conservative()` to keep the
  old behaviour, which retries a `POST` only on 429 and on failures that
  prove nothing was sent. A policy built as `{ ..RetryPolicy::default(),
  max_retries: n }` no longer compiles; write
  `@runtime.RetryPolicy::stainless(cap=NoCap).with_max_retries(n)` (or
  `conservative().with_max_retries(n)`), and follow `gaato/sdk-runtime`'s
  changelog for the rest of `RetryPolicy`.

### Added

- **`Anthropic::new(timer?, timeout_ms?, total_timeout_ms?)` limits calls in
  time.** With a `@sync.Timer` such as `gaato/http-async`'s `ClockTimer`,
  each attempt is limited to `timeout_ms` (600 s, the official default) and,
  when given, the whole call, retries and waits included, to
  `total_timeout_ms`; a Retry-After that would outlast it is not waited for.
  An attempt that runs out is retried like any timeout. Without a timer
  nothing changes and only the transport's timeouts apply; `AsyncTransport`
  defaults to 30 s, so raise its `timeout_ms` too (see the README).

## [0.10.0] - 2026-10-19

### Changed

- **`AuthHeader`, `Role`, `InputContent`, `ContentBlock`, `MessageEvent` and
  every enum in `gaato/anthropic/gen` are `#non_exhaustive`.** A value the
  API adds can then become a constructor in a patch release, including the
  regenerations made when the vendored spec changes. Until this module
  maps such a value, it still arrives as `Other(..)` with its wire value,
  as it did before. Migration: a `match` on one of these types ends with
  `TypeName::.. => …` after the existing constructors.

## [0.9.0] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.3.0 and `gaato/sdk-runtime` 0.4.0.** `HttpError` now says which phase of an exchange failed (`Timeout(phase~, ms~)`, `Network(phase~, ..)`, `Proxy(status~, ..)`), `Request.body` is a `Body` that may stream, and `Client` never resends a stream body a transport has read. Migration: update the `gaato/http` and `gaato/sdk-runtime` imports alongside this module, and follow their changelogs where you match `HttpError` or read `Request.body`.

## [0.8.1] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.2.1 and `gaato/sdk-runtime` 0.3.1.** Streams
  now count an event's `event` and `id` lines toward its 16 MiB bound and
  are parsed 64 KiB at a time, an error keeps at most 1 MiB of its body, and
  a server cannot hold a rate-limit bucket for more than an hour.

## [0.8.0] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.2.0 and `gaato/sdk-runtime` 0.3.0.** A
  streamed event larger than 16 MiB now fails the stream with
  `HttpError::Protocol` instead of being buffered without limit. Migration:
  update the `gaato/http` and `gaato/sdk-runtime` imports alongside this
  one.

## [0.7.0] - 2026-10-15

### Changed

- **Regenerated from the upstream spec fetched 2026-10-15** (sha256
  `ac6b3bb9cec6`): a `Speed` enum and a `speed` field on
  `CreateMessageParams`, `CountMessageTokensParams` and `Usage`;
  `between_tools` on `ThinkingTypes`.

## [0.6.0] - 2026-10-15

### Added

- **`Anthropic::paginate_models(limit?, lifecycle?)`** returns a
  `Paginator` that follows `after_id` pages.

### Changed

- **Generated operations percent-encode with `gaato/http`'s URL helpers**
  instead of a private copy; the encoding is unchanged. Depends on
  `gaato/http` 0.1.1 and `gaato/sdk-runtime` 0.2.2.

## [0.5.1] - 2026-10-14

### Changed

- **Regenerated from the upstream spec fetched 2026-10-14** (sha256
  `05e92b686382`): documentation of `ThinkingConfigParam` only.

## [0.5.0] - 2026-10-09

### Changed

- **Regenerated from the upstream spec fetched 2026-10-09** (sha256
  `166bdc0ad612`): 22 new `*ErrorDetails` types (compaction, CMEK, request
  body encoding, tool name and reference, spend limit, organization hold and
  others).

## [0.4.0] - 2026-10-08

### Changed

- **Regenerated from the upstream spec fetched 2026-10-07** (sha256
  `752f03c44b9e`): `ModelInfo` gains the required `lifecycle` and optional
  `line`, `deprecated_at` and `retires_at`; `ModelCapabilities` gains
  `server_tools`; `ThinkingTypes` gains `disabled`; `models_list_request`
  takes a `lifecycle` filter.
  Migration: pass `lifecycle~` to `ModelInfo::new`.

### Added

- **`Anthropic::list_models(lifecycle?)`** passes the lifecycle filter
  through; without it the API lists active and deprecated models.

## [0.3.0] - 2026-09-29

### Changed

- **Regenerated from the upstream spec fetched 2026-09-28** (sha256
  `15d8b499501f`): cache-miss diagnostics (`diagnostics` on
  `CreateMessageParams`, and on `Message` a `Diagnostics` with a
  `CacheMissReason`) and a `BetweenTools` variant of `ThinkingConfigParam`.
  The overlay keeps `Message.diagnostics` optional, so responses from
  compatible providers that omit it still decode.
- Depends on `gaato/sdk-runtime` 0.2.1.

## [0.2.1] - 2026-09-25

### Changed

- **Built on `gaato/sdk-runtime` 0.2.** `Anthropic::from_client` takes a 0.2
  `Client`, and `SdkError` and `RetryPolicy` are the 0.2 types.

## [0.2.0] - 2026-09-23

### Changed

- **The facade is rebuilt on types generated from Anthropic's OpenAPI
  document** (vendored from the official Python SDK), covering Messages,
  token counting and Models.
  Migration: `base_url` is now the server root without `/v1` (OpenRouter:
  `https://openrouter.ai/api`); `InputContent::Blocks` takes generated
  `InputContentBlock` values; `StopReason` and `Usage` are the generated
  types, and nullable metadata uses `Presence`; `ContentBlock::Thinking`
  carries `thinking` and `signature`; `MessageEvent::MessageDelta` carries
  the generated `delta` and `usage`; `tool_choice` takes a `ToolChoice`
  (see the `tool_choice_*` helpers). Prefer the constructors over struct
  literals.

### Added

- `count_tokens`, `list_models` and `retrieve_model`.
- `create_message_params` and `stream_message_params` for the full
  generated `CreateMessageParams`.
- `MessageRequest` takes `thinking`, `output_config` and `metadata`;
  `ToolDef` takes `strict`; `MessageResponse` keeps the generated `message`
  and offers `tool_uses()`; `Message::from_response` and
  `Message::user_blocks`.
- Thinking signatures (`SignatureDelta`) and `RedactedThinking` blocks.

## [0.1.0] - 2026-09-22

### Added

- Initial release: a hand-written Messages API client, buffered and
  streaming, with open content blocks and stream events and tool use. Works
  against Anthropic-compatible servers through `base_url`.
