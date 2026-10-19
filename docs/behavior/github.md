# GitHub: retry, rate-limit and pacing behaviour

Surveyed 2026-10-19. The method is in [new-sdk.md](../new-sdk.md). The design that consumes this note is [design-m10.md](../design-m10.md).

## Sources

- **A** (server contract, docs.github.com, read 2026-10-19; these pages carry no commit to pin):
  - [Rate limits for the REST API](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
  - [Best practices for using the REST API](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)
  - [Rate limits and query limits for the GraphQL API](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)
- **B** (GitHub's official JS SDK; `octokit.js` enables both plugins by default):
  - [`octokit/plugin-retry.js@d6e06bd`](https://github.com/octokit/plugin-retry.js/tree/d6e06bd8c68b34abcf1e4d24b647f74027788352)
  - [`octokit/plugin-throttling.js@eb4215e`](https://github.com/octokit/plugin-throttling.js/tree/eb4215edcd97f20ade800b18d964bf798e0d70b7)
  - [`octokit/octokit.js@bc34dea`](https://github.com/octokit/octokit.js/tree/bc34deaf357486594c41f167c05921d16e6aabe9)

## Server contract (A), quoted

- **Primary limit:** "If you exceed your primary rate limit, you will receive a `403` or `429` response". Then: "You should not retry your request until after the time specified by the `x-ratelimit-reset` header."
- **Secondary limit:**
  - "If the `retry-after` response header is present, you should not retry your request until after that many seconds has elapsed."
  - "Otherwise, wait for at least one minute before retrying."
  - "If your request continues to fail due to a secondary rate limit, wait for an exponentially increasing amount of time between retries, and throw an error after a specific number of retries."
- **Best practices:**
  - "To avoid exceeding secondary rate limits, you should make requests serially instead of concurrently."
  - Pause between mutative requests: "wait at least one second between each request."
  - "You should not ignore repeated `4xx` and `5xx` error codes."
- **GraphQL:**
  - Primary limit exceeded: "the response status will still be `200`", with `x-ratelimit-remaining` at `0`.
  - Secondary limit exceeded: "the response status will be `200` or `403`".
- **No idempotency key.** GitHub documents none for REST writes, so a resent POST can create a second issue or comment.

## Official SDK (B)

| Topic | octokit | Source |
|---|---|---|
| Retries | 3 | `retries: 3` ([`plugin-retry src/index.ts#L20`](https://github.com/octokit/plugin-retry.js/blob/d6e06bd8c68b34abcf1e4d24b647f74027788352/src/index.ts#L20)) |
| Statuses | Every status ≥ 400 except 400, 401, 403, 404, 410, 422 and 451. There is no method filter, so POST is retried too. | `doNotRetry` ([`index.ts#L19`](https://github.com/octokit/plugin-retry.js/blob/d6e06bd8c68b34abcf1e4d24b647f74027788352/src/index.ts#L19)); "retry all >= 400 && not doNotRetry" ([`error-request.ts#L20-L21`](https://github.com/octokit/plugin-retry.js/blob/d6e06bd8c68b34abcf1e4d24b647f74027788352/src/error-request.ts#L20-L21)) |
| Delay | `(retryCount + 1)^2` seconds. No jitter and no cap. Retry-After is not read. | [`error-request.ts#L24`](https://github.com/octokit/plugin-retry.js/blob/d6e06bd8c68b34abcf1e4d24b647f74027788352/src/error-request.ts#L24); `retryAfterBaseValue: 1000` ([`index.ts#L18`](https://github.com/octokit/plugin-retry.js/blob/d6e06bd8c68b34abcf1e4d24b647f74027788352/src/index.ts#L18)) |
| GraphQL transient error | A 200 whose errors match "Something went wrong while executing your query" is retried as if it were a 500 | [`wrap-request.ts#L49`](https://github.com/octokit/plugin-retry.js/blob/d6e06bd8c68b34abcf1e4d24b647f74027788352/src/wrap-request.ts#L49) |
| Secondary limit | Detected by `/\bsecondary rate\b/i` on the message. The wait is `retry-after`, falling back to 60 s. | [`plugin-throttling src/index.ts#L163-L171`](https://github.com/octokit/plugin-throttling.js/blob/eb4215edcd97f20ade800b18d964bf798e0d70b7/src/index.ts#L163-L171); `fallbackSecondaryRateRetryAfter: 60` ([`#L78`](https://github.com/octokit/plugin-throttling.js/blob/eb4215edcd97f20ade800b18d964bf798e0d70b7/src/index.ts#L78)) |
| Primary limit | Detected by `x-ratelimit-remaining: "0"` or a GraphQL `RATE_LIMITED` error. The wait is `reset − now + 1 s`. | [`index.ts#L181-L200`](https://github.com/octokit/plugin-throttling.js/blob/eb4215edcd97f20ade800b18d964bf798e0d70b7/src/index.ts#L181-L200) |
| Rate-limit retries | Retried once per request: the default handlers act only when `retryCount === 0` ("only retries once") | [`octokit.ts#L43-L44`](https://github.com/octokit/octokit.js/blob/bc34deaf357486594c41f167c05921d16e6aabe9/src/octokit.ts#L43-L44) |
| Pacing | Writes (any method except GET/HEAD) and **every GraphQL request**: ≥ 1 s apart. Search: ≥ 2 s apart. Writes that trigger notifications: ≥ 3 s apart. At most 10 requests in flight. | groups at [`index.ts#L30-L53`](https://github.com/octokit/plugin-throttling.js/blob/eb4215edcd97f20ade800b18d964bf798e0d70b7/src/index.ts#L30-L53); classification at [`wrap-request.ts#L25-L52`](https://github.com/octokit/plugin-throttling.js/blob/eb4215edcd97f20ade800b18d964bf798e0d70b7/src/wrap-request.ts#L25-L52) |

## gaato/github today (mbt-sdk `e6d31aa`)

- **Retries:** `RetryPolicy::default()`: 2 retries; 5xx is retried only for idempotent methods; giving up when Retry-After is over 60 s.
- **`GitHubRetry`** (`github/src/retry.mbt:15`) adds secondary-limit handling. Detection is `is_secondary_rate_limit`, `errors.mbt:78`. The wait is Retry-After, or 60 s doubling. The doubled wait is checked against the 60 s cap (`retry.mbt:38`), so a second secondary-limit retry without Retry-After never happens.
- **Buckets:** `rate_limit_bucket` (`call.mbt:52`) separates core, search and graphql. The `WindowLimiter` from `default_limiter` (`client.mbt:148`) has no gate and no pacing.
- **GraphQL:** a 200 that carries `errors` becomes `Decode` after `send` has returned (`graphql.mbt:212`). That is outside the retry loop, so `RATE_LIMITED` and secondary limits reported in a 200 are never retried.

## Divergences and what we adopt

| # | Divergence | Label | Adopt |
|---|---|---|---|
| 1 | Second secondary-limit wait (120 s) exceeds our 60 s cap, so we give up | A ("at least one minute", "exponentially increasing") | Secondary-limit branch ignores the generic cap. It waits Retry-After, or else `60 s << n`, bounded by the remaining total time and the retry count. |
| 2 | GraphQL `RATE_LIMITED` and secondary limits sent in a 200 are not retried | A (GraphQL page), B | `accept` hook in the attempt loop turns them into retryable errors |
| 3 | No pacing or concurrency control | A (serial requests; ≥ 1 s between mutative requests), B (write 1 s, search 2 s, notifications 3 s) | `WindowLimiter` `pace` covers write and graphql (1 s), search (2 s) and notifications (3 s). An optional caller-supplied `gate` makes requests serial. Notifications share the write group, so a notification write also holds the next plain write 3 s (stricter than octokit's separate queue, and it meets both of its limits). The notification paths are octokit's `src/generated/triggers-notification-paths.ts` at `eb4215e`, matched by whole segments rather than its looser regular expression. |
| 4 | Retries: 2 vs 3 | B | 3 |
| 5 | GraphQL "Something went wrong while executing your query" is not retried | B | Retry it **only for documents that are not mutations**. A document counts as a mutation when the keyword `mutation` appears outside every brace, parenthesis and bracket (comments and strings skipped), so a mutation after a fragment, or picked by `operationName` from several operations, is not retried either. The message is matched in any entry of `errors`. |
| 6 | octokit retries POST on 5xx | B, but it risks duplicate writes and GitHub has no idempotency key | **Not adopted.** 5xx is retried for idempotent methods only. This is a user decision recorded in design-m10. |
| 7 | octokit retries almost every 4xx and ignores Retry-After | B contradicts A ("should not retry … until after that many seconds") | **Not adopted.** A wins. |
| 8 | Primary limit: octokit waits for the reset after a failure and retries once; we only paused the next request before sending, and raised the failure | B (retry once after the reset), consistent with A ("should not retry … until after the time specified by the `x-ratelimit-reset` header") | Keep the limiter, and also retry a primary-limit `403`/`429` (or GraphQL `RATE_LIMITED`) **once**, for any method, after `ceil((reset − now) / 1 s) + 1 s` as octokit computes it. A second one is raised. Without a readable `x-ratelimit-reset` it is raised, since there is no reset to wait for. Bounded by the remaining total time. |
