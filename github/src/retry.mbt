///|
/// GitHub's retry rule: a secondary rate limit is waited out and retried;
/// everything else follows `policy`.
pub(all) struct GitHubRetry {
  policy : @runtime.RetryPolicy
}

///|
/// Exposes the retry decision as a method.
pub extend GitHubRetry with @runtime.RetryDecider::{next_delay_ms}

///|
/// Retries secondary limits regardless of request idempotency, within the
/// policy's retry count and server-delay cap.
pub impl @runtime.RetryDecider for GitHubRetry with fn next_delay_ms(
  self,
  error,
  request,
  attempt,
  random,
) {
  if !is_secondary_rate_limit(error) {
    return self.policy.next_delay_ms(error, request, attempt, random)
  }
  if attempt >= self.policy.max_retries {
    return None
  }
  let headers = match error {
    @runtime.Status(headers~, ..) | @runtime.RateLimited(headers~, ..) =>
      headers
    _ => return None
  }
  let delay = match @runtime.retry_after_ms(headers) {
    Some(ms) => ms
    None => {
      let mut ms = 60000
      for _ in 0..<attempt {
        if ms > self.policy.max_retry_after_ms || ms > 1073741823 {
          return None
        }
        ms *= 2
      }
      ms
    }
  }
  if delay > self.policy.max_retry_after_ms {
    None
  } else {
    Some(delay)
  }
}
