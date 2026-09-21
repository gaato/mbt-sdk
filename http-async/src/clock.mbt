///|
/// A production clock backed by moonbitlang/async timers and wall time.
pub struct AsyncClock {}

///|
/// Creates an async clock.
///
/// ```mbt check
/// test {
///   let _ = @adapter.AsyncClock::new()
/// }
/// ```
pub fn AsyncClock::new() -> AsyncClock {
  AsyncClock::{ }
}

///|
/// Explicit clock methods backed by moonbitlang/async.
pub extend AsyncClock with @clock.Clock::{sleep, now_unix_ms}

///|
/// Sleeps without raising an ordinary error; nonpositive values return directly.
pub impl @clock.Clock for AsyncClock with fn sleep(_self, milliseconds) {
  if milliseconds > 0 {
    @async.sleep(milliseconds)
  }
}

///|
/// Returns wall-clock milliseconds since the Unix epoch.
pub impl @clock.Clock for AsyncClock with fn now_unix_ms(_self) {
  @async.now()
}
