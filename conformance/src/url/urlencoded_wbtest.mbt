///|
/// web-platform-tests' url/urlencoded-parser.any.js (see NOTICE), as
/// `(input, pairs)` rows. Each input is read as the query of a URL.
let urlencoded_rows : Array[(String, Array[(String, String)])] = [
  ("test", [("test", "")]),
  ("\u{FEFF}test=\u{FEFF}", [("\u{FEFF}test", "\u{FEFF}")]),
  ("%EF%BB%BFtest=%EF%BB%BF", [("\u{FEFF}test", "\u{FEFF}")]),
  ("%EF%BF%BF=%EF%BF%BF", [("\u{FFFF}", "\u{FFFF}")]),
  ("%FE%FF", [("\u{FFFD}\u{FFFD}", "")]),
  ("%FF%FE", [("\u{FFFD}\u{FFFD}", "")]),
  ("†&†=x", [("†", ""), ("†", "x")]),
  ("%C2", [("\u{FFFD}", "")]),
  ("%C2x", [("\u{FFFD}x", "")]),
  (
    "_charset_=windows-1252&test=%C2x",
    [("_charset_", "windows-1252"), ("test", "\u{FFFD}x")],
  ),
  ("", []),
  ("a", [("a", "")]),
  ("a=b", [("a", "b")]),
  ("a=", [("a", "")]),
  ("=b", [("", "b")]),
  ("&", []),
  ("&a", [("a", "")]),
  ("a&", [("a", "")]),
  ("a&a", [("a", ""), ("a", "")]),
  ("a&b&c", [("a", ""), ("b", ""), ("c", "")]),
  ("a=b&c=d", [("a", "b"), ("c", "d")]),
  ("a=b&c=d&", [("a", "b"), ("c", "d")]),
  ("&&&a=b&&&&c=d&", [("a", "b"), ("c", "d")]),
  ("a=a&a=b&a=c", [("a", "a"), ("a", "b"), ("a", "c")]),
  ("a==a", [("a", "=a")]),
  ("a=a+b+c+d", [("a", "a b c d")]),
  ("%=a", [("%", "a")]),
  ("%a=a", [("%a", "a")]),
  ("%a_=a", [("%a_", "a")]),
  ("%61=a", [("a", "a")]),
  ("%61+%4d%4D=", [("a MM", "")]),
  ("id=0&value=%", [("id", "0"), ("value", "%")]),
  ("b=%2sf%2a", [("b", "%2sf*")]),
  ("b=%2%2af%2a", [("b", "%2*f*")]),
  ("b=%%2a", [("b", "%*")]),
]

///|
test "query_params decodes as WHATWG's urlencoded parser does" {
  for row in urlencoded_rows {
    let (input, expected) = row
    let url = @http.Url::parse("http://h/?" + input)
    assert_eq(url.query_params(), expected, msg=Repr(input).to_string())
  }
}
