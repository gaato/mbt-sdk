# Changelog

All notable changes to `gaato/http-async` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the
version is 0.x, a minor release (0.x → 0.y) may contain breaking changes; a
patch release never does. Every breaking change is listed with a migration
note.

## [Unreleased]

### Fixed

- **A read takes at most 64 KiB from the connection.** Stream reads and
  the reads of a body bounded by `max_body_bytes` asked for whatever the
  connection had buffered, so a stream chunk, and the bytes read past
  `max_body_bytes` before the body was refused, were bounded only by that
  buffer.

## [0.2.0] - 2026-10-18

### Added

- **`with_timeout_opt(clock, milliseconds, f)` runs `f` under a deadline on
  any `Clock`.** It is `@async.with_timeout_opt` with the clock as an
  argument, so code that takes a clock can be driven by `VirtualClock` in
  tests.

### Fixed

- **`Connection: close` is matched as a token.** A response whose
  `Connection` header merely contained the letters `close` (such as
  `closed-ish` or `keep-alive, x-close`) was treated as closing, so its
  connection was never reused.
- **Expired keep-alive connections are closed for every origin.** A parked
  connection that outlived `idle_max_ms` was closed only when the same
  origin was requested again, so an origin never requested again kept its
  socket until `close()`; expired connections also counted toward
  `max_idle_per_origin`, which could close a fresh connection while stale
  ones stayed parked. Every request now closes the expired connections of
  all origins first. No timer runs, so an idle transport still holds them
  until its next request or `close()`.

### Changed

- **Depends on `gaato/http` 0.2.0.** Types from `gaato/http` appear in this
  module's API, so a project using it moves to `gaato/http` 0.2.0 too.
  Migration: update the `gaato/http` import alongside this one.

## [0.1.6] - 2026-10-18

### Added

- **`AsyncTransport::new(max_body_bytes?)` bounds a buffered response
  body.** A longer body closes the connection and fails with
  `HttpError::Protocol` without reading further. The default stays
  unbounded, and `send_stream` leaves the limit to its reader.

## [0.1.5] - 2026-10-17

### Added

- **A virtual clock for async tests.** Package `gaato/http-async/mock` adds
  `VirtualClock`, a `Clock` whose time moves only when a test calls
  `advance` or `advance_to_next`. After each timer fires it lets the tasks
  under test settle, so every run sees the same states in the same order;
  tasks that never go idle raise `NoQuiescence` instead of hanging.

## [0.1.4] - 2026-10-16

### Changed

- Depends on `moonbitlang/async` 0.22.5.

## [0.1.3] - 2026-10-15

### Added

- **`SemaphoreGate`**, a `gaato/http/sync` `Gate` with a fixed number of
  permits, for example to serialize one rate-limit bucket in
  `gaato/sdk-runtime`'s `WindowLimiter`.
- **`DeadlineTransport`** puts a deadline on each exchange of any
  `Transport`: the whole buffered exchange, or the response head of a
  stream. Expiry raises `HttpError::Timeout`.

### Changed

- Depends on `gaato/http` 0.1.1.

## [0.1.2] - 2026-09-29

### Changed

- Depends on `moonbitlang/async` 0.22.4.

### Fixed

- **A request's `User-Agent` is sent exactly once.** It is now set when the
  connection is opened, and a pooled connection is reused only for requests
  with the same `User-Agent`; a request without one keeps
  `moonbitlang/async`'s default.

## [0.1.1] - 2026-09-23

### Added

- **Wasm support under moonrun**, sharing the native HTTP implementation and
  its error classification.

## [0.1.0] - 2026-09-22

### Added

- Initial release: `AsyncTransport` and `AsyncClock`, the `gaato/http`
  `Transport` and `Clock` over `moonbitlang/async` for native and js, with a
  keep-alive pool per origin that replays a request once on a fresh
  connection only when it is idempotent or carries an `Idempotency-Key`.
