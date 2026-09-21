///|
test "backoff defaults exponential growth cap and negative attempt" {
  let b = @runtime.Backoff::default()
  assert_eq(b, { base_ms: 500, max_ms: 30000, factor: 2.0, jitter: 0.2, })
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
    assert_eq(b.delay_ms(attempt, 0.5), expected)
  }
  assert_eq(b.delay_ms(0, 0.0), 400)
  assert_eq(b.delay_ms(0, 0.5), 500)
  assert_eq(b.delay_ms(0, 0.999), 599)
  assert_eq(b.delay_ms(2147483647, 0.0), 24000)
  assert_eq(b.delay_ms(2147483647, 0.999), 30000)
  assert_eq(b.delay_ms(0, -2.0), b.delay_ms(0, 0.0))
  assert_eq(b.delay_ms(0, 2.0), 600)
}

///|
test "backoff fractional milliseconds shrinking factors and invalid parameters" {
  let b : @runtime.Backoff = {
    base_ms: 3,
    max_ms: 100,
    factor: 1.5,
    jitter: 0.0,
  }
  assert_eq(b.delay_ms(1, 0.5), 4)
  assert_eq({ ..b, jitter: 0.2, }.delay_ms(1, 0.999), 5)
  assert_eq({ ..b, factor: 0.5, }.delay_ms(2, 0.5), 0)
  assert_eq({ ..b, factor: 0.0, }.delay_ms(0, 0.5), 3)
  assert_eq({ ..b, factor: 0.0, }.delay_ms(1, 0.5), 0)
  assert_eq({ ..b, base_ms: 0, }.delay_ms(2147483647, 0.5), 0)
  assert_eq({ ..b, base_ms: -1, }.delay_ms(1, 0.5), 0)
  assert_eq({ ..b, max_ms: -1, }.delay_ms(1, 0.5), 0)
  assert_eq({ ..b, factor: -1.0, }.delay_ms(1, 0.5), 0)
  assert_eq({ ..b, jitter: -1.0, }.delay_ms(0, 0.0), 3)
  assert_eq({ ..b, jitter: 2.0, }.delay_ms(0, 0.0), 0)
  let huge : @runtime.Backoff = {
    base_ms: 2147483647,
    max_ms: 2147483647,
    factor: 1.0e300,
    jitter: 1.0,
  }
  for attempt in [0, 1, 2147483647] {
    assert_eq(huge.delay_ms(attempt, 0.0), 0)
    assert_eq(huge.delay_ms(attempt, 0.5), 2147483647)
    assert_eq(huge.delay_ms(attempt, 0.999), 2147483647)
  }
  let nan = 0.0 / 0.0
  let infinity = 1.0 / 0.0
  assert_eq(@runtime.Backoff::default().delay_ms(0, nan), 400)
  assert_eq(@runtime.Backoff::default().delay_ms(0, infinity), 600)
  assert_eq(@runtime.Backoff::default().delay_ms(0, -infinity), 400)
  assert_eq({ ..b, factor: nan, }.delay_ms(1, 0.5), 0)
  assert_eq({ ..b, jitter: nan, }.delay_ms(0, 0.5), 3)
  assert_eq({ ..b, factor: infinity, }.delay_ms(2147483647, 0.5), 100)
}
