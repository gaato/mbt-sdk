///|
test "URL encoding matches generated helpers" {
  assert_eq(@http.percent_encode("a b/c~é"), "a%20b%2Fc~%C3%A9")
  assert_eq(@http.percent_encode_path("a b/c~é"), "a%20b/c~%C3%A9")
  assert_eq(@http.percent_encode(""), "")
  assert_eq(@http.percent_encode_path(""), "")
  assert_eq(@http.percent_encode("AZaz09-._~%?#"), "AZaz09-._~%25%3F%23")
  assert_eq(@http.append_query("/p", "a b", "é/"), "/p?a%20b=%C3%A9%2F")
  assert_eq(@http.append_query("/p?x=1", "", ""), "/p?x=1&=")
  assert_eq(@http.append_query("/p?", "a", "b"), "/p?&a=b")
}

///|
test "URL encoding of slashes, sub-delimiters and astral characters" {
  assert_eq(@http.percent_encode_path("/"), "/")
  assert_eq(@http.percent_encode_path("//a//"), "//a//")
  assert_eq(@http.percent_encode("!*'()"), "%21%2A%27%28%29")
  assert_eq(@http.percent_encode("😀"), "%F0%9F%98%80")
}

///|
fn resolved(reference : String) -> String raise @http.UrlError {
  @http.Url::parse("http://a/b/c/d;p?q")
  .resolve(@http.Url::parse(reference))
  .to_string()
}

///|
/// RFC 3986 §5.4.1 and §5.4.2, in the sections' order: 23 normal and 19
/// abnormal examples against the base `http://a/b/c/d;p?q`. The last is the
/// strict reading: `http:g` keeps its own scheme.
test "the 42 reference resolution examples of RFC 3986 §5.4" {
  let cases = [
    ("g:h", "g:h"),
    ("g", "http://a/b/c/g"),
    ("./g", "http://a/b/c/g"),
    ("g/", "http://a/b/c/g/"),
    ("/g", "http://a/g"),
    ("//g", "http://g"),
    ("?y", "http://a/b/c/d;p?y"),
    ("g?y", "http://a/b/c/g?y"),
    ("#s", "http://a/b/c/d;p?q#s"),
    ("g#s", "http://a/b/c/g#s"),
    ("g?y#s", "http://a/b/c/g?y#s"),
    (";x", "http://a/b/c/;x"),
    ("g;x", "http://a/b/c/g;x"),
    ("g;x?y#s", "http://a/b/c/g;x?y#s"),
    ("", "http://a/b/c/d;p?q"),
    (".", "http://a/b/c/"),
    ("./", "http://a/b/c/"),
    ("..", "http://a/b/"),
    ("../", "http://a/b/"),
    ("../g", "http://a/b/g"),
    ("../..", "http://a/"),
    ("../../", "http://a/"),
    ("../../g", "http://a/g"),
    ("../../../g", "http://a/g"),
    ("../../../../g", "http://a/g"),
    ("/./g", "http://a/g"),
    ("/../g", "http://a/g"),
    ("g.", "http://a/b/c/g."),
    (".g", "http://a/b/c/.g"),
    ("g..", "http://a/b/c/g.."),
    ("..g", "http://a/b/c/..g"),
    ("./../g", "http://a/b/g"),
    ("./g/.", "http://a/b/c/g/"),
    ("g/./h", "http://a/b/c/g/h"),
    ("g/../h", "http://a/b/c/h"),
    ("g;x=1/./y", "http://a/b/c/g;x=1/y"),
    ("g;x=1/../y", "http://a/b/c/y"),
    ("g?y/./x", "http://a/b/c/g?y/./x"),
    ("g?y/../x", "http://a/b/c/g?y/../x"),
    ("g#s/./x", "http://a/b/c/g#s/./x"),
    ("g#s/../x", "http://a/b/c/g#s/../x"),
    ("http:g", "http:g"),
  ]
  assert_eq(cases.length(), 42)
  for case in cases {
    assert_eq((case.0, resolved(case.0)), case)
  }
  // §5.2.3: a base with an authority and an empty path merges as if it were `/`.
  let bare = @http.Url::parse("http://a")
  assert_eq(bare.resolve(@http.Url::parse("g")).to_string(), "http://a/g")
}

///|
test "a URL comes apart into its RFC 3986 components" {
  let url = @http.Url::parse("https://leo:pw@example.test:8443/a/b?x=1#top")
  assert_eq(url.scheme, Some("https"))
  assert_eq(url.userinfo, Some("leo:pw"))
  assert_eq(url.host, Some("example.test"))
  assert_eq(url.port, Some(8443))
  assert_eq(url.path, "/a/b")
  assert_eq(url.query, Some("x=1"))
  assert_eq(url.fragment, Some("top"))
  // Empty is not absent: the delimiter is there either way.
  assert_eq(@http.Url::parse("http://h/p?").query, Some(""))
  assert_eq(@http.Url::parse("http://h/p").query, None)
  assert_eq(@http.Url::parse("http://h/p#").fragment, Some(""))
  assert_eq(@http.Url::parse("mailto:leo@example.test").host, None)
  assert_eq(@http.Url::parse("file:///tmp/x").host, Some(""))
  // A colon makes a scheme only after a letter-led name.
  assert_eq(@http.Url::parse("a+b-c.d:x").scheme, Some("a+b-c.d"))
  assert_eq(@http.Url::parse("2026:a").scheme, None)
  assert_eq(@http.Url::parse("a/b:c").scheme, None)
  // The last at-sign divides the userinfo from the host.
  let url = @http.Url::parse("http://a@b@host/p")
  assert_eq(url.userinfo, Some("a%40b"))
  assert_eq(url.host, Some("host"))
  assert_eq(@http.Url::parse("http://h:/p").port, None)
  assert_eq(@http.Url::parse("http://h:0/p").port, Some(0))
}

///|
test "IPv6 literals are validated, lower-cased and bracketed again" {
  let url = @http.Url::parse("http://[2001:DB8::1]:8080/p")
  assert_eq(url.host, Some("2001:db8::1"))
  assert_eq(url.port, Some(8080))
  assert_eq(url.to_string(), "http://[2001:db8::1]:8080/p")
  // RFC 5952's canonical form, so equal addresses serialise and compare alike.
  let long = @http.Url::parse("http://[2001:0DB8:0:0:0:0:0:0001]:80/p")
  assert_eq(long.to_string(), "http://[2001:db8::1]/p")
  assert_true(long.same_origin(@http.Url::parse("http://[2001:db8::1]/")))
  assert_false(long.same_origin(@http.Url::parse("http://[2001:db8::2]/")))
  assert_eq(
    @http.Url::parse("http://[0:0:0:0:0:ffff:192.0.2.1]/").host,
    Some("::ffff:192.0.2.1"),
  )
  for
    literal in [
      "::", "::1", "1:2:3:4:5:6:7:8", "1::8", "::ffff:192.0.2.1", "1:2:3:4:5:6:1.2.3.4",
    ] {
    assert_eq(@http.Url::parse("http://[" + literal + "]/").host, Some(literal))
  }
  for
    literal in [
      "", "1", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", "12345::", "g::",
      "::1.2.3", "::1.2.3.256", "::01.2.3.4", "1.2.3.4::", "fe80::1%25eth0", "v1.x",
      "1:2:3:4:5:6:7::8",
    ] {
    assert_eq(refusal("http://[" + literal + "]/"), "IP literal is not IPv6")
  }
}

///|
fn refusal(text : String) -> String {
  try @http.Url::parse(text) catch {
    Invalid(reason) => reason
  } noraise {
    url => "parsed as " + url.to_string()
  }
}

///|
test "malformed authorities are refused with a reason" {
  let cases = [
    ("http://h:80x/p", "port is not a number"),
    ("http://h:65536/", "port exceeds 65535"),
    ("http://h:99999999999999999999/", "port exceeds 65535"),
    ("http://[::1/p", "IP literal without a closing bracket"),
    ("http://[::1]x/p", "unexpected character after an IP literal"),
    ("http://[::1%25eth0]/", "IP literal is not IPv6"),
    ("http://bücher.example/", "non-ASCII host; pass its IDNA (xn--) form"),
    ("http://b%C3%BCcher.example/", "host contains \"%\""),
    ("http://a b/", "host contains \" \""),
    ("http://a\\b/", "host contains \"\\\\\""),
  ]
  for case in cases {
    assert_eq((case.0, refusal(case.0)), case)
  }
  assert_eq(@http.Url::parse("http://h:65535/").port, Some(65535))
  assert_eq(
    @http.Url::parse("http://xn--bcher-kva.example/").host,
    Some("xn--bcher-kva.example"),
  )
}

///|
test "parsing normalises scheme, host, default ports, escapes and dots" {
  let cases = [
    ("HTTP://EXAMPLE.com:80/", "http://example.com/"),
    ("https://h:443/p", "https://h/p"),
    ("https://h:80/p", "https://h:80/p"),
    ("ws://h:80/", "ws://h/"),
    ("wss://h:443/", "wss://h/"),
    ("ftp://h:21/", "ftp://h/"),
    ("foo://h:80/", "foo://h:80/"),
    (
      "http://h/a b/é?q=a b&c=é#f g", "http://h/a%20b/%C3%A9?q=a%20b&c=%C3%A9#f%20g",
    ),
    ("http://h/%7e%2F%zz", "http://h/%7e%2F%zz"),
    ("http://h/{x}^`\\|[]", "http://h/%7Bx%7D%5E%60%5C|[]"),
    ("http://h/?{x}'`\"<>", "http://h/?{x}'`%22%3C%3E"),
    ("http://h/#{x}`\"<> #", "http://h/#{x}%60%22%3C%3E%20#"),
    ("http://us er:p@ss:w@h/", "http://us%20er:p%40ss%3Aw@h/"),
    ("http://h/a/./b/../c/..", "http://h/a/"),
    ("http://h/😀", "http://h/%F0%9F%98%80"),
    ("  \u{0} http://h/a\tb\nc\r \u{1f}", "http://h/abc"),
    ("../a/./b", "../a/./b"),
    ("//H:80/./x", "//h:80/./x"),
    // RFC 3986 §5.2.4 roots a rootless path that climbs out of its first segment.
    ("a:b/../c", "a:/c"),
  ]
  for case in cases {
    assert_eq((case.0, @http.Url::parse(case.0).to_string()), case)
  }
}

///|
test "serialisation keeps paths that look like an authority or a scheme" {
  // A path starting `//` without an authority gets WHATWG's `/.` prefix.
  let url = @http.Url::parse("a:/b").resolve(@http.Url::parse("..//c"))
  assert_eq(url.path, "//c")
  assert_eq(url.to_string(), "a:/.//c")
  assert_eq(@http.Url::parse(url.to_string()), url)
  // A relative path whose first segment has a colon gets `./`.
  let relative = @http.Url::parse("x/y").resolve(@http.Url::parse("a:b"))
  assert_eq(relative.to_string(), "a:b")
  let colon = @http.Url::parse("./a:b")
  assert_eq(colon.path, "./a:b")
  let base = @http.Url::parse("rel")
  assert_eq(base.resolve(@http.Url::parse("./a:b")).to_string(), "./a:b")
}

///|
test "origins compare scheme, host and port with defaults" {
  let url = @http.Url::parse
  assert_true(url("http://h/a").same_origin(url("HTTP://H:80/b?c")))
  assert_true(url("https://h:8443/").same_origin(url("https://h:8443/x")))
  assert_false(url("http://h/").same_origin(url("https://h/")))
  assert_false(url("http://h/").same_origin(url("http://h:8080/")))
  assert_false(url("http://h/").same_origin(url("http://g/")))
  assert_false(url("/a").same_origin(url("/a")))
  assert_false(url("mailto:x").same_origin(url("mailto:x")))
  assert_true(url("foo://h/").same_origin(url("foo://h/x")))
  assert_eq(url("https://h/").port_or_default(), Some(443))
  assert_eq(url("http://h:81/").port_or_default(), Some(81))
  assert_eq(url("foo://h/").port_or_default(), None)
  assert_eq(url("/a").port_or_default(), None)
  assert_true(url("http:g").is_absolute())
  assert_false(url("//g").is_absolute())
  assert_eq(
    url("http://h/p?q#f").without_fragment().to_string(),
    "http://h/p?q",
  )
}

///|
test "query params decode as form data and append or merge as encoded pairs" {
  let url = @http.Url::parse("https://h/p?a=1&b=x+y%20z&&c&a=%E2%82%AC&d=%zz#f")
  assert_eq(url.query_params(), [
    ("a", "1"),
    ("b", "x y z"),
    ("c", ""),
    ("a", "€"),
    ("d", "%zz"),
  ])
  assert_eq(@http.Url::parse("https://h/p").query_params(), [])
  assert_eq(@http.Url::parse("https://h/p?").query_params(), [])
  let append = @http.Url::append_query_params
  assert_eq(
    append(@http.Url::parse("https://h/p"), [("a b", "é/")]).to_string(),
    "https://h/p?a%20b=%C3%A9%2F",
  )
  assert_eq(
    append(@http.Url::parse("https://h/p?"), [("a", "1")]).to_string(),
    "https://h/p?a=1",
  )
  assert_eq(
    append(@http.Url::parse("https://h/p?x&"), [("a", "1")]).to_string(),
    "https://h/p?x&a=1",
  )
  assert_eq(
    append(@http.Url::parse("https://h/p?x"), []).to_string(),
    "https://h/p?x",
  )
  let merge = @http.Url::merge_query_params
  assert_eq(
    merge(url, [("a", "2"), ("e", "3"), ("a", "4")]).to_string(),
    "https://h/p?b=x+y%20z&c&d=%zz&a=2&e=3&a=4#f",
  )
  assert_eq(
    merge(@http.Url::parse("https://h/p?a+b=1"), [("a b", "2")]).to_string(),
    "https://h/p?a%20b=2",
  )
  assert_eq(
    merge(@http.Url::parse("https://h/p?a=1"), [("a", "2")]).to_string(),
    "https://h/p?a=2",
  )
  assert_eq(
    merge(@http.Url::parse("https://h/p"), [("a", "2")]).to_string(),
    "https://h/p?a=2",
  )
  assert_eq(
    merge(@http.Url::parse("https://h/p?a=1"), []).to_string(),
    "https://h/p?a=1",
  )
}

///|
test "normalised URLs round-trip through parse and serialise" {
  for
    text in [
      "http://a/b/c/d;p?q", "https://u:p@h:8443/a%20b?x=1&y=%E2%82%AC#frag", "http://[::1]/",
      "http:g", "g:h", "mailto:leo@example.test", "file:///tmp/x", "http://h", "http://h?q",
      "http://h#f", "//g/x", "?y", "#s", "", "../g", "./a:b", "a:/.//c",
    ] {
    let url = @http.Url::parse(text)
    assert_eq(url.to_string(), text)
    assert_eq(@http.Url::parse(url.to_string()), url)
  }
}

///|
fn pick(rand : @random.Rand, choices : Array[String]) -> String {
  choices[rand.int(limit=choices.length())]
}

///|
fn random_path(rand : @random.Rand, absolute : Bool) -> String {
  let segments = [
    ".", "..", "a", "b c", "é", "%2F", "g;x=1", "", "x:y", "{", "%zz", "😀",
  ]
  let builder = StringBuilder()
  if absolute {
    builder.write_char('/')
  }
  let count = rand.int(limit=5)
  for i = count; i > 0; i = i - 1 {
    // An empty first segment would make `//`, an authority.
    let segment = pick(rand, segments)
    builder.write_string(
      if i == count && segment == "" {
        "a"
      } else {
        segment
      },
    )
    if i > 1 || rand.int(limit=2) == 0 {
      builder.write_char('/')
    }
  }
  builder.to_string()
}

///|
fn random_reference(rand : @random.Rand) -> String {
  let scheme = pick(rand, ["http:", "HTTPS:", "ws:", "foo:", "g:"])
  let authority = "//" +
    pick(rand, ["", "u@", "u:p@", "a b@"]) +
    pick(rand, [
      "a", "Example.COM", "[::1]", "[2001:DB8::A]", "[2001:0db8:0:0:1:0:0:1]", "[0:0:0:0:0:FFFF:1.2.3.4]",
      "127.0.0.1", "",
    ]) +
    pick(rand, ["", ":", ":80", ":443", ":8080"])
  let suffix = pick(rand, ["", "?", "?y", "?a=1&b=x y", "?./..", "?'"]) +
    pick(rand, ["", "#", "#s", "#s/../x", "#é"])
  let path_absolute = random_path(rand, true)
  match rand.int(limit=6) {
    0 => scheme + authority + path_absolute + suffix
    1 => scheme + random_path(rand, false) + suffix
    2 => authority + path_absolute + suffix
    3 => path_absolute + suffix
    4 => random_path(rand, false) + suffix
    _ => suffix
  }
}

///|
test "property: a resolved reference parses back to itself" {
  let rand = @random.Rand::chacha8(seed=b"gaato/http url resolve roundtrip")
  for _ in 0..<2000 {
    let base_text = pick(rand, ["http:", "HTTPS:", "foo:"]) +
      "//" +
      pick(rand, ["a", "Example.COM:443", "[::1]:80", "u@h"]) +
      random_path(rand, true) +
      pick(rand, ["", "?q", "?a=1"])
    let base = @http.Url::parse(base_text)
    let reference_text = random_reference(rand)
    let reference = @http.Url::parse(reference_text)
    let result = base.resolve(reference)
    let text = result.to_string()
    assert_eq(
      (base_text, reference_text, @http.Url::parse(text)),
      (base_text, reference_text, result),
    )
    assert_eq(@http.Url::parse(text).to_string(), text)
    // Resolving again changes nothing: the result has no dot segments left.
    assert_eq(base.resolve(result), result)
  }
}
