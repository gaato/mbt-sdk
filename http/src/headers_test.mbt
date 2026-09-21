///|
test "headers normalize names and preserve pair order and multiple values" {
  let input = [("X-A", "one"), ("X-B", "two"), ("x-a", "three")]
  let headers = @http.Headers::from_array(input)
  input.clear()
  assert_eq(headers.length(), 3)
  assert_eq(headers.get("X-A"), Some("one"))
  assert_true(headers.contains("x-B"))
  assert_eq(headers.get("missing"), None)
  assert_eq(headers.get_all("missing"), [])
  assert_eq(headers.get_all("X-a"), ["one", "three"])
  let values = headers.get_all("x-a")
  values.clear()
  assert_eq(headers.get_all("x-a"), ["one", "three"])
  let expected = [("x-a", "one"), ("x-b", "two"), ("x-a", "three")]
  assert_eq(headers.iter().to_array(), expected)
  let visited = []
  headers.each((name, value) => visited.push((name, value)))
  assert_eq(visited, expected)
  assert_eq(headers, @http.Headers::from_array(expected))
  assert_true(headers != @http.Headers::from_array([("X-A", "one")]))
  headers.append("X-B", "four")
  assert_eq(headers.iter().to_array(), [..expected, ("x-b", "four")])
}

///|
test "set replaces all values in place and remove removes all values" {
  let headers = @http.Headers::from_array([
    ("A", "1"),
    ("B", "2"),
    ("a", "3"),
    ("C", "4"),
  ])
  headers.set("a", "replacement")
  assert_eq(headers.iter().to_array(), [
    ("a", "replacement"),
    ("b", "2"),
    ("c", "4"),
  ])
  headers.set("D", "5")
  headers.append("B", "6")
  headers.remove("b")
  headers.remove("missing")
  assert_true(!headers.contains("B"))
  assert_eq(headers.iter().to_array(), [
    ("a", "replacement"),
    ("c", "4"),
    ("d", "5"),
  ])
  let empty = @http.Headers::new()
  assert_eq(empty.length(), 0)
  empty.remove("absent")
  empty.set("NEW", "value")
  assert_eq(empty.get("new"), Some("value"))
}
