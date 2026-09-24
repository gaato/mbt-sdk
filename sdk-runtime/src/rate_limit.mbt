///|
/// Remaining requests and the Unix millisecond instant when a window resets.
pub(all) struct RateLimitState {
  remaining : Int
  reset_at_unix_ms : Int64
} derive(Eq, Debug)

///|
/// Equality for rate-limit states.
pub extend RateLimitState with Eq::{equal, not_equal}

///|
/// Debug representation of rate-limit states.
pub extend RateLimitState with @debug.Debug::{to_repr}

///|
/// A per-bucket admission policy updated from HTTP responses.
///
/// `acquire` and `release` come in pairs: the client calls `release` exactly
/// once for every `acquire` that returned, with the response's status and
/// headers, or with status `0` and no headers when the attempt produced no
/// response (a transport failure or a cancellation). A limiter that holds
/// per-bucket state across the exchange, such as a gate that serialises one
/// bucket, relies on that pairing; a stateless window limiter ignores the
/// status-`0` calls.
///
/// A cancelled task still gets its `release`, but inside cancellation any
/// further asynchronous work is cut short, so an implementation that talks to
/// another process must recover on its own if that call does not complete
/// (dropping its connection so the peer can clean up, for example).
pub(open) trait RateLimiter {
  /// Waits until one request may enter a bucket. `global_exempt` marks a
  /// request that does not count toward an account-wide limit; a limiter
  /// without such a limit ignores it. An error (a limiter in another process
  /// that cannot be reached, say) fails the request before it is sent.
  async fn acquire(Self, String, global_exempt~ : Bool) -> Unit
  /// Reports the outcome of the request admitted by the matching `acquire`.
  /// Status `0` means no response arrived. An error raised on the success
  /// path reaches the caller; one raised while the attempt is already failing
  /// is dropped.
  async fn release(Self, String, status~ : Int, headers~ : @http.Headers) -> Unit
}

///|
/// A limiter that never delays requests and ignores releases.
pub struct NoLimiter {}

///|
/// Creates a limiter that admits every request.
pub fn NoLimiter::new() -> NoLimiter {
  NoLimiter::{ }
}

///|
/// Explicit no-op limiter methods.
pub extend NoLimiter with RateLimiter::{acquire, release}

///|
/// Admits immediately.
pub impl RateLimiter for NoLimiter with fn acquire(
  _self,
  _bucket,
  global_exempt~,
) {
  ignore(global_exempt)
}

///|
/// Ignores response state.
pub impl RateLimiter for NoLimiter with fn release(
  _self,
  _bucket,
  status~,
  headers~,
) {
  ignore(status)
  ignore(headers)
}

///|
/// A mutable per-bucket fixed-window limiter driven by an injected clock.
pub struct WindowLimiter {
  priv clock : &@clock.Clock
  priv parse : (@http.Headers, Int64) -> RateLimitState?
  priv states : Map[String, RateLimitState]
}

///|
/// Creates a limiter using an API-specific response-header parser.
pub fn WindowLimiter::new(
  clock : &@clock.Clock,
  parse : (@http.Headers, Int64) -> RateLimitState?,
) -> WindowLimiter {
  { clock, parse, states: Map([]), }
}

///|
/// Explicit fixed-window limiter methods.
pub extend WindowLimiter with RateLimiter::{acquire, release}

///|
/// Returns the currently recorded state for a bucket.
pub fn WindowLimiter::state(
  self : WindowLimiter,
  bucket : String,
) -> RateLimitState? {
  self.states.get(bucket)
}

///|
/// Rechecks the bucket after every sleep because another task may update it.
/// There is no account-wide window here, so `global_exempt` is ignored.
pub impl RateLimiter for WindowLimiter with fn acquire(
  self,
  bucket,
  global_exempt~,
) {
  ignore(global_exempt)
  for ;; {
    guard self.states.get(bucket) is Some(state) else { return }
    let now = self.clock.now_unix_ms()
    if now >= state.reset_at_unix_ms {
      self.states.remove(bucket)
      return
    }
    if state.remaining > 0 {
      self.states[bucket] = { ..state, remaining: state.remaining - 1, }
      return
    }
    let delta = state.reset_at_unix_ms - now
    let delay = if delta > 2147483647L { 2147483647 } else { delta.to_int() }
    self.clock.sleep(delay)
  }
}

///|
/// Replaces parsed state; a 429 Retry-After takes precedence over that parser.
/// An attempt without a response (status `0`) leaves the window unchanged.
pub impl RateLimiter for WindowLimiter with fn release(
  self,
  bucket,
  status~,
  headers~,
) {
  if status == 0 {
    return
  }
  let now_unix_ms = self.clock.now_unix_ms()
  if (self.parse)(headers, now_unix_ms) is Some(state) {
    self.states[bucket] = state
  }
  if status == 429 && retry_after_ms(headers, now_unix_ms~) is Some(ms) {
    self.states[bucket] = {
      remaining: 0,
      reset_at_unix_ms: saturating_add_ms(now_unix_ms, ms),
    }
  }
}

///|
/// Builds a parser for conventional remaining/reset response headers.
pub fn rate_limit_headers(
  remaining~ : String,
  reset_after_seconds? : String,
  reset_unix_seconds? : String,
) -> (@http.Headers, Int64) -> RateLimitState? {
  (headers, now) => {
    guard headers.get(remaining) is Some(raw_remaining) else { return None }
    guard parse_nonnegative_int(raw_remaining) is Some(left) else {
      return None
    }
    let reset = match reset_after_seconds {
      Some(name) =>
        match headers.get(name) {
          Some(value) =>
            decimal_seconds_ms(value).map(ms => saturating_add_i64(now, ms))
          None => None
        }
      None => None
    }
    let reset = match reset {
      Some(value) => Some(value)
      None =>
        match reset_unix_seconds {
          Some(name) =>
            match headers.get(name) {
              Some(value) => decimal_seconds_ms(value)
              None => None
            }
          None => None
        }
    }
    reset.map(reset_at_unix_ms => { remaining: left, reset_at_unix_ms, })
  }
}

///|
fn parse_nonnegative_int(value : String) -> Int? {
  let value = value.trim()
  if value.is_empty() {
    return None
  }
  let mut result = 0
  for c in value {
    guard c >= '0' && c <= '9' else { return None }
    let digit = c.to_int() - 48
    if result > (2147483647 - digit) / 10 {
      return None
    }
    result = result * 10 + digit
  }
  Some(result)
}

///|
fn decimal_seconds_ms(value : String) -> Int64? {
  let value = value.trim()
  let mut whole = 0L
  let mut fraction = 0L
  let mut weight = 100L
  let mut dot = false
  let mut before = 0
  let mut after = 0
  for c in value {
    if c == '.' && !dot {
      dot = true
    } else if c >= '0' && c <= '9' {
      let digit = (c.to_int() - 48).to_int64()
      if dot {
        after += 1
        if weight > 0L {
          fraction += digit * weight
          weight /= 10L
        }
      } else {
        before += 1
        whole = if whole > (9223372036854775807L - digit) / 10L {
          9223372036854775807L
        } else {
          whole * 10L + digit
        }
      }
    } else {
      return None
    }
  }
  if before == 0 || (dot && after == 0) {
    return None
  }
  if whole > (9223372036854775807L - fraction) / 1000L {
    Some(9223372036854775807L)
  } else {
    Some(whole * 1000L + fraction)
  }
}

///|
fn saturating_add_ms(now : Int64, milliseconds : Int) -> Int64 {
  saturating_add_i64(now, milliseconds.to_int64())
}

///|
fn saturating_add_i64(left : Int64, right : Int64) -> Int64 {
  if right > 0L && left > 9223372036854775807L - right {
    9223372036854775807L
  } else {
    left + right
  }
}
