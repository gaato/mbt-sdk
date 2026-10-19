///|
test "no jitter doubles up to the cap" {
  let b : @retry.Backoff = { base_ms: 100, max_ms: 1000, jitter: NoJitter, }
  for
    (attempt, expected) in [
      (-2147483648, 100),
      (-1, 100),
      (0, 100),
      (1, 200),
      (2, 400),
      (3, 800),
      (4, 1000),
      (30, 1000),
      (31, 1000),
      (2147483647, 1000),
    ] {
    assert_eq(b.delay_ms(attempt, 0.5), expected, msg=attempt.to_string())
  }
}

///|
test "nonpositive parameters give zero" {
  let b : @retry.Backoff = { base_ms: 100, max_ms: 1000, jitter: NoJitter, }
  assert_eq({ ..b, base_ms: 0, }.delay_ms(3, 0.5), 0)
  assert_eq({ ..b, base_ms: -5, }.delay_ms(3, 0.5), 0)
  assert_eq({ ..b, max_ms: 0, }.delay_ms(3, 0.5), 0)
  assert_eq({ ..b, max_ms: -5, }.delay_ms(3, 0.5), 0)
}

///|
test "largest parameters saturate without overflow" {
  let b : @retry.Backoff = {
    base_ms: 2147483647,
    max_ms: 2147483647,
    jitter: NoJitter,
  }
  assert_eq(b.delay_ms(0, 0.5), 2147483647)
  assert_eq(b.delay_ms(30, 0.5), 2147483647)
  assert_eq(b.delay_ms(2147483647, 0.5), 2147483647)
  let wide = { ..b, jitter: Proportional(lo=2147483647, hi=2147483647), }
  assert_eq(wide.delay_ms(2147483647, 0.999), 2147483647)
  let one = { ..b, base_ms: 1, jitter: Proportional(lo=2147483647, hi=0), }
  assert_eq(one.delay_ms(0, 0.0), 2147483)
  // A multiplier below zero gives zero, never a negative delay.
  let negative = { ..b, jitter: Proportional(lo=-2147483648, hi=-1), }
  assert_eq(negative.delay_ms(0, 0.999), 0)
  assert_eq(
    { ..b, jitter: Proportional(lo=-2147483648, hi=2147483647), }.delay_ms(
      0, 0.0,
    ),
    0,
  )
}

///|
test "full jitter stays below the delay" {
  // requesto's default: 1 s base, 30 s cap, full jitter.
  let b : @retry.Backoff = { base_ms: 1000, max_ms: 30000, jitter: Full, }
  assert_eq(b.delay_ms(0, 0.0), 0)
  assert_eq(b.delay_ms(0, 0.5), 500)
  assert_eq(b.delay_ms(0, 0.9999999999999999), 999)
  assert_eq(b.delay_ms(0, 1.0), 999)
  assert_eq(b.delay_ms(0, 7.0), 999)
  assert_eq(b.delay_ms(2, 0.25), 1000)
  assert_eq(b.delay_ms(5, 0.0), 0)
  assert_eq(b.delay_ms(5, 0.999), 29970)
  assert_eq(b.delay_ms(2147483647, 0.5), 15000)
}

///|
test "random is clamped into [0, 1) and NaN is zero" {
  let nan = 0.0 / 0.0
  let full : @retry.Backoff = { base_ms: 1000, max_ms: 30000, jitter: Full, }
  assert_eq(full.delay_ms(0, nan), 0)
  assert_eq(full.delay_ms(0, -2.0), 0)
  let proportional = { ..full, jitter: Proportional(lo=800, hi=1200), }
  assert_eq(proportional.delay_ms(0, nan), 800)
  assert_eq(proportional.delay_ms(0, -2.0), 800)
  assert_eq(proportional.delay_ms(0, 2.0), 1199)
  let none = { ..full, jitter: NoJitter, }
  assert_eq(none.delay_ms(0, nan), 1000)
}

///|
test "sdk-runtime default: 500 ms base, 30 s cap, plus or minus 20 percent" {
  let b : @retry.Backoff = {
    base_ms: 500,
    max_ms: 30000,
    jitter: Proportional(lo=800, hi=1200),
  }
  for
    (attempt, expected) in [
      (-2147483648, 500),
      (-1, 500),
      (0, 500),
      (1, 1000),
      (2, 2000),
      (5, 16000),
      (6, 30000),
      (2147483647, 30000),
    ] {
    assert_eq(b.delay_ms(attempt, 0.5), expected, msg=attempt.to_string())
  }
  assert_eq(b.delay_ms(0, 0.0), 400)
  assert_eq(b.delay_ms(0, 0.999), 599)
  assert_eq(b.delay_ms(2147483647, 0.0), 24000)
  // The jittered delay is capped again, as sdk-runtime's backoff was.
  assert_eq(b.delay_ms(2147483647, 0.999), 30000)
}

///|
test "stainless default: 500 ms base, 8 s cap, up to 25 percent shorter" {
  let b : @retry.Backoff = {
    base_ms: 500,
    max_ms: 8000,
    jitter: Proportional(lo=750, hi=1000),
  }
  assert_eq(b.delay_ms(0, 0.0), 375)
  assert_eq(b.delay_ms(0, 0.9999999999999999), 499)
  assert_eq(b.delay_ms(1, 0.5), 875)
  assert_eq(b.delay_ms(4, 0.5), 7000)
  assert_eq(b.delay_ms(10, 0.0), 6000)
  assert_eq(b.delay_ms(10, 0.9999999999999999), 7992)
}
