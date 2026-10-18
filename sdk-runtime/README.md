# gaato/sdk-runtime

API-agnostic client runtime for MoonBit SDKs, built on `gaato/http`: an error taxonomy (`SdkError`), `Retry-After` / `retry-after-ms` parsing, backoff and retry policy, a `Client` that resolves URLs, applies default headers and auth, runs a rate limiter and middleware, classifies responses and retries (never resending a stream body a transport has read); a window rate limiter, a paginator, tri-state JSON fields (`Presence`), open enums and a multipart writer whose file parts may stream (`gaato/sdk-runtime/json`, `gaato/sdk-runtime/multipart`). No async runtime dependency: time comes through the `Clock` trait.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk

Inject a gate from `gaato/http-async` to serialize each bucket until its response is reported. An optional global window counts non-exempt admissions across buckets; both timing and synchronization remain injected.

```moonbit
let limiter = @runtime.WindowLimiter::new(
  @adapter.AsyncClock::new(),
  @runtime.rate_limit_headers(remaining="x-ratelimit-remaining", reset_after_seconds="x-ratelimit-reset-after"),
  gate=() => @adapter.SemaphoreGate::new(),
  global={ limit: 50, window_ms: 1000 },
)
```
