// Retry decisions as data. A `RetryRule` says which responses and transport
// failures may be retried, for which methods, how long to wait and when to
// give up; `RetryRule::decide` turns one failed attempt into `Wait(ms)` or
// `Stop(reason)`. This package decides; it never sleeps, sends or reads a
// clock, so the same rule gives the same answer on every backend. The caller
// injects `random` (for jitter), the current time (for HTTP-date
// Retry-After values) and the time left in its budget.
//
// The rule holds no vendor defaults: presets live in the layers that own the
// policy, such as `gaato/sdk-runtime` (the behaviour of an official API SDK)
// and `gaato/requesto` (a client for people).

///|
/// A status code, or an inclusive range of status codes.
///
/// ```mbt check
/// test {
///   let rule : @retry.StatusRule = {
///     statuses: [Code(429), Range(500, 599)],
///     methods: Any,
///   }
///   assert_eq(rule.statuses.length(), 2)
/// }
/// ```
pub(all) enum StatusMatch {
  /// Exactly this status.
  Code(Int32)
  /// Every status from the first to the second, both included.
  Range(Int32, Int32)
} derive(Eq, Debug)

///|
/// Equality for status matches.
pub extend StatusMatch with Eq::{equal, not_equal}

///|
/// Debug representation of a status match.
pub extend StatusMatch with @debug.Debug::{to_repr}

///|
fn StatusMatch::contains(self : StatusMatch, status : Int32) -> Bool {
  match self {
    Code(code) => status == code
    Range(lo, hi) => status >= lo && status <= hi
  }
}

///|
/// Which request methods a retry is allowed for.
#non_exhaustive
pub(all) enum Methods {
  /// No method.
  Never
  /// Requests that `@http.is_idempotent` accepts (an idempotent method or
  /// an `Idempotency-Key` header), unless the caller says otherwise with
  /// `decide`'s `idempotent` argument.
  Idempotent
  /// These methods, compared ignoring ASCII case.
  Listed(Array[String])
  /// Every method.
  Any
} derive(Eq, Debug)

///|
/// Equality for method sets.
pub extend Methods with Eq::{equal, not_equal}

///|
/// Debug representation of a method set.
pub extend Methods with @debug.Debug::{to_repr}

///|
/// Response statuses that may be retried, and for which methods.
pub(all) struct StatusRule {
  /// The statuses this rule covers.
  statuses : Array[StatusMatch]
  /// The methods a response with one of those statuses may be retried for.
  methods : Methods
} derive(Eq, Debug)

///|
/// Equality for status rules.
pub extend StatusRule with Eq::{equal, not_equal}

///|
/// Debug representation of a status rule.
pub extend StatusRule with @debug.Debug::{to_repr}

///|
/// Where a server-requested delay is read from.
#non_exhaustive
pub(all) enum RetryAfterSource {
  /// Nowhere: the backoff always decides.
  Ignore
  /// The `Retry-After` header, as `@http.parse_retry_after` reads it.
  Header
  /// `retry-after-ms`, then `Retry-After`, as `@http.retry_after_ms` reads
  /// them (the OpenAI SDKs' behaviour).
  MsThenHeader
} derive(Eq, Debug)

///|
/// Equality for delay sources.
pub extend RetryAfterSource with Eq::{equal, not_equal}

///|
/// Debug representation of a delay source.
pub extend RetryAfterSource with @debug.Debug::{to_repr}

///|
/// What to do with a server-requested delay longer than a limit, in
/// milliseconds.
#non_exhaustive
pub(all) enum RetryAfterCap {
  /// Give up (`StopReason::RetryAfterTooLong`) rather than wait longer.
  StopAbove(Int32)
  /// Ignore the server and wait the backoff delay instead.
  BackoffAbove(Int32)
  /// Wait as long as the server asks.
  NoCap
} derive(Eq, Debug)

///|
/// Equality for delay caps.
pub extend RetryAfterCap with Eq::{equal, not_equal}

///|
/// Debug representation of a delay cap.
pub extend RetryAfterCap with @debug.Debug::{to_repr}

///|
/// How a server-requested delay is read and bounded.
pub(all) struct RetryAfter {
  /// Where the delay comes from.
  source : RetryAfterSource
  /// What a delay over the limit does.
  cap : RetryAfterCap
  /// Whether a delay of 0 means "use the backoff" rather than "retry now".
  zero_means_backoff : Bool
} derive(Eq, Debug)

///|
/// Equality for delay settings.
pub extend RetryAfter with Eq::{equal, not_equal}

///|
/// Debug representation of delay settings.
pub extend RetryAfter with @debug.Debug::{to_repr}

///|
/// How the exponential delay is spread, so that clients do not retry in
/// lockstep. Multipliers are per mille.
#non_exhaustive
pub(all) enum Jitter {
  /// The exponential delay itself.
  NoJitter
  /// A uniform delay in [0, delay), as in AWS's "full jitter".
  Full
  /// The delay times a multiplier from `lo` to `hi` per mille: (800, 1200)
  /// is ±20 %, (750, 1000) is up to 25 % shorter.
  Proportional(lo~ : Int32, hi~ : Int32)
} derive(Eq, Debug)

///|
/// Equality for jitter settings.
pub extend Jitter with Eq::{equal, not_equal}

///|
/// Debug representation of a jitter setting.
pub extend Jitter with @debug.Debug::{to_repr}

///|
/// Exponential backoff: `base_ms` doubled per attempt up to `max_ms`, then
/// jittered.
pub(all) struct Backoff {
  /// The delay before the first retry, before jitter.
  base_ms : Int32
  /// The largest delay before jitter.
  max_ms : Int32
  /// How the delay is spread.
  jitter : Jitter
} derive(Eq, Debug)

///|
/// Equality for backoff settings.
pub extend Backoff with Eq::{equal, not_equal}

///|
/// Debug representation of backoff settings.
pub extend Backoff with @debug.Debug::{to_repr}

///|
/// A retry policy as data: what may be retried, how long to wait, and when
/// to stop. `decide` applies it to one failed attempt.
///
/// ```mbt check
/// test {
///   let rule : @retry.RetryRule = {
///     ..@retry.RetryRule::never(),
///     max_retries: 2,
///     statuses: [{ statuses: [Code(429), Range(500, 599)], methods: Idempotent, }],
///     backoff: { base_ms: 500, max_ms: 8000, jitter: NoJitter, },
///   }
///   let get = @http.Request::get("/items")
///   let busy = @retry.Response(status=503, headers=@http.Headers::new())
///   assert_eq(rule.decide(busy, get, attempt=1, random=0.0), Wait(1000))
///   assert_eq(rule.decide(busy, get, attempt=2, random=0.0), Stop(Exhausted))
/// }
/// ```
pub(all) struct RetryRule {
  /// How many retries follow the first attempt.
  max_retries : Int32
  /// Retryable response statuses; the first rule containing a status wins.
  statuses : Array[StatusRule]
  /// For which methods a failure after the request may have been sent (a
  /// timeout or network error once connected) is retried.
  sent_failures : Methods
  /// Whether a failure that proves nothing was sent (`HttpError::is_unsent`)
  /// is retried, whatever the method. A proxy's refusal is retried only when
  /// its status also matches `statuses`.
  unsent_failures : Bool
  /// A response header that overrides the decision: `true` retries any
  /// method and status, `false` stops (e.g. `x-should-retry`).
  override_header : String?
  /// How a server-requested delay is used.
  retry_after : RetryAfter
  /// The delay when the server asks for none.
  backoff : Backoff
} derive(Eq, Debug)

///|
/// Equality for retry rules.
pub extend RetryRule with Eq::{equal, not_equal}

///|
/// Debug representation of a retry rule.
pub extend RetryRule with @debug.Debug::{to_repr}

///|
/// A rule that never retries, and a base to build others on with `{ ..never(), ... }`.
pub fn RetryRule::never() -> RetryRule {
  {
    max_retries: 0,
    statuses: [],
    sent_failures: Never,
    unsent_failures: false,
    override_header: None,
    retry_after: { source: Ignore, cap: NoCap, zero_means_backoff: false, },
    backoff: { base_ms: 0, max_ms: 0, jitter: NoJitter, },
  }
}

///|
/// The result of an attempt that did not succeed.
pub(all) enum Outcome {
  /// A response whose status the caller treats as a failure.
  Response(status~ : Int32, headers~ : @http.Headers)
  /// A transport failure.
  Failure(@http.HttpError)
} derive(Debug)

///|
/// Debug representation of an outcome.
pub extend Outcome with @debug.Debug::{to_repr}

///|
/// Why `decide` stopped.
#non_exhaustive
pub(all) enum StopReason {
  /// `max_retries` retries were already made.
  Exhausted
  /// The status or failure is not retryable under the rule.
  NotRetryable
  /// The status or failure is retryable, but not for this request's method.
  MethodNotAllowed
  /// The request body cannot be sent again.
  NotReplayable
  /// The override header said `false`.
  ServerSaidNo
  /// The server asked for this many milliseconds, over the `Stop` cap.
  RetryAfterTooLong(Int32)
  /// Waiting this many milliseconds would use up the remaining budget.
  Budget(Int32)
} derive(Eq, Debug)

///|
/// Equality for stop reasons.
pub extend StopReason with Eq::{equal, not_equal}

///|
/// Debug representation of a stop reason.
pub extend StopReason with @debug.Debug::{to_repr}

///|
/// What to do after a failed attempt.
pub(all) enum Decision {
  /// Wait this many milliseconds, then send the request again.
  Wait(Int32)
  /// Do not retry.
  Stop(StopReason)
} derive(Eq, Debug)

///|
/// Equality for decisions.
pub extend Decision with Eq::{equal, not_equal}

///|
/// Debug representation of a decision.
pub extend Decision with @debug.Debug::{to_repr}
