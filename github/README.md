# gaato/github

Unofficial GitHub API client for MoonBit, on `gaato/http` and `gaato/sdk-runtime`. The caller supplies a `Transport` and a `Clock`, for example `gaato/http-async`. REST is generated in full; GraphQL is a passthrough.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk

All 1,221 operations of the vendored first-party OpenAPI document are generated into `gaato/github/gen` as sans-IO pairs: `<operation>_request(...)` builds an `@http.Request`, and `<operation>_decode(response)` reads the success payload. See [spec provenance](spec/SOURCE.md) and [generation overlays](overlays/moonbit.yaml).

Unlike `gaato/openai` and `gaato/anthropic`, this module does not restate the generated types behind a hand-written vocabulary — at this surface area that would be a second API to keep in step with the first. The generated package *is* the public type vocabulary, and the facade only sends, follows, and reads:

```moonbit
let transport = @http_async.AsyncTransport::new(max_body_bytes=64 * 1024 * 1024)
let gh = @github.GitHub::new(transport, clock, token="ghp_...")
let repo = gh.call(@gen.repos_get_request("gaato", "mbt-sdk"), @gen.repos_get_decode)
let diff = gh.send(
  @gen.repos_compare_commits_request("gaato", "mbt-sdk", "main...topic")
    .header("accept", "application/vnd.github.diff"),
)
```

`call` decodes; `send` returns the response for operations with no body to decode (`204`, `304`) or a non-JSON representation such as `application/vnd.github.diff`. An operation that sets its own `accept` wins over the client default, as do all request headers.

Both read the whole body into memory, so give the transport a `max_body_bytes`; this client cannot set it because the transport is yours. 64 MiB is ample for API JSON, and a longer reply fails with `@runtime.Transport(Protocol(..))` rather than growing memory. Files are another matter. The archive, artifact, log and migration downloads (`repos_download_tarball_archive`, `repos_download_zipball_archive`, `actions_download_artifact`, the `actions_download_*_logs` operations, `migrations_download_archive_for_org`, `migrations_get_archive_for_authenticated_user`) answer `302` with a short-lived `location`, as do `repos_get_release_asset` with `accept: application/octet-stream` and `code_scanning_get_codeql_database` with `accept: application/zip` some of the time. The native and Wasm transports do not follow redirects, so `send` raises that `302` as `@runtime.Status`; read `location` from its headers and fetch it with `transport.send_stream`, without the token, writing chunks out as they arrive. `@http.follow_redirects_stream(request, r => transport.send_stream(r))` does both for a request carrying the full URL and token: it drops `Authorization` when the `location` is on another host and closes the `302` unread. On JS, `fetch` follows the redirect and the file arrives as a buffered body, as do raw content (`repos_get_content` with `accept: application/vnd.github.raw`, up to 100 MB) and large diffs on every target; send those through a second `GitHub` client whose transport has a limit sized for the largest file you accept.

GitHub paginates with RFC 8288 `Link` headers, so `paginator` follows the `rel="next"` URL the server wrote. It is an `@runtime.Paginator`, with `each`, `next_page` and `collect`:

```moonbit
let repos = gh
  .paginator(@gen.repos_list_for_user_request("gaato", per_page=100), @gen.repos_list_for_user_decode)
  .collect(max=250)
```

GraphQL is not generated, because there is nothing to generate from. In OpenAPI the shape of a response belongs to the operation, which is what `gen` compiles; in GraphQL it belongs to the query document the caller wrote, and the schema only says what is possible. So the endpoint is a passthrough over `Json`:

```moonbit
let data = gh.graphql(
  query="query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { stargazerCount } }",
  variables={ "owner": "gaato", "name": "mbt-sdk" },
)
```

A GraphQL failure does not use the HTTP status: the reply is `200` with an `errors` array beside a possibly partial `data`. `graphql` raises whenever that array is non-empty (`@runtime.Decode`, or `@runtime.RateLimited` for a rate limit), so an error cannot pass unnoticed, and `graphql_errors` reads it back — including `type_`, which names the condition (`NOT_FOUND`, `FORBIDDEN`, `RATE_LIMITED`). Use `graphql_response` when the partial `data` of such a reply is worth keeping. `graphql_paginator` walks a connection by threading `pageInfo.endCursor` through a query variable, `after` unless `cursor_variable` says otherwise.

A GraphQL rate limit is a `RATE_LIMITED` entry in that array rather than a `429`. It, a secondary limit reported in a `200`, and "Something went wrong while executing your query" are recognised inside the retry loop, so they are retried like an error status (see below); a document holding a mutation is not retried on "Something went wrong", since the mutation may have been applied. A rate limit that persists is raised as `@runtime.RateLimited`, with the reply's body for `graphql_errors`.

Search and GraphQL are each metered separately from the rest of the API, so requests to `/search/*` and to `/graphql` use their own rate limit buckets, and writes (any method but `GET` and `HEAD`) use `core:write`, or `core:notifications` for the paths that send notifications. The default `@runtime.WindowLimiter` paces each bucket against `x-ratelimit-remaining` and `x-ratelimit-reset`, keyed by `x-ratelimit-resource`, so a write still spends the `core` window. Following octokit and docs.github.com, it also spaces writes and every GraphQL request at least 1 s apart, writes that send notifications 3 s (which also holds the next write), and searches 2 s, so consecutive writes are slower than before. docs.github.com also asks for requests to be made "serially instead of concurrently"; this module has no async runtime to provide that, so pass a gate:

```moonbit
let gh = @github.GitHub::new(transport, clock, token="ghp_...", gate=() => @http_async.SemaphoreGate::new())
```

The gate serialises each group (writes and GraphQL, searches, reads). `timeouts` takes a `@runtime.Timeouts` for per-attempt and per-call limits. Pass `limiter=@runtime.NoLimiter::new()` to opt out of the limiter, pacing and gate.

Failures are `@runtime.SdkError`. `api_error` reads GitHub's error body (`message`, `documentation_url`, `status`, `errors`) out of one. `is_not_modified` recognises the `304` answer to a conditional request. `is_secondary_rate_limit` recognises the secondary limit, which is a different mechanism from the hourly quota, reported as `403` or `429` with `retry-after` or a message naming the secondary rate limit.

Clients created with `GitHub::new` retry through `GitHubRetry` around the `retry` policy, by default `@runtime.RetryPolicy::conservative().with_max_retries(3)`:

- Three retries, as octokit. A `5xx`, `408`, `409` or a timeout after sending is retried only for an idempotent request: unlike octokit, a `POST` is not resent, because GitHub has no idempotency key and a second issue or comment could be created.
- A secondary limit is retried for any method, after `retry-after`, or else after 60 s, 120 s, 240 s (docs.github.com: "wait for at least one minute", then "an exponentially increasing amount of time"). The policy's Retry-After cap does not apply; its retry count and a `total_ms` in `timeouts` do.
- A primary limit (`x-ratelimit-remaining: 0`, or GraphQL `RATE_LIMITED`) is retried once, one second after `x-ratelimit-reset`, as octokit does; docs.github.com asks not to retry before the reset. That can be up to an hour, so set a `total_ms` to bound it.

For GitHub Enterprise Server, point `base_url` at the REST mount: `@github.GitHub::new(transport, clock, token~, base_url="https://ghe.example.com/api/v3")`. GraphQL is not under that mount — Enterprise Server serves it from `/api/graphql` — so the GraphQL endpoint is derived from `base_url` rather than appended to it; pass `graphql_url` for a deployment that spells it differently. `from_client` takes a preconfigured `@runtime.Client` for anything further from the default deployment, and takes `graphql_url` too, because a runtime client keeps its `base_url` to itself.

Not every field is typed. At 43 places in the specification the generator could not resolve a schema into a single MoonBit type — unions whose branches carry no tag of their own, unions whose tag sits on a sibling property, objects mixing named and typed additional properties — and those are carried as raw `Json`. [The census](../docs/census.md) lists every one with the reason. They can be typed individually later without changing the operation signatures.
