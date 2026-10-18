# gaato/http

Sans-IO HTTP vocabulary for MoonBit SDKs: `Request`, `Response`, `Headers`, the `Transport` and `BodyStream` traits, middleware, a `Clock` trait (`gaato/http/clock`), an incremental WHATWG-conformant SSE parser (`gaato/http/sse`), and a scripted `FakeTransport` / `FakeClock` for tests (`gaato/http/mock`). No dependencies; runs on wasm-gc, wasm, js and native.

The SSE parser bounds one event at `max_event_bytes` (16 MiB by default): the raw bytes of its `data` lines plus the line being read. A server that never ends a line or never sends the blank line that ends an event makes `SseParser::feed`, and so `each_event`, fail with `HttpError::Protocol` instead of growing memory without bound. Pass `max_event_bytes` to `SseParser::new` or `each_event` to change it.

An SDK built on this module never imports an async runtime: the caller passes a `Transport` and a `Clock`, for example from `gaato/http-async`.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk
