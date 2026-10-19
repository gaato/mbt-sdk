///|
async test "ClockTimer reports work that finishes in time" {
  let clock = @simclock.VirtualClock()
  let timer = @adapter.ClockTimer::new(clock~)
  let release : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let got : Ref[Int32?] = Ref(None)
  let outcome : Ref[Bool?] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      outcome.val = Some(
        timer.within(100, () => got.val = Some(release.get() catch { _ => -1 })),
      )
    })
    clock.advance(99)
    assert_eq(outcome.val, None, msg="still waiting at 99 ms")
    release.put(7)
    clock.settle()
    assert_eq(outcome.val, Some(true))
    assert_eq(got.val, Some(7))
    assert_eq(clock.pending(), [], msg="the deadline timer is cancelled")
  })
}

///|
async test "ClockTimer cancels work when time runs out" {
  let clock = @simclock.VirtualClock()
  let timer = @adapter.ClockTimer::new(clock~)
  let never : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let log : Array[String] = []
  let outcome : Ref[Bool?] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      outcome.val = Some(
        timer.within(100, () => {
          defer log.push("f exited")
          let _ = never.get() catch { _ => 0 }
          log.push("f finished")
        }),
      )
    })
    clock.advance(99)
    assert_eq(outcome.val, None, msg="still waiting at 99 ms")
    clock.advance(1)
    assert_eq(outcome.val, Some(false))
    assert_eq(log, ["f exited"])
  })
}

///|
async test "ClockTimer with a nonpositive budget does not start the work" {
  let clock = @simclock.VirtualClock(start_ms=0)
  let timer = @adapter.ClockTimer::new(clock~)
  let started = Ref(false)
  for milliseconds in [0, -5] {
    assert_false(timer.within(milliseconds, () => started.val = true))
  }
  assert_false(started.val)
  assert_eq(clock.now_unix_ms(), 0L, msg="no virtual time passes")
}

///|
async test "ClockTimer works through the trait object" {
  let timer : &@sync.Timer = @adapter.ClockTimer::new(
    clock=@simclock.VirtualClock(),
  )
  let done = Ref(false)
  assert_true(timer.within(10, () => done.val = true))
  assert_true(done.val)
}
