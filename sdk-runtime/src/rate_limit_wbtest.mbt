// This package has no async runtime, so these tests drive the limiter with the
// compiler's coroutine primitives: a task runs until it suspends, and a test
// resumes it by hand. That is enough to hold a gate, queue on it and cancel.

///|
fn run_coroutine(f : async () -> Unit noraise + nocancel) = "%async.run"

///|
async fn[T] suspend_coroutine(
  register : ((T) -> Unit) -> Unit,
) -> T noraise + nocancel = "%async.suspend"

///|
async fn[X] raise_cancellation() -> X noraise = "%async.raise_cancellation_signal"

///|
async fn[X] catch_cancellation(
  f : async () -> X,
  handler~ : async () -> X nocancel,
) -> X nocancel = "%async.capture_cancellation"

///|
priv enum TaskState {
  Running
  Done
  Cancelled
  Failed(Error)
}

///|
priv struct Task {
  mut state : TaskState
}

///|
/// Runs `f` until it finishes or first suspends.
fn spawn(f : async () -> Unit) -> Task {
  let task = { state: Running, }
  run_coroutine(() => {
    try catch_cancellation(f, handler=() => task.state = Cancelled) catch {
      error => task.state = Failed(error)
    } noraise {
      _ => if task.state is Running { task.state = Done }
    }
  })
  task
}

///|
fn Task::is_done(self : Task) -> Bool {
  self.state is Done
}

///|
/// Runs `f` and requires it to finish without suspending.
fn run_now(f : async () -> Unit) -> Unit raise {
  let task = spawn(f)
  match task.state {
    Done => ()
    Running => fail("task suspended")
    Cancelled => fail("task was cancelled")
    Failed(error) => raise error
  }
}

///|
/// A one-slot gate whose queued waiters resume only when the test says so,
/// as a scheduler would run them after the releasing task yields.
priv struct TestGate {
  mut free : Bool
  waiters : Array[(Bool) -> Unit]
  woken : Array[(Bool) -> Unit]
}

///|
fn TestGate::new() -> TestGate {
  { free: true, waiters: [], woken: [], }
}

///|
impl @sync.Gate for TestGate with fn acquire(self) {
  if self.free {
    self.free = false
    return
  }
  let admitted : Bool = suspend_coroutine(wake => self.waiters.push(wake))
  if !admitted {
    raise_cancellation()
  }
}

///|
impl @sync.Gate for TestGate with fn release(self) {
  if self.waiters.is_empty() {
    assert_false(self.free) catch {
      _ => abort("gate released twice")
    }
    self.free = true
  } else {
    self.woken.push(self.waiters.remove(0))
  }
}

///|
/// Resumes every waiter that a release handed the slot to.
fn TestGate::run_woken(self : TestGate) -> Unit {
  while !self.woken.is_empty() {
    self.woken.remove(0)(true)
  }
}

///|
/// Cancels the oldest queued waiter, as a runtime would while it is parked.
fn TestGate::cancel_oldest(self : TestGate) -> Unit {
  self.waiters.remove(0)(false)
}

///|
fn counts(limiter : WindowLimiter, bucket : String) -> (Int32, Int32)? {
  limiter.gates.get(bucket).map(entry => (entry.holders, entry.waiters))
}

///|
fn headers(remaining : String, reset_after : String) -> @http.Headers {
  @http.Headers::from_array([
    ("remaining", remaining),
    ("reset-after", reset_after),
  ])
}

///|
fn gated_limiter(
  clock : @mock.FakeClock,
  made : Array[TestGate],
) -> WindowLimiter {
  WindowLimiter::new(
    clock,
    rate_limit_headers(remaining="remaining", reset_after_seconds="reset-after"),
    gate=() => {
      let gate = TestGate::new()
      made.push(gate)
      gate
    },
  )
}

///|
test "one-off buckets leave no gates and only unexpired states behind" {
  let clock = @mock.FakeClock::new(start_unix_ms=1000L)
  let made = []
  let limiter = gated_limiter(clock, made)
  let mut largest = 0
  for i in 0..<10000 {
    let bucket = "token-\{i}"
    run_now(() => {
      limiter.acquire(bucket, global_exempt=true)
      limiter.release(bucket, status=200, headers=headers("4", "0.05"))
    })
    clock.advance(1)
    largest = largest.max(limiter.states.length())
  }
  assert_eq(made.length(), 10000)
  assert_eq(limiter.gates.length(), 0)
  // About 50 states are live at once (50 ms resets, 1 ms apart); sweeps let
  // the map reach at most twice the floor.
  assert_true(largest <= 2 * states_sweep_floor)
}

///|
test "a released gate admits the next caller before it is forgotten" {
  let clock = @mock.FakeClock::new(start_unix_ms=1000L)
  let made = []
  let limiter = gated_limiter(clock, made)
  let order = []
  run_now(() => limiter.acquire("a", global_exempt=true))
  let second = spawn(() => {
    limiter.acquire("a", global_exempt=true)
    order.push("second admitted")
  })
  assert_false(second.is_done())
  assert_eq(counts(limiter, "a"), Some((1, 1)))
  run_now(() => {
    limiter.release("a", status=200, headers=headers("4", "1"))
    order.push("first released")
  })
  // The slot passed to the waiter, so the entry stays until it resumes.
  assert_eq(counts(limiter, "a"), Some((0, 1)))
  assert_false(second.is_done())
  made[0].run_woken()
  assert_true(second.is_done())
  assert_eq(order, ["first released", "second admitted"])
  assert_eq(counts(limiter, "a"), Some((1, 0)))
  run_now(() => limiter.release("a", status=0, headers=@http.Headers::new()))
  assert_eq(counts(limiter, "a"), None)
  assert_true(made[0].free)
  // A later caller gets a fresh gate that serializes the bucket again.
  run_now(() => limiter.acquire("a", global_exempt=true))
  let third = spawn(() => limiter.acquire("a", global_exempt=true))
  assert_eq(made.length(), 2)
  assert_false(third.is_done())
  run_now(() => limiter.release("a", status=0, headers=@http.Headers::new()))
  made[1].run_woken()
  assert_true(third.is_done())
  run_now(() => limiter.release("a", status=0, headers=@http.Headers::new()))
  assert_eq(limiter.gates.length(), 0)
}

///|
test "a cancelled waiter leaves the holder's gate intact and nothing behind" {
  let clock = @mock.FakeClock::new(start_unix_ms=1000L)
  let made = []
  let limiter = gated_limiter(clock, made)
  run_now(() => limiter.acquire("a", global_exempt=true))
  let cancelled = spawn(() => limiter.acquire("a", global_exempt=true))
  made[0].cancel_oldest()
  assert_true(cancelled.state is Cancelled)
  assert_eq(counts(limiter, "a"), Some((1, 0)))
  // The holder still owns the gate: a newcomer queues on it, not a new one.
  let next = spawn(() => limiter.acquire("a", global_exempt=true))
  assert_eq(made.length(), 1)
  assert_false(next.is_done())
  let last = spawn(() => limiter.acquire("a", global_exempt=true))
  assert_eq(counts(limiter, "a"), Some((1, 2)))
  made[0].cancel_oldest()
  assert_true(next.state is Cancelled)
  run_now(() => limiter.release("a", status=0, headers=@http.Headers::new()))
  made[0].run_woken()
  assert_true(last.is_done())
  assert_eq(counts(limiter, "a"), Some((1, 0)))
  run_now(() => limiter.release("a", status=0, headers=@http.Headers::new()))
  assert_eq(limiter.gates.length(), 0)
  assert_true(made[0].free)
  assert_true(made[0].waiters.is_empty())
}

///|
test "a sweep keeps states whose reset is still ahead" {
  let clock = @mock.FakeClock::new(start_unix_ms=1000L)
  let limiter = WindowLimiter::new(
    clock,
    rate_limit_headers(remaining="remaining", reset_after_seconds="reset-after"),
  )
  run_now(() => {
    limiter.release("live", status=200, headers=headers("0", "60"))
    for i in 1..<states_sweep_floor {
      limiter.release("old-\{i}", status=200, headers=headers("1", "0.001"))
      clock.advance(1)
    }
  })
  // Every old state has expired, but none is dropped below the floor.
  assert_eq(limiter.states.length(), states_sweep_floor)
  assert_true(limiter.state("old-1") is Some(_))
  run_now(() => limiter.release("new", status=200, headers=headers("1", "1")))
  assert_eq(limiter.states.length(), 2)
  assert_eq(
    limiter.state("live"),
    Some({ remaining: 0, reset_at_unix_ms: 61000L, }),
  )
  assert_eq(
    limiter.state("new"),
    Some({ remaining: 1, reset_at_unix_ms: 2063L, }),
  )
  assert_eq(limiter.state("old-1"), None)
  assert_eq(limiter.states_sweep_at, states_sweep_floor)
}

///|
test "a burst's expired states go once traffic settles on one bucket" {
  let clock = @mock.FakeClock::new(start_unix_ms=0L)
  let limiter = WindowLimiter::new(
    clock,
    rate_limit_headers(remaining="remaining", reset_after_seconds="reset-after"),
  )
  run_now(() => {
    for i in 0..<100 {
      limiter.release("burst-\{i}", status=200, headers=headers("1", "1"))
    }
  })
  // The doubling sweep at 64 kept the 64 live states, so the next one waits
  // for 128 entries, which steady traffic on one bucket never reaches.
  assert_true(limiter.states.length() >= 64)
  run_now(() => {
    for _ in 0..<120 {
      clock.advance(1000)
      limiter.release("steady", status=200, headers=headers("1", "1"))
    }
  })
  assert_eq(limiter.states.length(), 1)
  assert_true(limiter.state("steady") is Some(_))
}

///|
test "responses without rate-limit headers still sweep expired states" {
  let clock = @mock.FakeClock::new(start_unix_ms=0L)
  let limiter = WindowLimiter::new(
    clock,
    rate_limit_headers(remaining="remaining", reset_after_seconds="reset-after"),
  )
  run_now(() => {
    for i in 0..<50 {
      limiter.release("burst-\{i}", status=200, headers=headers("1", "1"))
    }
    clock.advance(61_000)
    limiter.release("plain", status=200, headers=@http.Headers::new())
  })
  assert_eq(limiter.states.length(), 0)
}

///|
test "a response cannot push a bucket's reset or the global block past an hour" {
  let hour = 3_600_000L
  let rows : Array[(String, Int32, Array[(String, String)], Int64)] = [
    (
      "relative reset ahead",
      200,
      [("remaining", "0"), ("reset-after", "60")],
      61_000L,
    ),
    (
      "relative reset at the cap",
      200,
      [("remaining", "0"), ("reset-after", "3600")],
      1000L + hour,
    ),
    (
      "relative reset past the cap",
      200,
      [("remaining", "0"), ("reset-after", "3600.001")],
      1000L + hour,
    ),
    (
      "relative reset that saturates",
      200,
      [("remaining", "0"), ("reset-after", "99999999999999999999999")],
      1000L + hour,
    ),
    (
      "absolute reset in a thousand years",
      200,
      [("remaining", "0"), ("reset", "33000000000")],
      1000L + hour,
    ),
    (
      "absolute reset behind the clock",
      200,
      [("remaining", "0"), ("reset", "0.5")],
      500L,
    ),
    ("retry-after within the cap", 429, [("retry-after", "30")], 31_000L),
    ("retry-after past the cap", 429, [("retry-after", "86400")], 1000L + hour),
    (
      "retry-after-ms that saturates",
      429,
      [("retry-after-ms", "99999999999")],
      1000L + hour,
    ),
  ]
  for row in rows {
    let (label, status, pairs, expected) = row
    let clock = @mock.FakeClock::new(start_unix_ms=1000L)
    let limiter = WindowLimiter::new(
      clock,
      rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
        reset_unix_seconds="reset",
      ),
    )
    run_now(() => {
      limiter.release("a", status~, headers=@http.Headers::from_array(pairs))
    })
    assert_eq(
      limiter.state("a").map(state => state.reset_at_unix_ms),
      Some(expected),
      msg=label,
    )
    // The next acquisition waits out at most the cap.
    run_now(() => limiter.acquire("a", global_exempt=true))
    let waited = clock.slept().fold(init=0L, (sum, ms) => sum + ms.to_int64())
    assert_true(waited <= hour, msg="\{label}: waited \{waited}")
  }
}

///|
test "an account-wide 429 cannot block past an hour" {
  let clock = @mock.FakeClock::new(start_unix_ms=1000L)
  let limiter = WindowLimiter::new(clock, (_, _) => None, global_block=_ => true)
  run_now(() => {
    limiter.release(
      "a",
      status=429,
      headers=@http.Headers::from_array([("retry-after", "2000000")]),
    )
  })
  assert_eq(limiter.global_blocked_until, Some(1000L + 3_600_000L))
}

///|
test "clamp_server_reset keeps resets within an hour and pulls later ones back" {
  let max_ms = 9223372036854775807L
  let rows : Array[(String, Int64, Int64, Int64)] = [
    ("reset behind the clock", 1000L, 0L, 0L),
    ("reset just ahead", 1000L, 1001L, 1001L),
    ("reset at the horizon", 1000L, 3_601_000L, 3_601_000L),
    ("reset one past the horizon", 1000L, 3_601_001L, 3_601_000L),
    ("saturated reset", 1000L, max_ms, 3_601_000L),
    ("negative clock", -5000L, max_ms, 3_595_000L),
    ("horizon that saturates", max_ms - 10L, max_ms, max_ms),
  ]
  for row in rows {
    let (label, now, reset, expected) = row
    let state = clamp_server_reset(
      { remaining: 3, reset_at_unix_ms: reset, },
      now,
    )
    assert_eq(state.remaining, 3, msg="\{label}: remaining")
    assert_eq(state.reset_at_unix_ms, expected, msg=label)
  }
}
