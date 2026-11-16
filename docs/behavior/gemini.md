# Gemini behavior survey

Survey date: 2026-11-16

## A — the server's contract

- [AIP-194](https://google.aip.dev/194): automatic retries are restricted to safe,
  non-transactional unary operations; the retryable status is `UNAVAILABLE`.
  Its warning is “Retries therefore may not be expected to work for several hours”
  for `RESOURCE_EXHAUSTED`. No automatic 429 retry is enabled here.
- [Gemini troubleshooting](https://ai.google.dev/gemini-api/docs/troubleshooting)
  recommends backoff and jitter for “429 RESOURCE_EXHAUSTED” and
  “503 UNAVAILABLE”, and a finite retry count. This is broader than AIP-194;
  this module follows the task's explicitly selected AIP-194 status policy.
  Neither document establishes idempotency keys for these endpoints.
- [AIP-193](https://google.aip.dev/193) specifies the HTTP JSON error envelope:
  `error.code` is the HTTP code, with message, status and typed details.
  Discovery omits error responses, so the overlay adds this schema for 4xx/5xx.
- [RetryInfo proto](https://github.com/googleapis/googleapis/blob/97f6460c3558c1435d7fd001a9251f8df058ae2f/google/rpc/error_details.proto#L82-L95)
  describes `retry_delay`, represented as a JSON duration `retryDelay` inside
  `error.details` with `@type: type.googleapis.com/google.rpc.RetryInfo`.
  No live error was collected. Details in tests are schema-constructed.
- [Files REST example](https://ai.google.dev/gemini-api/docs/files) starts a
  resumable session at `/upload/v1beta/files`, reads `X-Goog-Upload-URL`, then
  sends `X-Goog-Upload-Offset: 0` and `X-Goog-Upload-Command: upload, finalize`.
  This documented header protocol is used instead of guessing how Discovery's
  `/resumable/upload/v1beta/files` metadata maps to the header protocol.
- [Rate limits](https://ai.google.dev/gemini-api/docs/rate-limits) vary by
  project, model and usage tier. No fixed account limits or concurrency numbers
  are built into this SDK; callers can configure the shared runtime limiter.

## B — the vendor's official SDK

Inspected public source, pinned to googleapis/python-genai
`f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f`:

| Item | Official Python SDK | Source |
| --- | --- | --- |
| Default retries | Unset retry options give one attempt, i.e. no retry | [_api_client.py, retry_args](https://github.com/googleapis/python-genai/blob/f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f/google/genai/_api_client.py#L805-L837) |
| Opt-in attempts/statuses | Five attempts; 408, 429, 500, 502, 503, 504 | [retry constants and predicate](https://github.com/googleapis/python-genai/blob/f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f/google/genai/_api_client.py#L781-L837) |
| Opt-in delays | 1 s base, 60 s maximum, exponential base 2, additive random jitter | [retry_args](https://github.com/googleapis/python-genai/blob/f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f/google/genai/_api_client.py#L805-L837) |
| Methods and transport | Status predicate does not exclude POST; Python transient httpx/aiohttp failures are eligible | [retry predicate](https://github.com/googleapis/python-genai/blob/f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f/google/genai/_api_client.py#L750-L837) |
| Server delays | Retry-After and RetryInfo are not parsed by this retry implementation | [retry_args](https://github.com/googleapis/python-genai/blob/f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f/google/genai/_api_client.py#L805-L837) |
| Per-attempt timeout | Unset (`None`), converted to no HTTP request timeout | [HttpOptions](https://github.com/googleapis/python-genai/blob/f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f/google/genai/types.py#L2811-L2813), [conversion](https://github.com/googleapis/python-genai/blob/f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f/google/genai/_api_client.py#L384-L394), [httpx defaults](https://github.com/googleapis/python-genai/blob/f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f/google/genai/_api_client.py#L1714-L1715) |

The troubleshooting page's statement that retries are on by default disagrees
with this pinned implementation; the source distinguishes default and opt-in.
The special async aiohttp streaming connection retry is not reproduced.

## C — community libraries

No community retry policy is adopted. The research handoff surveyed existing
MoonBit Google bindings; none supplies a portable native Gemini policy that
would override A or B. This module introduces no community SDK dependency.

## Our behavior and divergences

| Setting | Adopted value and reason |
| --- | --- |
| Retries | Four retries (five attempts), a finite bound matching B's opt-in attempt count |
| HTTP status | 503 only; 429, 408, 500, 502 and 504 surface immediately, following the selected AIP-194 rule |
| Methods | All methods for 503, as requested by the module task; this does not establish an idempotency guarantee for writes. Use `retry=RetryPolicy::none()` when a repeated write would have unintended effects |
| Transport | Only failures for which mttp's `TransportError::is_unsent()` proves nothing reached the origin; no retry of sent/ambiguous failures |
| Server delay | Honour Retry-After from zero through 60000 ms; stop retrying above 60000 ms. B's maximum delay supplies the cap, because with no default timeout an unbounded server delay could hold a call indefinitely. Do not clip the delay and retry earlier than the server requested |
| Backoff | 1000 ms base, 60000 ms maximum; runtime proportional jitter 1.0–2.0 (different from B's additive jitter) |
| RetryInfo | Known limitation: generated retry rules cannot inspect JSON bodies. Details remain available in typed GoogleError and raw bytes; RetryInfo alone does not alter a wait or make 429 retryable |
| Timeout | No default per-attempt or total timeout, matching B's explicit `None`. This avoids cutting off long thinking requests by an invented vendor limit. Applications should choose `timeout_ms`, `total_ms` and a Timer; connection timeouts are backend settings |
| Streaming | Retry can establish a response; never resume or replay after SSE delivery begins |
| Pacing | No invented quotas; use a caller-owned runtime Client and limiter for project policy |

## Part and scope decisions

### Resource names and surface polish (2026-11-16)

Discovery canonical `path` templates retain the method's `model`/`name` label
and full regex; `flatPath` no longer determines the public arguments. For an
exact `^collection/[^/]+$` pattern, bare IDs are normalized by prepending the
collection. Other pattern shapes require the full name. This agrees with B's
[`t_model`](https://github.com/googleapis/python-genai/blob/f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f/google/genai/_transformers.py#L165-L188)
and [`t_cached_content_name`](https://github.com/googleapis/python-genai/blob/f50d2d1ff222d752ffa31dbdf30fe0a9770ad20f/google/genai/_transformers.py#L1022-L1023).
The generator validates the whole normalized name and rejects URL delimiters,
percent escapes, whitespace, backslashes, empty and dot segments before
constructing a request. Facade validation failures are typed and send nothing.

Several Google methods reuse `/{name}` for different collections. The converter
aliases colliding OpenAPI dictionary keys and retains the actual wire template
in `x-moonbit-request-path`; generic calls infer the operation by its complete
collection pattern. Aliases never appear in outgoing URLs. The auth alternatives
are ApiKey, ApiKeyInQuery and OAuthToken, named from Discovery's converted
security schemes; GoogleErrorStatus represents the embedded google.rpc.Status.
Fieldless protobuf message responses yield Unit while consuming/closing the
body. Omitted repeated fields in list responses yield empty pages, preserving
next-page cursors and rejecting present non-array fields.

The overlay selects sixteen operations: generation, typed SSE generation,
embedding and batch embedding, token counting, model get/list, file get/list/delete,
file metadata creation, and cached-content create/get/list/patch/delete. GCS file
registration is excluded because the requested file surface explicitly listed
get/list/delete plus upload. No selected response returns Operation, so no
operation endpoint or polling helper is added. Streaming stop is an application
predicate over a typed event; it stops before delivering that event.

`Part` uses a field-discriminated union: `Text(PartText)`, `InlineData(PartInlineData)`,
`FileData(PartFileData)`, function call/response, executable code/result and server
tool call/response. Each payload has exactly its required data field and all
non-data siblings from the vendored schema, including thought, thoughtSignature,
videoMetadata, speechMetadata, partMetadata and media settings. JSON remains flat;
there is no invented `type` tag. Decoding rejects zero or multiple known data
fields and invalid payloads. New data variants require a specification/overlay
update rather than silently accepting an ambiguous object. Unknown non-data
fields follow the generator's ordinary struct behavior and are not retained.

The [pinned proto](https://github.com/googleapis/googleapis/blob/97f6460c3558c1435d7fd001a9251f8df058ae2f/google/ai/generativelanguage/v1beta/content.proto#L104-L150)
defines the data oneof and metadata siblings. The newer server-tool fields in
the vendored Discovery schema are included as additional data choices using
their explicit field descriptions. Byte fields such as thought signatures and
inline media remain their JSON base64 strings; the SDK does not reinterpret them.

Upload is the only handwritten production implementation: buffered start plus
upload/finalize, with no chunking or interrupted-session recovery. Missing,
malformed and cross-origin session URLs fail before uploading bytes. The helper
uses the configured origin, so it also works with an explicit base URL override.
All other facade methods, codecs, errors, pagination, auth and retry policy are
generated. `from_client` uses caller policies; callers must include
`x-goog-api-key` in their redirect credential headers.
