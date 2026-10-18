///|
fn url_parts(url : String) -> (String, String, String)? {
  parse_request_url(url).map(url => (url.scheme, url.host, url.path))
}

///|
test "parse_request_url keeps the scheme, host and path a jar reads" {
  let cases : Array[(String, (String, String, String)?)] = [
    ("https://example.com", Some(("https", "example.com", "/"))),
    ("HTTPS://Example.COM/A/b?q=1#f", Some(("https", "example.com", "/A/b"))),
    ("http://user:pw@host:8080/x", Some(("http", "host", "/x"))),
    ("http://a@b@host/x", Some(("http", "host", "/x"))),
    ("http://host?q=/a", Some(("http", "host", "/"))),
    ("http://host#/a", Some(("http", "host", "/"))),
    ("wss://[::1]:443/ws", Some(("wss", "[::1]", "/ws"))),
    // Hosts and paths come out as @http.Url normalises them.
    ("http://[0:0:0:0:0:0:0:1]:8080/", Some(("http", "[::1]", "/"))),
    ("http://[2001:DB8:0::0:1]", Some(("http", "[2001:db8::1]", "/"))),
    (
      "HTTP://WWW.EXAMPLE.COM:80/Dir/../X",
      Some(("http", "www.example.com", "/X")),
    ),
    ("https://a.example/a b/./c", Some(("https", "a.example", "/a%20b/c"))),
    ("http://b\u{fc}cher.example/", None),
    ("http://%41.example/", None),
    ("http://ex ample.com/", None),
    ("http://[::1", None),
    ("http://[v1.x]/", None),
    ("/relative/path", None),
    ("file:///etc/hosts", None),
    ("http:///path", None),
    ("http://:80/", None),
    ("example.com/path", None),
    ("://example.com", None),
    ("1http://example.com", None),
    ("h t://example.com", None),
  ]
  for case in cases {
    assert_eq(url_parts(case.0), case.1, msg=case.0)
  }
}

///|
test "https and wss are the secure schemes" {
  let cases = [
    ("https://a.com", true),
    ("wss://a.com", true),
    ("http://a.com", false),
    ("ws://a.com", false),
  ]
  for case in cases {
    assert_eq(parse_request_url(case.0).unwrap().is_secure(), case.1)
  }
}

///|
test "IPv6 Domain values are compared in canonical form" {
  assert_eq(canonical_ip_literal("[0:0::1]"), "[::1]")
  assert_eq(canonical_ip_literal("[2001:DB8::0:1]"), "[2001:db8::1]")
  assert_eq(canonical_ip_literal("[::1]:80"), "[::1]:80")
  assert_eq(canonical_ip_literal("[bogus]"), "[bogus]")
  assert_eq(canonical_ip_literal("example.com"), "example.com")
}
