///|
async test "timers fire in deadline order, ties in registration order" {
  let clock = @mock.VirtualClock(start_ms=0)
  let timer : &@clock.Clock = clock
  let fired : Array[(String, Int64)] = []
  @async.with_task_group(group => {
    for entry in [("late", 30), ("first", 10), ("tie-a", 20), ("tie-b", 20)] {
      let (name, ms) = entry
      group.spawn_bg(() => {
        timer.sleep(ms)
        fired.push((name, clock.now_unix_ms()))
      })
    }
    clock.settle()
    assert_eq(clock.pending(), [10, 20, 20, 30])
    clock.advance(25)
    assert_eq(clock.now_unix_ms(), 25)
    assert_eq(fired, [("first", 10), ("tie-a", 20), ("tie-b", 20)])
    assert_true(clock.advance_to_next())
    assert_false(clock.advance_to_next())
  })
  assert_eq(fired.last(), Some(("late", 30)))
}

///|
async test "advance fires timers registered while it runs" {
  let clock = @mock.VirtualClock(start_ms=0)
  let timer : &@clock.Clock = clock
  let ticks : Array[Int64] = []
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      while true {
        timer.sleep(10)
        ticks.push(clock.now_unix_ms())
      }
    })
    clock.advance(35)
  })
  assert_eq(ticks, [10, 20, 30])
}

///|
async test "a cancelled sleep leaves no timer behind" {
  let clock = @mock.VirtualClock()
  let timer : &@clock.Clock = clock
  @async.with_task_group(group => {
    let task = group.spawn(() => timer.sleep(1000))
    clock.settle()
    assert_eq(clock.pending(), [1000])
    task.cancel()
    clock.settle()
    assert_eq(clock.pending(), [])
  })
}

///|
async test "settle waits out a chain of unobserved queue hops" {
  let clock = @mock.VirtualClock()
  let hops = 8
  let queues : Array[@aqueue.Queue[Int32]] = Array::makei(hops + 1, _ => {
    @aqueue.Queue(kind=Unbounded)
  })
  let delivered : Ref[Int32?] = Ref(None)
  @async.with_task_group(group => {
    for i in 0..<hops {
      group.spawn_bg(no_wait=true, () => {
        while true {
          queues[i + 1].put(queues[i].get() + 1)
        }
      })
    }
    group.spawn_bg(no_wait=true, () => delivered.val = Some(queues[hops].get()))
    clock.settle()
    queues[0].put(0)
    clock.touch()
    clock.settle()
    assert_eq(delivered.val, Some(hops))
  })
}

///|
async test "settle reports a task that never stops making progress" {
  let clock = @mock.VirtualClock()
  let timer : &@clock.Clock = clock
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      while true {
        timer.sleep(0)
      }
    })
    try clock.settle(max_rounds=1000) catch {
      NoQuiescence(rounds~) => assert_eq(rounds, 1000)
    } noraise {
      _ => fail("expected NoQuiescence")
    }
  })
}
