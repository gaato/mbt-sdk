///|
/// The delay before retry number `attempt + 1`, in milliseconds.
///
/// The exponential delay is `base_ms * 2^attempt` up to `max_ms`; a negative
/// attempt counts as 0, and a nonpositive `base_ms` or `max_ms` gives 0.
/// `random` is clamped into [0, 1), NaN to 0. The jitter then applies:
/// `NoJitter` keeps the delay, `Full` takes `trunc(delay * random)`, and
/// `Proportional(lo~, hi~)` multiplies by `lo + trunc(random * (hi - lo))`
/// per mille, in integers. The jittered delay is capped at `max_ms` again, so
/// a `hi` above 1000 spreads delays below the cap but never past it.
///
/// ```mbt check
/// test {
///   let backoff : @retry.Backoff = {
///     base_ms: 500,
///     max_ms: 30000,
///     jitter: Proportional(lo=800, hi=1200),
///   }
///   assert_eq(backoff.delay_ms(2, 0.5), 2000)
///   assert_eq(backoff.delay_ms(0, 0.0), 400)
/// }
/// ```
pub fn Backoff::delay_ms(
  self : Backoff,
  attempt : Int32,
  random : Double,
) -> Int32 {
  if self.base_ms <= 0 || self.max_ms <= 0 {
    return 0
  }
  let max = self.max_ms.to_int64()
  // base_ms < 2^31, so a shift below 31 stays under 2^62.
  let raw = if attempt >= 31 {
    max
  } else {
    (self.base_ms.to_int64() << attempt.max(0)).min(max)
  }
  let random = if !(random >= 0.0) {
    0.0
  } else {
    random.min(0.9999999999999999)
  }
  let delay = match self.jitter {
    NoJitter => raw
    Full => (raw.to_double() * random).to_int64()
    Proportional(lo~, hi~) => {
      // Both factors stay below 2^31, so the product fits in Int64.
      let span = (hi.to_int64() - lo.to_int64()).to_double()
      let per_mille = lo.to_int64() + (random * span).to_int64()
      raw * per_mille.max(0L) / 1000L
    }
  }
  delay.max(0L).min(max).to_int()
}
