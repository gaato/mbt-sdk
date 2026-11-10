///|
/// A thin OpenAI client backed by the runtime-free mttp Client.
pub struct OpenAI {
  priv client : @client.Client
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
///
/// `retry` defaults to the official SDK's behaviour (`openai-python`,
/// `_base_client.py`): an SDK-local policy with two
/// retries of 408, 409, 429 and every 5xx, and of a timeout or network
/// failure, for every method including POST, so a generation can run twice;
/// `x-should-retry` is obeyed, and a Retry-After over two minutes is not
/// waited for. Pass `retry=@client.RetryPolicy::conservative()` to retry a
/// POST only on failures that prove nothing was sent, unless explicitly
/// declared replay-safe.
///
/// Each attempt
/// is limited to `timeout_ms` (600 s, the official default) and, when
/// `total_timeout_ms` is given, the whole call, retries included, to that.
/// A total deadline requires a supplied Timer and includes admission, waits
/// and stream callbacks. Backend phase deadlines can finish attempts earlier.
pub fn OpenAI::new(
  api_key~ : String,
  backend : &@http.Backend,
  clock : &@rt.Clock,
  base_url~ : String = "https://api.openai.com/v1",
  organization? : String,
  project? : String,
  retry? : @client.RetryPolicy,
  timer? : &@rt.Timer,
  timeout_ms~ : Int32 = 600_000,
  max_body_bytes? : Int32,
  total_timeout_ms? : Int32,
) -> OpenAI {
  let mut headers = @http.Headers::of([("authorization", "Bearer " + api_key)])
  if organization is Some(value) {
    headers = headers.set("openai-organization", value)
  }
  if project is Some(value) {
    headers = headers.set("openai-project", value)
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
      timer?,
      total_ms?=total_timeout_ms,
    ),
  }
}

///|
/// Wraps a preconfigured runtime client for compatible APIs, Azure, and tests.
pub fn OpenAI::from_client(client : @client.Client) -> OpenAI {
  { client, }
}
