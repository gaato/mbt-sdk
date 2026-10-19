# Changelog

All notable changes to `gaato/github` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

`spec-watch.yml` releases this module when a new upstream spec changes the
generated code. Such a release carries one entry naming the spec; the API
change itself is the diff of `src/gen/pkg.generated.mbti`. Generated types
are `pub(all)`, so a new field breaks struct literals and a new variant
breaks exhaustive matches: build values with `::new`, whose new arguments
are optional unless the field is required, and keep a wildcard arm.

## [Unreleased]

## [0.17.0] - 2026-10-19

### Changed

- **Depends on `gaato/http` 0.4.1 and `gaato/sdk-runtime` 0.7.0.** Retries,
  pacing and server keys come from them. Migration: update the `gaato/http`
  and `gaato/sdk-runtime` imports alongside this module, and follow
  `gaato/sdk-runtime`'s changelog where you build a `RetryPolicy` or a
  `RetryDecider`.
- **`GitHubRetry` implements `gaato/sdk-runtime` 0.7.0's `RetryDecider`.**
  Its method is `decide(error, context) -> Decision` instead of
  `next_delay_ms(error, request, attempt, random) -> Int?`. It no longer
  holds a secondary-limit wait to the policy's Retry-After cap (below), and
  hands every error it does not recognise to the policy, whose `StopAbove`
  and `BackoffAbove` caps then apply as `gaato/http/retry` defines them.
  Migration: call
  `retry.decide(error, @runtime.RetryContext::new(request, attempt~, random~))`
  and match `Wait(ms)` and `Stop(_)` instead of `Some(ms)` and `None`; build a
  policy with `RetryPolicy::conservative().with_max_retries(n)` instead of a
  struct update.
- **Three retries by default, and still none for a `POST` on 5xx.**
  `GitHub::new` defaults to `RetryPolicy::conservative().with_max_retries(3)`
  (it was two retries), matching octokit's `plugin-retry`. Unlike octokit, a
  5xx, 408, 409 or a timeout after sending is retried only for an idempotent
  request: GitHub has no idempotency key, and a resent `POST` could open a
  second issue or comment. Migration: pass `retry=` with
  `.with_max_retries(2)` for the old count.
- **A secondary rate limit is waited out with growing waits.** Without
  `retry-after` (or with `retry-after: 0`) the waits are 60 s, 120 s, 240 s;
  `retry-after` is read as seconds or an HTTP date. Neither is held to the
  policy's Retry-After cap any more, so the second wait, which the 60 s cap
  used to stop, now happens, as docs.github.com asks ("wait for at least one
  minute", then "an exponentially increasing amount of time"). The retry
  count and a total time limit still bound it. Detection matches "secondary
  rate" in any case, as octokit does, also in a GraphQL reply.
- **A primary rate limit is retried once, a second after the reset.** A `403`
  or `429` with `x-ratelimit-remaining: 0` used to be raised at once; it is
  now retried, for any method, one second after `x-ratelimit-reset`, and only
  once per call, as octokit does (docs.github.com: do not retry before the
  reset). That wait can be up to an hour. Migration: set a total time limit
  through `timeouts`, or `retry=@runtime.RetryPolicy::none()` to raise at once.
- **GraphQL rate limits and transient failures in a `200` are retried.**
  `graphql`, `graphql_response` and `graphql_paginator` now check the reply
  inside the retry loop. A `RATE_LIMITED` error is raised as
  `@runtime.RateLimited` (it was `Decode`) and retried once after the reset; a
  secondary limit is raised as `RateLimited` and waited out as above;
  "Something went wrong while executing your query" is retried with the
  policy's backoff when the document holds no mutation (a mutation may have
  been applied, so it is raised as before). `graphql_response` raises these
  once their retries run out instead of returning the envelope. Migration:
  match `@runtime.RateLimited(..)` where you matched `Decode` for
  `RATE_LIMITED`; `graphql_errors` reads either.
- **Writes, GraphQL and searches are paced, so consecutive writes are
  slower.** The default limiter spaces writes (any method but `GET` and
  `HEAD`) and every GraphQL request at least 1 s apart, writes to the paths
  that send notifications (from octokit's `plugin-throttling`) 3 s, and
  searches 2 s, as octokit does and docs.github.com asks for mutative
  requests. Writes use the `core:write` and `core:notifications` buckets, and
  GraphQL `graphql` or `graphql:mutation`, but the limiter records state under
  the response's `x-ratelimit-resource`, so they still spend and wait on the
  `core` and `graphql` windows. Migration: pass
  `limiter=@runtime.NoLimiter::new()`, or a `WindowLimiter` of your own, to
  opt out.

### Added

- **`GitHub::new(gate?)` makes each paced group's requests serial.**
  docs.github.com asks for requests "serially instead of concurrently"; this
  module has no async runtime, so pass `gate=() => SemaphoreGate::new()` from
  `gaato/http-async`. It is used by the default limiter only.
- **`GitHub::new(timeouts?)` passes `@runtime.Timeouts` to the client,** for
  per-attempt and per-call time limits.

## [0.16.0] - 2026-10-19

### Changed

- **Every enum in `gaato/github/gen` is `#non_exhaustive`.** A value the
  API adds can then become a constructor in the patch releases made when
  the vendored spec changes. Migration: a `match` on one of these types
  ends with `TypeName::.. => …` after the existing constructors.

## [0.15.0] - 2026-10-18

### Changed

- **Regenerated from the upstream spec fetched 2026-10-18** (sha256 `88b84f4f57b5`). The public API changed; see the `pkg.generated.mbti` diff.

## [0.14.1] - 2026-10-19

### Changed

- **Built on `gaato/sdk-runtime` 0.5.0 and `gaato/http` 0.3.1.** Retry-After
  and Link parsing now come from `gaato/http`. The public API is unchanged.

## [0.14.0] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.3.0 and `gaato/sdk-runtime` 0.4.0.** `HttpError` now says which phase of an exchange failed (`Timeout(phase~, ms~)`, `Network(phase~, ..)`, `Proxy(status~, ..)`), `Request.body` is a `Body` that may stream, and `Client` never resends a stream body a transport has read. Migration: update the `gaato/http` and `gaato/sdk-runtime` imports alongside this module, and follow their changelogs where you match `HttpError` or read `Request.body`.

## [0.13.1] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.2.1 and `gaato/sdk-runtime` 0.3.1.** An error
  keeps at most 1 MiB of its body, and a server-sent `x-ratelimit-reset` or
  `Retry-After` can hold a rate-limit bucket for at most an hour. The README
  now sets up the transport with a 64 MiB `max_body_bytes` and explains how
  to fetch large downloads.

## [0.13.0] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.2.0 and `gaato/sdk-runtime` 0.3.0.**
  Migration: update the `gaato/http` and `gaato/sdk-runtime` imports
  alongside this one.

## [0.12.0] - 2026-10-16

### Changed

- **Regenerated from the upstream spec fetched 2026-10-15** (sha256
  `54f730a2b059`): `metadata` (raw `Json`) on `RuleSuiteRuleEvaluationsItem`
  and `include_metadata?` on `repos_get_org_rule_suite_request` and
  `repos_get_repo_rule_suite_request`.

## [0.11.0] - 2026-10-15

### Added

- **`GitHubRetry`**, a `RetryDecider` that waits out a secondary rate limit
  and otherwise follows its `RetryPolicy`.

### Changed

- **`GitHub::new` retries secondary rate limits by default**, POST requests
  included, within the policy's retry count. It waits `retry-after`, or
  60000 ms doubling per attempt without one, and stops instead of capping
  once a wait exceeds `max_retry_after_ms`.
- **Generated operations percent-encode with `gaato/http`'s URL helpers**
  instead of a private copy; the encoding is unchanged. Depends on
  `gaato/http` 0.1.1 and `gaato/sdk-runtime` 0.2.2.

## [0.10.0] - 2026-10-15

### Changed

- **Regenerated from the upstream spec fetched 2026-10-15** (sha256
  `ab64904dc9cd`): a `ScimError` type.

## [0.9.0] - 2026-10-13

### Changed

- **Regenerated from the upstream spec fetched 2026-10-13** (sha256
  `e1715ad0c67e`): ten `agent_automations_*` operations, and an `Anonymous`
  auth type for organization private registries.

## [0.8.2] - 2026-10-10

### Changed

- **Regenerated from the upstream spec fetched 2026-10-10** (sha256
  `9826c6965278`): documentation only.

## [0.8.1] - 2026-10-07

### Changed

- **Regenerated from the upstream spec fetched 2026-10-07** (sha256
  `4f96c45b78cc`): documentation only.

## [0.8.0] - 2026-10-06

### Changed

- **Regenerated from the upstream spec fetched 2026-10-06** (sha256
  `1010ef82d78c`): `CodeCoverage` and `CodeQuality` variants of
  `RepositoryRuleDetailed`.

## [0.7.0] - 2026-10-03

### Changed

- **Regenerated from the upstream spec fetched 2026-10-03** (sha256
  `182c54e55a27`): the `pulls_rerequest_reviewers` operation.

## [0.6.0] - 2026-09-30

### Changed

- **Regenerated from the upstream spec fetched 2026-09-30** (sha256
  `b0c6b0812842`): `bypass_rules` on `PullsMergeAsyncRequest`.

## [0.5.0] - 2026-09-29

### Changed

- **Regenerated from the upstream spec fetched 2026-09-28** (sha256
  `9c2b0e31f8f3`): six `orgs_external_properties_for_repos_*` operations,
  `actions_download_step_logs_for_workflow_run_job`, and
  `organization_external_properties_for_repos` on `AppPermissions`.
- Depends on `gaato/sdk-runtime` 0.2.1.

## [0.4.0] - 2026-09-25

### Changed

- **Regenerated from the upstream spec fetched 2026-09-25** (sha256
  `a9d6acf6f688`): the `issues_add_relates_to`, `issues_list_relates_to` and
  `issues_remove_relates_to` operations.

## [0.3.0] - 2026-09-24

### Changed

- **Built on `gaato/sdk-runtime` 0.2.** `paginator` and `graphql_paginator`
  return `Paginator[T, SdkError]`, and `from_client` takes a 0.2 `Client`.
  Migration: name the paginator type with its error parameter.

## [0.2.0] - 2026-09-24

### Added

- **An untyped GraphQL passthrough:** `graphql`, `graphql_response`,
  `graphql_paginator`, `GraphqlError` and `graphql_errors`. A reply with a
  non-empty `errors` array raises, GraphQL has its own rate limit bucket,
  and the endpoint is derived from `base_url` (GitHub Enterprise Server
  serves it from `/api/graphql`); `graphql_url?` on `GitHub::new` and
  `from_client` overrides it.

## [0.1.0] - 2026-09-24

### Added

- Initial release: all 1,221 operations of the vendored REST API description
  (`2022-11-28`) generated into `gaato/github/gen` as sans-IO
  `<operation>_request` / `<operation>_decode` pairs, and a facade that
  sends (`call`, `send`), follows `Link` pages (`paginator`) and reads
  GitHub's error bodies. Search uses its own rate limit bucket.
