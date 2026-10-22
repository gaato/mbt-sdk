///|
async test "semaphore gate respects permit count" {
  for permits in [1, 2] {
    let gate = @http_async.SemaphoreGate::new(permits~)
    let active = Ref(0)
    let peak = Ref(0)
    @async.with_task_group(group => {
      for _ in 0..<2 {
        group.spawn_bg(() => {
          gate.acquire()
          defer gate.release()
          active.val += 1
          peak.val = peak.val.max(active.val)
          @async.sleep(10)
          active.val -= 1
        })
      }
    })
    assert_eq(peak.val, permits)
    assert_eq(active.val, 0)
  }
}

///|
async test "cancelled gate waiter consumes no slot" {
  let gate = @http_async.SemaphoreGate::new()
  gate.acquire()
  let acquired = Ref(false)
  @async.with_task_group(group => {
    let waiter = group.spawn(
      () => {
        gate.acquire()
        defer gate.release()
        acquired.val = true
      },
      allow_failure=true,
    )
    @async.sleep(10)
    waiter.cancel()
    waiter.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      other => raise other
    }
  })
  assert_false(acquired.val)
  gate.release()
  @async.with_timeout(100, () => gate.acquire())
  gate.release()
}
