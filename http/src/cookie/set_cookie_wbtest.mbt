///|
/// A one-line rendering of a parse, listing only what was set.
fn parsed(text : String) -> String {
  guard parse_set_cookie(text) is Some(c) else { return "ignored" }
  let out = StringBuilder()
  out.write_string("\{Repr(c.name)}=\{Repr(c.value)}")
  if c.expires_ms is Some(ms) {
    out.write_string(" expires=\{ms}")
  }
  if c.max_age is Some(seconds) {
    out.write_string(" max-age=\{seconds}")
  }
  if c.domain is Some(domain) {
    out.write_string(" domain=\{domain}")
  }
  if c.path is Some(path) {
    out.write_string(" path=\{Repr(path)}")
  }
  if c.secure {
    out.write_string(" secure")
  }
  if c.http_only {
    out.write_string(" httponly")
  }
  if c.same_site is Some(same_site) {
    out.write_string(" samesite=\{Repr(same_site)}")
  }
  out.to_string()
}

///|
test "set-cookie name-value pairs parse leniently, as RFC 6265 section 5.2" {
  let cases = [
    ("SID=31d4d96e407aad42", "\"SID\"=\"31d4d96e407aad42\""),
    ("  foo  =  bar  ", "\"foo\"=\"bar\""),
    ("foo=\tbar\t", "\"foo\"=\"bar\""),
    ("foo=", "\"foo\"=\"\""),
    ("foo=\"bar\"", "\"foo\"=\"\\\"bar\\\"\""),
    ("foo=bar=baz", "\"foo\"=\"bar=baz\""),
    ("foo=bar, baz=qux", "\"foo\"=\"bar, baz=qux\""),
    ("foo = b a r ;", "\"foo\"=\"b a r\""),
    ("f\u{e9}=caf\u{e9}", "\"f\u{e9}\"=\"caf\u{e9}\""),
    // No `=`, an empty name, or a control character: ignored whole.
    ("foo", "ignored"),
    ("foo; bar=baz", "ignored"),
    ("=bar", "ignored"),
    ("  =bar", "ignored"),
    ("=", "ignored"),
    ("", "ignored"),
    ("foo=b\r\nar", "ignored"),
    ("foo=bar; Path=/\n", "ignored"),
    ("foo=b\u{7f}ar", "ignored"),
    ("foo=b\u{0}ar", "ignored"),
  ]
  for case in cases {
    assert_eq(parsed(case.0), case.1, msg=case.0)
  }
}

///|
test "set-cookie attributes parse case-insensitively, the last one winning" {
  let cases = [
    (
      "a=b; Expires=Wed, 09 Jun 2021 10:18:14 GMT", "\"a\"=\"b\" expires=1623233894000",
    ),
    ("a=b; expires=not a date", "\"a\"=\"b\""),
    (
      "a=b; Expires=Wed, 09 Jun 2021 10:18:14 GMT; Expires=bogus", "\"a\"=\"b\" expires=1623233894000",
    ),
    ("a=b; Max-Age=3600", "\"a\"=\"b\" max-age=3600"),
    ("a=b; max-age=0", "\"a\"=\"b\" max-age=0"),
    ("a=b; MAX-AGE=-5", "\"a\"=\"b\" max-age=-5"),
    ("a=b; Max-Age=3600, c=d; Path=/", "\"a\"=\"b\" path=\"/\""),
    ("a=b; Max-Age=+1", "\"a\"=\"b\""),
    ("a=b; Max-Age=-", "\"a\"=\"b\""),
    ("a=b; Max-Age=", "\"a\"=\"b\""),
    ("a=b; Max-Age=1; Max-Age=x", "\"a\"=\"b\" max-age=1"),
    (
      "a=b; Max-Age=99999999999999999999999", "\"a\"=\"b\" max-age=1000000000000000000",
    ),
    ("a=b; Domain=.Example.COM", "\"a\"=\"b\" domain=example.com"),
    ("a=b; Domain=..example.com", "\"a\"=\"b\" domain=.example.com"),
    ("a=b; Domain=example.com; Domain=", "\"a\"=\"b\" domain=example.com"),
    ("a=b; Domain=.", "\"a\"=\"b\""),
    ("a=b; Path=/foo; path=/bar", "\"a\"=\"b\" path=\"/bar\""),
    ("a=b; Path", "\"a\"=\"b\" path=\"\""),
    ("a=b; Path=foo", "\"a\"=\"b\" path=\"foo\""),
    ("a=b; Secure; HttpOnly", "\"a\"=\"b\" secure httponly"),
    ("a=b; secure=no; httponly=0", "\"a\"=\"b\" secure httponly"),
    ("a=b; SameSite=Strict", "\"a\"=\"b\" samesite=Strict"),
    ("a=b; samesite=LAX", "\"a\"=\"b\" samesite=Lax"),
    ("a=b; SameSite=None", "\"a\"=\"b\" samesite=NoRestriction"),
    ("a=b; SameSite=Lax; SameSite=bogus", "\"a\"=\"b\""),
    ("a=b; Version=1; Comment=x; Priority=High", "\"a\"=\"b\""),
    ("a=b;;  ;Secure ; ", "\"a\"=\"b\" secure"),
  ]
  for case in cases {
    assert_eq(parsed(case.0), case.1, msg=case.0)
  }
}

///|
test "a set-cookie value is ignored past 4096 bytes and an attribute past 1024" {
  // 4096 bytes in all: "n=" plus 4094 bytes of value.
  let fits = "n=" + "v".repeat(4094)
  let over = "n=" + "v".repeat(4095)
  assert_eq(utf8_length(fits), max_cookie_bytes)
  assert_true(parse_set_cookie(fits) is Some(_))
  assert_eq(parsed(over), "ignored")
  // Bytes are counted in UTF-8: each é takes two.
  let wide = "n=" + "\u{e9}".repeat(2047)
  assert_eq(utf8_length(wide), 4096)
  assert_true(parse_set_cookie(wide) is Some(_))
  assert_eq(parsed(wide + "v"), "ignored")
  assert_eq(utf8_length("\u{1F36A}\u{800}\u{7FF}"), 9)
  let path = "/" + "p".repeat(1023)
  assert_eq(parsed("a=b; Path=" + path), "\"a\"=\"b\" path=\{Repr(path)}")
  assert_eq(parsed("a=b; Path=" + path + "p"), "\"a\"=\"b\"")
}
