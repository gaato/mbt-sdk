///|
async test "AsyncClock sleeps and reports native wall time within a deadline" {
  @async.with_timeout(2000, () => {
    let clock = @adapter.AsyncClock::new()
    let before = clock.now_unix_ms()
    clock.sleep(5)
    let after = clock.now_unix_ms()
    assert_true(after >= before)
    assert_true(after - before >= 1L)
    assert_true((after - @async.now()).abs() < 1000L)
  })
}
