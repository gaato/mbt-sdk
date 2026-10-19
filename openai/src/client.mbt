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
///
/// `retry` defaults to the official SDK's behaviour (`openai-python`,
/// `_base_client.py`): `RetryPolicy::stainless(cap=StopAbove(120000))`, two
/// retries of 408, 409, 429 and every 5xx, and of a timeout or network
/// failure, for every method including POST, so a generation can run twice;
/// `x-should-retry` is obeyed, and a Retry-After over two minutes is not
/// waited for. Pass `retry=@runtime.RetryPolicy::conservative()` to retry a
/// POST only on 429 and on failures that prove nothing was sent.
///
/// With a `timer` (such as `gaato/http-async`'s `ClockTimer`), each attempt
/// is limited to `timeout_ms` (600 s, the official default) and, when
/// `total_timeout_ms` is given, the whole call, retries included, to that.
/// Without one this module sets no time limit and only the transport's own
/// timeouts apply.
pub fn OpenAI::new(
  api_key~ : String,
  transport : &@http.Transport,
  clock : &@clock.Clock,
  base_url~ : String = "https://api.openai.com/v1",
  organization? : String,
  project? : String,
  retry? : @runtime.RetryPolicy,
  timer? : &@sync.Timer,
  timeout_ms~ : Int32 = 600_000,
  total_timeout_ms? : Int32,
) -> OpenAI {
  let headers = @http.Headers::new()
  if organization is Some(value) {
    headers.set("openai-organization", value)
  }
  if project is Some(value) {
    headers.set("openai-project", value)
  }
  let retry : &@runtime.RetryDecider = match retry {
    Some(policy) => policy
    None => @runtime.RetryPolicy::stainless(cap=StopAbove(120000))
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
      default_headers=headers,
      auth=@runtime.Bearer(api_key),
      retry~,
      timeouts?,
    ),
  }
}

///|
/// Wraps a preconfigured runtime client for compatible APIs, Azure, and tests.
pub fn OpenAI::from_client(client : @runtime.Client) -> OpenAI {
  { client, }
}
