///|
/// A deterministic clock whose sleeps advance time without waiting.
pub struct FakeClock {
  priv mut now : Int64
  priv delays : Array[Int]
}

///|
/// Creates a fake clock at the supplied Unix millisecond timestamp.
///
/// ```mbt check
/// test {
///   let clock = @mock.FakeClock::new(start_unix_ms=123L)
///   assert_eq(clock.now_unix_ms(), 123L)
///   assert_eq(clock.slept(), [])
/// }
/// ```
pub fn FakeClock::new(start_unix_ms? : Int64 = 0L) -> FakeClock {
  { now: start_unix_ms, delays: [], }
}

///|
/// Returns an independent copy of all requested sleep durations.
pub fn FakeClock::slept(self : FakeClock) -> Array[Int] {
  self.delays.copy()
}

///|
/// Moves the fake wall clock by `milliseconds` without recording a sleep.
pub fn FakeClock::advance(self : FakeClock, milliseconds : Int) -> Unit {
  self.now += milliseconds.to_int64()
}

///|
/// Explicit clock methods for deterministic time control.
pub extend FakeClock with @clock.Clock::{sleep, now_unix_ms}

///|
/// Records every sleep; only positive durations advance the clock.
pub impl @clock.Clock for FakeClock with fn sleep(self, milliseconds) {
  self.delays.push(milliseconds)
  if milliseconds > 0 {
    self.now += milliseconds.to_int64()
  }
}

///|
/// Returns the current fake Unix millisecond timestamp.
pub impl @clock.Clock for FakeClock with fn now_unix_ms(self) {
  self.now
}
