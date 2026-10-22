# gaato/http

Sans-IO HTTP vocabulary for [MoonBit](https://www.moonbitlang.com/) SDKs and
clients: `Request`, `Response` and `Headers`, the `Transport` and `BodyStream`
traits, middleware, URL and form encoding, redirects, `Retry-After` and `Link`
parsing, a retry-decision core, a multipart writer, an incremental SSE parser,
a cookie jar, and a scripted fake transport for tests. It does no I/O itself:
code written against it takes a `Transport` and a `Clock` from the caller,
such as the ones in [`gaato/http-async`](https://mooncakes.io/docs/gaato/http-async).
It has no dependencies and runs on wasm-gc, wasm, js and native.

> **Status**: experimental. Minor releases may contain breaking changes; the
> [changelog](https://github.com/gaato/mbt-sdk/blob/main/http/CHANGELOG.md)
> lists each one.

## Install

```sh
moon add gaato/http
```

## Usage

Build a `Request`, send it through whatever `Transport` the caller passed in,
and read the `Response`:

```mbt check
///|
/// Fetches a JSON document, following redirects.
pub async fn fetch_json(transport : &@http.Transport, url : String) -> Json {
  let request = @http.Request::get(url).header("accept", "application/json")
  let response = @http.follow_redirects(request, r => transport.send(r))
  guard response.is_success() else { fail("HTTP \{response.status}") }
  response.json()
}
```

In tests, `@mock.FakeTransport` answers each expected request with a scripted
response and `@mock.FakeClock` moves only when told to.

## Packages

| Package | What it is |
|---|---|
| `gaato/http` | `Request`, `Response`, `Headers`, `Url`, the `Transport` and `BodyStream` traits, middleware (`send_with`), redirects, URL and form encoding, `Retry-After` and `Link` parsing, `HttpError` |
| `gaato/http/clock` | The `Clock` trait: the current time and sleeping |
| `gaato/http/sync` | `Gate` and `Timer` traits an async runtime implements, so sans-IO code can hold a slot or bound a wait |
| `gaato/http/retry` | `RetryRule::decide`: whether and when to retry a failed attempt, with the policy as data |
| `gaato/http/random` | Host randomness for jitter and multipart boundaries |
| `gaato/http/multipart` | A `multipart/form-data` writer whose file parts may stream |
| `gaato/http/sse` | An incremental WHATWG server-sent events parser |
| `gaato/http/cookie` | An RFC 6265bis cookie jar and its middleware step |
| `gaato/http/mock` | `FakeTransport` and `FakeClock` for tests |

## Transports and bodies

A `Transport` has two calls: `send` reads the whole response body into
`Response::body`, and `send_stream` returns the head and a `BodyStream` to
read as the body arrives. A request body is bytes (`body_bytes`, `body_text`,
`json_body`, `form_body`) or a stream (`body_stream`), which can be sent only
once.

`send_with(transport, steps, request)` runs a request through middleware
steps, such as `redirects()` and `@cookie.cookies(jar)`, before the transport.

## Errors

`HttpError` separates a failed connection (`Connect`: nothing was sent) from a
`Timeout` or `Network` failure in a later `Phase` (`Pool`, `Dial`, `Write`,
`Head`, `Body` or `Unknown`) and a malformed message (`Protocol`).
`HttpError::is_unsent` says whether a non-idempotent request may safely be
sent again.

## URLs and redirects

`Url` parses, normalises and resolves URI references by RFC 3986. Non-ASCII
hosts are refused; pass the IDNA `xn--` form.

`follow_redirects`, or the `redirects` middleware step, follows 301, 302, 303,
307 and 308 up to `max_redirects` (10 by default). It rewrites POST to GET
where browsers do, strips credentials when the origin changes, and refuses
`https` to `http` unless `allow_downgrade` is set. `follow_redirects_stream`
does the same for `send_stream`, closing each redirect body unread. A redirect
that would resend a stream body already sent is refused.

No transport follows redirects unless you add the step, except
`AsyncTransport` on JS, where fetch follows them itself.

## Server-sent events

`SseParser` takes the body in chunks of any size and returns the events each
chunk completes; `@sse.each_event` reads a `BodyStream` and calls a handler
for each event.

```mbt check
///|
test "parse server-sent events" {
  let parser = @sse.SseParser::new()
  let events = parser.feed(b"event: greeting\ndata: hello\n\n")
  assert_eq(events.length(), 1)
  assert_eq(events[0].event, "greeting")
  assert_eq(events[0].data, "hello")
}
```

One event is bounded by `max_event_bytes` (16 MiB by default; pass it to
`SseParser::new` or `each_event` to change it). The bound counts the event's
`data` lines, the `event` and `id` in effect, and the line being read. A stream
that exceeds it, for example by never ending a line, fails with
`HttpError::Protocol` instead of growing memory. Events completed before the
oversized one are still delivered first.

## Cookies

`CookieJar` stores the `Set-Cookie` headers of responses and builds the
`Cookie` header of later requests, reading the time from a `Clock`. Put the
`@cookie.cookies(jar)` step after `redirects` in the `send_with` array so that
every redirect hop stores and sends its own cookies.

- It keeps at most 50 cookies per domain and 3000 in all (`max_per_domain`,
  `max_total`), evicting expired cookies first and then the least recently
  used.
- It ignores a cookie whose name and value take more than 4096 bytes.
- It has no Public Suffix List: it refuses a single-label `Domain` such as
  `com`, and `is_public_suffix` takes a lookup to refuse more.
- `HttpOnly` cookies are sent, and `SameSite` is recorded but not enforced, as
  in other HTTP clients.

## Retries

`RetryRule::decide` turns one failed attempt, a response status or an
`HttpError`, into `Wait(ms)` or `Stop(reason)`. A rule says which statuses and
failures are retryable and for which methods, which override header to obey
(such as `x-should-retry`), how to read and cap `Retry-After`, and the
exponential backoff with no, full or proportional jitter. It decides only: the
caller sleeps, sends, and supplies the random number, the clock reading and
the remaining time budget. Rules carry no vendor defaults; presets live in
[`gaato/sdk-runtime`](https://mooncakes.io/docs/gaato/sdk-runtime).

## Links

- [Changelog](https://github.com/gaato/mbt-sdk/blob/main/http/CHANGELOG.md)
- [Repository](https://github.com/gaato/mbt-sdk)
- [Transport and parser contract](https://github.com/gaato/mbt-sdk/blob/main/CONTRACT.md):
  what transports, body streams and the incremental parsers guarantee
- [Specifications followed](https://github.com/gaato/mbt-sdk/blob/main/SPECIFICATIONS.md),
  with their errata and known deviations

## License

Apache-2.0
