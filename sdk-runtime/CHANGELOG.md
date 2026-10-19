# Changelog

All notable changes to `gaato/sdk-runtime` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the
version is 0.x, a minor release (0.x → 0.y) may contain breaking changes; a
patch release never does. Every breaking change is listed with a migration
note.

## [Unreleased]

## [0.7.0] - 2026-10-19

### Added

- **Retry presets: `RetryPolicy::conservative()`, `stainless(cap~)`,
  `none()` and `from_rule(rule)`.** `conservative()` is the default and
  keeps this module's behaviour; `stainless` is the official OpenAI and
  Anthropic SDKs' (`_base_client.py`): 408, 409, 429 and every 5xx for any
  method, transport failures for any method, `x-should-retry`, a backoff of
  500 ms to 8 s shortened by up to 25 %, with `cap` choosing what a long
  Retry-After does (`StopAbove(120000)` as openai-python, `NoCap` as
  anthropic-sdk-python). `with_max_retries(n)` and `allow_non_idempotent()`
  adjust a policy; `SdkError::outcome()` turns an error into the `Outcome`
  a rule reads.
- **`Client::new(timeouts?)` limits each attempt and each call.**
  `Timeouts { timer, attempt_ms, total_ms }` takes a `@sync.Timer` (such as
  `gaato/http-async`'s `ClockTimer`), so this module still needs no async
  runtime. An exchange that runs out fails with
  `Transport(Timeout(phase=Unknown, ..))` and goes to the retry decider like
  any transport failure; `total_ms` also stops a retry whose wait would not
  fit (`StopReason::Budget`) and an attempt that would start too late. The
  rate limiter's `acquire` and `release` are not interrupted, so a limiter
  wait counts against the total but can overrun it.
- **`send` and `send_json` take an `accept` hook.** It sees each 2xx
  response inside the attempt and may raise to reject it, which the retry
  decider then handles like an error status: for APIs that report rate
  limits in a successful body, such as GitHub GraphQL.
- **`WindowLimiter::new(pace?)` spaces a group's admissions: `Pace { group,
  min_interval_ms }`.** The function maps each bucket to a group whose
  admissions start at least `min_interval_ms` apart, for APIs that ask for
  spacing their headers do not report (GitHub: writes and GraphQL 1 s apart,
  search 2 s, notifications 3 s). It must be pure. The `gate` is now one per
  group, so the buckets of a group are serialised together; by default each
  bucket is its own unpaced group, as before.
- **`WindowLimiter::new(server_key?)` records a bucket's state under the key
  its responses name.** Several buckets that the server counts as one window
  (GitHub's `x-ratelimit-resource`, Discord's `X-RateLimit-Bucket`) then
  share their remaining count and reset; `WindowLimiter::state` looks a
  bucket up through its key. The gate and the pace group stay the bucket's
  own, so a key learned mid-request cannot strand a gate slot. Learned keys
  are swept with the states they point at.
- **`WindowLimiter::new(scope?)` decides what a 429 affects:
  `LimitScope::{Bucket, Global, Shared, Ignore}`.** `Bucket` empties the
  bucket until the Retry-After, `Global` blocks every non-exempt request,
  `Shared` keeps only the parsed header state (Discord's
  `X-RateLimit-Scope: shared`), and `Ignore` records no state and sets no
  block (a `server_key` in its headers is still learned). It supersedes
  `global_block`, which stays for existing callers, means `Global` when it
  returns true and `Bucket` otherwise, and is ignored when `scope` is given.

### Changed

- **Depends on `gaato/http` 0.4.1**, for `gaato/http/retry` and
  `@sync.Timer`. Migration: update the `gaato/http` import alongside this
  module.
- **Retry decisions are `gaato/http/retry` rules.** `RetryPolicy` is now
  `{ rule : RetryRule }`, and the rule types (`RetryRule`, `StatusRule`,
  `StatusMatch`, `Methods`, `RetryAfter`, `RetryAfterSource`,
  `RetryAfterCap`, `Backoff`, `Jitter`, `Outcome`, `Decision`, `StopReason`)
  are re-exported here. Migration: replace `{ ..RetryPolicy::default(),
  max_retries: n }` with `RetryPolicy::default().with_max_retries(n)`,
  `retry_non_idempotent: true` with `.allow_non_idempotent()`, and
  `max_retry_after_ms` and `backoff` with a struct update of `rule`
  (`RetryPolicy::from_rule({ ..policy.rule, retry_after: { ..policy.rule.retry_after, cap: StopAbove(ms) } })`).
  A constructor of a re-exported enum is written without the package, as
  `StopAbove(ms)` where the type is known, not `@runtime.StopAbove(ms)`.
- **`RetryDecider` returns a `Decision` from a `RetryContext`.** The trait
  method is `decide(Self, SdkError, RetryContext) -> Decision` instead of
  `next_delay_ms(Self, SdkError, Request, Int, Double) -> Int?`; the
  context carries the bucket, request, attempt, random number, current time,
  the time left under `Timeouts.total_ms` and whether the request can be
  resent. Migration: rename the method, read the old arguments from
  `context.request`, `context.attempt` and `context.random`, and return
  `Wait(ms)` for `Some(ms)` and `Stop(reason)` for `None`;
  `RetryContext::new(request, ..)` builds a context for tests or for asking
  another decider.
- **`Backoff` is `gaato/http/retry`'s: `{ base_ms, max_ms, jitter : Jitter }`.**
  The factor is always 2 and the arithmetic is integer, so the top of the
  default ±20 % range can be 1 ms lower than before (a `random` clamped to
  just under 1 gives 599 ms for the first retry, where it gave 600); other
  default delays are unchanged. `Backoff::default()` is gone. Migration: take the default
  from `RetryPolicy::conservative().rule.backoff`, replace `factor` (only 2
  remains) and write `jitter: Proportional(lo=800, hi=1200)` for
  `jitter: 0.2`.
- **`conservative()` retries a few more failures than the old default, and
  `SdkError::is_retryable` agrees with it.** A proxy's refusal to open a
  tunnel (`Proxy(status~)`) is retried when its status is 408, 409, 429 or
  500, as well as 502, 503 and 504, for any method, because a rule applies
  one status list to responses and proxies alike. A `Status(status=429)`
  built by hand (rather than by `classify`, which makes it `RateLimited`)
  is retried for any method, like `RateLimited`. Migration: none for
  responses that come through `classify`; to keep the narrower proxy set,
  write a rule without those statuses.

### Fixed

- **An HTTP-date `Retry-After` on an error status is honoured.** The retry
  decision now gets the current time, so `Retry-After: <date>` on a 503 or
  any other retryable status waits until then; it used to fall back to the
  backoff. A 429's date was already read when the response was classified.

## [0.6.0] - 2026-10-19

### Changed

- **`Auth` is `#non_exhaustive`.** Another credential scheme can then be
  added without breaking matches in your code. Migration: a `match` on
  `Auth` outside this module ends with `@runtime.Auth::.. => …` after the
  existing constructors.

### Removed

- **The deprecated aliases of the parts that moved to `gaato/http` in
  0.5.0.** `parse_retry_after`, `retry_after_ms`, `parse_link_next`,
  `is_idempotent` and `default_random` are gone from this module, and so is
  the `gaato/sdk-runtime/multipart` package. Migration: import
  `gaato/http/multipart` and `gaato/http/random`, and call the header
  helpers as `@http.<name>`.

## [0.5.0] - 2026-10-19

### Changed

- **The HTTP-generic parts moved down to `gaato/http`, leaving this module
  to what SDKs share.** `parse_retry_after`, `retry_after_ms`,
  `parse_link_next` and `is_idempotent` are in `gaato/http`,
  `default_random` in `gaato/http/random`, and the multipart writer in
  `gaato/http/multipart`. The old names stay for this release as deprecated
  aliases of the new ones, so `Part` and `MultipartError` are the same
  types either way, and go in the next minor. Error constructors cannot be
  aliased, so a pattern such as `@multipart.BoundaryCollision` written
  against `gaato/sdk-runtime/multipart` no longer resolves. Migration:
  import `gaato/http/multipart` instead of `gaato/sdk-runtime/multipart`
  and `gaato/http/random` for `default_random`, and call the header
  helpers as `@http.<name>`.

## [0.4.0] - 2026-10-18

### Changed

- **A proxy's refusal to open a tunnel is retried only for 502, 503 and
  504.** `SdkError::is_retryable` treats `HttpError::Proxy(status~, ..)`
  like a gateway status: a proxy that could not reach the origin may
  succeed next time, while 407 (credentials) or 403 (refused destination)
  will not.
- **Multipart file parts can stream: `Part.body` is an `@http.Body`.** An
  upload no longer has to hold its files in memory. `Part::file_stream(name,
  filename, content_type, stream, length?)` makes a part read from a
  `BodyStream` as the request is sent; `encode_body` and `apply` produce a
  stream body when any part streams, with `Content-Length` only when every
  stream part has a length and chunked otherwise. A body of bytes parts is
  unchanged, byte for byte. Bytes parts are still checked for the boundary
  before anything is sent; a stream part cannot be, so it is scanned as it
  streams and one that contains the delimiter fails the request with
  `HttpError::Protocol` before the colliding bytes go out (with
  `make_boundary`'s 165 random bits this is not expected to happen).
  `encode` and `encode_segments`, which return bytes, raise the new
  `MultipartError::StreamPart(name)` for a stream part. Migration: compare
  `part.body` with `Bytes(b"...")` or read it with `part.body.as_bytes()`,
  write `body: Bytes(...)` in a `Part` literal, and add an arm for
  `StreamPart(_)` where you match `MultipartError` exhaustively.
- **`Client` never resends a stream request body a transport has read.**
  Requires `gaato/http`'s new `Body`. A request built with
  `Request::body_stream` is sent once: after a failure, the client raises
  it instead of asking the retry decider, unless the transport failed
  before reading the stream (as with `Connect`) or `body` rebuilds the body
  for each attempt. A custom `RetryDecider` cannot override this, since a
  resent stream would go out empty or cut short. Migration: the requests
  `Client` hands to the observer, the retry decider and middleware carry a
  `Body`; read `attempt.request.body.as_bytes()` instead of
  `attempt.request.body`.
- **Retries use the phase a transport failure happened in.** Requires
  `gaato/http`'s new `HttpError`. `SdkError::is_retryable` is true for
  `Network` failures, which transports used to report as the
  non-retryable `Protocol` on native; `Protocol` stays non-retryable.
  `RetryPolicy` now retries a non-idempotent request after any failure
  `HttpError::is_unsent` vouches for, which adds timeouts while waiting for
  a connection slot or connecting to `Connect`; a JS fetch failure is no
  longer `Connect`, so a POST is not resent after one that may have reached
  the server. Migration: match `Timeout(..)` instead of `Timeout(_)` in
  `Transport` patterns, and handle `Transport(Network(..))`.

### Fixed

- **`Client` keeps an absolute URL whatever the case of its scheme.** A
  request URL starting `HTTPS://` or `Http://` was taken for a path and
  joined onto the base URL; any absolute `http` or `https` URL with a host
  now goes out as it is, as lower-case ones did. Paths are still joined onto
  the base URL, not resolved by RFC 3986, which would drop a base path such
  as OpenAI's `/v1`. Requires `gaato/http`'s new `Url`.
- **Multipart text fields, names and filenames no longer abort on a lone
  surrogate.** `Part::text`, `Part::json` and the `Content-Disposition`
  parameters encoded with `@utf8.encode`, which aborts the process on an
  unpaired UTF-16 surrogate; it is now written as U+FFFD. Requires
  `gaato/http`'s new `encode_utf8`.

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
