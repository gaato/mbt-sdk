///|
async test "WindowLimiter sleeps to reset and removes the expired state" {
  bounded(() => {
    let clock = @mock.FakeClock::new(start_unix_ms=1000L)
    let limiter = @runtime.WindowLimiter::new(
      clock,
      @runtime.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
    )
    limiter.release(
      "bucket",
      status=200,
      headers=@http.Headers::from_array([
        ("remaining", "0"),
        ("reset-after", "2"),
      ]),
    )
    limiter.acquire("bucket", global_exempt=false)
    assert_eq(clock.slept(), [2000])
    assert_eq(clock.now_unix_ms(), 3000L)
    assert_eq(limiter.state("bucket"), None)
  })
}

///|
async test "WindowLimiter gives 429 Retry-After precedence" {
  bounded(() => {
    let clock = @mock.FakeClock::new(start_unix_ms=1000L)
    let limiter = @runtime.WindowLimiter::new(
      clock,
      @runtime.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
    )
    limiter.release(
      "bucket",
      status=429,
      headers=@http.Headers::from_array([
        ("remaining", "5"),
        ("reset-after", "100"),
        ("retry-after", "1.5"),
      ]),
    )
    assert_eq(
      limiter.state("bucket"),
      Some({ remaining: 0, reset_at_unix_ms: 2500L, }),
    )
    limiter.acquire("bucket", global_exempt=false)
    assert_eq(clock.slept(), [1500])
    assert_eq(limiter.state("bucket"), None)
  })
}

///|
async test "WindowLimiter buckets are independent and remaining is consumed" {
  bounded(() => {
    let clock = @mock.FakeClock::new(start_unix_ms=1000L)
    let limiter = @runtime.WindowLimiter::new(
      clock,
      @runtime.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
    )
    limiter.release(
      "blocked",
      status=200,
      headers=@http.Headers::from_array([
        ("remaining", "0"),
        ("reset-after", "2"),
      ]),
    )
    limiter.release(
      "open",
      status=200,
      headers=@http.Headers::from_array([
        ("remaining", "2"),
        ("reset-after", "5"),
      ]),
    )
    limiter.acquire("open", global_exempt=false)
    assert_eq(clock.slept(), [])
    assert_eq(
      limiter.state("open"),
      Some({ remaining: 1, reset_at_unix_ms: 6000L, }),
    )
    assert_eq(
      limiter.state("blocked"),
      Some({ remaining: 0, reset_at_unix_ms: 3000L, }),
    )
    limiter.acquire("blocked", global_exempt=false)
    assert_eq(clock.slept(), [2000])
    assert_eq(
      limiter.state("open"),
      Some({ remaining: 1, reset_at_unix_ms: 6000L, }),
    )
  })
}

///|
async test "WindowLimiter ignores a release without a response" {
  bounded(() => {
    let clock = @mock.FakeClock::new(start_unix_ms=1000L)
    let limiter = @runtime.WindowLimiter::new(
      clock,
      @runtime.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
    )
    limiter.release(
      "bucket",
      status=200,
      headers=@http.Headers::from_array([
        ("remaining", "3"),
        ("reset-after", "5"),
      ]),
    )
    limiter.release("bucket", status=0, headers=@http.Headers::new())
    assert_eq(
      limiter.state("bucket"),
      Some({ remaining: 3, reset_at_unix_ms: 6000L, }),
    )
    limiter.acquire("bucket", global_exempt=true)
    assert_eq(clock.slept(), [])
    assert_eq(
      limiter.state("bucket"),
      Some({ remaining: 2, reset_at_unix_ms: 6000L, }),
    )
  })
}
