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
    limiter.observe(
      "bucket",
      200,
      @http.Headers::from_array([("remaining", "0"), ("reset-after", "2")]),
      1000L,
    )
    limiter.acquire("bucket")
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
    limiter.observe(
      "bucket",
      429,
      @http.Headers::from_array([
        ("remaining", "5"),
        ("reset-after", "100"),
        ("retry-after", "1.5"),
      ]),
      1000L,
    )
    assert_eq(
      limiter.state("bucket"),
      Some({ remaining: 0, reset_at_unix_ms: 2500L, }),
    )
    limiter.acquire("bucket")
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
    limiter.observe(
      "blocked",
      200,
      @http.Headers::from_array([("remaining", "0"), ("reset-after", "2")]),
      1000L,
    )
    limiter.observe(
      "open",
      200,
      @http.Headers::from_array([("remaining", "2"), ("reset-after", "5")]),
      1000L,
    )
    limiter.acquire("open")
    assert_eq(clock.slept(), [])
    assert_eq(
      limiter.state("open"),
      Some({ remaining: 1, reset_at_unix_ms: 6000L, }),
    )
    assert_eq(
      limiter.state("blocked"),
      Some({ remaining: 0, reset_at_unix_ms: 3000L, }),
    )
    limiter.acquire("blocked")
    assert_eq(clock.slept(), [2000])
    assert_eq(
      limiter.state("open"),
      Some({ remaining: 1, reset_at_unix_ms: 6000L, }),
    )
  })
}
