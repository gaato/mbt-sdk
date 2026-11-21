# gaato/github

A GitHub API client for MoonBit. Every REST operation, with its types, is
generated from GitHub's own OpenAPI description, and GraphQL queries are sent
with variables and come back as `Json`. The client follows pagination links,
paces itself against GitHub's rate limits, retries the way GitHub asks, and
works with GitHub.com and Enterprise Server.

Unofficial, and not affiliated with GitHub. A minor release can change the
API; the
[changelog](https://github.com/gaato/moonbit-sdks/blob/main/github/CHANGELOG.md)
lists each change with a migration note.

## Install

```sh
moon add gaato/github
moon add gaato/mttp
```

Import `gaato/github` and `gaato/github/gen`. `gaato/mttp` supplies the
network, the clock and the timer. A library that wraps this SDK adds
`gaato/mttp_core` instead, and takes the backend and clock from its caller.
Request attributes, `NoLimiter` and the other client types named below come
from `gaato/mttp_core/client`, which needs `moon add gaato/mttp_core` too.

## Call a REST operation

Each operation is a pair in `gaato/github/gen`: `<operation>_request(...)`
builds the request, and `<operation>_decode` reads the reply into its type.
`call` sends one and decodes with the other.

```mbt check
///|
pub async fn stars(
  gh : @github.GitHub,
  owner : String,
  repo : String,
) -> Result[Int32, @github.GitHubFailure] {
  match gh.call(@gen.repos_get_request(owner, repo), @gen.repos_get_decode) {
    Ok(repository) => Ok(repository.stargazers_count)
    Err(failure) => Err(failure)
  }
}
```

A command-line program builds the client from mttp's backend, clock and timer,
and closes the backend when it is done. The token is optional: without one,
GitHub allows a small number of anonymous requests. Import `gaato/mttp`,
`moonbitlang/core/env` and `moonbitlang/core/debug` in its `moon.pkg`:

```mbt nocheck
///|
fn main {
  @mttp.run(async fn() {
    let backend = @mttp.backend()
    defer backend.close()
    let gh = @github.GitHub::new(
      backend,
      @mttp.clock(),
      token?=@env.get_env_var("GITHUB_TOKEN"),
      timer=@mttp.timer(),
      total_timeout_ms=60_000,
    )
    match stars(gh, "gaato", "moonbit-sdks") {
      Ok(count) => println("\{count} stars")
      Err(failure) => println(@debug.to_string(failure))
    }
  })
}
```

Some schema fields that do not resolve to one MoonBit type, such as untagged
unions, are carried as raw `Json`. The
[census](https://github.com/gaato/moonbit-sdks/blob/main/docs/census.md) (in
Japanese) lists each one.

## Collect several pages

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

The paginator follows the `Link` header the server wrote. `collect(max=...)`
bounds how many items you keep. Use `each` or `next_page` to process them as
they come.

## Diffs, archives and downloads

`send` returns the raw reply, for an operation with no body to decode or one
you ask for in another representation. A header you set on the request, such
as `accept: application/vnd.github.diff`, wins over the client's default.

Archive, artifact, log and release-asset downloads answer `302` with a
short-lived URL. `send` follows it and buffers the file, up to
`max_body_bytes` (64 MiB by default). Credentials are dropped when the redirect
leaves GitHub's host. For a file too large to buffer, read it with an mttp
client and `as_stream`. To get the URL instead, turn off redirects for that
request with an attribute from `gaato/mttp_core/client`:

```mbt check
///|
/// The short-lived URL of a repository's tarball, without downloading it.
pub async fn tarball_url(gh : @github.GitHub, ref_ : String) -> String? {
  let request = @gen.repos_download_tarball_archive_request(
    "gaato", "moonbit-sdks", ref_,
  ).attribute(@client.redirect_limit, 0)
  match gh.send(request) {
    Err(@github.GitHubFailure::Http(failure)) if failure.head().status == 302 =>
      failure.head().headers.get("location")
    _ => None
  }
}
```

## GraphQL

GraphQL is not generated, because the shape of a reply follows the query you
write. `graphql` sends a query with its variables and returns the `data`:

```mbt check
///|
/// Reads a repository's star count through GraphQL.
pub async fn stars_graphql(
  gh : @github.GitHub,
) -> Result[Json, @github.GitHubFailure] {
  gh.graphql(
    query="query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { stargazerCount } }",
    variables={ "owner": "gaato", "name": "moonbit-sdks" },
  )
}
```

GitHub can answer HTTP 200 with an `errors` array and partial `data`. `graphql`
returns that as a `GraphqlFailure`, and `graphql_errors` reads the entries.
`graphql_response` gives you the partial data instead, for errors that are not
retryable. `graphql_paginator` walks a connection by passing
`pageInfo.endCursor` back as the `after` variable.

## Rate limits and retries

The default limiter follows GitHub's guidance:

- It tracks `x-ratelimit-remaining` and `x-ratelimit-reset` per bucket. Search
  and GraphQL have their own buckets.
- It spaces writes and GraphQL requests 1 s apart, writes that send
  notifications 3 s apart, and searches 2 s apart.
- GitHub also asks for requests to be made one at a time. Pass a gate to get
  that: `gate=() => @runtime.SemaphoreGate::new()`, from `gaato/mttp/runtime`.
- `limiter=@client.NoLimiter::new()` turns all of this off.

Retries:

- **A POST is not resent after a server error**, because GitHub has no
  idempotency key and a second issue or comment could be created. Idempotent
  requests are retried up to three times on 5xx, 408, 409 and timeouts.
- A **secondary** rate limit (403 or 429 that names it) is retried for any
  method, after `retry-after`, or else after 60, 120 and 240 s.
- A **primary** rate limit (`x-ratelimit-remaining: 0`) is retried once, after
  the reset. That can be up to an hour away.

**Set `total_timeout_ms` (with `timer=`) to bound these waits.** Without it, a
call can wait until the rate limit resets. A GraphQL document that holds a
mutation is not retried on GitHub's "Something went wrong" error, since the
mutation may have been applied.

## Errors

Calls return `Result` with `GitHubFailure`:

- `Http(failure)`: an HTTP or decoding failure. `api_error` reads GitHub's
  error body (`message`, `documentation_url`, `errors`).
  `is_not_modified` recognises a `304` answer to a conditional request.
  `is_secondary_rate_limit` recognises the secondary limit.
- `GraphqlFailure(head, message~, body~)`: GraphQL errors, including a rate
  limit that persisted.
- `Validation(message)`: invalid input, caught before sending.

Transport failures raise `TransportError`.

## GitHub Enterprise Server

Point `base_url` at the REST mount:
`GitHub::new(backend, clock, token~, base_url="https://ghe.example.com/api/v3")`.
The GraphQL endpoint (`/api/graphql`) is derived from it. Pass `graphql_url`
for a deployment that places it elsewhere.

## Links

- [Changelog](https://github.com/gaato/moonbit-sdks/blob/main/github/CHANGELOG.md)
- [Repository](https://github.com/gaato/moonbit-sdks)
- [Spec provenance](https://github.com/gaato/moonbit-sdks/blob/main/github/spec/SOURCE.md)
- [Untyped fields census](https://github.com/gaato/moonbit-sdks/blob/main/docs/census.md)
  (in Japanese)

## License

Apache-2.0
