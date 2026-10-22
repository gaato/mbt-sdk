///|
/// A production clock backed by moonbitlang/async timers and wall time.
pub struct AsyncClock {}

///|
/// Creates an async clock.
///
/// ```mbt check
/// test {
///   let _ = @http_async.AsyncClock::new()
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

///|
/// Runs `f`, giving up after `milliseconds` on `clock`: `None` when the time
/// runs out first, in which case `f` is cancelled. Errors from `f` propagate.
/// The clock-driven form of `@async.with_timeout_opt`, so a test can expire
/// the deadline by advancing a virtual clock instead of waiting for it.
///
/// A nonpositive `milliseconds` has already expired: `f` still starts, so a
/// result it produces without waiting is returned, but anything it has to
/// wait for gives up.
///
/// ```mbt check
/// async test {
///   let clock = @http_async.AsyncClock::new()
///   assert_eq(@http_async.with_timeout_opt(clock, 1000, () => 7), Some(7))
/// }
/// ```
pub async fn[X] with_timeout_opt(
  clock : &@clock.Clock,
  milliseconds : Int32,
  f : async () -> X,
) -> X? {
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      clock.sleep(milliseconds)
      group.return_immediately(None)
    })
    Some(f())
  })
}
