///|
/// An Anthropic API client backed by the transport-independent SDK runtime.
///
/// Request and response shapes come from the generated `gen` package, which is
/// produced from the vendored first-party OpenAPI document; this facade adds a
/// small stable vocabulary on top of it.
pub struct Anthropic {
  priv client : @runtime.Client
  priv version : String
}

///|
/// Redacted debug representation of an Anthropic client.
pub extend Anthropic with @debug.Debug::{to_repr}

///|
/// Formats a client without exposing authentication or other runtime internals.
pub impl @debug.Debug for Anthropic with fn to_repr(_self) {
  @debug.Repr::ctor("Anthropic", [
    (None, @debug.Repr::literal("<credentials redacted>")),
  ])
}

///|
/// Creates an Anthropic client with the selected authentication header.
///
/// `base_url` is the server root: generated paths already start with `/v1`,
/// so an Anthropic-compatible gateway is addressed by its root as well
/// (for example `https://openrouter.ai/api`).
///
/// `retry` defaults to the official SDK's behaviour (`anthropic-sdk-python`,
/// `_base_client.py`): `RetryPolicy::stainless(cap=NoCap)`, two retries of
/// 408, 409, 429 and every 5xx (529 overloaded included), and of a timeout or
/// network failure, for every method including POST, so a message can be
/// generated twice; `x-should-retry` is obeyed, and any Retry-After is waited
/// out however long, so set `total_timeout_ms` to bound a call. Pass
/// `retry=@runtime.RetryPolicy::conservative()` to retry a POST only on 429
/// and on failures that prove nothing was sent.
///
/// With a `timer` (such as `gaato/http-async`'s `ClockTimer`), each attempt
/// is limited to `timeout_ms` (600 s, the official default) and, when
/// `total_timeout_ms` is given, the whole call, retries and their waits
/// included, to that. Without one this module sets no time limit and only the
/// transport's own timeouts apply.
pub fn Anthropic::new(
  api_key~ : String,
  transport : &@http.Transport,
  clock : &@clock.Clock,
  base_url~ : String = "https://api.anthropic.com",
  version~ : String = "2023-06-01",
  auth_header~ : AuthHeader = XApiKey,
  retry? : @runtime.RetryPolicy,
  timer? : &@sync.Timer,
  timeout_ms~ : Int32 = 600_000,
  total_timeout_ms? : Int32,
) -> Anthropic {
  let auth = match auth_header {
    XApiKey => @runtime.Header("x-api-key", api_key)
    Bearer => @runtime.Bearer(api_key)
  }
  let retry : &@runtime.RetryDecider = match retry {
    Some(policy) => policy
    None => @runtime.RetryPolicy::stainless(cap=NoCap)
  }
  let timeouts = timer.map(timer => {
    @runtime.Timeouts::new(
      timer,
      attempt_ms=timeout_ms,
      total_ms?=total_timeout_ms,
    )
  })
  {
    client: @runtime.Client::new(
      transport,
      clock,
      base_url~,
      auth~,
      retry~,
      timeouts?,
    ),
    version,
  }
}

///|
/// Wraps a preconfigured runtime client for compatible APIs and tests.
pub fn Anthropic::from_client(
  client : @runtime.Client,
  version~ : String = "2023-06-01",
) -> Anthropic {
  { client, version, }
}
