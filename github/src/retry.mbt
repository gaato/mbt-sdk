///|
/// GitHub's retry rule: the rate limits GitHub documents are waited out as
/// docs.github.com asks, a transient GraphQL failure of a query is retried,
/// and everything else follows `policy`.
///
/// `GitHub::new` wraps its `retry` policy in this, by default
/// `RetryPolicy::conservative().with_max_retries(3)`: three retries, as
/// octokit's `plugin-retry`, but a 5xx or a timeout after sending is retried
/// only for an idempotent request, because GitHub has no idempotency key and a
/// resent POST can open a second issue or comment.
pub(all) struct GitHubRetry {
  policy : @runtime.RetryPolicy
}

///|
/// Exposes the retry decision as a method.
pub extend GitHubRetry with @runtime.RetryDecider::{decide}

///|
/// Decides a retry, recognising three GitHub conditions before handing the
/// error to `policy`; each of them is retried for any method, because the
/// request was rejected rather than processed.
///
/// - **Secondary rate limit** (`is_secondary_rate_limit`: a `403` or `429`
///   with `retry-after` or a message naming the secondary rate limit, which
///   a GraphQL `200` also carries): waits `retry-after` (seconds or an HTTP
///   date), or, when it is absent or not positive, 60 s doubled for each
///   retry already made ("wait for at least one minute", "an exponentially
///   increasing amount of time"). The policy's Retry-After cap does not
///   apply; its retry count and the call's remaining time
///   (`RetryContext::remaining_ms`, stopping with `Budget`) do.
/// - **Primary rate limit** (a `403` or `429` with `x-ratelimit-remaining: 0`,
///   or a GraphQL `RATE_LIMITED` error): waits until one second past
///   `x-ratelimit-reset` ("you should not retry your request until after"
///   it), and only once per call, as octokit does; a second one stops with
///   `Exhausted`. Without a readable reset it stops with `NotRetryable`
///   rather than guess, and the policy's retry count and the remaining time
///   bound it as above.
/// - **Transient GraphQL failure** ("Something went wrong while executing
///   your query", raised as `Decode` by `graphql` for a document that is not
///   a mutation, in the `"graphql"` bucket): waits the policy's backoff, within
///   its retry count and the remaining time. A mutation's (`"graphql:mutation"`)
///   is never retried, since it may have been applied.
///
/// Every other error, including the cases of `policy.rule.retry_after.cap`,
/// is decided by `policy` alone.
///
/// ```mbt check
/// test {
///   let retry : @github.GitHubRetry = {
///     policy: @runtime.RetryPolicy::conservative().with_max_retries(3),
///   }
///   let post = @http.Request::post("/repos/o/r/issues")
///   let limited = @runtime.Status(
///     status=403,
///     headers=@http.Headers::new(),
///     body=b"{\"message\":\"You have exceeded a secondary rate limit.\"}",
///   )
///   let waits = [0, 1, 2, 3].map(attempt => {
///     retry.decide(limited, @runtime.RetryContext::new(post, attempt~))
///   })
///   assert_eq(waits, [Wait(60000), Wait(120000), Wait(240000), Stop(Exhausted)])
/// }
/// ```
pub impl @runtime.RetryDecider for GitHubRetry with fn decide(
  self,
  error,
  context,
) {
  match github_condition(error, context.bucket) {
    Some(Secondary(headers)) => self.secondary_decision(headers, context)
    Some(Primary(headers)) => self.primary_decision(headers, context)
    Some(TransientGraphql) => self.transient_decision(context)
    None => self.policy.decide(error, context)
  }
}

///|
/// A failure GitHub's own rules decide, with the headers its wait is read
/// from.
priv enum GitHubCondition {
  Secondary(@http.Headers)
  Primary(@http.Headers)
  TransientGraphql
}

///|
/// Recognises the conditions `GitHubRetry` decides itself. The secondary limit
/// is checked first: a `403` that names it is not the hourly quota even when
/// that quota is also spent.
fn github_condition(
  error : @runtime.SdkError,
  bucket : String,
) -> GitHubCondition? {
  let (headers, body) = match error {
    @runtime.Status(status=403 | 429, headers~, body~)
    | @runtime.RateLimited(headers~, body~, ..) => (headers, body)
    @runtime.Decode(body~, ..) =>
      return if bucket == graphql_bucket &&
        graphql_reply_has(body, GraphqlTransient) {
        Some(TransientGraphql)
      } else {
        None
      }
    _ => return None
  }
  if is_secondary_rate_limit(error) {
    Some(Secondary(headers))
  } else if headers.get("x-ratelimit-remaining").map(value => value.trim()) ==
    Some("0") ||
    graphql_reply_has(body, GraphqlRateLimited) {
    Some(Primary(headers))
  } else {
    None
  }
}

///|
/// The checks every GitHub-specific retry shares: the policy's retry count
/// and a body that can be sent again.
fn GitHubRetry::refusal(
  self : GitHubRetry,
  context : @runtime.RetryContext,
) -> @runtime.Decision? {
  if context.attempt >= self.policy.rule.max_retries {
    Some(Stop(Exhausted))
  } else if !context.replayable {
    Some(Stop(NotReplayable))
  } else {
    None
  }
}

///|
/// Waits `delay` milliseconds unless that would use up the call's remaining
/// time.
fn within_budget(
  delay : Int32,
  context : @runtime.RetryContext,
) -> @runtime.Decision {
  if context.remaining_ms is Some(remaining) && delay.to_int64() >= remaining {
    Stop(Budget(delay))
  } else {
    Wait(delay)
  }
}

///|
/// The secondary-limit wait: `retry-after` when positive, else 60 s doubled
/// per retry already made, saturating at the longest `Int` wait.
fn GitHubRetry::secondary_decision(
  self : GitHubRetry,
  headers : @http.Headers,
  context : @runtime.RetryContext,
) -> @runtime.Decision {
  if self.refusal(context) is Some(decision) {
    return decision
  }
  let delay = match
    @http.retry_after_ms(headers, now_unix_ms=context.now_unix_ms) {
    Some(ms) if ms > 0 => ms
    _ => {
      let mut ms = 60000L
      for _ in 0..<context.attempt {
        ms = (ms * 2L).min(2147483647L)
      }
      ms.to_int()
    }
  }
  within_budget(delay, context)
}

///|
/// The primary-limit wait: until one second past `x-ratelimit-reset`, rounded
/// up to whole seconds as octokit's `plugin-throttling` does, and only on the
/// first retry.
fn GitHubRetry::primary_decision(
  self : GitHubRetry,
  headers : @http.Headers,
  context : @runtime.RetryContext,
) -> @runtime.Decision {
  if self.refusal(context) is Some(decision) {
    return decision
  }
  if context.attempt > 0 {
    return Stop(Exhausted)
  }
  guard headers.get("x-ratelimit-reset").bind(parse_unix_seconds) is Some(reset) else {
    return Stop(NotRetryable)
  }
  within_budget(primary_wait_ms(reset, context.now_unix_ms), context)
}

///|
/// `max(ceil((reset - now) / 1 s) + 1 s, 0)` in milliseconds, saturating at
/// the longest `Int` wait. `reset` is in Unix seconds, `now` in Unix
/// milliseconds.
fn primary_wait_ms(reset_unix_seconds : Int64, now_unix_ms : Int64) -> Int32 {
  // Bounded by the parser, so neither product overflows.
  let delta_ms = reset_unix_seconds * 1000L - now_unix_ms
  let seconds = if delta_ms > 0L {
    (delta_ms + 999L) / 1000L
  } else {
    // Integer division truncates toward zero, which is the ceiling here.
    delta_ms / 1000L
  }
  let wait = (seconds + 1L).max(0L) * 1000L
  wait.min(2147483647L).to_int()
}

///|
/// Reads a non-negative whole number of Unix seconds, as GitHub writes
/// `x-ratelimit-reset`; `None` for anything else, or a value past year 2⁴⁰.
fn parse_unix_seconds(value : String) -> Int64? {
  let value = value.trim()
  if value.is_empty() {
    return None
  }
  let mut seconds = 0L
  for c in value {
    guard c >= '0' && c <= '9' else { return None }
    seconds = seconds * 10L + (c.to_int() - 48).to_int64()
    if seconds > 1099511627776L {
      return None
    }
  }
  Some(seconds)
}

///|
/// The transient GraphQL wait: the policy's backoff for the retry about to be
/// made.
fn GitHubRetry::transient_decision(
  self : GitHubRetry,
  context : @runtime.RetryContext,
) -> @runtime.Decision {
  if self.refusal(context) is Some(decision) {
    return decision
  }
  within_budget(
    self.policy.rule.backoff.delay_ms(context.attempt, context.random),
    context,
  )
}
