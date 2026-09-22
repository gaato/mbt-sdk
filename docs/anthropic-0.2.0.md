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
  need new fields. Prefer the constructors. See `anthropic/README.md` for migration.

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
