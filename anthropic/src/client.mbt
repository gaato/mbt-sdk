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
/// `_base_client.py`): an SDK-local policy with two retries of
/// 408, 409, 429 and every 5xx (529 overloaded included), and of a timeout or
/// network failure, for every method including POST, so a message can be
/// generated twice; `x-should-retry` is obeyed, and any Retry-After is waited
/// out however long, so set `total_timeout_ms` to bound a call. Pass
/// `retry=@client.RetryPolicy::conservative()` to retry a POST only on failures
/// that prove nothing was sent, unless explicitly declared replay-safe.
///
/// With a `timer` (such as `@mttp_async.timer()`), each attempt
/// is limited to `timeout_ms` (600 s, the official default) and, when
/// `total_timeout_ms` is given, the whole call, retries and their waits
/// included, to that. A total deadline requires Timer and also covers admission
/// and stream callbacks. Backend phase deadlines can finish attempts earlier.
///
/// Redirects are followed as mttp's `Client` does by default, except that
/// `x-api-key` is removed along with `authorization`, `proxy-authorization`
/// and `cookie` when a redirect leaves the origin, so the API key is sent
/// only to the origin it was given for.
pub fn Anthropic::new(
  api_key~ : String,
  backend : &@http.Backend,
  clock : &@rt.Clock,
  base_url~ : String = "https://api.anthropic.com",
  version~ : String = "2026-10-21",
  auth_header~ : AuthHeader = XApiKey,
  retry? : @client.RetryPolicy,
  timer? : &@rt.Timer,
  timeout_ms~ : Int32 = 600_000,
  max_body_bytes? : Int32,
  total_timeout_ms? : Int32,
) -> Anthropic {
  let headers = match auth_header {
    XApiKey => @http.Headers::of([("x-api-key", api_key)])
    Bearer => @http.Headers::of([("authorization", "Bearer " + api_key)])
  }
  let retry : @client.RetryPolicy = match retry {
    Some(policy) => policy
    None => default_retry()
  }
  {
    client: @client.Client::new(
      backend,
      clock,
      base_url~,
      headers~,
      timeout_ms~,
      read_idle_ms=timeout_ms,
      max_body_bytes?,
      retry~,
      redirect=redirect_config(),
      timer?,
      total_ms?=total_timeout_ms,
    ),
    version,
  }
}

///|
/// mttp's default redirect handling plus `x-api-key`, the default credential
/// header, among the headers removed on an origin change. Built from the
/// default so that headers mttp adds later stay removed too.
fn redirect_config() -> @client.RedirectConfig {
  let default = @client.RedirectConfig::default()
  let credential_headers = default.credential_headers.copy()
  credential_headers.push("x-api-key")
  { ..default, credential_headers, }
}

///|
/// Wraps a preconfigured runtime client for compatible APIs and tests.
///
/// The client's own redirect configuration applies: mttp's default forwards
/// `x-api-key` across origins, so add it to `credential_headers` when the
/// client carries one.
pub fn Anthropic::from_client(
  client : @client.Client,
  version~ : String = "2026-10-21",
) -> Anthropic {
  { client, version, }
}
