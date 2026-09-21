///|
/// A thin OpenAI client backed by the transport-independent SDK runtime.
pub struct OpenAI {
  priv client : @runtime.Client
}

///|
/// Redacted debug representation of an OpenAI client.
pub extend OpenAI with @debug.Debug::{to_repr}

///|
/// Formats a client without exposing authentication or other runtime internals.
pub impl @debug.Debug for OpenAI with fn to_repr(_self) {
  @debug.Repr::ctor("OpenAI", [
    (None, @debug.Repr::literal("<credentials redacted>")),
  ])
}

///|
/// Creates an OpenAI client using bearer authentication and optional tenant headers.
pub fn OpenAI::new(
  api_key~ : String,
  transport : &@http.Transport,
  clock : &@clock.Clock,
  base_url? : String = "https://api.openai.com/v1",
  organization? : String,
  project? : String,
  retry? : @runtime.RetryPolicy,
) -> OpenAI {
  let headers = @http.Headers::new()
  if organization is Some(value) {
    headers.set("openai-organization", value)
  }
  if project is Some(value) {
    headers.set("openai-project", value)
  }
  {
    client: @runtime.Client::new(
      transport,
      clock,
      base_url~,
      default_headers=headers,
      auth=@runtime.Bearer(api_key),
      retry?,
    ),
  }
}

///|
/// Wraps a preconfigured runtime client for compatible APIs, Azure, and tests.
pub fn OpenAI::from_client(client : @runtime.Client) -> OpenAI {
  { client, }
}
