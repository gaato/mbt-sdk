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
pub fn Anthropic::new(
  api_key~ : String,
  transport : &@http.Transport,
  clock : &@clock.Clock,
  base_url? : String = "https://api.anthropic.com",
  version? : String = "2023-06-01",
  auth_header? : AuthHeader = XApiKey,
  retry? : @runtime.RetryPolicy,
) -> Anthropic {
  let auth = match auth_header {
    XApiKey => @runtime.Header("x-api-key", api_key)
    Bearer => @runtime.Bearer(api_key)
  }
  let retry : &@runtime.RetryDecider? = retry.map(policy => policy)
  {
    client: @runtime.Client::new(transport, clock, base_url~, auth~, retry?),
    version,
  }
}

///|
/// Wraps a preconfigured runtime client for compatible APIs and tests.
pub fn Anthropic::from_client(
  client : @runtime.Client,
  version? : String = "2023-06-01",
) -> Anthropic {
  { client, version, }
}
