///|
/// Retry limits, backoff, Retry-After cap, and non-idempotent policy.
pub(all) struct RetryPolicy {
  max_retries : Int
  backoff : Backoff
  max_retry_after_ms : Int
  retry_non_idempotent : Bool
} derive(Eq, Debug)

///|
/// Equality for retry policy values.
pub extend RetryPolicy with Eq::{equal, not_equal}

///|
/// Debug representation of retry policy values.
pub extend RetryPolicy with @debug.Debug::{to_repr}

///|
/// Uses two retries, default backoff, a 60-second server-delay cap, and only
/// retries non-idempotent requests when the failure proves they were not run.
pub fn RetryPolicy::default() -> RetryPolicy {
  {
    max_retries: 2,
    backoff: Backoff::default(),
    max_retry_after_ms: 60000,
    retry_non_idempotent: false,
  }
}

///|
/// Disables retries while retaining the other default settings.
pub fn RetryPolicy::none() -> RetryPolicy {
  { ..RetryPolicy::default(), max_retries: 0, }
}

///|
/// Reports whether the method is idempotent or an idempotency key is present.
pub fn is_idempotent(request : @http.Request) -> Bool {
  if request.headers.contains("idempotency-key") {
    return true
  }
  match request.http_method.to_lower() {
    "get" | "head" | "put" | "delete" | "options" | "trace" => true
    _ => false
  }
}

///|
/// Purely decides whether to retry and, if so, how long to wait.
pub fn RetryPolicy::next_delay_ms(
  self : RetryPolicy,
  error : SdkError,
  request : @http.Request,
  attempt : Int,
  random : Double,
) -> Int? {
  if attempt >= self.max_retries || !error.is_retryable() {
    return None
  }
  let processed_is_known_false = match error {
    RateLimited(..) | Transport(Connect(_)) => true
    _ => false
  }
  if !is_idempotent(request) &&
    !self.retry_non_idempotent &&
    !processed_is_known_false {
    return None
  }
  let server_delay = match error {
    RateLimited(retry_after_ms=Some(ms), ..) => Some(ms)
    Status(headers~, ..) => retry_after_ms(headers)
    _ => None
  }
  match server_delay {
    Some(ms) if ms > self.max_retry_after_ms => None
    Some(ms) => Some(ms)
    None => Some(self.backoff.delay_ms(attempt, random))
  }
}
