///|
/// Parameters for pure exponential backoff with symmetric jitter.
pub(all) struct Backoff {
  base_ms : Int
  max_ms : Int
  factor : Double
  jitter : Double
} derive(Eq, Debug)

///|
/// Compares backoff parameters.
pub extend Backoff with Eq::{equal, not_equal}

///|
/// Formats backoff parameters for debugging.
pub extend Backoff with @debug.Debug::{to_repr}

///|
/// Uses 500ms base, 30000ms cap, factor 2, and jitter 0.2.
pub fn Backoff::default() -> Backoff {
  { base_ms: 500, max_ms: 30000, factor: 2.0, jitter: 0.2, }
}

///|
/// Computes a capped delay, truncating fractional milliseconds.
/// Negative attempts behave as zero; random is clamped into [0, 1).
///
/// ```mbt check
/// test {
///   assert_eq(@runtime.Backoff::default().delay_ms(2, 0.5), 2000)
/// }
/// ```
pub fn Backoff::delay_ms(self : Backoff, attempt : Int, random : Double) -> Int {
  let cap = self.max_ms.max(0).to_double()
  let base = self.base_ms.max(0).to_double()
  if base == 0.0 || cap == 0.0 {
    return 0
  }
  let factor = if self.factor >= 0.0 { self.factor } else { 0.0 }
  let raw = base * @math.pow(factor, attempt.max(0).to_double())
  let raw = if raw >= cap { cap } else if raw >= 0.0 { raw } else { 0.0 }
  let random = if !(random >= 0.0) {
    0.0
  } else {
    random.min(0.9999999999999999)
  }
  let jitter = if self.jitter >= 0.0 { self.jitter.min(1.0) } else { 0.0 }
  let result = raw * (1.0 - jitter + 2.0 * jitter * random)
  if result >= cap {
    cap.to_int()
  } else if result > 0.0 {
    result.to_int()
  } else {
    0
  }
}
