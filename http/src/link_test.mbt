///|
test "parse_link_next handles repeated values comma URLs and relation forms" {
  let headers = @http.Headers::new()
  assert_eq(@http.parse_link_next(headers), None)
  headers.append("Link", "<https://api.test/prev>; rel=prev")
  headers.append(
    "link", "<https://api.test/items?a=1,2>; title=\"a,b\"; rel=\"last next\", <https://api.test/other>; rel=last",
  )
  assert_eq(
    @http.parse_link_next(headers),
    Some("https://api.test/items?a=1,2"),
  )
  let unquoted = @http.Headers::from_array([
    ("link", "<cursor-1>; REL=next, <cursor-2>; rel=last"),
  ])
  assert_eq(@http.parse_link_next(unquoted), Some("cursor-1"))
  let escaped = @http.Headers::from_array([
    (
      "link", "<ignored>; title=\"x\\\";y\"; rel=prev, <chosen>; rel=\"NEXT last\"",
    ),
  ])
  assert_eq(@http.parse_link_next(escaped), Some("chosen"))
  assert_eq(
    @http.parse_link_next(
      @http.Headers::from_array([("link", "not-a-link; rel=next")]),
    ),
    None,
  )
}

///|
test "only the first rel parameter of a link value counts" {
  // RFC 8288 §3.3: occurrences after the first MUST be ignored.
  let later_next = @http.Headers::from_array([
    ("link", "<skipped>; rel=prev; rel=next, <chosen>; rel=next"),
  ])
  assert_eq(@http.parse_link_next(later_next), Some("chosen"))
  let first_next = @http.Headers::from_array([
    ("link", "<chosen>; title=x; rel=next; rel=prev"),
  ])
  assert_eq(@http.parse_link_next(first_next), Some("chosen"))
}
