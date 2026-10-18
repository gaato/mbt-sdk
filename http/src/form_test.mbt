///|
test "form_urlencode follows the WHATWG urlencoded serializer" {
  // Expected strings are what `new URLSearchParams(pairs).toString()` gives.
  let rows : Array[(String, Array[(String, String)], String)] = [
    ("no pairs", [], ""),
    ("empty name and value", [("", "")], "="),
    (
      "order and repetition are kept",
      [("b", "1"), ("a", "2"), ("b", "3")],
      "b=1&a=2&b=3",
    ),
    ("space is a plus", [("a b", " c ")], "a+b=+c+"),
    ("a literal plus is encoded", [("x", "1+1")], "x=1%2B1"),
    ("the bytes left as they are", [("AZaz09", "*-._")], "AZaz09=*-._"),
    ("tilde is encoded, unlike in percent_encode", [("t", "~")], "t=%7E"),
    (
      "separators inside names and values",
      [("a&b=c", "d=e&f")],
      "a%26b%3Dc=d%3De%26f",
    ),
    (
      "reserved and sub-delimiters",
      [("r", ":/?#[]@!$'(),;")],
      "r=%3A%2F%3F%23%5B%5D%40%21%24%27%28%29%2C%3B",
    ),
    ("percent, quote and backslash", [("p", "%\"\\")], "p=%25%22%5C"),
    (
      "control characters and newlines",
      [("c", "\t\r\n\u{7f}")],
      "c=%09%0D%0A%7F",
    ),
    ("two-byte UTF-8", [("é", "ü")], "%C3%A9=%C3%BC"),
    ("three-byte UTF-8", [("q", "日本語")], "q=%E6%97%A5%E6%9C%AC%E8%AA%9E"),
    ("astral character", [("e", "😀")], "e=%F0%9F%98%80"),
  ]
  for row in rows {
    let (label, pairs, expected) = row
    assert_eq(@http.form_urlencode(pairs), expected, msg=label)
  }
}

///|
test "form_urlencode writes a lone surrogate as U+FFFD" {
  let unit = (code : Int32) => code.unsafe_to_char()
  let rows : Array[(String, Array[Char], String)] = [
    ("high surrogate at the end", ['a', unit(0xD800)], "a%EF%BF%BD"),
    ("low surrogate alone", [unit(0xDC00), 'b'], "%EF%BF%BDb"),
    (
      "pair in the wrong order",
      [unit(0xDE00), unit(0xD83D)],
      "%EF%BF%BD%EF%BF%BD",
    ),
    ("high surrogate before a BMP character", [unit(0xD83D), 'c'], "%EF%BF%BDc"),
    ("a valid pair", [unit(0xD83D), unit(0xDE00)], "%F0%9F%98%80"),
  ]
  for row in rows {
    let (label, units, expected) = row
    assert_eq(
      @http.form_urlencode([("s", String::from_array(units))]),
      "s=" + expected,
      msg=label,
    )
  }
}

///|
test "form_body sets the body and a default content type" {
  let request = @http.Request::post("/token").form_body([
    ("grant_type", "client_credentials"),
    ("scope", "read write"),
  ])
  assert_eq(
    request.body,
    Bytes(b"grant_type=client_credentials&scope=read+write"),
  )
  assert_eq(
    request.headers.get("content-type"),
    Some("application/x-www-form-urlencoded"),
  )
  let kept = @http.Request::post("/token")
    .header("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
    .form_body([("a", "b")])
  assert_eq(kept.headers.get_all("content-type"), [
    "application/x-www-form-urlencoded; charset=utf-8",
  ])
}
