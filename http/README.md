# gaato/http

Sans-IO HTTP vocabulary for MoonBit SDKs: `Request`, `Response`, `Headers`, the `Transport` and `BodyStream` traits, middleware, a `Clock` trait (`gaato/http/clock`), an incremental WHATWG-conformant SSE parser (`gaato/http/sse`), an RFC 6265 cookie jar (`gaato/http/cookie`), and a scripted `FakeTransport` / `FakeClock` for tests (`gaato/http/mock`). No dependencies; runs on wasm-gc, wasm, js and native.

The SSE parser bounds one event at `max_event_bytes` (16 MiB by default): the raw bytes of its `data` lines, of the `event` and `id` lines in effect (the `id` persists into later events, so it counts against each of them until replaced), and of the line being read. A stream that never ends a line, or never sends the blank line that ends an event, fails with `HttpError::Protocol` instead of growing memory without bound. Events completed before the oversized one are still delivered: when they arrive in the same chunk, `SseParser::feed` returns them and the next `feed` (an empty chunk is enough) or `finish` raises; `each_event` dispatches them and then raises without reading further. Pass `max_event_bytes` to `SseParser::new` or `each_event` to change it.

`Url` parses, normalises and resolves URI references by RFC 3986 (non-ASCII hosts are refused; pass the IDNA `xn--` form). `follow_redirects`, or the `redirects` middleware step, follows 301/302/303/307/308 up to `max_redirects` (10 by default), rewriting POST to GET where browsers do, stripping credentials when the origin changes and refusing `https` to `http` unless `allow_downgrade` is set. `follow_redirects_stream` does the same for `send_stream`, closing each redirect body unread. Nothing follows redirects unless you add the step.

`CookieJar` stores the `Set-Cookie` headers of responses and builds the `Cookie` header of later requests, reading the time from a `Clock`. It keeps at most 50 cookies per domain and 3000 in all (both adjustable), evicting expired cookies first and then the least recently used, and ignores a `Set-Cookie` over 4096 bytes. It has no Public Suffix List: it refuses a single-label `Domain` such as `com`, and `CookieJar::new(clock, is_public_suffix=...)` takes a lookup to refuse more. `HttpOnly` cookies are sent and `SameSite` is recorded but not enforced, as in other HTTP clients.

An SDK built on this module never imports an async runtime: the caller passes a `Transport` and a `Clock`, for example from `gaato/http-async`.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk
