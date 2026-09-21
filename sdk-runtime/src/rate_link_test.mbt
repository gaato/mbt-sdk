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

///|
test "parse_link_next handles repeated values comma URLs and relation forms" {
  let headers = @http.Headers::new()
  assert_eq(@runtime.parse_link_next(headers), None)
  headers.append("Link", "<https://api.test/prev>; rel=prev")
  headers.append(
    "link", "<https://api.test/items?a=1,2>; title=\"a,b\"; rel=\"last next\", <https://api.test/other>; rel=last",
  )
  assert_eq(
    @runtime.parse_link_next(headers),
    Some("https://api.test/items?a=1,2"),
  )
  let unquoted = @http.Headers::from_array([
    ("link", "<cursor-1>; REL=next, <cursor-2>; rel=last"),
  ])
  assert_eq(@runtime.parse_link_next(unquoted), Some("cursor-1"))
  let escaped = @http.Headers::from_array([
    (
      "link", "<ignored>; title=\"x\\\";y\"; rel=prev, <chosen>; rel=\"NEXT last\"",
    ),
  ])
  assert_eq(@runtime.parse_link_next(escaped), Some("chosen"))
  assert_eq(
    @runtime.parse_link_next(
      @http.Headers::from_array([("link", "not-a-link; rel=next")]),
    ),
    None,
  )
}
