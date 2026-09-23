# gaato/github

Unofficial GitHub API client for MoonBit, on `gaato/http` and `gaato/sdk-runtime`. The caller supplies a `Transport` and a `Clock`, for example `gaato/http-async`. REST is generated in full; GraphQL is a passthrough.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk

All 1,221 operations of the vendored first-party OpenAPI document are generated into `gaato/github/gen` as sans-IO pairs: `<operation>_request(...)` builds an `@http.Request`, and `<operation>_decode(response)` reads the success payload. See [spec provenance](spec/SOURCE.md) and [generation overlays](overlays/moonbit.yaml).

Unlike `gaato/openai` and `gaato/anthropic`, this module does not restate the generated types behind a hand-written vocabulary — at this surface area that would be a second API to keep in step with the first. The generated package *is* the public type vocabulary, and the facade only sends, follows, and reads:

```moonbit
let gh = @github.GitHub::new(transport, clock, token="ghp_...")
let repo = gh.call(@gen.repos_get_request("gaato", "mbt-sdk"), @gen.repos_get_decode)
let diff = gh.send(
  @gen.repos_compare_commits_request("gaato", "mbt-sdk", "main...topic")
    .header("accept", "application/vnd.github.diff"),
)
```

`call` decodes; `send` returns the response for operations with no body to decode (`204`, `304`) or a non-JSON representation such as `application/vnd.github.diff`. An operation that sets its own `accept` wins over the client default, as do all request headers.

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

A GraphQL failure does not use the HTTP status: the reply is `200` with an `errors` array beside a possibly partial `data`. `graphql` raises `@runtime.Decode` whenever that array is non-empty, so an error cannot pass unnoticed, and `graphql_errors` reads it back — including `type_`, which names the condition (`NOT_FOUND`, `FORBIDDEN`, `RATE_LIMITED`). Use `graphql_response` when the partial `data` of such a reply is worth keeping. `graphql_paginator` walks a connection by threading `pageInfo.endCursor` through a query variable, `after` unless `cursor_variable` says otherwise.

A GraphQL rate limit is a `RATE_LIMITED` entry in that array rather than a `429`, and it is deliberately not retryable: the point budget refills on the hour and carries no `retry-after`, so replaying it immediately would only spend the retry policy's attempts. The limiter has the reset and paces the next call.

Search and GraphQL are each metered separately from the rest of the API, so requests to `/search/*` and to `/graphql` use their own rate limit buckets; the default `@runtime.WindowLimiter` paces each bucket against `x-ratelimit-remaining` and `x-ratelimit-reset`. Pass `limiter=@runtime.NoLimiter::new()` to opt out.

Failures are `@runtime.SdkError`. `api_error` reads GitHub's error body (`message`, `documentation_url`, `status`, `errors`) out of one. `is_not_modified` recognises the `304` answer to a conditional request. `is_secondary_rate_limit` recognises the secondary limit, which is a different mechanism from the hourly quota, reported as `403` or `429` with `retry-after`, and which no limiter can anticipate: back off and retry.

For GitHub Enterprise Server, point `base_url` at the REST mount: `@github.GitHub::new(transport, clock, token~, base_url="https://ghe.example.com/api/v3")`. GraphQL is not under that mount — Enterprise Server serves it from `/api/graphql` — so the GraphQL endpoint is derived from `base_url` rather than appended to it; pass `graphql_url` for a deployment that spells it differently. `from_client` takes a preconfigured `@runtime.Client` for anything further from the default deployment, and takes `graphql_url` too, because a runtime client keeps its `base_url` to itself.

Not every field is typed. At 43 places in the specification the generator could not resolve a schema into a single MoonBit type — unions whose branches carry no tag of their own, unions whose tag sits on a sibling property, objects mixing named and typed additional properties — and those are carried as raw `Json`. [The census](../docs/census.md) lists every one with the reason. They can be typed individually later without changing the operation signatures.
