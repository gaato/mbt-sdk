# Replicate: retry and timeout behaviour

Surveyed 2026-11-15. The method is in [new-sdk.md](../new-sdk.md).

Sources:

- **B** (primary) — official Python SDK at [`replicate/replicate-python@d2956ff`](https://github.com/replicate/replicate-python/tree/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20): [`replicate/client.py`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py) (`RetryTransport`).
- **B** (secondary) — official JavaScript SDK at [`replicate/replicate-javascript@2fd6f39`](https://github.com/replicate/replicate-javascript/tree/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861): [`index.js`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/index.js), [`lib/util.js`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/lib/util.js), [`lib/predictions.js`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/lib/predictions.js), [`lib/stream.js`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/lib/stream.js). The two SDKs disagree (see table); this is the "two SDKs from one vendor" trap.
- **A** — docs read 2026-11-15: [HTTP API reference](https://replicate.com/docs/reference/http) (rate-limit section, headers), [rate limits](https://replicate.com/docs/topics/predictions/rate-limits), [create a prediction](https://replicate.com/docs/topics/predictions/create-a-prediction), [prediction lifecycle](https://replicate.com/docs/topics/predictions/lifecycle), [streaming](https://replicate.com/docs/topics/predictions/streaming), and the OpenAPI schema at https://api.replicate.com/openapi.json.
- **C** — not consulted.

## Server contract (A)

- Limits: "You can create predictions at 600 requests per minute." and "All other endpoints you can call at 3000 requests per minute." Short bursts above these are allowed "before being throttled". "As you approach running out of credit, we apply stronger rate limits." An account with granted credit and no payment method is limited to 1 request per second, at most 6 per minute.
- Signal: "you will receive a response with status `429`". The two pages show different bodies: `{"detail":"Request was throttled. Expected available in 1 second."}` (HTTP reference) and `{"detail":"Request was throttled. Your rate limit resets in ~30s."}` (rate-limit page). The delay is in the **body text**, not documented as a header.
- No documented `Retry-After`, `X-RateLimit-*`, concurrency limit, idempotency-key header, or list of transient statuses. The OpenAPI file lists no header parameters except `Prefer` and `Cancel-After` on prediction creation, and no 429/5xx responses.
- Sync mode: `Prefer: wait` / `wait=n`, n 1 to 60, default 60 s; if exceeded, the prediction comes back in `starting` or `processing` and is fetched via `urls.get`. `Cancel-After` (5 s to 24 h, e.g. `30`, `30s`, `5m`, `2h`) sets a server-side deadline. "Predictions time out after running for 30 minutes."
- Pagination: list endpoints return `{"next": ..., "previous": ..., "results": [...]}`; `GET /predictions` "will return 100 records per page". Confirmed in OpenAPI and used by both SDKs (`response.next` URL followed with GET; JS `paginate`, [`index.js#L371-L380`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/index.js#L371-L380)).
- Streaming: a prediction's `urls.stream` is an SSE endpoint (`Accept: text/event-stream`; events carry `event:`, `id:`, `data:`). The docs say nothing about reconnecting or `Last-Event-ID`. Unverified: server support for resume.

## Official behaviour

| Topic | Official SDK | Source |
|---|---|---|
| Retries (Python) | 10 attempts total, i.e. up to 9 retries | `max_attempts: int = 10` ([`client.py#L242`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L242)) |
| Retries (JS) | `maxRetries` default 5 (loop of 5, then one final unconditional request: up to 5 retries) | [`util.js#L195-L240`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/lib/util.js#L195-L240) |
| Methods (Python) | `HEAD, GET, PUT, DELETE, OPTIONS, TRACE`. **POST is never retried**, so a 429 on prediction creation surfaces to the caller | `RETRYABLE_METHODS` ([`#L228`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L228)); early return ([`#L295-L296`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L295-L296)) |
| Methods (JS) | All. GET retries on 429 and >= 500; every other method retries on 429 only | [`index.js#L280-L283`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/index.js#L280-L283) |
| Statuses (Python) | 429, 503, 504 | [`client.py#L229-L235`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L229-L235) |
| Statuses (JS) | 429; plus every status >= 500 for GET | as above |
| Server override header | None (no `x-should-retry`) | not present in either SDK |
| Transport failures | Not retried in Python (exceptions propagate from `handle_request`). In JS a thrown fetch error propagates too (the `catch` only inspects `ApiError`, which `request` does not throw before the retry wrapper returns) | [`client.py#L292-L317`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L292-L317); [`util.js#L209-L229`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/lib/util.js#L209-L229) |
| Server delay (Python) | `Retry-After` only. Integer seconds are used **uncapped**; a date is parsed with `fromisoformat` (not an HTTP-date, so it usually fails and falls back) and capped at 60 s | [`client.py#L271-L285`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L271-L285) |
| Server delay (JS) | `Retry-After` read only inside `catch (error instanceof ApiError)`; the wrapped request returns a `Response` instead of throwing, so this branch is effectively dead. Also `Number.isInteger(retryAfter)` is applied to a header string, which is always false | [`util.js#L214-L229`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/lib/util.js#L214-L229) |
| Backoff (Python) | `min(0.1 s · 2^(n-1) · (1 ± 0.1), 60 s)`, sign random (+10% or -10%), n = attempts made | [`client.py#L287-L290`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L287-L290); `backoff_factor=0.1`, `jitter_ratio=0.1`, `MAX_BACKOFF_WAIT = 60` ([`#L236`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L236), [`#L244-L245`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L244-L245)) |
| Backoff (JS) | Documented as `500 ms · 2^n + rand·100 ms`. Code reading (not run): the actual sleep is `interval * 2 ** (options.maxRetries - maxRetries)` where `options.maxRetries` is `undefined` by default, giving `NaN` and a zero-length timer, and it is skipped when `delay` is not an integer (it has a random fraction). So default retries are probably back-to-back. Unverified by execution | [`util.js#L198-L240`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/lib/util.js#L198-L240) |
| Timeout (Python) | `httpx.Timeout(5.0, read=30.0, write=30.0, connect=5.0, pool=10.0)` | [`client.py#L386-L388`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L386-L388) |
| Timeout (JS) | None set (global `fetch` default; caller passes an `AbortSignal`) | [`index.js#L274-L279`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/index.js#L274-L279) |
| Polling | `poll_interval` 0.5 s (env `REPLICATE_POLL_INTERVAL`); JS `wait` interval 500 ms. Polling GETs use the retry rules above | [`client.py#L61`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/client.py#L61); [`index.js#L415-L433`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/index.js#L415-L433) |
| Sync wait | JS sends `Prefer: wait` or `wait=n` (n >= 1, rounded up); `run()` defaults to block mode | [`lib/predictions.js#L29-L35`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/lib/predictions.js#L29-L35) |
| Idempotency | No idempotency key in either SDK or in the docs | grep of both repos at the pinned SHAs |
| SSE reconnect | None. Both SDKs open the stream once and parse events (`id`/`retry` fields are parsed and exposed but never used to reconnect; no `Last-Event-ID` sent) | [`stream.py`](https://github.com/replicate/replicate-python/blob/d2956ff9c3e26ef434bc839cc5c87a50c49dfe20/replicate/stream.py), [`lib/stream.js#L54-L83`](https://github.com/replicate/replicate-javascript/blob/2fd6f3944f5e252f2eb7cd4e9e5416786b9c4861/lib/stream.js#L54-L83) |

## Recommended ledger values

| Field | Value | Reason |
|---|---|---|
| retries | 5 (6 attempts) | B-JS default 5; B-Python's 9 is excessive for a user-facing call, and A states no figure |
| methods | GET, HEAD, PUT, DELETE (idempotent) always; **POST only on 429** | A: 429 means the request was throttled before running, so no duplicate prediction. B-Python never retries POST; B-JS retries POST on 429 only. Resending POST after 5xx/transport failure could create a second billed prediction and A offers no idempotency key |
| statuses | 429, 503, 504 for all retried methods; plus 500, 502 for GET only | B-Python 429/503/504; B-JS adds >= 500 for GET |
| honour x-should-retry | no | neither SDK nor A has it |
| Retry-After | Honour the header if present (seconds or HTTP-date), cap at 60 s, above cap fall back to backoff. If absent, parse the 429 body text "Expected available in N second(s)" or "resets in ~Ns" only if a typed `decide_retry` is wanted (unverified, free-text) | B-Python honours Retry-After with a 60 s cap on dates; A documents the delay only in the 429 body, no header (Retry-After header from the server is unverified) |
| backoff | base 0.5 s, factor 2, cap 60 s, jitter ±10% (or 0.75–1.0 proportional) | B-Python formula (0.1 s base, 60 s cap, ±10%) is very short for a 600 RPM limit; B-JS documents 500 ms. Choose 0.5 s with Python's cap and jitter |
| per-attempt timeout | connect 5 s, read 30 s, write 30 s (pool 10 s); for `Prefer: wait` calls, 60 s + margin (e.g. 70 s) | B-Python defaults; A: sync mode holds the request up to 60 s |
| idempotency-key header | none | A and both B have none; do not invent one |
| polling | 0.5 s interval; stop on succeeded/failed/canceled/aborted | B-Python/JS; A lifecycle |
| SSE | no automatic reconnect | B has none; A documents no resume. Surface the end of stream and let the caller re-fetch the prediction by `urls.get` |
