# Changelog

All notable changes to `gaato/http` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

### Fixed

- **`max_event_bytes` now counts an SSE event's `event` and `id` lines, not
  only its `data` lines.** Each of the three could reach the bound on its
  own, so one event could keep about three times `max_event_bytes`. The
  `id` persists into later events, as the spec says, so it counts against
  each of them until replaced. Events completed earlier in the same chunk
  are still delivered before the error.
- **`SseEvent.retry` is capped at one hour.** The server picks the `retry:`
  reconnection delay, and the parser passed on anything up to `Int32`
  milliseconds (about 24 days) to a caller that sleeps for it before
  reconnecting. A larger value now reads as 3,600,000. A run of digits too
  long for `Int32` also reads as that cap instead of being ignored, since
  the spec accepts any run of ASCII digits.
- **`each_event` feeds the parser at most 64 KiB at a time.** It passed
  each read to `SseParser::feed` whole and dispatched the events only after
  parsing it, so the events held at once were bounded only by the size of
  one read, which the transport decides. Each slice's events are now
  dispatched before the next slice is parsed.

## [0.2.0] - 2026-10-18

### Changed

- **An SSE event is bounded, 16 MiB by default.** A server that never sent
  a newline or a blank line made `SseParser` buffer without limit, and the
  OpenAI and Anthropic streams go through it. `SseParser::new` and
  `each_event` take `max_event_bytes?` (the raw bytes of one event's `data`
  lines plus the line being read); past it the stream is refused with
  `HttpError::Protocol`. Events completed earlier in the same chunk are
  still delivered and the error comes on the next `feed` or `finish`;
  `each_event` raises it at once. Migration: `SseParser::feed` and
  `SseParser::finish` now raise `@http.HttpError`, so call them from a
  raising context; callers of `each_event` need no change.

## [0.1.2] - 2026-10-16

### Changed

- **`percent_encode` and `percent_encode_path` are built on
  `moonbitlang/core`'s `encoding/percent`.** The output is unchanged; new
  tests pin slashes, sub-delimiters and astral characters.

## [0.1.1] - 2026-10-15

### Added

- **URL helpers shared by the generated SDKs:** `percent_encode` (keeps only
  RFC 3986 unreserved bytes), `percent_encode_path` (also keeps `/`) and
  `append_query`. Before, every generated module carried its own copy.
- **Package `gaato/http/sync` with a `Gate` trait** (`acquire` / `release`),
  so a runtime can serialize work without depending on an async runtime;
  `gaato/http-async` provides `SemaphoreGate`.
- **`FakeTransport::expect_error`** scripts a transport failure for a request.

## [0.1.0] - 2026-09-22

### Added

- Initial release: `Request`, `Response`, `Headers`, the `Transport` and
  `BodyStream` traits and middleware (`send_with`); a `Clock` trait
  (`gaato/http/clock`); an incremental SSE parser (`gaato/http/sse`); and a
  scripted `FakeTransport` and `FakeClock` for tests (`gaato/http/mock`). No
  dependencies; runs on wasm-gc, wasm, js and native.
