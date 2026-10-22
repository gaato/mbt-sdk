# gaato/http-async

The [`gaato/http`](https://mooncakes.io/docs/gaato/http) `Transport` and
`Clock` over [`moonbitlang/async`](https://mooncakes.io/docs/moonbitlang/async),
for native, JS, and linear-memory Wasm run by `moonrun`. `AsyncTransport`
sends requests with a keep-alive pool, per-phase timeouts, content decoding
and proxy support; `AsyncClock`, `ClockTimer` and `SemaphoreGate` give
sans-IO SDKs such as [`gaato/openai`](https://mooncakes.io/docs/gaato/openai)
their time, deadlines and serialisation. `gaato/http-async/mock` has a virtual
clock for deterministic async tests.

> **Status**: experimental. Minor releases may contain breaking changes; the
> [changelog](https://github.com/gaato/mbt-sdk/blob/main/http-async/CHANGELOG.md)
> lists each one.

## Install

```sh
moon add gaato/http
moon add gaato/http-async
moon add moonbitlang/async
```

The module name contains a hyphen, so give the package an alias in
`moon.pkg`, as in `"gaato/http-async" @http_async`; the examples here use that
alias.

## Usage

```mbt check
///|
/// Fetches a page as text.
pub async fn fetch_text(url : String) -> String {
  let transport = @http_async.AsyncTransport::new(
    timeout_ms=30_000,
    max_body_bytes=64 * 1024 * 1024,
  )
  defer transport.close()
  let response = transport.send(@http.Request::get(url))
  guard response.is_success() else { fail("HTTP \{response.status}") }
  response.text()
}
```

Set `max_body_bytes`: it caps a buffered response body after decoding, and it
is unbounded by default. A longer body closes the connection and fails with
`HttpError::Protocol`; `send_stream` leaves the limit to its reader. 64 MiB is
ample for API JSON. SDKs built on
[`gaato/sdk-runtime`](https://mooncakes.io/docs/gaato/sdk-runtime) take the
transport from you and cannot set it themselves.

## Packages

| Package | What it is |
|---|---|
| `gaato/http-async` | `AsyncTransport`, `AsyncClock`, `ClockTimer`, `SemaphoreGate`, `DeadlineTransport`, `with_timeout_opt` |
| `gaato/http-async/mock` | `VirtualClock`, a `Clock` whose time moves only when a test advances it |

## Targets

Native and Wasm share one HTTP implementation and the same error
classification. The Wasm backend uses `moonrun`'s host APIs for sockets and
TLS; it is not a browser or generic WASI transport. With a `moonrun --policy`
file, allow the destination host and port in `net.connect`.

JS uses fetch, which connects, sends and waits for the head in one call and
does not say how it failed, so failures before the head are
`Network(phase=Unknown)`, never `Connect`. Fetch also follows redirects and
the platform's proxy settings itself.

## Timeouts

`AsyncTransport::new` takes `timeout_ms` (30 s by default) for a whole
buffered exchange, or a stream up to its head, and per-phase limits that
default to it:

- `connect_timeout_ms`: DNS, TCP and TLS.
- `write_timeout_ms`: each write of the request body.
- `read_timeout_ms`: the head, then each body read; it alone bounds a stream's
  reads.
- `pool_timeout_ms`: waiting for a connection under a cap.

A `Timeout` error names the phase it cut short.

`ClockTimer` bounds a wait with a `Clock`, which is how an SDK limits an
attempt or a whole call. `with_timeout_opt(clock, milliseconds, f)` is
`@async.with_timeout_opt` with the deadline taken from a `Clock`, so code that
accepts a clock can have its timeouts driven by `VirtualClock` in tests.

## Connections

`max_connections` and `max_connections_per_origin` cap the connections in
use; a request over a cap waits its turn until `pool_timeout_ms`. Without
them, the default, requests never wait.

`AsyncTransport` keeps a small keep-alive pool per origin
(`max_idle_per_origin`, `idle_max_ms`); call `close()` to drop the parked
connections. When a reused connection fails before the response head, the
request is sent once more on a fresh connection, but only for an idempotent
method or a request carrying an `Idempotency-Key`, and never with a stream
body already read.

A request's `User-Agent` is set when its connection is opened, so connections
are reused only for requests with the same `User-Agent`. A request without one
gets moonbitlang/async's default.

`SemaphoreGate` is a `gaato/http/sync` `Gate`: pass it to an SDK's rate
limiter to serialise requests.

## Request bodies

A body in memory, or a stream body declared with a length
(`Request::body_stream(stream, length=...)`), is sent with `Content-Length`; a
stream without one is sent chunked, read as it is written. On JS, the body is
handed to fetch whole, so a stream body is read into memory first, and one
over 16 MiB fails with `Protocol` before anything is sent.

## Response bodies

On native and Wasm the transport sends
`Accept-Encoding: gzip, deflate, br, zstd` and decodes the body as it reads
it, unless the request sets `Accept-Encoding` itself; a coding it does not
know is left on the body. A `zstd` frame that needs a larger window than
RFC 9659 allows fails with `Protocol`.

## Proxies

On native and Wasm, `AsyncTransport::new(proxy="http://user:pass@proxy:3128")`
sends every request through an HTTP proxy (`https://` proxies too): `http://`
requests are forwarded and `https://` ones tunnelled with `CONNECT`. Without
`proxy`, `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` are read when
the transport is made, as curl reads them; `trust_env=false` turns that off. A
refused tunnel raises `HttpError::Proxy` with the proxy's status. On JS, a
transport given `proxy` refuses its requests.

## Testing with virtual time

`@mock.VirtualClock` is a `Clock` for async tests. Sleeps fire in deadline
order as the test calls `advance` or `advance_to_next`, and `settle` lets the
tasks under test run until they go idle between timers, so timing-dependent
code runs the same way on every run and target. `settle` raises
`NoQuiescence` when the tasks never go idle, such as a retry loop that never
waits.

## Known limitations

An IPv6 literal host (`http://[::1]:8080/`, as an origin or a proxy) cannot be
dialled: moonbitlang/async passes the bracketed address to name resolution,
which fails with `Connect`. Use a host name instead.

## Links

- [Changelog](https://github.com/gaato/mbt-sdk/blob/main/http-async/CHANGELOG.md)
- [Repository](https://github.com/gaato/mbt-sdk)
- [Transport contract](https://github.com/gaato/mbt-sdk/blob/main/CONTRACT.md):
  what transports and body streams guarantee

## License

Apache-2.0
