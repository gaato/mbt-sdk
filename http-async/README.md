# gaato/http-async

`AsyncTransport` and `AsyncClock`: the `gaato/http` `Transport` and `Clock` over `moonbitlang/async`, for native, JS, and linear-memory Wasm on `moonrun`.

`gaato/http-async/mock` has `VirtualClock`, a `Clock` for async tests whose time moves only when the test advances it: sleeps fire in deadline order, and `settle` lets the tasks under test run until they go idle between timers, so timing-dependent code runs the same way on every run and target.

`with_timeout_opt(clock, milliseconds, f)` is `@async.with_timeout_opt` with the deadline taken from a `Clock`, so code that accepts a clock can have its timeouts driven by `VirtualClock` too.

The Wasm backend uses MoonBit host APIs for sockets and TLS; it is not a
browser or generic WASI transport. When using a `moonrun --policy` file, allow
the destination host and port in `net.connect`. Loopback tests also need local
socket bind permission. Native and Wasm share the HTTP implementation and
connection/protocol error classification; JS uses fetch, which connects,
sends and waits for the head in one call and does not say how it failed, so
its failures before the head are `Network(phase=Unknown)`, never `Connect`.

`AsyncTransport::new` takes `timeout_ms` (30 s) for a whole buffered exchange, or a stream up to its head, and per-phase limits that default to it: `connect_timeout_ms` (DNS, TCP, TLS), `write_timeout_ms`, `read_timeout_ms` (the head, then each body read; it alone bounds a stream's reads) and `pool_timeout_ms`. A `Timeout` names the phase it cut short. `max_connections` and `max_connections_per_origin` cap the connections in use; a request over a cap waits its turn until `pool_timeout_ms`. Without them, the default, requests never wait.

`AsyncTransport` keeps a small keep-alive pool per origin (`max_idle_per_origin`, `idle_max_ms`) and replays a request once on a fresh connection when a reused one fails before the response head, but only for idempotent methods or requests carrying an `Idempotency-Key`. Call `close()` to drop parked connections. On native and Wasm the transport sends `Accept-Encoding: gzip, deflate, br` and decodes the body as it reads it, unless the request sets `Accept-Encoding` itself; a coding it does not know is left on the body. Each `br` body may hold up to 16 MiB of window, and only as much as it has decoded. `max_body_bytes` caps a buffered response body after decoding; a longer body closes the connection and fails with `Protocol`, while `send_stream` leaves the limit to its reader. It is unbounded by default, so set it: `AsyncTransport::new(max_body_bytes=64 * 1024 * 1024)` is ample for API JSON, and the SDKs built on `gaato/sdk-runtime` take the transport from you and cannot set it themselves.

In 0.1.2, a request's `User-Agent` is set when its connection is opened. Connections are reused only for requests with the same `User-Agent`; requests without one retain moonbitlang/async's default.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk
