///|
test "phase_budget takes the phase's limit unless the exchange ends first" {
  let rows : Array[(Int32, Int64?, (Int32, Int32))] = [
    // A stream's body read has no exchange deadline.
    (400, None, (400, 400)),
    (400, Some(5000L), (400, 400)),
    // On a tie the phase's own limit is the one reported.
    (400, Some(400L), (400, 400)),
    (400, Some(399L), (399, 5000)),
    (400, Some(0L), (0, 5000)),
    (400, Some(-20L), (0, 5000)),
    // A nonpositive limit has run out before the phase starts.
    (0, Some(5000L), (0, 0)),
    (-1, None, (-1, -1)),
  ]
  for row in rows {
    let (limit, remaining, expected) = row
    assert_eq(phase_budget(limit, total=5000, remaining~), expected)
  }
}

///|
test "Timeouts gives the head and body the read limit" {
  let limits = { total: 1, pool: 2, connect: 3, write: 4, read: 5, }
  let phases : Array[@http.Phase] = [Pool, Dial, Write, Head, Body, Unknown]
  assert_eq(phases.map(phase => limits.of(phase)), [2, 3, 4, 5, 5, 5])
  let uniform = Timeouts::uniform(7)
  assert_eq(phases.map(phase => uniform.of(phase)), [7, 7, 7, 7, 7, 7])
  assert_eq(uniform.total, 7)
}

///|
/// Runs `steps` in order on `timer`, each sleeping its duration on `clock`,
/// and labels the outcome with the virtual time it was reached at.
async fn run_steps(
  clock : @simclock.VirtualClock,
  timer : PhaseTimer,
  steps : Array[(@http.Phase, Int32)],
) -> String {
  let outcome = Ref("pending")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let label = try {
        for step in steps {
          let (phase, ms) = step
          timer.run(phase, () => clock.sleep(ms))
        }
        "done"
      } catch {
        error => @debug.to_string(error)
      }
      outcome.val = "\{label} at \{clock.now_unix_ms()}"
    })
    clock.advance(1_000_000)
  })
  outcome.val
}

///|
/// `Timeout` as the timer reports it for `phase` on this platform.
fn timeout_label(phase : @http.Phase, ms : Int32, at : Int32) -> String {
  let error = @http.HttpError::Timeout(phase=reported_phase(phase), ms~)
  "\{@debug.to_string(error)} at \{at}"
}

///|
async test "each phase times out at its own limit" {
  let limits = { total: 10000, pool: 100, connect: 200, write: 300, read: 400, }
  let rows : Array[(@http.Phase, Int32)] = [
    (Pool, 100),
    (Dial, 200),
    (Write, 300),
    (Head, 400),
    (Body, 400),
  ]
  for row in rows {
    let (phase, limit) = row
    let clock = @simclock.VirtualClock(start_ms=0)
    let timer = PhaseTimer::exchange(clock, limits)
    assert_eq(
      run_steps(clock, timer, [(phase, limit + 1)]),
      timeout_label(phase, limit, limit),
    )
    // A phase that finishes on its last millisecond succeeds.
    let clock = @simclock.VirtualClock(start_ms=0)
    let timer = PhaseTimer::exchange(clock, limits)
    assert_eq(
      run_steps(clock, timer, [(phase, limit - 1)]),
      "done at \{limit - 1}",
    )
  }
}

///|
async test "the exchange deadline cuts the phase in progress short" {
  // Each phase alone fits its 600 ms, but the exchange has 1000 ms in all:
  // the write that starts at 500 ms is cut at 1000 ms and reports the total.
  let limits = { total: 1000, pool: 600, connect: 600, write: 600, read: 600, }
  let clock = @simclock.VirtualClock(start_ms=0)
  let timer = PhaseTimer::exchange(clock, limits)
  assert_eq(
    run_steps(clock, timer, [(Dial, 500), (Write, 5000)]),
    timeout_label(Write, 1000, 1000),
  )
  // Body reads of a buffered exchange share the deadline...
  let clock = @simclock.VirtualClock(start_ms=0)
  let timer = PhaseTimer::exchange(clock, limits)
  assert_eq(
    run_steps(clock, timer, [(Head, 300), (Body, 500), (Body, 500)]),
    timeout_label(Body, 1000, 1000),
  )
  // ...while each read of a stream gets the read limit afresh.
  let clock = @simclock.VirtualClock(start_ms=0)
  let timer = PhaseTimer::stream(clock, limits)
  assert_eq(
    run_steps(clock, timer, [(Body, 500), (Body, 500), (Body, 500)]),
    "done at 1500",
  )
  let clock = @simclock.VirtualClock(start_ms=0)
  let timer = PhaseTimer::stream(clock, limits)
  assert_eq(
    run_steps(clock, timer, [(Body, 500), (Body, 700)]),
    timeout_label(Body, 600, 1100),
  )
}

///|
async test "a spent limit raises without starting the phase" {
  for total in [0, -1] {
    let clock = @simclock.VirtualClock(start_ms=0)
    let timer = PhaseTimer::exchange(clock, Timeouts::uniform(total))
    let mut started = false
    let outcome = try timer.run(Dial, () => started = true) catch {
      error => @debug.to_string(error)
    } noraise {
      _ => "ran"
    }
    assert_eq(outcome, "Timeout(phase=Dial, ms=\{total})")
    assert_false(started)
  }
}

///|
async test "a phase's failure becomes an HttpError of that phase" {
  let clock = @simclock.VirtualClock(start_ms=0)
  let timer = PhaseTimer::exchange(clock, Timeouts::uniform(1000))
  let rows : Array[(@http.Phase, String)] = [
    (Dial, "Connect(\"down\")"),
    (Write, "Network(phase=Write, message=\"down\")"),
    (Body, "Network(phase=Body, message=\"down\")"),
  ]
  for row in rows {
    let (phase, expected) = row
    let step : async () -> Unit = () => raise Broken("down")
    let outcome = try timer.run(phase, step) catch {
      error => @debug.to_string(error)
    } noraise {
      _ => "ran"
    }
    assert_eq(outcome, expected)
  }
  assert_eq(clock.pending(), [], msg="every phase timer is cancelled")
}
