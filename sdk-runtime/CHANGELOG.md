# Changelog

All notable changes to `gaato/sdk-runtime` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the
version is 0.x, a minor release (0.x → 0.y) may contain breaking changes; a
patch release never does. Every breaking change is listed with a migration
note.

## [Unreleased]

### Fixed

- **`Client` keeps an absolute URL whatever the case of its scheme.** A
  request URL starting `HTTPS://` or `Http://` was taken for a path and
  joined onto the base URL; any absolute `http` or `https` URL with a host
  now goes out as it is, as lower-case ones did. Paths are still joined onto
  the base URL, not resolved by RFC 3986, which would drop a base path such
  as OpenAI's `/v1`. Requires `gaato/http`'s new `Url`.

## [0.3.1] - 2026-10-18

### Fixed

- **An error keeps at most 1 MiB of the response body.** `classify`, and so
  `Client::send`, put the whole buffered body into `Status` and
  `RateLimited`, so an error held anywhere kept a body as large as the
  transport allowed alive with it. They now keep its first 1 MiB, the same
  bound `send_stream` already read an error body to; a shorter body is kept
  as it is, without a copy. `Decode` still carries the successful body it
  failed to decode.
- **A response can hold a `WindowLimiter` bucket for at most an hour.** A
  reset parsed from headers (`rate_limit_headers` reads `x-ratelimit-reset`
  as an absolute instant) was kept as the server sent it, so a reset far in
  the future kept the bucket's state, and made its acquisitions wait,
  practically forever; a 429's `Retry-After` could block a bucket or every
  request for up to 24 days. `release` now pulls both back to one hour after
  the response, the longest window among the APIs served (GitHub's hourly
  quota). `rate_limit_headers` and `retry_after_ms` still return what the
  server sent.

## [0.3.0] - 2026-10-18

### Fixed

- **A bucket wait no longer spins when the reset is far away.** The wait
  until a bucket reset subtracted the clock from the reset time without an
  overflow guard, so a saturated reset with a negative clock wrapped to a
  zero-length sleep and busy-looped.
- **A `GlobalWindow` that cannot limit is ignored.** A non-positive `limit`
  made every acquisition sleep forever, and a non-positive `window_ms`
  reset the window on every admission. `WindowLimiter::new` now drops such
  a window, so it imposes no global limit, as documented on the type.

### Changed

- **Depends on `gaato/http` 0.2.0.** Types from `gaato/http` appear in this
  module's API, so a project using it moves to `gaato/http` 0.2.0 too.
  Migration: update the `gaato/http` import alongside this one.

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
