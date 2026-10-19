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

///|
/// A clock whose sleeps park the task until the test moves time past them.
priv struct ParkingClock {
  mut now : Int64
  sleepers : Array[(Int64, () -> Unit)]
}

///|
fn ParkingClock::new(now : Int64) -> ParkingClock {
  { now, sleepers: [], }
}

///|
impl @clock.Clock for ParkingClock with fn sleep(self, milliseconds) {
  let until = self.now + milliseconds.to_int64()
  suspend_coroutine(wake => self.sleepers.push((until, () => wake(()))))
}

///|
impl @clock.Clock for ParkingClock with fn now_unix_ms(self) {
  self.now
}

///|
/// Moves time to `now` and resumes, oldest first, every sleep that has ended.
fn ParkingClock::advance_to(self : ParkingClock, now : Int64) -> Unit {
  self.now = now
  let due = []
  let rest = []
  for sleeper in self.sleepers {
    if sleeper.0 <= now {
      due.push(sleeper.1)
    } else {
      rest.push(sleeper)
    }
  }
  self.sleepers.clear()
  self.sleepers.append(rest)
  for wake in due {
    wake()
  }
}

///|
/// Paces buckets named `write:*` as one group with a one-second interval;
/// every other bucket is its own unpaced group.
fn write_pace(bucket : String) -> Pace {
  if bucket.has_prefix("write:") {
    { group: "write", min_interval_ms: 1000, }
  } else {
    { group: bucket, min_interval_ms: 0, }
  }
}

///|
fn keyed_headers(
  key : String,
  remaining : String,
  reset_after : String,
) -> @http.Headers {
  @http.Headers::from_array([
    ("key", key),
    ("remaining", remaining),
    ("reset-after", reset_after),
  ])
}

///|
fn header_key(_bucket : String, headers : @http.Headers) -> String? {
  headers.get("key")
}

///|
test "two tasks woken at one pace deadline are admitted a full interval apart" {
  let clock = ParkingClock::new(1000L)
  let limiter = WindowLimiter::new(clock, (_, _) => None, pace=write_pace)
  let admitted = []
  fn admit(bucket : String) -> Task {
    spawn(() => {
      limiter.acquire(bucket, global_exempt=true)
      admitted.push("\{bucket}@\{clock.now}")
    })
  }

  assert_true(admit("write:a").is_done())
  let second = admit("write:b")
  let third = admit("write:a")
  // Another group is not held back by the paced one.
  assert_true(admit("read").is_done())
  assert_true(admit("read").is_done())
  assert_false(second.is_done())
  assert_false(third.is_done())
  assert_eq(limiter.next_admit_at.get("write"), Some(2000L))
  // Both sleepers wake at 2000; the first takes the slot and the second,
  // checking right after with no suspension in between, waits again.
  clock.advance_to(2000L)
  assert_true(second.is_done())
  assert_false(third.is_done())
  assert_eq(clock.sleepers.map(sleeper => sleeper.0), [3000L])
  clock.advance_to(3000L)
  assert_true(third.is_done())
  assert_eq(admitted, [
    "write:a@1000", "read@1000", "read@1000", "write:b@2000", "write:a@3000",
  ])
  assert_eq(limiter.next_admit_at.get("read"), None)
}

///|
test "a gate is keyed by the pace group, so a learned key cannot leak it" {
  let clock = @mock.FakeClock::new(start_unix_ms=1000L)
  let made = []
  let limiter = WindowLimiter::new(
    clock,
    rate_limit_headers(remaining="remaining", reset_after_seconds="reset-after"),
    gate=() => {
      let gate = TestGate::new()
      made.push(gate)
      gate
    },
    pace=write_pace,
    server_key=header_key,
  )
  run_now(() => limiter.acquire("write:a", global_exempt=true))
  // A second bucket of the same group queues on the same gate.
  let other = spawn(() => limiter.acquire("write:b", global_exempt=true))
  assert_false(other.is_done())
  assert_eq(made.length(), 1)
  assert_eq(counts(limiter, "write"), Some((1, 1)))
  run_now(() => {
    limiter.release(
      "write:a",
      status=200,
      headers=keyed_headers("core", "5", "60"),
    )
  })
  assert_eq(limiter.aliases.get("write:a"), Some("core"))
  made[0].run_woken()
  assert_true(other.is_done())
  run_now(() => {
    limiter.release(
      "write:b",
      status=200,
      headers=keyed_headers("core", "4", "60"),
    )
  })
  assert_eq(limiter.gates.length(), 0)
  assert_true(made[0].free)
  // The second bucket of the group waited out the pace after taking the gate.
  assert_eq(clock.slept(), [1000])
  assert_eq(limiter.states.length(), 1)
  assert_eq(
    limiter.state("write:a"),
    Some({ remaining: 4, reset_at_unix_ms: 62000L, }),
  )
  assert_eq(limiter.state("write:b"), limiter.state("core"))
}

///|
test "a bucket follows the key its latest response names" {
  let clock = @mock.FakeClock::new(start_unix_ms=1000L)
  let limiter = WindowLimiter::new(
    clock,
    rate_limit_headers(remaining="remaining", reset_after_seconds="reset-after"),
    server_key=header_key,
  )
  run_now(() => {
    limiter.release("a", status=200, headers=keyed_headers("k1", "5", "60"))
  })
  assert_eq(limiter.resolve("a"), "k1")
  assert_eq(limiter.resolve("b"), "b")
  // A response without the header keeps the learned key.
  run_now(() => limiter.release("a", status=200, headers=headers("3", "60")))
  assert_eq(limiter.resolve("a"), "k1")
  assert_eq(
    limiter.states.get("k1"),
    Some({ remaining: 3, reset_at_unix_ms: 61000L, }),
  )
  run_now(() => {
    limiter.release("a", status=200, headers=keyed_headers("k2", "7", "60"))
  })
  assert_eq(limiter.resolve("a"), "k2")
  assert_eq(
    limiter.state("a"),
    Some({ remaining: 7, reset_at_unix_ms: 61000L, }),
  )
  // Naming the bucket itself forgets the alias.
  run_now(() => {
    limiter.release("a", status=200, headers=keyed_headers("a", "2", "60"))
  })
  assert_eq(limiter.aliases.get("a"), None)
  assert_eq(
    limiter.state("a"),
    Some({ remaining: 2, reset_at_unix_ms: 61000L, }),
  )
  // A response with no status learns nothing.
  run_now(() => {
    limiter.release("a", status=0, headers=keyed_headers("k3", "1", "60"))
  })
  assert_eq(limiter.aliases.get("a"), None)
}

///|
test "a sweep drops orphaned aliases and pace deadlines already passed" {
  let clock = @mock.FakeClock::new(start_unix_ms=0L)
  let limiter = WindowLimiter::new(
    clock,
    rate_limit_headers(remaining="remaining", reset_after_seconds="reset-after"),
    pace=bucket => { group: bucket, min_interval_ms: 10, },
    server_key=header_key,
  )
  run_now(() => {
    limiter.acquire("paced-old", global_exempt=true)
    limiter.release("paced-old", status=0, headers=@http.Headers::new())
    limiter.release("a", status=200, headers=keyed_headers("k1", "1", "1"))
    limiter.release("b", status=200, headers=keyed_headers("k2", "1", "120"))
  })
  assert_eq(limiter.next_admit_at.length(), 1)
  assert_eq(limiter.aliases.length(), 2)
  clock.advance(61_000)
  run_now(() => {
    limiter.acquire("paced-new", global_exempt=true)
    limiter.release("paced-new", status=200, headers=@http.Headers::new())
  })
  assert_eq(limiter.states.length(), 1)
  assert_true(limiter.states.get("k2") is Some(_))
  assert_eq(limiter.aliases.length(), 1)
  assert_eq(limiter.aliases.get("b"), Some("k2"))
  assert_eq(limiter.next_admit_at.length(), 1)
  assert_eq(limiter.next_admit_at.get("paced-new"), Some(61_010L))
}

///|
test "one-off aliased and paced buckets keep the maps bounded" {
  let clock = @mock.FakeClock::new(start_unix_ms=1000L)
  let limiter = WindowLimiter::new(
    clock,
    rate_limit_headers(remaining="remaining", reset_after_seconds="reset-after"),
    pace=bucket => { group: bucket, min_interval_ms: 1, },
    server_key=header_key,
  )
  let mut largest = 0
  for i in 0..<10000 {
    let bucket = "token-\{i}"
    run_now(() => {
      limiter.acquire(bucket, global_exempt=true)
      limiter.release(
        bucket,
        status=200,
        headers=keyed_headers("key-\{i}", "4", "0.05"),
      )
    })
    clock.advance(1)
    largest = largest.max(limiter.swept_entries())
  }
  // About 50 states and their 50 aliases are live at once, and one pace
  // deadline; sweeps at twice the live count keep the maps under 4 floors.
  assert_true(largest <= 4 * states_sweep_floor)
  assert_true(limiter.aliases.length() <= limiter.states.length())
}

///|
test "scope supersedes global_block, which keeps its old meaning alone" {
  let rows : Array[(String, WindowLimiter, LimitScope)] = [
    (
      "neither",
      WindowLimiter::new(@mock.FakeClock::new(), (_, _) => None),
      Bucket,
    ),
    (
      "global_block alone",
      WindowLimiter::new(@mock.FakeClock::new(), (_, _) => None, global_block=_ => {
        true
      }),
      Global,
    ),
    (
      "global_block that declines",
      WindowLimiter::new(@mock.FakeClock::new(), (_, _) => None, global_block=_ => {
        false
      }),
      Bucket,
    ),
    (
      "scope wins",
      WindowLimiter::new(
        @mock.FakeClock::new(),
        (_, _) => None,
        scope=(_, _) => Shared,
        global_block=_ => true,
      ),
      Shared,
    ),
  ]
  for row in rows {
    let (label, limiter, expected) = row
    assert_eq((limiter.scope)(429, @http.Headers::new()), expected, msg=label)
  }
}
