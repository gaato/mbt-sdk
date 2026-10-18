# Changelog

All notable changes to `gaato/sdk-runtime` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the
version is 0.x, a minor release (0.x → 0.y) may contain breaking changes; a
patch release never does. Every breaking change is listed with a migration
note.

## [Unreleased]

## [0.2.3] - 2026-10-17

### Fixed

- **`WindowLimiter` forgets idle buckets.** A bucket's gate is dropped once
  no task holds or waits on it, and recorded states whose reset has passed
  are swept on `release`. Before, both maps kept one entry for every bucket
  name ever seen.

## [0.2.2] - 2026-10-15

### Added

- **`WindowLimiter::new` takes `gate?`, `global?`, `global_block?` and
  `default_retry_after_ms?`.** `gate` makes a `gaato/http/sync` `Gate` per
  bucket, held from `acquire` to the paired `release`, so a bucket can be
  serialized until its response is reported; `global` (a `GlobalWindow`)
  counts non-exempt admissions across buckets; `global_block` recognizes an
  account-wide 429; `default_retry_after_ms` is the wait for a 429 without
  `Retry-After`.
- **`default_random`** is public, and `@multipart` adds
  `encode_segments_fresh` (draws a fresh boundary, retrying on a collision)
  and `join_segments`.

### Fixed

- **Jitter varies where the host has no randomness source.**
  `default_random` falls back to a seeded xorshift64 generator instead of
  returning 0.5 every time. The fallback is not for security.

## [0.2.1] - 2026-09-25

### Added

- **`Client::send`, `send_json` and `send_stream` take `body?`**, a function
  that builds the request body once per attempt, after the limiter admits
  it, so a request waiting for admission holds no encoded body. A multipart
  upload can keep only the segments from `@multipart.encode_segments`.

## [0.2.0] - 2026-09-24

### Changed

- **`RateLimiter` pairs `acquire` with `release`.** `observe` is replaced by
  `release(bucket, status~, headers~)`, which the client calls exactly once
  for every `acquire` that returned, including after a transport failure or
  a cancellation (status `0`, no headers). `acquire` takes `global_exempt~`
  and may raise, which fails the request before it is sent.
  Migration: rename `observe` to `release`, read the time from your own
  clock, ignore status `0` if you hold no per-request state, and accept
  `global_exempt~` in `acquire`.
- **Retry is pluggable.** `Client::new(retry?)` takes any `&RetryDecider`;
  `RetryPolicy` implements it, so existing policies still work.
- **`Paginator` carries its error type and owns no cursor by default.**
  `Paginator[T]` becomes `Paginator[T, E]`, and `Paginator::new` takes a
  fetch that keeps its own cursor and returns `None` at the end.
  Migration: replace `Paginator::new(fetch)` with
  `Paginator::with_cursor(fetch)` for a string cursor, and name the type
  `Paginator[T, SdkError]`.

### Added

- **`Client::new(observer?)`** is called once per attempt with an
  `Attempt` (bucket, request, attempt number, status, headers, body,
  duration and error), including attempts that fail or are cancelled.
- **`global_exempt?`** on `Client::send`, `send_json` and `send_stream`,
  passed to the limiter.
- **`@multipart.encode_segments`** returns the body as ordered segments,
  each part's bytes uncopied, so a host can stream a large upload.

## [0.1.0] - 2026-09-22

### Added

- Initial release: the `SdkError` taxonomy, `Retry-After` /
  `retry-after-ms` parsing, backoff and `RetryPolicy`; a `Client` that
  resolves URLs, applies default headers and auth, runs a rate limiter and
  middleware, classifies responses and retries; `WindowLimiter`,
  `Paginator`, tri-state JSON fields (`Presence`) and open enums
  (`gaato/sdk-runtime/json`), and a multipart writer
  (`gaato/sdk-runtime/multipart`). Time comes through the `Clock` trait, so
  there is no async runtime dependency.
