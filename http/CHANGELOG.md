# Changelog

All notable changes to `gaato/http` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

### Added

- **`Url`: RFC 3986 URI references with parsing, normalisation and
  resolution.** `Url::parse` splits a reference into scheme, userinfo, host
  (IPv6 literals included), port, path, query and fragment, lower-cases the
  scheme and host, writes IPv6 addresses in RFC 5952's canonical form (so
  equal addresses serialise alike and `same_origin` matches them), drops
  default ports and percent-encodes by the WHATWG
  URL Standard's sets; `Url::resolve` implements RFC 3986 §5.2 and passes all
  42 examples of §5.4. `same_origin`, `port_or_default`, `query_params`,
  `append_query_params` and `merge_query_params` cover what HTTP clients
  need. Non-ASCII hosts are refused: IDNA is out of scope, so pass the
  `xn--` form. The algorithm is ported from moonbitstack/moonhttp's `url`
  package (Apache-2.0).
- **`follow_redirects` and the `redirects` middleware step.** They follow
  301, 302, 303, 307 and 308 up to `max_redirects` (10 by default), rewrite
  the method as browsers and httpx do, drop the body and its headers when
  the request becomes a GET, strip `Authorization`, `Cookie`,
  `Proxy-Authorization` and caller-named credential headers when the origin
  changes (except a same-host upgrade to `https`), and refuse an `https` to
  `http` downgrade unless `allow_downgrade` is set. `follow_redirects`
  raises the new `RedirectError`; `redirects` reports refusals as
  `HttpError::Protocol`, so `HttpError` keeps its variants. `on_redirect`
  sees each hop for callers that keep a history. Nothing follows redirects
  unless a caller adds the step.
- **`follow_redirects_stream` follows redirects for `send_stream`.** Same
  rules and limit as `follow_redirects`; each 3xx body is closed unread
  before the next request, and on every error or cancellation after its
  head arrived, so only the final stream is left open for the caller.
  `on_redirect` receives a `StreamRedirectHop` (request, 3xx head, next
  request).
- **`gaato/http/cookie`: an RFC 6265 cookie jar for HTTP clients.**
  `CookieJar::store` takes a response's `Set-Cookie` headers and the request
  URL; `CookieJar::header_for` builds the `Cookie` header of a request. It
  parses `Set-Cookie` leniently as RFC 6265 §5.2 does (the §5.1.1 date
  algorithm for `Expires`, `Max-Age`, `Domain`, `Path`, `Secure`, `HttpOnly`,
  `SameSite`), applies the §5.3 storage model and sends cookies in §5.4
  order, with the RFC 6265bis rules browsers follow: Secure cookies only from
  https, the `__Secure-` and `__Host-` prefixes, no insecure overwrite of a
  Secure cookie, control characters refused, lifetimes cut to 400 days. Time
  comes from a `@clock.Clock`. The jar keeps at most 50 cookies per domain and
  3000 in all by default, and ignores a `Set-Cookie` over 4096 bytes. There is
  no Public Suffix List: a single-label `Domain` is refused and an IP host
  only gets host-only cookies; pass `is_public_suffix` to refuse more.
- **`@cookie.cookies(jar)`, a middleware step that sends and stores a jar's
  cookies.** Each request gets the jar's `Cookie` header for its URL unless
  it already has one, and each response's `Set-Cookie` headers are stored.
  Placed inside `redirects`, it runs once per hop, so every hop stores its
  cookies and sends its own. `CookieJar::attach` does the sending half on
  its own, for `send_stream` callers, who store from the `ResponseHead`.

## [0.2.1] - 2026-10-18

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
