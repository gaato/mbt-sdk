# GitHub 0.2.0 release candidate

Publish only `gaato/github@0.2.0`. Its registry dependencies remain
`gaato/http@0.1.0` and `gaato/sdk-runtime@0.1.0`; the transport adapter is
caller-supplied and is not a package dependency. The unpublished runtime test
module now imports `gaato/github@0.2.0`.

## Changes

- Add an untyped GraphQL passthrough: `graphql`, `graphql_response`,
  `graphql_paginator`, `GraphqlError` and `graphql_errors`. Nothing is
  generated for it, because there is nothing to generate from — in OpenAPI a
  response's shape belongs to the operation, which is what `gen` compiles, while
  in GraphQL it belongs to the query document the caller wrote.
- Report a GraphQL failure instead of losing it. GitHub answers a failed query
  with HTTP `200` and an `errors` array, which `@runtime.classify` cannot see,
  so `graphql` raises `@runtime.Decode` whenever that array is non-empty and
  attaches the body for `graphql_errors` to read back.
- Meter GraphQL in its own rate limit bucket. It was falling into `core`, which
  made the limiter pace two independent windows as one.
- Derive the GraphQL endpoint from `base_url` rather than appending to it.
  GitHub Enterprise Server serves REST from `/api/v3` and GraphQL from
  `/api/graphql`, so the appended form addressed an endpoint that does not
  exist. `graphql_url` overrides the derivation.

## Public API

```moonbit
GitHub::new(transport, clock, token?, base_url?, api_version?, user_agent?,
            retry?, limiter?, graphql_url?)          // graphql_url? is new
GitHub::from_client(@runtime.Client, graphql_url?)   // graphql_url? is new

GitHub::graphql(query~, variables?, operation_name?)          -> Json
GitHub::graphql_response(query~, variables?, operation_name?) -> Json
GitHub::graphql_paginator(page, query~, variables?, cursor_variable?, operation_name?)
GraphqlError { message, type_, path, locations, extensions }
graphql_errors(@runtime.SdkError) -> Array[GraphqlError]?
```

`graphql` returns `data` and raises when the reply carries errors;
`graphql_response` returns the whole `{data, errors, extensions}` envelope and
raises only for what the HTTP status reports, which is what keeps the partial
`data` of a field-level failure reachable. `graphql_paginator` takes no path
into the payload — a connection's `pageInfo` sits wherever the query put it — so
the caller's extractor returns each page's items together with the cursor for
the next, and the paginator threads that cursor through a query variable named
`after` unless `cursor_variable` says otherwise.

The GraphQL request sends `accept: application/json` in place of the REST media
type. The `x-github-api-version` default rides along; it selects a REST version
and GraphQL has none.

## Breaking changes

None. Both signature changes are new optional named parameters, and the REST
surface is untouched.

## Known limitations

- **GraphQL is untyped.** `graphql` returns `Json`; decoding is the caller's.
  This is not a gap the generator can close later: typing it means compiling the
  caller's query documents, which needs a generator that runs in the consumer's
  build, and MoonBit's build system has no hook for that. Generating the schema
  instead would produce 1,026 object types whose 7,627 fields would all have to
  be optional (58% already are), giving `Json`'s guarantees at 100k lines.
- **`graphql_paginator`'s extractor is not type-safe.** Reading `pageInfo` from
  the wrong place stops the walk after one page, silently. The contract —
  return `None` once `hasNextPage` is false — is the caller's to keep.
- **A GraphQL rate limit is not retried.** `RATE_LIMITED` arrives as an ordinary
  errors entry, the point budget refills on the hour, and no `retry-after` comes
  with it, so an immediate replay would only spend the retry policy's attempts.
  `@runtime.Decode` is not retryable; the limiter has the reset and paces the
  next call. Read the condition with `graphql_errors`.
- **`GraphqlError.type_` stays a `String`.** GitHub does not document the set of
  values it can take.
- The GraphQL schema is not vendored. Nothing generates from it, so there is
  nothing for `spec-watch.yml` to diff.
- Everything listed under 0.1.0 still holds: 43 raw-`Json` places, public types
  tied to the upstream schema, required-and-nullable fields needing the key, no
  per-operation wrappers.

## Scope and evidence

`scripts/gates.sh` is green in 69 s, including `operations=1221 diagnostics=0`
for the all-operation census and no drift from `scripts/generate.sh --check`.
The generated `gen` package is unchanged by this release: the addition is 332
lines of hand-written facade.

Measured against the published schema
(`docs.github.com/public/fpt/schema.docs.graphql`, 1.55 MB / 74,822 lines):
1,026 object types, 50 interfaces, 50 unions, 255 enums, 418 input types, 13
custom scalars, 31 `Query` and 54 `Mutation` root fields, 7,627 fields of which
58% are nullable, 158 `*Connection` types, 1,259 `@deprecated`. An
unauthenticated `POST https://api.github.com/graphql` answers `403` with a
REST-shaped body and `x-ratelimit-resource: graphql`, which is where the bucket
name comes from; the vendored OpenAPI document lists the same resource beside
`core` and `search`.

Tests: 22 synchronous in `github/src` (up from 13 — five for `graphql_errors`
against real envelopes, four for the bucket, the endpoint derivation and cursor
threading), 19 asynchronous in `runtime-tests/src/github` (up from 11 — the
request that leaves the client, `operationName`, a 200 carrying errors, partial
data through `graphql_response`, `RATE_LIMITED` not being retried, bucket
separation from `core`, the Enterprise Server endpoint, a three-page cursor
walk), and a second live check against the real API alongside the REST one.

The live GraphQL check is the only place the 200-with-errors path meets the real
server: it runs a query, makes GitHub produce a `NOT_FOUND` envelope, confirms
the partial data survives `graphql_response`, and confirms the limiter recorded
a `graphql` bucket and not a `core` one. It is opt-in, reads
`MBT_SDK_GITHUB_TOKEN`, and is not part of the gates, so **this candidate has
not been checked against the live API yet**.

Pushing the version bump to `main` triggers the existing release workflow after
CI succeeds. Review the candidate diff and publish dry-run before authorizing
that push; no manual publish is needed.
