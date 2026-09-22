# gaato/http

Sans-IO HTTP vocabulary for MoonBit SDKs: `Request`, `Response`, `Headers`, the `Transport` and `BodyStream` traits, middleware, a `Clock` trait (`gaato/http/clock`), an incremental WHATWG-conformant SSE parser (`gaato/http/sse`), and a scripted `FakeTransport` / `FakeClock` for tests (`gaato/http/mock`). No dependencies; runs on wasm-gc, wasm, js and native.

An SDK built on this module never imports an async runtime: the caller passes a `Transport` and a `Clock`, for example from `gaato/http-async`.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk
