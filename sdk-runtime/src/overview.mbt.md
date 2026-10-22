# gaato/sdk-runtime

An API-agnostic client runtime for [MoonBit](https://www.moonbitlang.com/)
SDKs, built on [`gaato/http`](https://mooncakes.io/docs/gaato/http). Its
`Client` resolves URLs against a base URL, applies default headers and auth,
runs a rate limiter and middleware, classifies responses into an error
taxonomy (`SdkError`), and retries by a policy, with optional per-attempt and
per-call time limits. It also has a window rate limiter, a paginator, and JSON
helpers for tri-state fields and open enums. It is for writing an SDK; the
API clients [`gaato/openai`](https://mooncakes.io/docs/gaato/openai),
[`gaato/anthropic`](https://mooncakes.io/docs/gaato/anthropic) and
[`gaato/github`](https://mooncakes.io/docs/gaato/github) are built on it.

It has no async runtime dependency: the caller passes a `Transport` and a
`Clock`, for example from
[`gaato/http-async`](https://mooncakes.io/docs/gaato/http-async).

> **Status**: experimental. Minor releases may contain breaking changes; the
> [changelog](https://github.com/gaato/mbt-sdk/blob/main/sdk-runtime/CHANGELOG.md)
> lists each one.

## Install

```sh
moon add gaato/http
moon add gaato/sdk-runtime
```

The module name contains a hyphen, so give the package an alias in
`moon.pkg`, as in `"gaato/sdk-runtime" @runtime`; the examples here use that
alias.

## Usage

```mbt check
///|
/// Reads one item from a JSON API with a bearer token.
pub async fn get_item(
  transport : &@http.Transport,
  clock : &@clock.Clock,
  token~ : String,
  id : String,
) -> Json raise @runtime.SdkError {
  let client = @runtime.Client::new(
    transport,
    clock,
    base_url="https://api.example.com/v1",
    auth=Bearer(token),
  )
  client.send_json(
    @http.Request::get("/items/\{@http.percent_encode_path(id)}"),
  )
}
```

A request URL that is not absolute is appended to `base_url`. `send` returns
the response, `send_json` its decoded body, and `send_stream` the head and a
body stream.

## Packages

| Package | What it is |
|---|---|
| `gaato/sdk-runtime` | `Client`, `SdkError`, `RetryPolicy`, `Timeouts`, `WindowLimiter`, `Paginator`, `Auth`, and the retry rule types of `gaato/http/retry` |
| `gaato/sdk-runtime/json` | Tri-state fields (`Presence`), open enums, and field readers and builders for generated JSON codecs |

## Errors

Every call raises `SdkError`:

- `Transport(HttpError)`: the request failed in the transport.
- `Status(status~, headers~, body~)`: the server answered with an error status.
- `RateLimited(retry_after_ms~, headers~, body~)`: the server refused with a
  rate limit.
- `Decode(message~, body~)`: a successful body did not decode.
- `Config(String)`: the client was configured wrongly.

An error body kept in an `SdkError` is cut to its first 1 MiB.
`SdkError::is_retryable` and `SdkError::status` help callers that handle
errors themselves.

## Retries

`retry` takes a policy; `RetryPolicy` offers presets over `gaato/http/retry`
rules:

- `conservative()`, the default: two retries; 429 for any method; 408, 409,
  500, 502, 503 and 504, and a timeout or network failure after sending, only
  for an idempotent request; a failure that proves nothing was sent for any
  method. A server asking to wait more than 60 s is not retried.
- `stainless(cap~)`: the behaviour of the official OpenAI and Anthropic SDKs,
  which retry 408, 409, 429, every 5xx and transport failures for any method,
  `POST` included.
- `none()`: no retries.

Adjust one with `with_max_retries` or `allow_non_idempotent`, or start from
any rule with `from_rule`. A request whose stream body a transport has read is
never sent again, whatever the policy says.

## Timeouts

Without an async runtime the client cannot stop an exchange by itself. Pass
`timeouts=@runtime.Timeouts::new(timer, attempt_ms=..., total_ms=...)` with a
`gaato/http/sync` `Timer`, such as `ClockTimer` from `gaato/http-async`:
`attempt_ms` limits each attempt and `total_ms` the whole call, retries and
their waits included. Without it, only the transport's own timeouts apply.

## Rate limits

`WindowLimiter` paces each bucket against the rate-limit headers that
`rate_limit_headers` reads. Pass a gate, such as `SemaphoreGate` from
`gaato/http-async`, to serialise each bucket until its response is reported;
an optional global window counts admissions across buckets.

```mbt check
///|
/// A limiter for an API that reports its window in two headers and allows
/// 50 requests a second in all.
pub fn api_limiter(
  clock : &@clock.Clock,
  gate : () -> &@sync.Gate,
) -> @runtime.WindowLimiter {
  @runtime.WindowLimiter::new(
    clock,
    @runtime.rate_limit_headers(
      remaining="x-ratelimit-remaining",
      reset_after_seconds="x-ratelimit-reset-after",
    ),
    gate~,
    global={ limit: 50, window_ms: 1000, },
  )
}
```

Pass it to `Client::new` as `limiter`.

## Pagination

`Paginator` walks pages with `each`, `next_page` and `collect(max=...)`.
Build one from a function that returns the next page (`Paginator::new`) or
from one that takes a cursor (`Paginator::with_cursor`).

## Links

- [Changelog](https://github.com/gaato/mbt-sdk/blob/main/sdk-runtime/CHANGELOG.md)
- [Repository](https://github.com/gaato/mbt-sdk)
- [Adding an SDK](https://github.com/gaato/mbt-sdk/blob/main/docs/new-sdk.md)

## License

Apache-2.0
