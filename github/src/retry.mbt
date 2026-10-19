///|
/// GitHub's retry rule: a secondary rate limit is waited out and retried;
/// everything else follows `policy`.
pub(all) struct GitHubRetry {
  policy : @runtime.RetryPolicy
}

///|
/// Exposes the retry decision as a method.
pub extend GitHubRetry with @runtime.RetryDecider::{decide}

///|
/// Retries secondary limits regardless of request idempotency, within the
/// policy's retry count and server-delay cap; everything else is decided by
/// `policy`.
///
/// The secondary-limit wait is `retry-after` when present, else 60 s doubled
/// for each retry already made. A wait over the policy's `retry_after.cap`
/// limit (`StopAbove` or `BackoffAbove`; none for `NoCap`) stops, as does
/// one that would not leave time for another attempt
/// (`RetryContext::remaining_ms`).
pub impl @runtime.RetryDecider for GitHubRetry with fn decide(
  self,
  error,
  context,
) {
  if !is_secondary_rate_limit(error) {
    return self.policy.decide(error, context)
  }
  let attempt = context.attempt
  if attempt >= self.policy.rule.max_retries {
    return Stop(Exhausted)
  }
  let headers = match error {
    @runtime.Status(headers~, ..) | @runtime.RateLimited(headers~, ..) =>
      headers
    _ => return Stop(NotRetryable)
  }
  let cap = match self.policy.rule.retry_after.cap {
    StopAbove(ms) | BackoffAbove(ms) => ms
    _ => 2147483647
  }
  let delay = match @http.retry_after_ms(headers) {
    Some(ms) => ms
    None => {
      let mut ms = 60000
      for _ in 0..<attempt {
        if ms > cap || ms > 1073741823 {
          return Stop(RetryAfterTooLong(ms))
        }
        ms *= 2
      }
      ms
    }
  }
  if delay > cap {
    Stop(RetryAfterTooLong(delay))
  } else if context.remaining_ms is Some(remaining) &&
    delay.to_int64() >= remaining {
    Stop(Budget(delay))
  } else {
    Wait(delay)
  }
}
