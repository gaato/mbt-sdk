///|
/// A retry rule of `gaato/http/retry`: which failures to retry, how long to
/// wait, and how often.
pub using @retry {type RetryRule}

///|
/// Response statuses a `RetryRule` retries, and for which methods (from
/// `gaato/http/retry`).
pub using @retry {type StatusRule}

///|
/// One status code or an inclusive range of them, in a `StatusRule` (from
/// `gaato/http/retry`).
pub using @retry {type StatusMatch}

///|
/// The request methods a retry is allowed for (from `gaato/http/retry`).
pub using @retry {type Methods}

///|
/// How a server-requested delay is read and bounded (from `gaato/http/retry`).
pub using @retry {type RetryAfter}

///|
/// A header a server-requested delay is read from (from `gaato/http/retry`).
pub using @retry {type RetryAfterSource}

///|
/// What to do with a server-requested delay over a limit (from
/// `gaato/http/retry`).
pub using @retry {type RetryAfterCap}

///|
/// Exponential backoff between attempts, in milliseconds (from
/// `gaato/http/retry`).
pub using @retry {type Backoff}

///|
/// How a backoff delay is spread so clients do not retry in lockstep (from
/// `gaato/http/retry`).
pub using @retry {type Jitter}

///|
/// The result of an attempt that did not succeed: a status or an `HttpError`
/// (from `gaato/http/retry`).
pub using @retry {type Outcome}

///|
/// What to do after a failed attempt: wait and retry, or stop (from
/// `gaato/http/retry`).
pub using @retry {type Decision}

///|
/// Why a `RetryRule` stopped retrying (from `gaato/http/retry`).
pub using @retry {type StopReason}

///|
/// A retry policy for `Client`: a `RetryRule` of `gaato/http/retry` applied
/// to `SdkError`s.
///
/// Start from a preset — `conservative()` (the default), `stainless(cap~)`,
/// `none()` — or from any rule with `from_rule`, and adjust it with
/// `with_max_retries`, `allow_non_idempotent` or a struct update of `rule`.
///
/// ```mbt check
/// test {
///   let policy = @runtime.RetryPolicy::conservative().with_max_retries(3)
///   assert_eq(policy.rule.max_retries, 3)
///   let post = @http.Request::post("/items")
///   let busy = @runtime.Status(status=503, headers=@http.Headers::new(), body=b"")
///   let context = @runtime.RetryContext::new(post, random=0.5)
///   assert_eq(policy.decide(busy, context), Stop(MethodNotAllowed))
///   assert_eq(policy.allow_non_idempotent().decide(busy, context), Wait(500))
/// }
/// ```
pub(all) struct RetryPolicy {
  /// What is retried, how long to wait, and when to stop.
  rule : RetryRule
} derive(Eq, Debug)

///|
/// Equality for retry policy values.
pub extend RetryPolicy with Eq::{equal, not_equal}

///|
/// Debug representation of retry policy values.
pub extend RetryPolicy with @debug.Debug::{to_repr}

///|
/// The policy `Client` uses unless told otherwise: two retries; 429 for any
/// method; 408, 409, 500, 502, 503 and 504 only for an idempotent request
/// (`@http.is_idempotent`, which accepts an `Idempotency-Key`); a failure
/// that proves nothing was sent (`HttpError::is_unsent`) for any method,
/// and a proxy's refusal only when its status is one of those; a timeout or
/// network failure after sending only for an idempotent request.
///
/// The wait is `retry-after-ms`, else `Retry-After` (seconds or an HTTP
/// date), and a server that asks for more than 60 s is not retried;
/// `Retry-After: 0` retries at once. Without one, the backoff starts at
/// 500 ms, doubles up to 30 s and is spread by ±20 %.
///
/// ```mbt check
/// test {
///   let policy = @runtime.RetryPolicy::conservative()
///   assert_eq(policy.rule.max_retries, 2)
///   assert_eq(policy.rule.backoff.delay_ms(1, 0.5), 1000)
///   assert_eq(@runtime.RetryPolicy::default(), policy)
/// }
/// ```
pub fn RetryPolicy::conservative() -> RetryPolicy {
  {
    rule: {
      max_retries: 2,
      statuses: [
        { statuses: [Code(429)], methods: Any, },
        {
          statuses: [
            Code(408),
            Code(409),
            Code(500),
            Code(502),
            Code(503),
            Code(504),
          ],
          methods: Idempotent,
        },
      ],
      sent_failures: Idempotent,
      unsent_failures: true,
      override_header: None,
      retry_after: {
        source: MsThenHeader,
        cap: StopAbove(60000),
        zero_means_backoff: false,
      },
      backoff: {
        base_ms: 500,
        max_ms: 30000,
        jitter: Proportional(lo=800, hi=1200),
      },
    },
  }
}

///|
/// `conservative()`.
pub fn RetryPolicy::default() -> RetryPolicy {
  RetryPolicy::conservative()
}

///|
/// The retries of the official Stainless-generated SDKs (`openai-python`
/// and `anthropic-sdk-python`, `_base_client.py`): two retries; 408, 409,
/// 429 and every 5xx for any method, as is any transport failure but a
/// protocol error; `x-should-retry: true` retries any response and `false`
/// none.
///
/// The wait is `retry-after-ms`, else `Retry-After`; `cap` decides what a
/// long one does (the OpenAI SDK gives up above two minutes,
/// `StopAbove(120000)`; the Anthropic SDK waits whatever it is told,
/// `NoCap`), and 0 means no delay was given. Without one, the backoff starts
/// at 500 ms, doubles up to 8 s and is shortened by up to 25 %.
///
/// Retrying a POST after a 5xx or a timeout can run it twice; the official
/// SDKs accept that for model APIs.
///
/// ```mbt check
/// test {
///   let policy = @runtime.RetryPolicy::stainless(cap=StopAbove(120000))
///   let post = @http.Request::post("/v1/responses")
///   let error = @runtime.Status(
///     status=500,
///     headers=@http.Headers::new(),
///     body=b"",
///   )
///   let context = @runtime.RetryContext::new(post, random=0.0)
///   assert_eq(policy.decide(error, context), Wait(375))
/// }
/// ```
pub fn RetryPolicy::stainless(cap~ : RetryAfterCap) -> RetryPolicy {
  {
    rule: {
      max_retries: 2,
      statuses: [
        {
          statuses: [Code(408), Code(409), Code(429), Range(500, 599)],
          methods: Any,
        },
      ],
      sent_failures: Any,
      unsent_failures: true,
      override_header: Some("x-should-retry"),
      retry_after: { source: MsThenHeader, cap, zero_means_backoff: true, },
      backoff: {
        base_ms: 500,
        max_ms: 8000,
        jitter: Proportional(lo=750, hi=1000),
      },
    },
  }
}

///|
/// `conservative()` without retries.
pub fn RetryPolicy::none() -> RetryPolicy {
  RetryPolicy::conservative().with_max_retries(0)
}

///|
/// A policy applying `rule` as it is.
pub fn RetryPolicy::from_rule(rule : RetryRule) -> RetryPolicy {
  { rule, }
}

///|
/// This policy with `max_retries` retries after the first attempt.
pub fn RetryPolicy::with_max_retries(
  self : RetryPolicy,
  max_retries : Int32,
) -> RetryPolicy {
  { rule: { ..self.rule, max_retries, }, }
}

///|
/// This policy with every `Idempotent` method set widened to `Any`, in its
/// status rules and for failures after sending: what `retry_non_idempotent:
/// true` did before 0.7.0. A retried POST may then run twice.
///
/// ```mbt check
/// test {
///   let policy = @runtime.RetryPolicy::conservative().allow_non_idempotent()
///   assert_eq(policy.rule.sent_failures, Any)
///   assert_true(policy.rule.statuses.iter().all(rule => rule.methods == Any))
/// }
/// ```
pub fn RetryPolicy::allow_non_idempotent(self : RetryPolicy) -> RetryPolicy {
  let widen = (methods : Methods) => {
    match methods {
      Idempotent => Methods::Any
      methods => methods
    }
  }
  {
    rule: {
      ..self.rule,
      statuses: self.rule.statuses.map(rule => {
        ..rule,
        methods: widen(rule.methods),
      }),
      sent_failures: widen(self.rule.sent_failures),
    },
  }
}

///|
/// Whether `Client` may send `request` again at all, before any
/// `RetryDecider` is asked: when each attempt builds its own body
/// (`rebuilt`), or the body can be sent again (`Body::is_replayable`: bytes,
/// or a stream no transport has read yet).
fn can_resend(request : @http.Request, rebuilt~ : Bool) -> Bool {
  rebuilt || request.body.is_replayable()
}

///|
/// What a `RetryDecider` knows about the attempt that failed, besides the
/// error.
///
/// `Client` asks a decider only when it may send the request again, so the
/// `replayable` it passes is always true; the field is there for a decider
/// that hands the context on to `RetryRule::decide`, and for contexts made
/// with `RetryContext::new`.
pub struct RetryContext {
  /// The rate-limit bucket the request was sent through.
  bucket : String
  /// The request as the client prepared it, without a deferred `body`.
  request : @http.Request
  /// The retries already made: 0 after the first attempt fails.
  attempt : Int32
  /// A random number in [0, 1), for jitter.
  random : Double
  /// The time the attempt ended, in Unix milliseconds, for HTTP-date
  /// `Retry-After` values.
  now_unix_ms : Int64
  /// The time left before `Timeouts.total_ms` runs out, when one is set: a
  /// wait at least this long cannot be followed by another attempt.
  remaining_ms : Int64?
  /// Whether the request can be sent again: its body is rebuilt for each
  /// attempt or can be read again.
  replayable : Bool
}

///|
/// A retry context, for tests and for deciders that consult another. By
/// default the bucket is `""`, the attempt `0`, `random` 0.5 (the middle of
/// any jitter), the time 0, no total timeout, and `replayable` is
/// `request.body.is_replayable()`.
///
/// ```mbt check
/// test {
///   let context = @runtime.RetryContext::new(@http.Request::get("/"))
///   assert_eq(context.attempt, 0)
///   assert_true(context.replayable)
/// }
/// ```
pub fn RetryContext::new(
  request : @http.Request,
  bucket~ : String = "",
  attempt~ : Int32 = 0,
  random~ : Double = 0.5,
  now_unix_ms~ : Int64 = 0L,
  remaining_ms? : Int64,
  replayable? : Bool,
) -> RetryContext {
  {
    bucket,
    request,
    attempt,
    random,
    now_unix_ms,
    remaining_ms,
    replayable: replayable.unwrap_or_else(() => request.body.is_replayable()),
  }
}

///|
/// Decides, after a failed attempt, whether the client sends the request
/// again and how long it waits first.
///
/// `RetryPolicy` is the general-purpose implementation. An API with rules a
/// `RetryRule` cannot express — a delay read from a response body, a limit
/// recognised by its message — supplies its own implementation to
/// `Client::new`, and can hand everything else to a `RetryPolicy`.
pub(open) trait RetryDecider {
  /// `Wait(ms)` to send again after `ms` milliseconds, or `Stop(reason)` to
  /// raise `error`.
  fn decide(Self, SdkError, RetryContext) -> Decision
}

///|
/// The policy's decision as a dot-callable method.
pub extend RetryPolicy with RetryDecider::{decide}

///|
/// Applies the rule to `error.outcome()`: `Decode` and `Config` errors stop
/// with `NotRetryable`. A `RateLimited` error's `retry_after_ms`, when
/// present, is the server's delay unless the rule ignores server delays;
/// otherwise the rule reads the headers, with `now_unix_ms` for an HTTP
/// date.
pub impl RetryDecider for RetryPolicy with fn decide(self, error, context) {
  guard error.outcome() is Some(outcome) else { return Stop(NotRetryable) }
  let server_delay_ms = match error {
    RateLimited(retry_after_ms=Some(ms), ..) if !(self.rule.retry_after.source
      is Ignore) => Some(ms)
    _ => None
  }
  self.rule.decide(
    outcome,
    context.request,
    attempt=context.attempt,
    random=context.random,
    now_unix_ms=context.now_unix_ms,
    remaining_ms?=context.remaining_ms,
    server_delay_ms?,
    replayable=context.replayable,
  )
}
