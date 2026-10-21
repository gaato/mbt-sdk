///|
/// 2020-09-13T12:26:40Z, before the RFC 6265 examples' 2021 expiry.
const T0 : Int64 = 1_600_000_000_000L

///|
fn test_jar(
  max_per_domain~ : Int32 = default_max_per_domain,
  max_total~ : Int32 = default_max_total,
  is_public_suffix~ : (String) -> Bool = _ => false,
) -> CookieJar {
  CookieJar::new(
    @mock.FakeClock::new(start_unix_ms=T0),
    max_per_domain~,
    max_total~,
    is_public_suffix~,
  )
}

///|
fn set_at(jar : CookieJar, url : String, line : String, now : Int64) -> Unit {
  jar.store_at(parse_request_url(url).unwrap(), line, now)
}

///|
fn get_at(jar : CookieJar, url : String, now : Int64) -> String? {
  jar.header_at(parse_request_url(url).unwrap(), now)
}

///|
/// Stored `name=value` pairs in iteration order.
fn pairs(jar : CookieJar) -> Array[String] {
  jar.iter().map(c => c.name + "=" + c.value).collect()
}

///|
/// Scenarios from RFC 6265 and the http-state parser and storage tests: each
/// stores `(request URL, Set-Cookie)` steps one millisecond apart, then asks
/// for the `Cookie` header of a request.
test "the storage model and the cookie header follow RFC 6265 scenarios" {
  let cases : Array[(String, Array[(String, String)], String, String?)] = [
    // RFC 6265 §3.1.
    (
      "§3.1 simple",
      [("http://example.com/", "SID=31d4d96e407aad42")],
      "http://example.com/",
      Some("SID=31d4d96e407aad42"),
    ),
    (
      "§3.1 secure and domain",
      [
        (
          "https://example.com/", "SID=31d4d96e407aad42; Path=/; Secure; HttpOnly",
        ),
        ("https://example.com/", "lang=en-US; Path=/; Domain=example.com"),
      ],
      "https://example.com/",
      Some("SID=31d4d96e407aad42; lang=en-US"),
    ),
    (
      "§3.1 host-only SID stays on its host",
      [
        (
          "https://example.com/", "SID=31d4d96e407aad42; Path=/; Secure; HttpOnly",
        ),
        ("https://example.com/", "lang=en-US; Path=/; Domain=example.com"),
      ],
      "https://www.example.com/",
      Some("lang=en-US"),
    ),
    (
      "§3.1 past Expires deletes",
      [
        (
          "http://example.com/", "lang=en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT",
        ),
        ("http://example.com/", "lang=; Expires=Sun, 06 Nov 1994 08:49:37 GMT"),
      ],
      "http://example.com/",
      None,
    ),
    // Name-value parsing reaches the header unchanged.
    (
      "two cookies",
      [("http://a.com/", "foo=bar"), ("http://a.com/", "foo2=bar2")],
      "http://a.com/",
      Some("foo=bar; foo2=bar2"),
    ),
    (
      // RFC 6265bis-22 §5.6 step 3: a pair without `=` is a value without a
      // name, sent alone; §5.7 step 2 ignores an empty name and value.
      "a nameless cookie between, an empty pair ignored",
      [
        ("http://a.com/", "a=b"),
        ("http://a.com/", "="),
        ("http://a.com/", "novalue"),
        ("http://a.com/", "c=d"),
      ],
      "http://a.com/",
      Some("a=b; novalue; c=d"),
    ),
    (
      "quoted value kept",
      [("http://a.com/", "foo=\"bar baz\"")],
      "http://a.com/",
      Some("foo=\"bar baz\""),
    ),
    ("empty value", [("http://a.com/", "foo=")], "http://a.com/", Some("foo=")),
    // Domain attribute.
    (
      "host-only not sent to subdomain",
      [("http://example.com/", "a=1")],
      "http://www.example.com/",
      None,
    ),
    (
      "domain cookie sent to subdomain",
      [("http://example.com/", "a=1; Domain=example.com")],
      "http://a.b.example.com/",
      Some("a=1"),
    ),
    (
      "leading dot ignored",
      [("http://example.com/", "a=1; Domain=.example.com")],
      "http://www.example.com/",
      Some("a=1"),
    ),
    (
      "not sent to a lookalike",
      [("http://example.com/", "a=1; Domain=example.com")],
      "http://badexample.com/",
      None,
    ),
    (
      "parent domain from subdomain",
      [("http://www.example.com/", "a=1; Domain=example.com")],
      "http://example.com/",
      Some("a=1"),
    ),
    (
      "child domain refused",
      [("http://example.com/", "a=1; Domain=www.example.com")],
      "http://www.example.com/",
      None,
    ),
    (
      "sibling domain refused",
      [("http://home.example.org/", "a=1; Domain=sibling.example.org")],
      "http://sibling.example.org/",
      None,
    ),
    (
      "port in domain refused",
      [("http://home.example.org/", "a=1; Domain=home.example.org:8888")],
      "http://home.example.org/",
      None,
    ),
    (
      "uppercase domain",
      [("http://home.example.org/", "a=1; Domain=HOME.EXAMPLE.ORG")],
      "http://sub.home.example.org/",
      Some("a=1"),
    ),
    (
      "empty domain is host-only",
      [("http://home.example.org/", "a=1; Domain=")],
      "http://sub.home.example.org/",
      None,
    ),
    (
      "empty domain still stored",
      [("http://home.example.org/", "a=1; Domain=")],
      "http://home.example.org/",
      Some("a=1"),
    ),
    (
      "double dot refused",
      [("http://home.example.org/", "a=1; Domain=..example.org")],
      "http://home.example.org/",
      None,
    ),
    (
      "non-ASCII domain refused",
      [("http://xn--bcher-kva.example/", "a=1; Domain=b\u{fc}cher.example")],
      "http://xn--bcher-kva.example/",
      None,
    ),
    (
      "TLD refused",
      [("http://example.com/", "a=1; Domain=com")],
      "http://example.com/",
      None,
    ),
    (
      "dotted TLD refused",
      [("http://example.com/", "a=1; Domain=.com")],
      "http://other.com/",
      None,
    ),
    (
      "single label from itself is host-only",
      [("http://localhost/", "a=1; Domain=localhost")],
      "http://localhost/",
      Some("a=1"),
    ),
    (
      "IP host with its own Domain",
      [("http://127.0.0.1/", "a=1; Domain=127.0.0.1")],
      "http://127.0.0.1/",
      Some("a=1"),
    ),
    (
      "IP host with a partial Domain",
      [("http://127.0.0.1/", "a=1; Domain=0.0.1")],
      "http://127.0.0.1/",
      None,
    ),
    (
      "IPv6 host",
      [("http://[::1]:8080/", "a=1; Domain=[::1]")],
      "http://[::1]/",
      Some("a=1"),
    ),
    (
      "IPv6 Domain in another spelling",
      [("http://[0:0::1]/", "a=1; Domain=[0:0:0:0:0:0:0:1]")],
      "http://[::1]:9090/",
      Some("a=1"),
    ),
    (
      "IPv6 Domain of another address",
      [("http://[::1]/", "a=1; Domain=[::2]")],
      "http://[::1]/",
      None,
    ),
    (
      "IPv6 host-only cookie stays on its address",
      [("http://[2001:db8::1]/", "a=1")],
      "http://[2001:DB8:0::2]/",
      None,
    ),
    (
      "uppercase request host",
      [("http://example.com/", "a=1")],
      "http://EXAMPLE.COM/",
      Some("a=1"),
    ),
    (
      "uppercase setting host with Domain",
      [("http://WWW.Example.COM/", "a=1; Domain=example.com")],
      "http://api.example.com/",
      Some("a=1"),
    ),
    (
      "path read after dot-segment removal",
      [("http://a.com/x/../y/page", "a=1")],
      "http://a.com/y/z",
      Some("a=1"),
    ),
    (
      "port does not matter",
      [("http://example.com:8080/", "a=1")],
      "http://example.com:9090/",
      Some("a=1"),
    ),
    // Path attribute and the default path.
    (
      "path prefix with slash",
      [("http://a.com/", "a=1; Path=/foo")],
      "http://a.com/foo/bar",
      Some("a=1"),
    ),
    (
      "path exact",
      [("http://a.com/", "a=1; Path=/foo")],
      "http://a.com/foo?x=/",
      Some("a=1"),
    ),
    (
      "path not a segment prefix",
      [("http://a.com/", "a=1; Path=/foo")],
      "http://a.com/foobar",
      None,
    ),
    ("path above", [("http://a.com/", "a=1; Path=/foo")], "http://a.com/", None),
    (
      "path case-sensitive",
      [("http://a.com/", "a=1; Path=/foo")],
      "http://a.com/FOO",
      None,
    ),
    (
      "default path is the directory",
      [("http://a.com/foo/bar", "a=1")],
      "http://a.com/foo/baz",
      Some("a=1"),
    ),
    (
      "default path excludes others",
      [("http://a.com/foo/bar", "a=1")],
      "http://a.com/other",
      None,
    ),
    (
      "default path of a top-level file",
      [("http://a.com/foo", "a=1")],
      "http://a.com/other",
      Some("a=1"),
    ),
    (
      "relative Path uses the default",
      [("http://a.com/foo/bar", "a=1; Path=baz")],
      "http://a.com/foo/x",
      Some("a=1"),
    ),
    (
      "empty Path uses the default",
      [("http://a.com/foo/bar", "a=1; Path")],
      "http://a.com/x",
      None,
    ),
    // Secure.
    (
      "secure cookie refused from http",
      [("http://a.com/", "a=1; Secure")],
      "https://a.com/",
      None,
    ),
    (
      "secure cookie not sent over http",
      [("https://a.com/", "a=1; Secure")],
      "http://a.com/",
      None,
    ),
    (
      "secure cookie sent over wss",
      [("https://a.com/", "a=1; Secure")],
      "wss://a.com/",
      Some("a=1"),
    ),
    (
      "plain cookie sent over https",
      [("http://a.com/", "a=1")],
      "https://a.com/",
      Some("a=1"),
    ),
    (
      "insecure overwrite of a secure cookie refused",
      [("https://a.com/", "a=1; Secure"), ("http://a.com/", "a=2")],
      "https://a.com/",
      Some("a=1"),
    ),
    (
      "insecure shadow on a subpath refused",
      [("https://a.com/", "a=1; Secure"), ("http://a.com/", "a=2; Path=/x")],
      "https://a.com/x",
      Some("a=1"),
    ),
    (
      "insecure shadow from a subdomain refused",
      [
        ("https://a.com/", "a=1; Secure; Domain=a.com"),
        ("http://www.a.com/", "a=2"),
      ],
      "https://www.a.com/",
      Some("a=1"),
    ),
    (
      "insecure cookie of another name allowed",
      [("https://a.com/", "a=1; Secure"), ("http://a.com/", "b=2")],
      "https://a.com/",
      Some("a=1; b=2"),
    ),
    (
      "insecure cookie on an unrelated path allowed",
      [
        ("https://a.com/x", "a=1; Secure; Path=/x"),
        ("http://a.com/", "a=2; Path=/y"),
      ],
      "http://a.com/y",
      Some("a=2"),
    ),
    (
      "secure overwrite from https",
      [("https://a.com/", "a=1; Secure"), ("https://a.com/", "a=2")],
      "http://a.com/",
      Some("a=2"),
    ),
    // Cookie prefixes (RFC 6265bis-22 §4.1.3).
    (
      "__Secure- needs Secure",
      [("https://a.com/", "__Secure-a=1")],
      "https://a.com/",
      None,
    ),
    (
      "__Secure- with Secure",
      [("https://a.com/", "__Secure-a=1; Secure; Domain=a.com")],
      "https://www.a.com/",
      Some("__Secure-a=1"),
    ),
    (
      "__secure- matches ignoring case",
      [("https://a.com/", "__SECURE-a=1")],
      "https://a.com/",
      None,
    ),
    (
      "__Host- complete",
      [("https://a.com/x/y", "__Host-a=1; Secure; Path=/")],
      "https://a.com/",
      Some("__Host-a=1"),
    ),
    (
      "__Host- without Path",
      [("https://a.com/", "__Host-a=1; Secure")],
      "https://a.com/",
      None,
    ),
    (
      "__Host- with a deeper Path",
      [("https://a.com/", "__Host-a=1; Secure; Path=/x")],
      "https://a.com/x",
      None,
    ),
    (
      "__Host- with an invalid Path",
      [("https://a.com/", "__Host-id=1; Secure; Path=invalid")],
      "https://a.com/",
      None,
    ),
    (
      "__Host- with an empty Path",
      [("https://a.com/", "__Host-id=1; Secure; Path")],
      "https://a.com/",
      None,
    ),
    (
      "__Host- with Domain",
      [("https://a.com/", "__Host-a=1; Secure; Path=/; Domain=a.com")],
      "https://a.com/",
      None,
    ),
    (
      "__Host- without Secure",
      [("https://a.com/", "__Host-a=1; Path=/")],
      "https://a.com/",
      None,
    ),
    // Replacement, deletion and ordering.
    (
      "same name, domain and path replaces",
      [("http://a.com/", "a=1"), ("http://a.com/", "a=2")],
      "http://a.com/",
      Some("a=2"),
    ),
    (
      "host-only and domain cookies of one domain replace each other",
      [("http://a.com/", "a=1"), ("http://a.com/", "a=2; Domain=a.com")],
      "http://www.a.com/",
      Some("a=2"),
    ),
    (
      "another path keeps both",
      [("http://a.com/", "a=1; Path=/"), ("http://a.com/", "a=2; Path=/foo")],
      "http://a.com/foo",
      Some("a=2; a=1"),
    ),
    (
      "Max-Age=0 deletes",
      [("http://a.com/", "a=1"), ("http://a.com/", "a=2; Max-Age=0")],
      "http://a.com/",
      None,
    ),
    (
      "negative Max-Age deletes",
      [("http://a.com/", "a=1"), ("http://a.com/", "a=2; Max-Age=-1")],
      "http://a.com/",
      None,
    ),
    (
      "deletion needs the same path",
      [
        ("http://a.com/", "a=1; Path=/"),
        ("http://a.com/", "a=; Path=/x; Max-Age=0"),
      ],
      "http://a.com/x",
      Some("a=1"),
    ),
    (
      "Max-Age wins over a past Expires",
      [
        (
          "http://a.com/", "a=1; Max-Age=60; Expires=Sun, 06 Nov 1994 08:49:37 GMT",
        ),
      ],
      "http://a.com/",
      Some("a=1"),
    ),
    (
      "Max-Age=0 wins over a future Expires",
      [
        (
          "http://a.com/", "a=1; Expires=Wed, 09 Jun 2021 10:18:14 GMT; Max-Age=0",
        ),
      ],
      "http://a.com/",
      None,
    ),
    (
      "invalid Expires keeps a session cookie",
      [("http://a.com/", "a=1; Expires=yesterday")],
      "http://a.com/",
      Some("a=1"),
    ),
    (
      "longer paths first",
      [
        ("http://a.com/", "a=1; Path=/"),
        ("http://a.com/", "b=2; Path=/foo"),
        ("http://a.com/", "c=3; Path=/foo/bar"),
      ],
      "http://a.com/foo/bar/baz",
      Some("c=3; b=2; a=1"),
    ),
    (
      "then earlier creation",
      [
        ("http://a.com/", "b=1"),
        ("http://a.com/", "a=2"),
        ("http://a.com/", "c=3"),
      ],
      "http://a.com/",
      Some("b=1; a=2; c=3"),
    ),
    (
      "a replaced cookie keeps its creation time",
      [
        ("http://a.com/", "a=1"),
        ("http://a.com/", "b=1"),
        ("http://a.com/", "a=2"),
      ],
      "http://a.com/",
      Some("a=2; b=1"),
    ),
    (
      "domain and host-only cookies together",
      [
        ("http://www.a.com/", "h=1"),
        ("http://www.a.com/", "d=2; Domain=a.com"),
        ("http://a.com/", "x=3"),
      ],
      "http://www.a.com/",
      Some("h=1; d=2"),
    ),
  ]
  for case in cases {
    let (label, steps, request, expected) = case
    let jar = test_jar()
    for i, step in steps {
      set_at(jar, step.0, step.1, T0 + i.to_int64())
    }
    assert_eq(get_at(jar, request, T0 + 1000L), expected, msg=label)
  }
}

///|
/// Steps of `(time offset in ms, request URL, Set-Cookie)`, then a request
/// at the last step's time plus one: an expired cookie no longer blocks,
/// shadows or lends its creation time to a new one.
test "expired cookies take no part in storing new ones" {
  let cases : Array[(String, Array[(Int64, String, String)], String, String?)] = [
    (
      "an expired Secure cookie does not block an insecure one",
      [
        (0L, "https://a.com/", "a=1; Secure; Max-Age=1"),
        (1000L, "http://a.com/", "a=2"),
      ],
      "http://a.com/",
      Some("a=2"),
    ),
    (
      "an expired Secure cookie on a parent domain does not shadow",
      [
        (0L, "https://a.com/", "a=1; Secure; Domain=a.com; Max-Age=1"),
        (1000L, "http://www.a.com/", "a=2; Path=/x"),
      ],
      "http://www.a.com/x",
      Some("a=2"),
    ),
    (
      "a live Secure cookie still blocks",
      [
        (0L, "https://a.com/", "a=1; Secure; Max-Age=2"),
        (1000L, "http://a.com/", "a=2"),
      ],
      "https://a.com/",
      Some("a=1"),
    ),
    (
      "replacing an expired cookie starts a new creation time",
      [
        (0L, "http://a.com/", "a=1; Max-Age=1"),
        (500L, "http://a.com/", "b=1"),
        (2000L, "http://a.com/", "a=2"),
      ],
      "http://a.com/",
      Some("b=1; a=2"),
    ),
    (
      "replacing a live cookie keeps its creation time",
      [
        (0L, "http://a.com/", "a=1; Max-Age=5"),
        (500L, "http://a.com/", "b=1"),
        (2000L, "http://a.com/", "a=2"),
      ],
      "http://a.com/",
      Some("a=2; b=1"),
    ),
  ]
  for case in cases {
    let (label, steps, request, expected) = case
    let jar = test_jar()
    let mut last = T0
    for step in steps {
      last = T0 + step.0
      set_at(jar, step.1, step.2, last)
    }
    assert_eq(get_at(jar, request, last + 1L), expected, msg=label)
  }
}

///|
test "stored cookies carry the storage model's fields" {
  let jar = test_jar()
  set_at(
    jar,
    "https://www.a.com/p/q",
    "s=1; Secure; HttpOnly; SameSite=Lax",
    T0,
  )
  set_at(
    jar,
    "https://www.a.com/",
    "d=2; Domain=A.com; Path=/x; Max-Age=60",
    T0,
  )
  set_at(jar, "http://127.0.0.1/", "i=3; Domain=127.0.0.1", T0)
  assert_eq(jar.iter().collect(), [
    {
      name: "s",
      value: "1",
      domain: "www.a.com",
      host_only: true,
      path: "/p",
      expires_ms: None,
      secure: true,
      http_only: true,
      same_site: Some(SameSite::Lax),
      creation_ms: T0,
      last_access_ms: T0,
    },
    {
      name: "d",
      value: "2",
      domain: "a.com",
      host_only: false,
      path: "/x",
      expires_ms: Some(T0 + 60_000L),
      secure: false,
      http_only: false,
      same_site: None,
      creation_ms: T0,
      last_access_ms: T0,
    },
    {
      name: "i",
      value: "3",
      domain: "127.0.0.1",
      host_only: true,
      path: "/",
      expires_ms: None,
      secure: false,
      http_only: false,
      same_site: None,
      creation_ms: T0,
      last_access_ms: T0,
    },
  ])
}

///|
test "a public-suffix predicate refuses more domains, except from the host itself" {
  let jar = test_jar(is_public_suffix=domain => domain == "co.uk")
  set_at(jar, "http://example.co.uk/", "a=1; Domain=co.uk", T0)
  set_at(jar, "http://example.co.uk/", "b=2; Domain=example.co.uk", T0)
  set_at(jar, "http://co.uk/", "c=3; Domain=co.uk", T0)
  assert_eq(get_at(jar, "http://www.example.co.uk/", T0), Some("b=2"))
  assert_eq(get_at(jar, "http://co.uk/", T0), Some("c=3"))
  assert_eq(get_at(jar, "http://other.co.uk/", T0), None)
  assert_eq(jar.iter().map(c => c.host_only).collect(), [false, true])
}

///|
test "cookies expire at their Max-Age or Expires and are evicted when met" {
  let jar = test_jar()
  set_at(jar, "http://a.com/", "m=1; Max-Age=10", T0)
  set_at(jar, "http://a.com/", "e=2; Expires=Sun, 13 Sep 2020 12:26:50 GMT", T0)
  set_at(jar, "http://a.com/", "s=3", T0)
  assert_eq(get_at(jar, "http://a.com/", T0 + 9_999L), Some("m=1; e=2; s=3"))
  assert_eq(jar.length(), 3)
  assert_eq(get_at(jar, "http://a.com/", T0 + 10_000L), Some("s=3"))
  assert_eq(jar.length(), 1)
  assert_eq(pairs(jar), ["s=3"])
}

///|
test "lifetimes are cut to 400 days" {
  let jar = test_jar()
  set_at(jar, "http://a.com/", "m=1; Max-Age=99999999999999999999", T0)
  set_at(jar, "http://a.com/", "x=1; Max-Age=34560000", T0)
  set_at(jar, "http://a.com/", "e=2; Expires=Fri, 31 Dec 9999 23:59:59 GMT", T0)
  set_at(jar, "http://a.com/", "n=3; Max-Age=34559999", T0)
  assert_eq(jar.iter().map(c => c.expires_ms).collect(), [
    Some(T0 + max_lifetime_ms),
    Some(T0 + max_lifetime_ms),
    Some(T0 + max_lifetime_ms),
    Some(T0 + max_lifetime_ms - 1000L),
  ])
}

///|
test "Cookie::is_expired compares the expiry with a time" {
  let cookie : Cookie = {
    name: "a",
    value: "1",
    domain: "a.com",
    host_only: true,
    path: "/",
    expires_ms: Some(10L),
    secure: false,
    http_only: false,
    same_site: Some(SameSite::Strict),
    creation_ms: 0L,
    last_access_ms: 0L,
  }
  assert_false(cookie.is_expired(9L))
  assert_true(cookie.is_expired(10L))
  assert_false({ ..cookie, expires_ms: None, }.is_expired(@int64.MAX_VALUE))
}

///|
test "header_for marks the cookies it sends as accessed" {
  let jar = test_jar()
  set_at(jar, "http://a.com/", "a=1; Path=/a", T0)
  set_at(jar, "http://a.com/", "b=2; Path=/b", T0)
  assert_eq(get_at(jar, "http://a.com/a", T0 + 5L), Some("a=1"))
  assert_eq(jar.iter().map(c => c.last_access_ms).collect(), [T0 + 5L, T0])
  assert_eq(get_at(jar, "http://a.com/c", T0 + 6L), None)
}

///|
test "the per-domain cap evicts the least recently accessed cookie" {
  let jar = test_jar(max_per_domain=3)
  for i in 0..<3 {
    set_at(jar, "http://a.com/", "c\{i}=v; Path=/\{i}", T0 + i.to_int64())
  }
  assert_eq(jar.length(), 3)
  // c0 is the oldest by creation, but sending it makes c1 the least recent.
  assert_eq(get_at(jar, "http://a.com/0", T0 + 10L), Some("c0=v"))
  set_at(jar, "http://a.com/", "c3=v; Path=/3", T0 + 11L)
  assert_eq(pairs(jar), ["c0=v", "c2=v", "c3=v"])
  // Replacing c2 refreshes it, so c0 goes next.
  set_at(jar, "http://a.com/", "c2=w; Path=/2", T0 + 12L)
  set_at(jar, "http://a.com/", "c4=v; Path=/4", T0 + 13L)
  assert_eq(pairs(jar), ["c3=v", "c2=w", "c4=v"])
  // Another domain has its own allowance.
  set_at(jar, "http://b.com/", "d=v", T0 + 14L)
  assert_eq(jar.length(), 4)
}

///|
test "the per-domain cap evicts cookies that are not Secure first" {
  // RFC 6265bis-22 §5.7, removing excess cookies: after the expired ones,
  // a domain's cookies that are not Secure go before its Secure ones.
  let jar = test_jar(max_per_domain=3)
  set_at(jar, "https://a.com/", "s0=v; Secure", T0)
  set_at(jar, "https://a.com/", "s1=v; Secure", T0 + 1L)
  set_at(jar, "https://a.com/", "p0=v", T0 + 2L)
  set_at(jar, "https://a.com/", "p1=v", T0 + 3L)
  assert_eq(pairs(jar), ["s0=v", "s1=v", "p1=v"])
  // With only Secure cookies left, the least recently accessed goes.
  let jar = test_jar(max_per_domain=2)
  set_at(jar, "https://a.com/", "s0=v; Secure", T0)
  set_at(jar, "https://a.com/", "s1=v; Secure", T0 + 1L)
  set_at(jar, "https://a.com/", "s2=v; Secure", T0 + 2L)
  assert_eq(pairs(jar), ["s1=v", "s2=v"])
}

///|
test "cookies are kept and sent as RFC 6265bis-22 section 5.7 stores them" {
  // Step 19: SameSite=None only on a Secure cookie.
  let jar = test_jar()
  set_at(jar, "https://a.com/", "a=1; SameSite=None", T0)
  set_at(jar, "https://a.com/", "b=1; SameSite=None; Secure", T0 + 1L)
  set_at(jar, "https://a.com/", "c=1; SameSite=Lax", T0 + 2L)
  assert_eq(pairs(jar), ["b=1", "c=1"])
  // Step 22: a cookie without a name may not look like a prefixed one.
  let jar = test_jar()
  for
    line in ["__Secure-x; Secure", "=__Host-x=1; Secure; Path=/", "__SECURE-y"] {
    set_at(jar, "https://a.com/", line, T0)
  }
  set_at(jar, "https://a.com/", "plain", T0 + 1L)
  assert_eq(pairs(jar), ["=plain"])
  assert_eq(get_at(jar, "https://a.com/", T0 + 2L), Some("plain"))
  // Step 23: a host-only cookie and a domain cookie of the same name, domain
  // and path are two cookies; each replaces only its own kind.
  let jar = test_jar()
  set_at(jar, "http://a.com/", "n=host", T0)
  set_at(jar, "http://a.com/", "n=domain; Domain=a.com", T0 + 1L)
  set_at(jar, "http://a.com/", "n=host2", T0 + 2L)
  assert_eq(pairs(jar), ["n=domain", "n=host2"])
  assert_eq(get_at(jar, "http://a.com/", T0 + 3L), Some("n=host2; n=domain"))
  assert_eq(get_at(jar, "http://www.a.com/", T0 + 3L), Some("n=domain"))
}

///|
test "the per-domain cap evicts expired cookies before live ones" {
  let jar = test_jar(max_per_domain=3)
  set_at(jar, "http://a.com/", "c0=v", T0)
  set_at(jar, "http://a.com/", "c1=v", T0 + 1L)
  set_at(jar, "http://a.com/", "c2=v; Max-Age=1", T0 + 2L)
  set_at(jar, "http://a.com/", "c3=v", T0 + 5_000L)
  assert_eq(pairs(jar), ["c0=v", "c1=v", "c3=v"])
}

///|
test "the per-domain cap counts host-only and domain cookies of one domain" {
  let jar = test_jar(max_per_domain=2)
  set_at(jar, "http://a.com/", "h=1", T0)
  set_at(jar, "http://www.a.com/", "d=2; Domain=a.com", T0 + 1L)
  set_at(jar, "http://www.a.com/", "w=3", T0 + 2L)
  set_at(jar, "http://a.com/", "x=4; Domain=a.com", T0 + 3L)
  assert_eq(pairs(jar), ["d=2", "x=4", "w=3"])
}

///|
test "the total cap evicts expired cookies, then the least recently accessed" {
  let jar = test_jar(max_total=3)
  set_at(jar, "http://a.com/", "a=1", T0)
  set_at(jar, "http://b.com/", "b=1; Max-Age=1", T0 + 1L)
  set_at(jar, "http://c.com/", "c=1", T0 + 2L)
  set_at(jar, "http://d.com/", "d=1", T0 + 5_000L)
  assert_eq(pairs(jar), ["a=1", "c=1", "d=1"])
  set_at(jar, "http://e.com/", "e=1", T0 + 5_001L)
  assert_eq(pairs(jar), ["c=1", "d=1", "e=1"])
  assert_eq(jar.length(), 3)
}

///|
test "zero or negative caps keep nothing" {
  for jar in [test_jar(max_per_domain=0), test_jar(max_total=-1)] {
    set_at(jar, "http://a.com/", "a=1", T0)
    assert_eq(jar.length(), 0)
    assert_eq(get_at(jar, "http://a.com/", T0), None)
  }
}

///|
test "the default caps are 50 cookies per domain and 3000 in all" {
  let jar = test_jar()
  for i in 0..<51 {
    set_at(jar, "http://a.com/", "c\{i}=v", T0 + i.to_int64())
  }
  assert_eq(jar.length(), 50)
  assert_false(pairs(jar).contains("c0=v"))
  assert_true(pairs(jar).contains("c50=v"))
  jar.clear()
  let mut now = T0
  for domain in 0..<61 {
    for i in 0..<50 {
      now += 1L
      set_at(jar, "http://d\{domain}.com/", "c\{i}=v", now)
    }
  }
  assert_eq(jar.length(), 3000)
  assert_eq(jar.iter().count(), 3000)
  assert_eq(get_at(jar, "http://d0.com/", now), None)
  assert_true(get_at(jar, "http://d60.com/", now) is Some(_))
}

///|
/// Cookie names, hosts, paths and attributes that overlap often enough to
/// exercise domain and path matching, replacement, expiry and eviction.
fn random_set_cookie(rand : @random.Rand, value : Int32) -> String {
  let names = ["a", "b", "__Secure-s", "__Host-h"]
  let line = StringBuilder()
  line.write_string(names[rand.int(limit=names.length())] + "=\{value}")
  let attributes = [
    "; Domain=example.com", "; Domain=a.example.com", "; Domain=com", "; Domain=other.org",
    "; Path=/", "; Path=/x", "; Path=/x/y", "; Path=x", "; Secure", "; HttpOnly",
    "; Max-Age=0", "; Max-Age=-3", "; Max-Age=2", "; Max-Age=50", "; Expires=Sun, 13 Sep 2020 12:26:41 GMT",
    "; Expires=Sun, 06 Nov 1994 08:49:37 GMT",
  ]
  for _ in 0..<rand.int(limit=4) {
    line.write_string(attributes[rand.int(limit=attributes.length())])
  }
  line.to_string()
}

///|
fn random_url(rand : @random.Rand) -> String {
  let schemes = ["http", "https"]
  let hosts = [
    "example.com", "a.example.com", "b.a.example.com", "other.org", "10.0.0.1", "com",
  ]
  let paths = ["", "/", "/x", "/x/", "/x/y", "/x/y/z", "/xy", "/q"]
  schemes[rand.int(limit=2)] +
  "://" +
  hosts[rand.int(limit=hosts.length())] +
  paths[rand.int(limit=paths.length())]
}

///|
test "header_for sends exactly the live matching cookies, longest path first" {
  let rand = @random.Rand::chacha8(seed=b"gaato/http cookie jar property 1")
  for round in 0..<200 {
    let jar = test_jar(max_per_domain=4, max_total=8)
    let mut now = T0
    let mut value = 0
    for step in 0..<40 {
      now += rand.int(limit=1500).to_int64()
      if rand.int(limit=3) > 0 {
        value += 1
        set_at(jar, random_url(rand), random_set_cookie(rand, value), now)
        continue
      }
      let request = random_url(rand)
      let url = parse_request_url(request).unwrap()
      let stored = jar.iter().collect()
      let expected = stored.filter(c => {
        !c.is_expired(now) &&
        (if c.host_only {
          url.host == c.domain
        } else {
          domain_match(url.host, c.domain)
        }) &&
        path_match(url.path, c.path) &&
        (!c.secure || url.is_secure())
      })
      let label = "round \{round} step \{step} \{request}"
      match jar.header_at(url, now) {
        None => assert_eq(expected.length(), 0, msg=label)
        Some(header) => {
          let sent = header.split("; ").map(p => p.to_owned()).collect()
          let wanted = expected.map(c => c.name + "=" + c.value)
          assert_eq(sent.copy()..sort(), wanted..sort(), msg=label)
          // Values are unique, so each pair names one stored cookie.
          let path_lengths = sent.map(pair => {
            let c = stored
              .search_by(c => c.name + "=" + c.value == pair)
              .map(i => stored[i])
              .unwrap()
            c.path.length()
          })
          for i in 1..<path_lengths.length() {
            assert_true(path_lengths[i - 1] >= path_lengths[i], msg=label)
          }
        }
      }
      // No expired cookie survives a request that met it, and the caps hold.
      assert_true(jar.length() <= 8, msg=label)
      for _, entries in jar.domains {
        assert_true(entries.length() <= 4, msg=label)
      }
      assert_eq(jar.iter().count(), jar.length(), msg=label)
      for c in jar.iter() {
        assert_false(c.domain == "com" && !c.host_only, msg=label)
        assert_false(c.domain == "10.0.0.1" && !c.host_only, msg=label)
      }
    }
  }
}
