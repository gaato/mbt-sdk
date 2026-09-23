# gaato/github

Unofficial GitHub REST API client for MoonBit, on `gaato/http` and `gaato/sdk-runtime`. The caller supplies a `Transport` and a `Clock`, for example `gaato/http-async`.

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

Search is metered separately from the rest of the API, so requests to `/search/*` use their own rate limit bucket; the default `@runtime.WindowLimiter` paces each bucket against `x-ratelimit-remaining` and `x-ratelimit-reset`. Pass `limiter=@runtime.NoLimiter::new()` to opt out.

Failures are `@runtime.SdkError`. `api_error` reads GitHub's error body (`message`, `documentation_url`, `status`, `errors`) out of one. `is_not_modified` recognises the `304` answer to a conditional request. `is_secondary_rate_limit` recognises the secondary limit, which is a different mechanism from the hourly quota, reported as `403` or `429` with `retry-after`, and which no limiter can anticipate: back off and retry.

For GitHub Enterprise Server, point `base_url` at the REST mount: `@github.GitHub::new(transport, clock, token~, base_url="https://ghe.example.com/api/v3")`. `from_client` takes a preconfigured `@runtime.Client` for anything further from the default deployment.

Not every field is typed. At 43 places in the specification the generator could not resolve a schema into a single MoonBit type — unions whose branches carry no tag of their own, unions whose tag sits on a sibling property, objects mixing named and typed additional properties — and those are carried as raw `Json`. [The census](../docs/census.md) lists every one with the reason. They can be typed individually later without changing the operation signatures.
