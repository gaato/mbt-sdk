# gaato/http

Sans-IO HTTP vocabulary for MoonBit SDKs: `Request`, `Response`, `Headers`, the `Transport` and `BodyStream` traits, middleware, a `Clock` trait (`gaato/http/clock`), an incremental WHATWG-conformant SSE parser (`gaato/http/sse`), and a scripted `FakeTransport` / `FakeClock` for tests (`gaato/http/mock`). No dependencies; runs on wasm-gc, wasm, js and native.

The SSE parser bounds one event at `max_event_bytes` (16 MiB by default): the raw bytes of its `data` lines, of the `event` and `id` lines in effect (the `id` persists into later events, so it counts against each of them until replaced), and of the line being read. A stream that never ends a line, or never sends the blank line that ends an event, fails with `HttpError::Protocol` instead of growing memory without bound. Events completed before the oversized one are still delivered: when they arrive in the same chunk, `SseParser::feed` returns them and the next `feed` (an empty chunk is enough) or `finish` raises; `each_event` dispatches them and then raises without reading further. Pass `max_event_bytes` to `SseParser::new` or `each_event` to change it.

`Url` parses, normalises and resolves URI references by RFC 3986 (non-ASCII hosts are refused; pass the IDNA `xn--` form).

An SDK built on this module never imports an async runtime: the caller passes a `Transport` and a `Clock`, for example from `gaato/http-async`.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk
