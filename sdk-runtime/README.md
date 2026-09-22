# gaato/sdk-runtime

API-agnostic client runtime for MoonBit SDKs, built on `gaato/http`: an error taxonomy (`SdkError`), `Retry-After` / `retry-after-ms` parsing, backoff and retry policy, a `Client` that resolves URLs, applies default headers and auth, runs a rate limiter and middleware, classifies responses and retries; a window rate limiter, a paginator, tri-state JSON fields (`Presence`), open enums and a multipart writer (`gaato/sdk-runtime/json`, `gaato/sdk-runtime/multipart`). No async runtime dependency: time comes through the `Clock` trait.

Unofficial and experimental. Source, issues and design notes: https://github.com/gaato/mbt-sdk
