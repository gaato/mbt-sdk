# Jina: retry and timeout behaviour

Surveyed 2026-11-15. The method is in [new-sdk.md](../new-sdk.md).

Sources:

- **B** — none. Jina publishes no official SDK for the Search Foundation APIs (embeddings, rerank, reader, batch). The only client-like repositories under the `jina-ai` GitHub organisation are [`jina-ai/jinaai-js`](https://github.com/jina-ai/jinaai-js) (last pushed 2024-01-25; wraps SceneXplain, PromptPerfect, Rationale, BestBanner and JinaChat, not these APIs), [`jina-ai/jina-hubble-sdk`](https://github.com/jina-ai/jina-hubble-sdk) (Hubble auth and resource management) and old Jina-framework clients (`client-go`, `inference-client`). None of them is B for this API. No community library was promoted.
- **A** — [OpenAPI schema for api.jina.ai](https://api.jina.ai/openapi.json) (version 2026.10.13.1624, read 2026-11-15), [Reader OpenAPI](https://r.jina.ai/openapi.json) (0.5.0) and the [rate-limit dashboard page](https://jina.ai/api-dashboard/rate-limit).
- **C** — a third-party aggregator (apis.io) says to honour `Retry-After`; unverified and not from Jina. Not used.

## Server contract (A)

- api.jina.ai: "Requests per minute and tokens per minute. Anything over a limit answers `429`." Table: `/v1/embeddings` and `/v1/rerank` 500 RPM · 1M TPM (free), 500 RPM · 10M TPM (paid), 5,000 RPM · 100M TPM (premium); `/v1/chat/completions` 100 RPM · 500K TPM (free), 100 RPM · 5M TPM (paid), 1,000 RPM · 50M TPM (premium). The dashboard page gives different, older numbers (embeddings free 100 RPM and 100,000 TPM, paid 500 RPM and 2,000,000 TPM; Reader 20 RPM without key, 500 with; search 100 RPM). A pages disagree; the OpenAPI is newer.
- "Limits are enforced per IP or per API key", and "When you provide an API key in the request header, we track rate limits by key rather than IP address."
- Error codes (OpenAPI): 429 `RATE_REQUEST_LIMIT_EXCEEDED` ("Request rate limit exceeded: <current>/<limit> requests per minute"), `RATE_TOKEN_LIMIT_EXCEEDED`, `RATE_CONCURRENCY_LIMIT_EXCEEDED` ("Concurrency limit exceeded: <current>/<limit> concurrent requests"), `RATE_IP_LIMIT_EXCEEDED`; 500 `INTERNAL_ERROR`, 503 `SERVICE_UNAVAILABLE` ("Service temporarily unavailable"), 504 `SERVICE_TIMEOUT`; 409 `CONFLICT_RESOURCE_BUSY` ("is currently being modified", batch resources); 403 `AUTHZ_INSUFFICIENT_BALANCE` (not transient). Bodies carry `detail`, `code`, `request_id`. `/v1/chat/completions` uses OpenAI's error envelope.
- Reader (r.jina.ai): `RateLimitTriggeredError` (429) has body fields `retryAfter` (seconds) and `retryAfterDate`. The delay is therefore in the **body**, not a documented header. Reader also takes `X-Timeout` / `timeout` (seconds, max 180).
- No documented `Retry-After` header, `*-ratelimit-*` headers, idempotency key, or retry schedule. Whether live responses carry `Retry-After` is unverified (no live call made).
- Concurrency limit exists (429 code above) but its value is not documented.
- Pagination: none for embeddings/rerank. Batch endpoints (`/v1/batches`, `/v1/batch/{id}`, `/output`, `/errors`) are asynchronous resources; pagination details not read. Streaming: SSE only for `/v1/chat/completions` with `stream: true` (`chat.completion.chunk` events); no reconnect semantics documented.

## Official behaviour

| Topic | Official SDK | Source |
|---|---|---|
| Retries | no B | no official SDK |
| Methods | no B | |
| Statuses | no B; A calls 429, 503, 504 rate-limit/availability errors (500 `INTERNAL_ERROR` unspecified) | OpenAPI error table |
| Server override header | none documented | A |
| Retry-After | none as header (unverified); Reader 429 body has `retryAfter` / `retryAfterDate` | Reader OpenAPI `RateLimitTriggeredError` |
| Backoff | no B, no A | |
| Timeout | no B; Reader `X-Timeout` max 180 s | Reader OpenAPI |
| Idempotency | none documented; embeddings/rerank are read-only computations, but each call spends tokens | A |
| Pagination / SSE | none for core endpoints; SSE on chat/completions only | OpenAPI |

## Recommended ledger values

| Field | Value | Reason |
|---|---|---|
| retry table | none; use `mttp_core.RetryPolicy::conservative()` | There is no B source establishing a vendor retry policy. The suggestion to retry any method for embeddings/rerank/reader is not adopted: compute retries still spend tokens, and batch creation can duplicate work |
| retries / methods / statuses | mttp_core conservative defaults: two retries; 408, 409, 429, 500, 502, 503, 504 for idempotent requests; failures proving the request was not processed may retry any method | Keep the established conservative contract rather than inventing an all-method vendor rule |
| honour x-should-retry | no | conservative default; no vendor evidence |
| Retry-After | conservative header handling: retry-after-ms then Retry-After, cap 60 s, above cap stop | This is the runtime fallback policy, not a claim that Jina sends those headers |
| backoff | conservative default: base 0.5 s, factor 2, cap 30 s, proportional jitter 0.8–1.2 | No official SDK provides evidence for a different schedule |
| per-attempt timeout | `timeout_ms = 60000` (60 s); no generated connect or total default | Provider-specific client choice, overridable by the caller; backend connect deadlines remain caller-owned |
| idempotency-key header | none | none documented |
| rate limiting | do not hard-code limits; they differ per plan and between pages. React to 429 `code` (RPM/TPM/concurrency/IP) | A pages disagree |

Known limitation: the generated layer does not read Reader's body-level
`retryAfter` or `retryAfterDate`. The runtime policy handles response headers
only; Reader-specific body delays require a future explicit implementation.
