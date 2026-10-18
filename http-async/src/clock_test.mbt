///|
suberror Boom derive(Debug)

///|
async test "with_timeout_opt returns what f produces before the deadline" {
  let clock = @simclock.VirtualClock()
  let release : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let outcome : Ref[Int32??] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      outcome.val = Some(
        @adapter.with_timeout_opt(clock, 100, () => release.get()),
      )
    })
    clock.advance(99)
    assert_eq(outcome.val, None, msg="still waiting at 99 ms")
    release.put(7)
    clock.settle()
    assert_eq(outcome.val, Some(Some(7)))
    assert_eq(clock.pending(), [], msg="the deadline timer is cancelled")
  })
}

///|
async test "with_timeout_opt cancels f when the deadline comes first" {
  let clock = @simclock.VirtualClock()
  let release : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let log : Array[String] = []
  let outcome : Ref[Int32??] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      outcome.val = Some(
        @adapter.with_timeout_opt(clock, 100, () => {
          defer log.push("f exited")
          let value = release.get()
          log.push("f finished")
          value
        }),
      )
    })
    clock.advance(99)
    assert_eq(outcome.val, None, msg="still waiting at 99 ms")
    clock.advance(1)
    assert_eq(outcome.val, Some(None))
    assert_eq(log, ["f exited"])
  })
}

///|
async test "with_timeout_opt with a nonpositive deadline only keeps a ready result" {
  let clock = @simclock.VirtualClock(start_ms=0)
  let never : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  for milliseconds in [0, -5] {
    assert_eq(
      @adapter.with_timeout_opt(clock, milliseconds, () => 7),
      Some(7),
      msg="ready result at \{milliseconds} ms",
    )
    assert_eq(
      @adapter.with_timeout_opt(clock, milliseconds, () => never.get()),
      None,
      msg="waiting f at \{milliseconds} ms",
    )
  }
  assert_eq(clock.now_unix_ms(), 0L, msg="no virtual time passes")
}

///|
async test "with_timeout_opt propagates errors from f" {
  let clock = @simclock.VirtualClock()
  let outcome = try {
    let _ : Int32? = @adapter.with_timeout_opt(clock, 100, () => raise Boom)
    "returned"
  } catch {
    Boom => "Boom"
    error => "unexpected \{Repr(error)}"
  }
  assert_eq(outcome, "Boom")
  assert_eq(clock.pending(), [], msg="the deadline timer is cancelled")
}
