# Changelog

All notable changes to `gaato/openai` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

`spec-watch.yml` releases this module when a new upstream spec changes the
generated code. Such a release carries one entry naming the spec; the API
change itself is the diff of `src/gen/pkg.generated.mbti`.

## [Unreleased]

## [0.4.0] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.3.0 and `gaato/sdk-runtime` 0.4.0.** `HttpError` now says which phase of an exchange failed (`Timeout(phase~, ms~)`, `Network(phase~, ..)`, `Proxy(status~, ..)`), `Request.body` is a `Body` that may stream, and `Client` never resends a stream body a transport has read. Migration: update the `gaato/http` and `gaato/sdk-runtime` imports alongside this module, and follow their changelogs where you match `HttpError` or read `Request.body`.

## [0.3.1] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.2.1 and `gaato/sdk-runtime` 0.3.1.** Streams
  now count an event's `event` and `id` lines toward its 16 MiB bound and
  are parsed 64 KiB at a time, an error keeps at most 1 MiB of its body, and
  a server cannot hold a rate-limit bucket for more than an hour.

## [0.3.0] - 2026-10-18

### Changed

- **Depends on `gaato/http` 0.2.0 and `gaato/sdk-runtime` 0.3.0.** A
  streamed event larger than 16 MiB now fails the stream with
  `HttpError::Protocol` instead of being buffered without limit. Migration:
  update the `gaato/http` and `gaato/sdk-runtime` imports alongside this
  one.

## [0.2.1] - 2026-10-15

### Changed

- **Generated operations percent-encode with `gaato/http`'s URL helpers**
  instead of a private copy; the encoding is unchanged. Depends on
  `gaato/http` 0.1.1 and `gaato/sdk-runtime` 0.2.2.

## [0.2.0] - 2026-09-25

### Changed

- **Built on `gaato/sdk-runtime` 0.2.** `OpenAI::from_client` takes a 0.2
  `Client`, and `SdkError` and `RetryPolicy` are the 0.2 types.
  Migration: depend on `gaato/sdk-runtime` 0.2 if you name its types; see
  its changelog for the `RateLimiter` and `Paginator` changes.

### Added

- **Every generated type derives `Eq` and `Debug`.**

## [0.1.0] - 2026-09-22

### Added

- Initial release: models, embeddings, Responses and Chat Completions
  (buffered and streaming, with tool calling and a typed `reasoning_effort`),
  with types and operations generated from the vendored OpenAPI spec behind a
  hand-written facade. Works against OpenAI-compatible servers through
  `base_url`.
