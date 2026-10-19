# Changelog

All notable changes to `gaato/openai` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

`spec-watch.yml` releases this module when a new upstream spec changes the
generated code. Such a release carries one entry naming the spec; the API
change itself is the diff of `src/gen/pkg.generated.mbti`.

## [Unreleased]

## [0.6.0] - 2026-10-19

### Changed

- **Depends on `gaato/http` 0.4.1 and `gaato/sdk-runtime` 0.7.0.** The
  retry policy and the new timeouts come from them. Migration: update the
  `gaato/http` and `gaato/sdk-runtime` imports alongside this module, and
  follow `gaato/sdk-runtime`'s changelog where you build a `RetryPolicy`.
- **Retries follow the official SDK (`openai-python`), POST included.**
  `OpenAI::new` now defaults to `RetryPolicy::stainless(cap=StopAbove(120000))`
  of `gaato/sdk-runtime`: two retries of 408, 409, 429 and every 5xx, and of
  a timeout or network failure after the request was sent, for every method.
  A `POST` such as a response or an embedding is therefore resent after a
  5xx or a timeout, as the official SDK does, and the model may generate (and
  bill) it twice. The server's `x-should-retry: true`/`false` overrides the
  status rules; the backoff runs from 0.5 s to 8 s, shortened by up to a
  quarter (it was 0.5 s to 30 s, ±20 %); a `Retry-After` over 120 s is raised
  instead of waited for (the limit was 60 s), and one of 0 means the backoff.
  Migration: pass `retry=@runtime.RetryPolicy::conservative()` to keep the
  old behaviour, which retries a `POST` only on 429 and on failures that
  prove nothing was sent. A policy built as `{ ..RetryPolicy::default(),
  max_retries: n }` no longer compiles; write
  `@runtime.RetryPolicy::stainless(cap=StopAbove(120000)).with_max_retries(n)`
  (or `conservative().with_max_retries(n)`), and follow `gaato/sdk-runtime`'s
  changelog for the rest of `RetryPolicy`.

### Added

- **`OpenAI::new(timer?, timeout_ms?, total_timeout_ms?)` limits calls in
  time.** With a `@sync.Timer` such as `gaato/http-async`'s `ClockTimer`,
  each attempt is limited to `timeout_ms` (600 s, the official default) and,
  when given, the whole call, retries and waits included, to
  `total_timeout_ms`. An attempt that runs out is retried like any timeout.
  Without a timer nothing changes and only the transport's timeouts apply;
  `AsyncTransport` defaults to 30 s, so raise its `timeout_ms` too (see the
  README).

## [0.5.0] - 2026-10-19

### Changed

- **`FinishReason`, `ChatEvent`, `ResponseStatus`, `ResponseEvent` and every
  enum in `gaato/openai/gen` are `#non_exhaustive`.** A value the API adds
  can then become a constructor in a patch release, including the
  regenerations made when the vendored spec changes. Until this module
  maps such a value, it still arrives as `Unknown(..)` or `Other(..)` with
  its wire value, as it did before. Migration: a `match` on one of these
  types ends with `TypeName::.. => …` after the existing constructors.

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
