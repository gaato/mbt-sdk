# gaato/github

An unofficial GitHub API client for [MoonBit](https://www.moonbitlang.com/).
Every operation of GitHub's REST API is generated, with its types, from the
first-party OpenAPI description; GraphQL is a passthrough over `Json`. It is
built on [`gaato/http`](https://mooncakes.io/docs/gaato/http) and
[`gaato/sdk-runtime`](https://mooncakes.io/docs/gaato/sdk-runtime) and has no
async runtime of its own: the caller supplies a `Transport` and a `Clock`, for
example from [`gaato/http-async`](https://mooncakes.io/docs/gaato/http-async).

> **Status**: unofficial and experimental. Minor releases may contain breaking
> changes; the
> [changelog](https://github.com/gaato/mbt-sdk/blob/main/github/CHANGELOG.md)
> lists each one with a migration note.

## Install

```sh
moon add gaato/github
moon add gaato/http-async
moon add moonbitlang/async
```

## Usage

Make a transport and a clock with `gaato/http-async`:

```mbt nocheck
///|
let transport = @http_async.AsyncTransport::new(max_body_bytes=64 * 1024 * 1024)

///|
let clock = @http_async.AsyncClock::new()
```

Then pass them to the client and call an operation:

```mbt check
///|
/// Reads a repository's star count.
pub async fn stars(
  transport : &@http.Transport,
  clock : &@clock.Clock,
  token~ : String,
) -> Int32 raise @runtime.SdkError {
  let gh = @github.GitHub::new(transport, clock, token~)
  let repo = gh.call(
    @gen.repos_get_request("gaato", "mbt-sdk"),
    @gen.repos_get_decode,
  )
  repo.stargazers_count
}
```

`call` and `send` read the whole body into memory, so give the transport a
`max_body_bytes` as above; this client cannot set it because the transport is
yours. 64 MiB is ample for API JSON, and a longer reply fails with
`@runtime.Transport(Protocol(..))` rather than growing memory. Files are
another matter: see [Downloads and redirects](#downloads-and-redirects).

## Packages

| Package | What it is |
|---|---|
| `gaato/github` | The `GitHub` client: sending, pagination, GraphQL, rate limits, retries and error helpers |
| `gaato/github/gen` | Every REST operation and its types, generated from the OpenAPI description |

## Requests and responses

Each REST operation is a sans-IO pair in `gaato/github/gen`:
`<operation>_request(...)` builds an `@http.Request`, and
`<operation>_decode(response)` reads the success payload. The generated types
are the public vocabulary; the client only sends, follows and reads.

`call` sends a request and decodes the reply. `send` returns the response, for
an operation with no body to decode (`204`, `304`) or one asked for in another
representation, such as a diff:

```mbt check
///|
/// Reads the diff between two refs.
pub async fn compare_diff(gh : @github.GitHub, range : String) -> String {
  let response = gh.send(
    @gen.repos_compare_commits_request("gaato", "mbt-sdk", range).header(
      "accept", "application/vnd.github.diff",
    ),
  )
  response.text()
}
```

A header set on the request, such as that `accept`, wins over the client's
default.

Not every field is typed. Where the generator could not resolve a schema into
a single MoonBit type, such as a union whose branches carry no tag of their
own, the value is carried as raw `Json`. The
[census](https://github.com/gaato/mbt-sdk/blob/main/docs/census.md) (in
Japanese) lists each one with the reason.

## Downloads and redirects

The archive, artifact, log and migration downloads answer `302` with a
short-lived `location`:

- `repos_download_tarball_archive` and `repos_download_zipball_archive`
- `actions_download_artifact` and the `actions_download_*_logs` operations
- `migrations_download_archive_for_org` and
  `migrations_get_archive_for_authenticated_user`
- some of the time, `repos_get_release_asset` with
  `accept: application/octet-stream` and `code_scanning_get_codeql_database`
  with `accept: application/zip`

The native and Wasm transports do not follow redirects, so `send` raises that
`302` as `@runtime.Status`. Read `location` from its headers and fetch it with
`transport.send_stream`, without the token, writing chunks out as they arrive.
`@http.follow_redirects_stream(request, r => transport.send_stream(r))` does
both for a request carrying the full URL and the token: it drops
`Authorization` when the `location` is on another host and closes the `302`
unread.

On JS, fetch follows the redirect and the file arrives as a buffered body.
So do raw content (`repos_get_content` with
`accept: application/vnd.github.raw`, up to 100 MB) and large diffs on every
target. Send those through a second `GitHub` client whose transport has a
limit sized for the largest file you accept.

## Pagination

GitHub paginates with `Link` headers, so `paginator` follows the
`rel="next"` URL the server wrote. It is an `@runtime.Paginator`, with `each`,
`next_page` and `collect`:

```mbt check
///|
/// Lists up to 250 of a user's repositories.
pub async fn user_repos(
  gh : @github.GitHub,
  user : String,
) -> Array[@gen.MinimalRepository] raise @runtime.SdkError {
  let repos = gh.paginator(
    @gen.repos_list_for_user_request(user, per_page=100),
    @gen.repos_list_for_user_decode,
  )
  repos.collect(max=250)
}
```

## GraphQL

GraphQL is not generated: the shape of a reply follows the query you write.
`graphql` sends a query with its variables and returns the `data`:

```mbt check
///|
/// Reads a repository's star count through GraphQL.
pub async fn stars_graphql(gh : @github.GitHub) -> Json raise @runtime.SdkError {
  gh.graphql(
    query="query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { stargazerCount } }",
    variables={ "owner": "gaato", "name": "mbt-sdk" },
  )
}
```

A GraphQL failure does not use the HTTP status: the reply is `200` with an
`errors` array beside a possibly partial `data`. `graphql` raises whenever
that array is non-empty (`@runtime.Decode`, or `@runtime.RateLimited` for a
rate limit), and `graphql_errors` reads it back, including `type_`, which
names the condition (`NOT_FOUND`, `FORBIDDEN`, `RATE_LIMITED`). Use
`graphql_response` when the partial `data` of such a reply is worth keeping.

`graphql_paginator` walks a connection by passing `pageInfo.endCursor` back
through a query variable: `after`, unless `cursor_variable` says otherwise.

## Rate limits

Search and GraphQL are metered separately from the rest of the API, so
requests to `/search/*` and to `/graphql` use their own buckets. Writes (any
method but `GET` and `HEAD`) use `core:write`, or `core:notifications` for
the paths that send notifications. The default `@runtime.WindowLimiter` paces
each bucket against `x-ratelimit-remaining` and `x-ratelimit-reset`, keyed by
`x-ratelimit-resource`, so a write still spends the `core` window.

Following GitHub's guidance and octokit, the limiter also spaces requests:

- writes and every GraphQL request at least 1 s apart;
- writes that send notifications 3 s apart, which also holds the next write;
- searches 2 s apart.

GitHub also asks for requests to be made serially. This module has no async
runtime to do that, so pass a gate, such as `SemaphoreGate` from
`gaato/http-async`:

```mbt nocheck
///|
let gh = @github.GitHub::new(transport, clock, token~, gate=() => {
  @http_async.SemaphoreGate::new()
})
```

The gate serialises each group: writes and GraphQL, searches, and reads.
`timeouts` takes a `@runtime.Timeouts` for per-attempt and per-call limits.
Pass `limiter=@runtime.NoLimiter::new()` to opt out of the limiter, the pacing
and the gate.

## Errors and retries

Failures are `@runtime.SdkError`.

- `api_error` reads GitHub's error body (`message`, `documentation_url`,
  `status`, `errors`) out of one.
- `is_not_modified` recognises the `304` answer to a conditional request.
- `is_secondary_rate_limit` recognises the secondary rate limit, a different
  mechanism from the hourly quota, reported as `403` or `429` with
  `retry-after` or a message naming it.

Clients created with `GitHub::new` retry through `GitHubRetry` around the
`retry` policy, by default `@runtime.RetryPolicy::conservative().with_max_retries(3)`:

- Three retries, as octokit. A `5xx`, `408`, `409` or a timeout after sending
  is retried only for an idempotent request: a `POST` is not resent, because
  GitHub has no idempotency key and a second issue or comment could be
  created.
- A secondary limit is retried for any method, after `retry-after`, or else
  after 60 s, 120 s and 240 s, as GitHub's documentation asks. The policy's
  Retry-After cap does not apply; its retry count and a `total_ms` in
  `timeouts` do.
- A primary limit (`x-ratelimit-remaining: 0`, or GraphQL `RATE_LIMITED`) is
  retried once, one second after `x-ratelimit-reset`. That can be up to an
  hour away, so set a `total_ms` to bound it.

A GraphQL rate limit, a secondary limit reported in a `200`, and "Something
went wrong while executing your query" are retried like an error status. A
document holding a mutation is not retried on "Something went wrong", since
the mutation may have been applied. A rate limit that persists is raised as
`@runtime.RateLimited`, with the reply's body for `graphql_errors`.

## GitHub Enterprise Server

Point `base_url` at the REST mount:
`@github.GitHub::new(transport, clock, token~, base_url="https://ghe.example.com/api/v3")`.
Enterprise Server serves GraphQL from `/api/graphql`, outside that mount, so
the GraphQL endpoint is derived from `base_url` rather than appended to it;
pass `graphql_url` for a deployment that spells it differently. `from_client`
takes a preconfigured `@runtime.Client` for anything further from the default
deployment, and takes `graphql_url` too.

## Links

- [Changelog](https://github.com/gaato/mbt-sdk/blob/main/github/CHANGELOG.md)
- [Repository](https://github.com/gaato/mbt-sdk)
- [Spec provenance](https://github.com/gaato/mbt-sdk/blob/main/github/spec/SOURCE.md)
  and [generation overlays](https://github.com/gaato/mbt-sdk/blob/main/github/overlays/moonbit.yaml)
- [Untyped fields census](https://github.com/gaato/mbt-sdk/blob/main/docs/census.md)
  (in Japanese)

## License

Apache-2.0
