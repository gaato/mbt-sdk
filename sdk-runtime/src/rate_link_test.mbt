///|
test "rate_limit_headers parses relative and absolute decimal seconds" {
  let both = @runtime.rate_limit_headers(
    remaining="x-remaining",
    reset_after_seconds="x-reset-after",
    reset_unix_seconds="x-reset",
  )
  let headers = @http.Headers::from_array([
    ("X-Remaining", " 2 "),
    ("X-Reset-After", "1.2349"),
    ("X-Reset", "99.5"),
  ])
  assert_eq(
    both(headers, 1000L),
    Some({ remaining: 2, reset_at_unix_ms: 2234L, }),
  )
  headers.set("x-reset-after", "bad")
  assert_eq(
    both(headers, 1000L),
    Some({ remaining: 2, reset_at_unix_ms: 99500L, }),
  )
  headers.set("x-remaining", "-1")
  assert_eq(both(headers, 1000L), None)
  headers.set("x-remaining", "2147483648")
  assert_eq(both(headers, 1000L), None)
  headers.set("x-remaining", "2")
  headers.set("x-reset", "6m0s")
  assert_eq(both(headers, 1000L), None)
  let absolute = @runtime.rate_limit_headers(
    remaining="remaining",
    reset_unix_seconds="reset",
  )
  assert_eq(
    absolute(
      @http.Headers::from_array([("remaining", "0"), ("reset", "123.4567")]),
      999L,
    ),
    Some({ remaining: 0, reset_at_unix_ms: 123456L, }),
  )
}
