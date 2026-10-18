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
