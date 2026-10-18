// The window limiter's decisions, kept free of the clock and the maps so each
// boundary can be checked on plain values.

///|
/// What one pass of the global wait does.
priv enum GlobalStep {
  /// No global window: admit without counting.
  Pass
  /// Admit, leaving the window starting at `start` with `count` admissions.
  Admit(start~ : Int64, count~ : Int32)
  /// Sleep this many milliseconds, then look again.
  Wait(Int32)
}

///|
/// Decides one pass of the global wait at `now`. An account-wide block holds
/// every non-exempt request, even when the window has room; a window opens at
/// the first admission and a fresh one opens once `now` reaches its end.
fn global_step(
  now : Int64,
  blocked_until~ : Int64?,
  window~ : GlobalWindow?,
  start~ : Int64?,
  count~ : Int32,
) -> GlobalStep {
  if blocked_until is Some(until) && now < until {
    return Wait(delay_until(until, now))
  }
  guard window is Some(window) else { return Pass }
  let (start, count) = match start {
    Some(start) if now < saturating_add_ms(start, window.window_ms) =>
      (start, count)
    _ => (now, 0)
  }
  if count < window.limit {
    Admit(start~, count=count + 1)
  } else {
    Wait(delay_until(saturating_add_ms(start, window.window_ms), now))
  }
}

///|
/// What one pass of a bucket's wait does.
priv enum BucketStep {
  /// No recorded state: admit.
  Admit
  /// The recorded window has reset: forget it and admit.
  Expired
  /// Admit, recording the state with one fewer request left.
  Consume(RateLimitState)
  /// Sleep this many milliseconds, then look again.
  Wait(Int32)
}

///|
/// Decides one pass of a bucket's wait at `now` from its recorded state.
fn bucket_step(state : RateLimitState?, now : Int64) -> BucketStep {
  guard state is Some(state) else { return Admit }
  if now >= state.reset_at_unix_ms {
    return Expired
  }
  if state.remaining > 0 {
    return Consume({ ..state, remaining: state.remaining - 1, })
  }
  Wait(delay_until(state.reset_at_unix_ms, now))
}

///|
/// How long to sleep from `now` until `until`, saturating at the longest sleep
/// a clock takes instead of wrapping when the span overflows.
fn delay_until(until : Int64, now : Int64) -> Int32 {
  if until <= now {
    return 0
  }
  let delta = if now < 0L && until > 9223372036854775807L + now {
    9223372036854775807L
  } else {
    until - now
  }
  if delta > 2147483647L {
    2147483647
  } else {
    delta.to_int()
  }
}

///|
/// What a response does to its bucket and to the account-wide block.
priv struct ReleaseEffect {
  /// The state to record for the bucket, if any.
  record : RateLimitState?
  /// The account-wide block after the response.
  blocked_until : Int64?
}

///|
/// Decides what a response with `status` does at `now`. `parsed` is the
/// parser's state, `delay_ms` the Retry-After delay or the configured default,
/// and `global` whether the response is an account-wide 429. A 429 with a delay
/// empties the bucket until then, or, when global, extends the account-wide
/// block (never shortening it) and leaves the parsed state as it is.
fn release_effect(
  status : Int32,
  parsed~ : RateLimitState?,
  delay_ms~ : Int32?,
  global~ : Bool,
  blocked_until~ : Int64?,
  now~ : Int64,
) -> ReleaseEffect {
  guard status == 429 && delay_ms is Some(ms) else {
    return { record: parsed, blocked_until, }
  }
  let until = saturating_add_ms(now, ms.max(0))
  if global {
    let blocked_until = match blocked_until {
      Some(previous) => previous.max(until)
      None => until
    }
    { record: parsed, blocked_until: Some(blocked_until), }
  } else {
    { record: Some({ remaining: 0, reset_at_unix_ms: until, }), blocked_until, }
  }
}
