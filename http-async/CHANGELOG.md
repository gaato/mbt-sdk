# Changelog

All notable changes to `gaato/http-async` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the
version is 0.x, a minor release (0.x → 0.y) may contain breaking changes; a
patch release never does. Every breaking change is listed with a migration
note.

## [Unreleased]

## [0.5.0] - 2026-10-22

### Changed

- **A `*.example.com` entry in `NO_PROXY` bypasses the proxy for
  `example.com` and its subdomains**, as `.example.com` does. The entry
  was skipped, so those hosts went through the proxy; Go reads `*.` this
  way. NO_PROXY handling is now also checked against the NO_PROXY tables of
  Go's `httpproxy` and curl (see NOTICE).
- **Content decoding goes through `gaato/codec_bytes`' `Decode`.** gzip and
  `deflate` bodies are decoded by `gaato/deflate` 0.1.0 instead of
  `moonbit-community/flate`, no longer a direct dependency, and `br` and
  `zstd` bodies by `gaato/brotli` 0.4.1 and `gaato/zstd` 0.3.1. The
  `Protocol` message of a malformed body ends with the decoder's own
  message, which now reads differently for gzip and `deflate` bodies
  (for example "data after the last member" for bytes after a gzip body);
  a `deflate` body of one byte is refused as raw DEFLATE cut short. A gzip
  body's header fields (extra field, name, comment) are skipped whatever
  their size, not held, and its header CRC is checked.
- **A stream's reader gets the output decoded before an error.** When the
  bytes after a body, or a checksum, are found in the same step that
  decoded its last output, `send_stream` hands on that output and raises on
  the next read, as it did when those bytes came in a later chunk. A
  buffered body still fails whole.

## [0.4.2] - 2026-10-19

### Changed

- **Depends on `gaato/http` 0.4.1**, for `@sync.Timer`. Migration: update
  the `gaato/http` import alongside this module.

### Added

- **`ClockTimer`, the `@sync.Timer` of this runtime.** `within(ms, f)` runs
  `f` until it finishes or `ms` pass on the clock it was built with (the
  wall clock by default, a `VirtualClock` in tests), and cancels `f` when
  time runs out. `gaato/sdk-runtime` takes a `Timer` to bound each attempt
  without importing an async runtime, as it takes a `Gate` for admission.

## [0.4.1] - 2026-10-19

### Changed

- **Requires `gaato/http` 0.4.0, whose `Phase` is `#non_exhaustive`.** A
  phase added to `gaato/http` later is reported as a network failure and
  timed with the read limit, as `Unknown` is. The `Phase::..` pattern that
  does this does not compile against an older `gaato/http`.

## [0.4.0] - 2026-10-19

### Added

- **The `zstd` content coding.** On native and Wasm the transport now undoes
  `Content-Encoding: zstd` (RFC 8878) as it undoes `gzip`, `deflate` and
  `br`, with `gaato/zstd`: in bounded slices, with the window capped at
  8 MiB, the limit RFC 9659 sets for the coding (`zstd_window_bits`). A frame
  that needs a larger window, a dictionary, or fails its checksum raises
  `Protocol`, as a malformed body of any coding does.

### Changed

- **`Accept-Encoding` offers `zstd`.** A request without its own
  `Accept-Encoding` is sent with `gzip, deflate, br, zstd`, so servers that
  prefer zstd (several CDNs do) now answer with it. Responses decode the same
  either way; set `Accept-Encoding` on the request to choose the codings
  yourself.
- `gaato/brotli` 0.2.0 (was 0.1.0); the decoder is unchanged.

## [0.3.1] - 2026-10-18

### Added

- **`AsyncTransport::new(clock~)`.** The phase limits and the idle time of parked connections were measured on the wall clock, so a caller that times everything else on an injected clock (a test on a virtual clock, an SDK forwarding its own) could not expire them; the transport already ran on a clock inside, and now takes one, defaulting to `AsyncClock`.

## [0.3.0] - 2026-10-18

### Added

- **HTTP proxies: `AsyncTransport::new(proxy=..., trust_env=...)`.** A
  client behind a corporate or CI proxy could not reach anything. On native
  and Wasm, `proxy` (`http://` or `https://`, with optional
  `user:password@`) carries every request: an `http://` request is
  forwarded to it in absolute form, an `https://` one goes through a
  `CONNECT` tunnel with TLS end to end, as curl, httpx and Mint do. The
  credentials go to the proxy alone, as `Basic` `Proxy-Authorization`; a
  `Proxy-Authorization` header set on a request is dropped, so it can never
  reach an origin through a tunnel or a redirect.
  Without `proxy`, the transport reads `HTTP_PROXY`, `HTTPS_PROXY`,
  `ALL_PROXY` and `NO_PROXY` (lower case first; upper-case `HTTP_PROXY` is
  ignored under CGI, as Go and Python ignore it) once, when it is made,
  unless `trust_env=false`; an explicit `proxy` ignores the environment, as
  httpx's does. `NO_PROXY` takes curl's forms: `*`, a domain with or
  without a leading dot for itself and its subdomains, IPv4 and IPv6
  addresses and `/prefix` networks, and `:port` to restrict an entry. Each
  request is routed by its own URL, so a redirect to another origin is
  routed afresh, and connections are parked and capped per origin and
  proxy. A proxy that cannot be reached fails with `Connect`, a refused
  tunnel with the new `HttpError::Proxy(status~, ..)`, and an unusable proxy
  URL with `Protocol`; none sends the request direct. On JS, fetch uses the
  platform's proxy settings, if any; the environment is not read, and a
  request on a transport given `proxy` fails with `Protocol`. Behaviour
  change: a transport now honours proxy environment variables that were
  ignored before; pass `trust_env=false` to keep connecting directly.
- **Stream request bodies are sent as they are read.** A large upload no
  longer has to sit in memory: `Request::body_stream` bodies are written
  chunk by chunk on native and Wasm, with `Content-Length` when the stream
  was declared with a length and `Transfer-Encoding: chunked` otherwise.
  Every body, in memory or streamed, is written in slices of at most
  64 KiB, each one a `Write` phase: `write_timeout_ms` bounds each slice
  and each read from the stream, as httpx's write timeout bounds a chunk,
  and `timeout_ms` the whole upload. The stream is closed when the request
  is sent or fails. A stale-connection replay never resends a stream it
  already read. On JS, moonbitlang/async's client buffers the body and
  hands it to fetch whole, so a stream body is read into memory first, up
  to 16 MiB; past that the request fails with `Protocol` before anything is
  sent. Streaming it to fetch would need a `ReadableStream` body with
  `duplex: "half"`, which Node supports but Firefox and Safari do not, and
  Chromium only over HTTP/2.
- **Per-phase timeouts: `connect_timeout_ms`, `write_timeout_ms`,
  `read_timeout_ms` and `pool_timeout_ms`.** One `timeout_ms` could not
  give a slow streaming response a long wait for its head while failing
  fast on an unreachable host. Each new limit bounds one phase (dialing
  with DNS, TCP and TLS; sending the request head and each write of at
  most 64 KiB of its body; the head and each body read separately; waiting
  for a connection slot), always within the
  exchange's `timeout_ms`, and the `Timeout` it raises names the phase and
  the limit that ran out. Each defaults to `timeout_ms`, so existing
  callers keep one limit per exchange and per stream read. A stream's
  reads are bounded by `read_timeout_ms` alone, as before by `timeout_ms`.
  Like httpx's `Timeout(connect=, read=, write=, pool=)`, plus the overall
  deadline httpx lacks. All timing goes through the transport's clock.
- **`max_connections` and `max_connections_per_origin` cap the connections
  in use.** A connection is in use from its request's slot until its body
  is read or abandoned; parked ones do not count. A request over a cap
  waits in arrival order (a freed slot goes to the earliest waiter it
  fits, so one origin at its cap does not hold up another) until
  `pool_timeout_ms`, then fails with `Timeout(phase=Pool)`; a waiter that
  gives up or is cancelled leaves the queue and releases only a slot it was
  granted, and `close()` refuses the waiters with `Connect`. Unset, the
  default, requests never wait, as before.

- **Native and Wasm responses in `deflate`, and in chains of codings, are
  decoded.** moonbitlang/async undoes only a single `gzip`, and failed the
  request on any other `Content-Encoding`. The transport now sends
  `Accept-Encoding: gzip, deflate` and undoes both itself, streaming, with
  each decoded read at most 64 KiB and the decoded bytes counted against
  `max_body_bytes`, so a decompression bomb stops there. `deflate` is read
  as zlib or, when its first two bytes are not a zlib header, raw DEFLATE,
  as browsers do. Up to five chained codings are undone, last applied
  first; more fail with `Protocol`. JS is unchanged, since fetch decodes.
- **Native and Wasm responses in Brotli (`br`) are decoded.** The transport
  sends `Accept-Encoding: gzip, deflate, br`, as browsers do, and undoes
  `br` with `gaato/brotli`, a streaming RFC 7932 decoder in MoonBit, under
  the same rules as `gzip` and `deflate`: 64 KiB reads, decoded bytes
  against `max_body_bytes`, chains of up to five codings, and malformed,
  truncated or trailing data failing with `Protocol`. Any window RFC 7932
  allows is accepted, as browsers accept it; a `br` body holds at most
  16 MiB of it, and no more than it has decoded.

### Changed

- **Request bodies are sent with `Content-Length`.** moonbitlang/async
  sends a body without a declared length chunked, and the transport used
  to drop the caller's `Content-Length`, so every non-empty body went out
  chunked, which some servers and signed upload URLs refuse. A body in
  memory now declares its length, as fetch, httpx and browsers do; an empty
  one declares `Content-Length: 0` for POST, PUT and PATCH (RFC 9110 §8.6)
  and nothing otherwise. A `Content-Length` header the caller sets is still
  replaced by the body's own. JS is unchanged, since fetch frames the body.
- **Failures and timeouts name the phase they happened in.** Requires
  `gaato/http`'s new `HttpError`. The transport dials, writes the request,
  waits for the head and reads the body as separate phases, so a timeout is
  `Timeout(phase=Dial | Write | Head | Body, ms=timeout_ms)` for the phase
  the deadline interrupted, and the deadline is still one per buffered
  exchange (up to the head for a stream) and one per stream read. On
  native and Wasm, a reset or an end of stream after connecting is now
  `Network` in its phase instead of `Protocol`; only a message the parser
  refuses stays `Protocol`. A body cut short of its `Content-Length` is
  therefore `Network(phase=Body)`, where httpx says `RemoteProtocolError`:
  the connection ended, which is what a retry policy needs to know. On JS,
  fetch connects, sends and waits for the head in one call and rejects
  every failure alike with a `TypeError`, so those failures are
  `Network(phase=Unknown)` instead of `Connect`, and a timeout there is
  `Timeout(phase=Unknown)`; `Connect` would claim the request was never
  sent, which fetch cannot know. `DeadlineTransport` cannot see the inner
  transport's phase and reports `Timeout(phase=Unknown, ms)`. A stale
  parked connection is replayed only when it fails with `Network`, which
  is how a dropped connection shows; before, any failure before the head
  was replayed. The request is flushed before the head is awaited, so a
  bodiless request now leaves in two writes. Migration: see `gaato/http`'s
  `HttpError` note; code that matched `Protocol` to catch dropped
  connections should match `Network(..)`.
- **A decoded response's headers describe the decoded body, and an unknown
  coding passes through.** The undone codings leave `Content-Encoding` and
  `Content-Length` is dropped; a coding the transport does not know, and any
  applied before it, stays on the body and in the header, as in httpx and
  Go, where moonbitlang/async raised `NotImplemented`. Before, a gzip body
  kept `Content-Encoding: gzip` after decoding. A request that sets
  `Accept-Encoding` itself still gets the body as the server sent it.

### Fixed

- **A connection is not reused after `101 Switching Protocols` or a caller's
  `CONNECT`.** Either turns it into something other than an HTTP connection
  (through a forwarding proxy, a tunnel to the origin), so parking it let
  the next request, and any proxy credentials on it, reach the wrong peer.

## [0.2.1] - 2026-10-18

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
