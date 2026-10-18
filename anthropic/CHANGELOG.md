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
