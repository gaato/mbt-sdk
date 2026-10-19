///|
/// Decides whether to retry after a failed attempt, and how long to wait.
///
/// `attempt` counts the retries already made: 0 after the first attempt
/// fails. The checks run in order, and the first that applies wins:
///
/// 1. `attempt >= max_retries` stops with `Exhausted`.
/// 2. A body that cannot be sent again stops with `NotReplayable`;
///    `replayable` overrides `request.body.is_replayable()`.
/// 3. A response carrying `override_header` with the value `true` (ignoring
///    case and surrounding whitespace) skips step 4; `false` stops with
///    `ServerSaidNo`; any other value is ignored.
/// 4. The outcome must be retryable for the request's method: a response
///    through the first `StatusRule` containing its status; `Protocol`
///    never; `Proxy` when `unsent_failures` is set and its status matches a
///    `StatusRule`; another unsent failure when `unsent_failures` is set;
///    any other failure through `sent_failures`. `Idempotent` asks
///    `@http.is_idempotent` unless `idempotent` is given.
/// 5. The wait is `server_delay_ms` when given, otherwise the response's
///    header per `retry_after.source` (an HTTP date needs `now_unix_ms`),
///    bounded by `retry_after.cap`; without one it is
///    `backoff.delay_ms(attempt, random)`.
/// 6. With `remaining_ms`, a wait that is not shorter than it stops with
///    `Budget(wait)`.
///
/// ```mbt check
/// test {
///   let rule : @retry.RetryRule = {
///     ..@retry.RetryRule::never(),
///     max_retries: 2,
///     statuses: [{ statuses: [Code(429)], methods: Any, }],
///     retry_after: {
///       source: Header,
///       cap: StopAbove(60000),
///       zero_means_backoff: false,
///     },
///   }
///   let post = @http.Request::post("/messages")
///   let headers = @http.Headers::from_array([("Retry-After", "3")])
///   let limited = @retry.Response(status=429, headers~)
///   assert_eq(rule.decide(limited, post, attempt=0, random=0.5), Wait(3000))
///   assert_eq(
///     rule.decide(limited, post, attempt=0, random=0.5, remaining_ms=2000),
///     Stop(Budget(3000)),
///   )
/// }
/// ```
pub fn RetryRule::decide(
  self : RetryRule,
  outcome : Outcome,
  request : @http.Request,
  attempt~ : Int32,
  random~ : Double,
  now_unix_ms? : Int64,
  remaining_ms? : Int64,
  server_delay_ms? : Int32,
  idempotent? : Bool,
  replayable? : Bool,
) -> Decision {
  if attempt >= self.max_retries {
    return Stop(Exhausted)
  }
  let replayable = match replayable {
    Some(replayable) => replayable
    None => request.body.is_replayable()
  }
  if !replayable {
    return Stop(NotReplayable)
  }
  let forced = match (outcome, self.override_header) {
    (Response(headers~, ..), Some(name)) =>
      match headers.get(name).map(value => value.trim().to_lower()) {
        Some("true") => true
        Some("false") => return Stop(ServerSaidNo)
        _ => false
      }
    _ => false
  }
  if !forced && self.refusal(outcome, request, idempotent) is Some(reason) {
    return Stop(reason)
  }
  let wait = match self.server_delay(outcome, server_delay_ms, now_unix_ms) {
    Ok(Some(delay)) => delay
    Ok(None) => self.backoff.delay_ms(attempt, random)
    Err(reason) => return Stop(reason)
  }
  if remaining_ms is Some(remaining) && wait.to_int64() >= remaining {
    return Stop(Budget(wait))
  }
  Wait(wait)
}

///|
// Step 4: why the outcome may not be retried, if it may not.
fn RetryRule::refusal(
  self : RetryRule,
  outcome : Outcome,
  request : @http.Request,
  idempotent : Bool?,
) -> StopReason? {
  match outcome {
    Response(status~, ..) =>
      match self.status_rule(status) {
        None => Some(NotRetryable)
        Some(rule) => permit(rule.methods, request, idempotent)
      }
    Failure(Protocol(_)) => Some(NotRetryable)
    Failure(Proxy(status~, ..)) =>
      if self.unsent_failures && self.status_rule(status) is Some(_) {
        None
      } else {
        Some(NotRetryable)
      }
    Failure(error) =>
      if error.is_unsent() {
        if self.unsent_failures {
          None
        } else {
          Some(NotRetryable)
        }
      } else if self.sent_failures is Never {
        Some(NotRetryable)
      } else {
        permit(self.sent_failures, request, idempotent)
      }
  }
}

///|
fn RetryRule::status_rule(self : RetryRule, status : Int32) -> StatusRule? {
  for rule in self.statuses {
    for matcher in rule.statuses {
      if matcher.contains(status) {
        return Some(rule)
      }
    }
  }
  None
}

///|
// None when `methods` allows the request, else `MethodNotAllowed`.
fn permit(
  methods : Methods,
  request : @http.Request,
  idempotent : Bool?,
) -> StopReason? {
  let allowed = match methods {
    Never => false
    Any => true
    Idempotent =>
      match idempotent {
        Some(idempotent) => idempotent
        None => @http.is_idempotent(request)
      }
    Listed(names) => {
      let verb = request.http_method.to_lower()
      names.iter().any(name => name.to_lower() == verb)
    }
  }
  if allowed {
    None
  } else {
    Some(MethodNotAllowed)
  }
}

///|
// Step 5: the server's delay after `retry_after.cap`, None to use the
// backoff, or the reason to stop.
fn RetryRule::server_delay(
  self : RetryRule,
  outcome : Outcome,
  given : Int32?,
  now_unix_ms : Int64?,
) -> Result[Int32?, StopReason] {
  let delay = match (given, outcome) {
    (Some(delay), _) => Some(delay.max(0))
    (None, Response(headers~, ..)) =>
      match self.retry_after.source {
        Ignore => None
        Header =>
          match headers.get("retry-after") {
            Some(value) => @http.parse_retry_after(value, now_unix_ms?)
            None => None
          }
        MsThenHeader => @http.retry_after_ms(headers, now_unix_ms?)
      }
    (None, Failure(_)) => None
  }
  guard delay is Some(delay) else { return Ok(None) }
  if delay == 0 && self.retry_after.zero_means_backoff {
    return Ok(None)
  }
  match self.retry_after.cap {
    StopAbove(limit) if delay > limit => Err(RetryAfterTooLong(delay))
    BackoffAbove(limit) if delay > limit => Ok(None)
    _ => Ok(Some(delay))
  }
}
