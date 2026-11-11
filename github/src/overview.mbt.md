# gaato/github

An unofficial GitHub API client for [MoonBit](https://www.moonbitlang.com/).
Every operation of GitHub's REST API is generated, with its types, from the
first-party OpenAPI description; GraphQL is a passthrough over `Json`. It is
built on [`gaato/mttp`](https://github.com/gaato/mttp) and requires a
caller-supplied `Backend` and `Clock`; the facade has no async runtime.

> **Status**: unofficial and experimental. Minor releases may contain breaking
> changes; the
> [changelog](https://github.com/gaato/mbt-sdk/blob/main/github/CHANGELOG.md)
> lists each one with a migration note.

## Install

```sh
moon add gaato/github
moon add gaato/mttp_async
```

An app adds these two modules. A library that wraps this SDK adds only
`gaato/github` and takes the `Backend` and `Clock` from its caller.

## Usage

`gaato/mttp_async` supplies the real network, the clock and the timer; no
experimental opt-in is needed:

```mbt nocheck
///|
let client = @github.GitHub::new(
  @mttp_async.backend(),
  @mttp_async.clock(),
  token~,
  timer=@mttp_async.timer(),
)
```

The function below takes the backend and the clock as parameters, so it also
runs against a fake `Backend` in tests. To call an operation:

```mbt check
///|
/// Reads a repository's star count.
pub async fn stars(
  backend : &@http.Backend,
  clock : &@rt.Clock,
  token~ : String,
) -> Result[Int32, @github.GitHubFailure] {
  let gh = @github.GitHub::new(backend, clock, token~)
  let repo = gh.call(
    @gen.repos_get_request("gaato", "mbt-sdk"),
    @gen.repos_get_decode,
  )
  match repo {
    Ok(repo) => Ok(repo.stargazers_count)
    Err(error) => Err(error)
  }
}
```

`call` and `send` buffer successful bodies up to 64 MiB by default. Set
`max_body_bytes` in `GitHub::new` to change this limit. Overflow
raises `TransportError` with kind `TooLarge`. Close the backend when its
owner shuts down.

## Packages

| Package | What it is |
|---|---|
| `gaato/github` | The `GitHub` client: sending, pagination, GraphQL, rate limits, retries and error helpers |
| `gaato/github/gen` | Every REST operation and its types, generated from the OpenAPI description |

## Requests and responses

Each REST operation is a sans-IO pair in `gaato/github/gen`:
`<operation>_request(...)` builds an `@http.Request`, and
`<operation>_decode(head, bytes)` returns the success payload or a
`ResponseFailure` value. The generated types
are the public vocabulary; the client only sends, follows and reads.

`call` sends a request and decodes the reply. `send` returns the response, for
an operation with no body to decode (`204`, `304`) or one asked for in another
representation, such as a diff:

```mbt check
///|
/// Reads the diff between two refs.
pub async fn compare_diff(
  gh : @github.GitHub,
  range : String,
) -> Result[String, @github.GitHubFailure] {
  let response = gh.send(
    @gen.repos_compare_commits_request("gaato", "mbt-sdk", range).header(
      "accept", "application/vnd.github.diff",
    ),
  )
  match response {
    Ok(response) => Ok(@utf8.decode_lossy(response.body))
    Err(error) => Err(error)
  }
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

The client follows these redirects, up to ten hops: `send` returns the
downloaded body, buffered up to `max_body_bytes`. On a hop to another origin
it drops `authorization` and `cookie`, so the token is not sent to the
download host, and it closes the intermediate bodies. For a download too large
to buffer, build an mttp Client with `Client::new` over the same backend and
read the body with `as_stream`; that Client follows redirects the same way.

To get the `302` back instead, for example to hand the short-lived URL to
another program, set the `redirect_limit` attribute to 0 on the request. The
redirect then returns an HTTP failure value whose head keeps `location`:

```mbt check
///|
/// The short-lived URL of a repository's tarball, without downloading it.
pub async fn tarball_url(gh : @github.GitHub, ref_ : String) -> String? {
  let request = @gen.repos_download_tarball_archive_request(
    "gaato", "mbt-sdk", ref_,
  ).attribute(@client.redirect_limit, 0)
  match gh.send(request) {
    Err(@github.GitHubFailure::Http(failure)) =>
      failure.head().headers.get("location")
    _ => None
  }
}
```

A Client built with `redirect=@client.RedirectConfig::none()` and passed to
`GitHub::from_client` returns every `3xx` this way. Host fetch redirect
behavior has platform constraints documented by `gaato/mttp_async`.

## Pagination

GitHub paginates with `Link` headers, so `paginator` follows the
`rel="next"` URL the server wrote. It is an `@client.Paginator`, with `each`,
`next_page` and `collect`:

```mbt check
///|
/// Lists up to 250 of a user's repositories.
pub async fn user_repos(
  gh : @github.GitHub,
  user : String,
) -> Result[Array[@gen.MinimalRepository], @github.GitHubFailure] {
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
pub async fn stars_graphql(
  gh : @github.GitHub,
) -> Result[Json, @github.GitHubFailure] {
  gh.graphql(
    query="query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { stargazerCount } }",
    variables={ "owner": "gaato", "name": "mbt-sdk" },
  )
}
```

A GraphQL reply may contain HTTP 200 with an `errors` array and partial
`data`. `graphql` returns a `GraphqlFailure` value for a non-empty array, retaining
the actual response head and body. `graphql_errors` reads the typed error
entries back. `graphql_response` returns partial data for errors that are
not retryable; exhausted rate limits and transient query failures return errors.

`graphql_paginator` walks a connection by passing `pageInfo.endCursor` back
through a query variable: `after`, unless `cursor_variable` says otherwise.

## Rate limits

Search and GraphQL are metered separately from the rest of the API, so
requests to `/search/*` and to `/graphql` use their own buckets. Writes (any
method but `GET` and `HEAD`) use `core:write`, or `core:notifications` for
the paths that send notifications. The default `@ratelimit.WindowLimiter` paces
each bucket against `x-ratelimit-remaining` and `x-ratelimit-reset`, keyed by
`x-ratelimit-resource`, so a write still spends the `core` window.

Following GitHub's guidance and octokit, the limiter also spaces requests:

- writes and every GraphQL request at least 1 s apart;
- writes that send notifications 3 s apart, which also holds the next write;
- searches 2 s apart.

GitHub also asks for requests to be made serially. This module has no async
runtime to do that, so pass a gate, such as `SemaphoreGate` from
`gaato/mttp_async`:

```mbt nocheck
///|
let gh = @github.GitHub::new(backend, clock, token~, gate=() => {
  @runtime.SemaphoreGate::new()
})
```

The gate serialises each group: writes and GraphQL, searches, and reads.
`timeout_ms` limits each attempt, and `total_timeout_ms` bounds the
whole call, including admission and stream processing. A total deadline
requires `timer`; necessary cleanup may continue after expiry.
Pass `limiter=@client.NoLimiter::new()` to opt out of the limiter, the pacing
and the gate.

## Errors and retries

Calls return `Result` with `GitHubFailure`: `Http(ResponseFailure)` for HTTP
and REST decoding failures, `GraphqlFailure` for GraphQL envelopes, and
`Validation` for invalid SDK inputs. Transport failures raise `TransportError`;
unknown decoder exceptions and cancellation retain their identity.

- `api_error` reads GitHub's error body (`message`, `documentation_url`,
  `status`, `errors`) out of one.
- `is_not_modified` recognises the `304` answer to a conditional request.
- `is_secondary_rate_limit` recognises the secondary rate limit, a different
  mechanism from the hourly quota, reported as `403` or `429` with
  `retry-after` or a message naming it.

Clients created with `GitHub::new` retry through `GitHubRetry` around the
`retry` policy, by default an SDK-local conservative rule with three retries
and 429 permitted for every method:

- Three retries, as octokit. A `5xx`, `408`, `409` or a timeout after sending
  is retried only for an idempotent request: a `POST` is not resent, because
  GitHub has no idempotency key and a second issue or comment could be
  created.
- A secondary limit is retried for any method, after `retry-after`, or else
  after 60 s, 120 s and 240 s, as GitHub's documentation asks. The policy's
  Retry-After cap does not apply; its retry count and `total_timeout_ms` do.
- A primary limit (`x-ratelimit-remaining: 0`, or GraphQL `RATE_LIMITED`) is
  retried once, one second after `x-ratelimit-reset`. That can be up to an
  hour away, so set `total_timeout_ms` to bound it.

A GraphQL rate limit, a secondary limit reported in a `200`, and "Something
went wrong while executing your query" are retried like an error status. A
document holding a mutation is not retried on "Something went wrong", since
the mutation may have been applied. A rate limit that persists is returned as
`GraphqlFailure`, with the reply's body for `graphql_errors`.

## GitHub Enterprise Server

Point `base_url` at the REST mount:
`@github.GitHub::new(backend, clock, token~, base_url="https://ghe.example.com/api/v3")`.
Enterprise Server serves GraphQL from `/api/graphql`, outside that mount, so
the GraphQL endpoint is derived from `base_url` rather than appended to it;
pass `graphql_url` for a deployment that spells it differently. `from_client`
takes a preconfigured `@client.Client` for anything further from the default
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
