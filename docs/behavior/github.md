# GitHub: retry, rate-limit and pacing behaviour

Surveyed 2026-10-19. The method is in [new-sdk.md](../new-sdk.md).

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

## Current implementation

GitHubRetry in github/src/retry.mbt inspects typed mttp AttemptResult values.
The default is three conservative retries, with the SDK's exception allowing
429 for every method (mttp's generic conservative policy permits only
idempotent requests). Secondary limits wait Retry-After
or at least 60 seconds with exponential increase. Primary limits retry once,
one second after the reset. GraphQL transient failures retry only queries.
Both rate-limited and GraphQL failures retain their actual response head.

The mttp WindowLimiter shares windows by x-ratelimit-resource. Writes and
GraphQL use a one-second group, notification writes three seconds, searches
two seconds. Optional gates serialize groups. A reset and pacing deadline
may be combined into one wait.

Intentional divergence from octokit: sent writes do not retry arbitrary 5xx
or almost every 4xx, because GitHub provides no idempotency key and repeated
writes can create duplicate effects. Explicit primary/secondary rejection
can retry any method. Header delays take precedence over backoff.
