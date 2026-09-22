# gaato/http-async

`AsyncTransport` and `AsyncClock`: the `gaato/http` `Transport` and `Clock` over `moonbitlang/async`, for native, JS, and linear-memory Wasm on `moonrun`.

The Wasm backend uses MoonBit host APIs for sockets and TLS; it is not a
browser or generic WASI transport. When using a `moonrun --policy` file, allow
the destination host and port in `net.connect`. Loopback tests also need local
socket bind permission. Native and Wasm share the HTTP implementation and
connection/protocol error classification; JS uses fetch.

`AsyncTransport` keeps a small keep-alive pool per origin (`max_idle_per_origin`, `idle_max_ms`), never queues concurrent requests, and replays a request once on a fresh connection when a reused one fails before the response head, but only for idempotent methods or requests carrying an `Idempotency-Key`. Call `close()` to drop parked connections.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk
