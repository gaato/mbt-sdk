# Anthropic 0.2.0 release candidate

Publish only `gaato/anthropic@0.2.0`. Its registry dependencies remain
`gaato/http@0.1.0` and `gaato/sdk-runtime@0.1.0`; the transport adapter is
caller-supplied and is not a package dependency. The unpublished runtime test
module now imports `gaato/anthropic@0.2.0`.

## Changes

- Generate the Messages, token-counting, and Models API types and operations
  from the official Anthropic Python SDK's vendored OpenAPI document.
- Expose typed input blocks, tool choice, thinking, metadata, output configuration,
  generated request entry points, and response-to-assistant-message conversion.
- Support thinking signatures and streamed tool argument reconstruction.
- Watch the upstream Anthropic spec alongside OpenAI's spec.
- Keep compatibility exceptions in the Anthropic overlay. Required nullable
  fields remain required in the shared generator; decode defaults require an
  explicit annotation.

## Breaking changes

- `base_url` is now the server root, without `/v1` (OpenRouter:
  `https://openrouter.ai/api`).
- Input blocks and tool choice use generated types instead of raw JSON.
- `Thinking` carries both text and signature. Message delta events carry
  generated delta and usage records.
- Stop reasons and usage use generated types; optional nullable metadata uses
  `Presence` to preserve absent/null/value distinctions.
- Code constructing public request, response, and tool records directly may
  need new fields. Prefer the constructors. See [Migration from 0.1.0](#migration-from-010).

## Scope and evidence

The selected four operations generate without diagnostics. This does not cover
the complete upstream API: the full 244-operation census still reports 13
diagnostics. Beta APIs, batches, and files are outside this release.

On 2026-09-23, the official API live tests passed with Haiku 4.5: model listing
and retrieval, token counting, buffered and streaming Messages, a tool-result
round trip, streamed tool arguments, and buffered/streaming thinking signatures.
This is evidence for those exercised paths, not every model or content-block kind.

The HTTP adapter's moonrun Wasm support and its CI step are a separate local
change and are excluded from this release candidate. Shared generator changes
also regenerate OpenAI, Codex, and fixture sources, but their module versions
are not bumped and they are not being republished.

Pushing the version bump to `main` triggers the existing release workflow after
CI succeeds. Review the candidate diff and publish dry-run before authorizing
that push; no manual publish is needed.

## Migration from 0.1.0

- `base_url` now names the server root because generated paths include `/v1`.
  For OpenRouter use `https://openrouter.ai/api`; remove a trailing `/v1` from
  other compatible server roots.
- `InputContent::Blocks` now takes generated `InputContentBlock` values.
  Unknown block kinds can be represented with `InputContentBlock::Unknown`.
- Stop reasons, usage, and message delta values use generated types. Nullable
  optional metadata uses `gaato/sdk-runtime/json.Presence` to distinguish
  absent, null, and present values.
- `ContentBlock::Thinking` now contains both `thinking` and `signature`;
  `MessageEvent::MessageDelta` contains generated `delta` and `usage` values.
  `tool_choice` accepts a generated `ToolChoice`; the `tool_choice_auto`,
  `tool_choice_any`, `tool_choice_none`, and `tool_choice_tool` helpers
  construct common choices.
