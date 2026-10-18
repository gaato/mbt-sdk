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
    ("http://[::1", None),
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
