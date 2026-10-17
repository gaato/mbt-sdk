///|
/// Raised by `VirtualClock::settle` when tasks keep making progress for
/// `rounds` scheduler rounds without ever going idle: a livelock, such as a
/// retry loop that never waits.
pub suberror NoQuiescence {
  NoQuiescence(rounds~ : Int32)
} derive(Debug)

///|
pub extend NoQuiescence with @debug.Debug::{to_repr}

///|
priv struct Waiter {
  deadline : Int64
  requested : Int32
  seq : Int32
  mut fired : Bool
  cond : @cond_var.Cond
}

///|
/// A `Clock` whose time moves only when a test advances it.
///
/// Sleeps register a timer and suspend until `advance` reaches its deadline;
/// timers with the same deadline fire in registration order. Between timers
/// the clock waits for the tasks under test to go idle (`settle`), so a test
/// observes every state the code passes through, in the same order on every
/// run and every target.
///
/// Idleness is approximated: `@async.pause` returns after every task that was
/// ready has run once, and the clock counts progress — its own sleeps plus
/// whatever fakes report through `touch`. The tasks are idle once that count
/// stays unchanged for `stable_rounds` consecutive rounds, so a chain of
/// unobserved hops (queue to queue) longer than that may be cut short.
pub struct VirtualClock {
  priv mut now : Int64
  priv mut next_seq : Int32
  priv waiters : Array[Waiter]
  priv mut progress : Int32
}

///|
pub fn VirtualClock::VirtualClock(
  start_ms~ : Int64 = 1_700_000_000_000L,
) -> VirtualClock {
  { now: start_ms, next_seq: 0, waiters: [], progress: 0, }
}

///|
/// Explicit clock methods for deterministic time control.
pub extend VirtualClock with @clock.Clock::{sleep, now_unix_ms}

///|
/// A nonpositive sleep only yields, so a loop of them still lets other tasks
/// run and `settle` reports it as a livelock instead of hanging.
pub impl @clock.Clock for VirtualClock with fn sleep(self, milliseconds) {
  self.progress += 1
  if milliseconds <= 0 {
    @async.pause()
    return
  }
  let waiter = {
    deadline: self.now + milliseconds.to_int64(),
    requested: milliseconds,
    seq: self.next_seq,
    fired: false,
    cond: @cond_var.Cond(),
  }
  self.next_seq += 1
  self.waiters.push(waiter)
  defer (if !waiter.fired {
    self.waiters.retain(other => !physical_equal(other, waiter))
  })
  while !waiter.fired {
    waiter.cond.wait()
  }
}

///|
pub impl @clock.Clock for VirtualClock with fn now_unix_ms(self) {
  self.now
}

///|
/// Record progress made outside the clock, such as a fake transport sending a
/// frame, so `settle` keeps waiting while it happens.
pub fn VirtualClock::touch(self : VirtualClock) -> Unit {
  self.progress += 1
}

///|
/// Durations requested by the sleeps still pending, in firing order.
pub fn VirtualClock::pending(self : VirtualClock) -> Array[Int32] {
  self.sorted().map(waiter => waiter.requested)
}

///|
/// The deadline of the earliest pending timer.
pub fn VirtualClock::next_deadline(self : VirtualClock) -> Int64? {
  match self.sorted() {
    [waiter, ..] => Some(waiter.deadline)
    [] => None
  }
}

///|
/// Let ready tasks run until the progress count stays unchanged for
/// `stable_rounds` consecutive scheduler rounds.
pub async fn VirtualClock::settle(
  self : VirtualClock,
  stable_rounds~ : Int32 = 16,
  max_rounds~ : Int32 = 100_000,
) -> Unit raise NoQuiescence {
  let mut last = self.progress
  let mut stable = 0
  for _ in 0..<max_rounds {
    @async.pause()
    if self.progress == last {
      stable += 1
      if stable >= stable_rounds {
        return
      }
    } else {
      last = self.progress
      stable = 0
    }
  } nobreak {
    raise NoQuiescence(rounds=max_rounds)
  }
}

///|
/// Move time forward by `milliseconds`, firing each timer whose deadline it
/// reaches — including timers registered along the way — and settling after
/// each one.
pub async fn VirtualClock::advance(
  self : VirtualClock,
  milliseconds : Int32,
) -> Unit raise NoQuiescence {
  let target = self.now + milliseconds.to_int64()
  self.settle()
  while self.next_due(target) is Some(waiter) {
    self.fire(waiter)
    self.settle()
  }
  self.now = target
}

///|
/// Fire the earliest pending timer, whatever its deadline, and settle.
/// Returns false when no timer is pending.
pub async fn VirtualClock::advance_to_next(
  self : VirtualClock,
) -> Bool raise NoQuiescence {
  self.settle()
  guard self.sorted() is [waiter, ..] else { return false }
  self.fire(waiter)
  self.settle()
  true
}

///|
fn VirtualClock::sorted(self : VirtualClock) -> Array[Waiter] {
  let waiters = self.waiters.copy()
  waiters.sort_by((a, b) => {
    match a.deadline.compare(b.deadline) {
      0 => a.seq.compare(b.seq)
      order => order
    }
  })
  waiters
}

///|
fn VirtualClock::next_due(self : VirtualClock, target : Int64) -> Waiter? {
  match self.sorted() {
    [waiter, ..] if waiter.deadline <= target => Some(waiter)
    _ => None
  }
}

///|
fn VirtualClock::fire(self : VirtualClock, waiter : Waiter) -> Unit {
  self.waiters.retain(other => !physical_equal(other, waiter))
  if waiter.deadline > self.now {
    self.now = waiter.deadline
  }
  waiter.fired = true
  self.progress += 1
  waiter.cond.signal()
}
