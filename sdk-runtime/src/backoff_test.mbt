///|
/// `@runtime.Backoff` is `gaato/http/retry`'s; these are conservative()'s
/// numbers. Integer arithmetic replaced the Double formula in 0.7.0, which
/// moves the top of the jitter range by a millisecond (599 where it was 600).
test "conservative backoff grows exponentially, caps, and jitters ±20 %" {
  let b = @runtime.RetryPolicy::conservative().rule.backoff
  assert_eq(b, {
    base_ms: 500,
    max_ms: 30000,
    jitter: Proportional(lo=800, hi=1200),
  })
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
  assert_eq(b.delay_ms(0, 0.999), 599)
  assert_eq(b.delay_ms(2147483647, 0.0), 24000)
  assert_eq(b.delay_ms(2147483647, 0.999), 30000)
  assert_eq(b.delay_ms(0, -2.0), 400)
  assert_eq(b.delay_ms(0, 2.0), 599)
  let nan = 0.0 / 0.0
  let infinity = 1.0 / 0.0
  assert_eq(b.delay_ms(0, nan), 400)
  assert_eq(b.delay_ms(0, infinity), 599)
  assert_eq(b.delay_ms(0, -infinity), 400)
  let flat : @runtime.Backoff = { base_ms: 3, max_ms: 100, jitter: NoJitter, }
  assert_eq(flat.delay_ms(1, 0.5), 6)
  assert_eq({ ..flat, base_ms: 0, }.delay_ms(2147483647, 0.5), 0)
  assert_eq({ ..flat, max_ms: -1, }.delay_ms(1, 0.5), 0)
}
