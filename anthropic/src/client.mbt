///|
/// An Anthropic API client backed by the transport-independent SDK runtime.
///
/// Request and response shapes come from the generated `gen` package, which is
/// produced from the vendored first-party OpenAPI document; this facade adds a
/// small stable vocabulary on top of it.
pub struct Anthropic {
  priv client : @client.Client
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
/// `retry=@client.RetryPolicy::conservative()` to retry a POST only on 429
/// and on failures that prove nothing was sent.
///
/// With a `timer` (such as `gaato/mttp-net/runtime`'s `ClockTimer`), each attempt
/// is limited to `timeout_ms` (600 s, the official default) and, when
/// `total_timeout_ms` is given, the whole call, retries and their waits
/// included, to that. Without one the client uses its clock-based fallback;
/// backend phase deadlines can finish an attempt earlier.
pub fn Anthropic::new(
  api_key~ : String,
  backend : &@client.Backend,
  clock : &@clock.Clock,
  base_url~ : String = "https://api.anthropic.com",
  version~ : String = "2023-06-01",
  auth_header~ : AuthHeader = XApiKey,
  retry? : @client.RetryPolicy,
  timer? : &@clock.Timer,
  timeout_ms~ : Int32 = 600_000,
  total_timeout_ms? : Int32,
) -> Anthropic {
  let headers = match auth_header {
    XApiKey => @model.Headers::of([("x-api-key", api_key)])
    Bearer => @model.Headers::of([("authorization", "Bearer " + api_key)])
  }
  let retry : &@client.RetryDecider = match retry {
    Some(policy) => policy
    None => @client.RetryPolicy::stainless(cap=NoCap)
  }
  {
    client: @client.Client::new(
      backend,
      clock,
      base_url~,
      headers~,
      options={
        ..@client.RequestOptions::default(),
        timeout_ms: Some(timeout_ms),
      },
      retry~,
      timer?,
      total_ms?=total_timeout_ms,
    ),
    version,
  }
}

///|
/// Wraps a preconfigured runtime client for compatible APIs and tests.
pub fn Anthropic::from_client(
  client : @client.Client,
  version~ : String = "2023-06-01",
) -> Anthropic {
  { client, version, }
}
