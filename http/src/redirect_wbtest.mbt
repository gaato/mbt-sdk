///|
test "redirect_status follows 301, 302, 303, 307 and 308 only" {
  let followed = []
  for status in 100..<600 {
    if redirect_status(status) {
      followed.push(status)
    }
  }
  assert_eq(followed, [301, 302, 303, 307, 308])
}

///|
test "redirect_method rewrites like Fetch and httpx" {
  let cases : Array[(Int32, String, String)] = [
    (301, "GET", "GET"),
    (301, "POST", "GET"),
    (301, "post", "GET"),
    (301, "PUT", "PUT"),
    (301, "HEAD", "HEAD"),
    (302, "POST", "GET"),
    (302, "DELETE", "DELETE"),
    (303, "POST", "GET"),
    (303, "PUT", "GET"),
    (303, "PATCH", "GET"),
    (303, "DELETE", "GET"),
    (303, "GET", "GET"),
    (303, "get", "get"),
    (303, "HEAD", "HEAD"),
    (303, "head", "head"),
    (307, "POST", "POST"),
    (307, "PUT", "PUT"),
    (308, "POST", "POST"),
    (308, "DELETE", "DELETE"),
  ]
  for case in cases {
    assert_eq((case.0, case.1, redirect_method(case.0, case.1)), case)
  }
}

///|
fn target(request_url : String, location : String) -> String {
  try redirect_target(request_url, location) catch {
    BadLocation(reason~, ..) => "refused: " + reason
    error => "unexpected: " + @debug.to_string(error)
  } noraise {
    (_, to) => to.to_string()
  }
}

///|
test "redirect_target resolves the Location against the request URL" {
  let cases = [
    ("https://h/a/b?q", "/c", "https://h/c"),
    ("https://h/a/b?q", "c", "https://h/a/c"),
    ("https://h/a/b?q", "?r", "https://h/a/b?r"),
    ("https://h/a/b?q", "", "https://h/a/b?q"),
    ("https://h/a/b#f", "#g", "https://h/a/b#g"),
    ("https://h/a/b", "//g/x", "https://g/x"),
    ("https://h/a/b", "HTTP://G:80/x/../y", "http://g/y"),
    ("https://h/a/b", "https://g/ä b", "https://g/%C3%A4%20b"),
    ("http://h:8080/a", "../../x", "http://h:8080/x"),
    ("https://h/a", "mailto:x@y", "refused: not an http or https URL"),
    ("https://h/a", "ftp://h/x", "refused: not an http or https URL"),
    ("https://h/a", "http:g", "refused: no host"),
    ("https://h/a", "http:///x", "refused: no host"),
    ("https://h/a", "https://h:99999/", "refused: port exceeds 65535"),
    (
      "https://h/a", "https://bücher.example/", "refused: non-ASCII host; pass its IDNA (xn--) form",
    ),
    ("/a", "/b", "refused: request URL is not absolute http(s)"),
    ("https://h:x/", "/b", "refused: request URL: port is not a number"),
  ]
  for case in cases {
    assert_eq((case.0, case.1, target(case.0, case.1)), case)
  }
}

///|
fn kept(
  from : String,
  to : String,
  drop_body~ : Bool = false,
  credential_headers~ : Array[String] = [],
) -> Array[String] raise UrlError {
  let headers = Headers::from_array([
    ("Authorization", "Bearer t"),
    ("Cookie", "c=1"),
    ("Proxy-Authorization", "Basic p"),
    ("Host", "h"),
    ("X-Api-Key", "k"),
    ("Content-Type", "application/json"),
    ("Content-Length", "2"),
    ("Transfer-Encoding", "chunked"),
    ("Content-Encoding", "gzip"),
    ("Content-Language", "en"),
    ("Content-Location", "/x"),
    ("Accept", "*/*"),
  ])
  redirect_headers(
    headers,
    from=Url::parse(from),
    to=Url::parse(to),
    drop_body~,
    credential_headers~,
  )
  .iter()
  .map(pair => pair.0)
  .to_array()
}

///|
test "redirect_headers strips credentials across origins and body headers on GET" {
  let all = [
    "authorization", "cookie", "proxy-authorization", "host", "x-api-key", "content-type",
    "content-length", "transfer-encoding", "content-encoding", "content-language",
    "content-location", "accept",
  ]
  let body = [
    "content-type", "content-length", "transfer-encoding", "content-encoding", "content-language",
    "content-location",
  ]
  let credentials = ["authorization", "cookie", "proxy-authorization"]
  let without = (names : Array[String]) => {
    all.filter(name => !names.contains(name))
  }
  // Same origin, including a default port written out.
  assert_eq(kept("https://h/a", "https://h:443/b"), all)
  assert_eq(kept("https://h/a", "https://h/b", drop_body=true), without(body))
  // Another host, scheme or port.
  assert_eq(
    kept("https://h/a", "https://g/a"),
    without([..credentials, "host"]),
  )
  assert_eq(
    kept("https://h/a", "https://h:8443/a"),
    without([..credentials, "host"]),
  )
  assert_eq(kept("https://h/a", "http://h/a"), without([..credentials, "host"]))
  assert_eq(
    kept("https://h/a", "https://g/a", drop_body=true),
    without([..credentials, "host", ..body]),
  )
  // Caller-named credentials go with the standard ones, in any case.
  assert_eq(
    kept("https://h/a", "https://g/a", credential_headers=["X-API-KEY"]),
    without([..credentials, "host", "x-api-key"]),
  )
  assert_eq(
    kept("https://h/a", "https://h/b", credential_headers=["x-api-key"]),
    all,
  )
  // The same-host upgrade to https on default ports keeps credentials.
  assert_eq(kept("http://h/a", "https://h/a"), without(["host"]))
  assert_eq(
    kept("http://h:80/a", "https://h:443/a", credential_headers=["x-api-key"]),
    without(["host"]),
  )
  // Not an upgrade: another host, a non-default port, or the other direction.
  assert_eq(kept("http://h/a", "https://g/a"), without([..credentials, "host"]))
  assert_eq(
    kept("http://h:8080/a", "https://h/a"),
    without([..credentials, "host"]),
  )
  assert_eq(
    kept("http://h/a", "https://h:8443/a"),
    without([..credentials, "host"]),
  )
}

///|
fn plan(
  request : Request,
  status : Int32,
  location? : String,
  followed~ : Int32 = 0,
  max_redirects~ : Int32 = 10,
  allow_downgrade~ : Bool = false,
) -> String {
  let headers = Headers::new()
  if location is Some(location) {
    headers.set("Location", location)
  }
  try
    plan_redirect(
      request,
      { status, headers, },
      followed~,
      max_redirects~,
      allow_downgrade~,
      credential_headers=[],
    )
  catch {
    TooManyRedirects(max~, location~) =>
      "too many: " + max.to_string() + " " + location
    Downgrade(location~) => "downgrade: " + location
    BadLocation(location~, reason~) => "bad: " + location + " " + reason
    UnreplayableBody(location~) => "unreplayable: " + location
    Transport(_) => "transport"
  } noraise {
    None => "stop"
    Some(next) => {
      let body = match next.body {
        Bytes(bytes) => @utf8.decode_lossy(bytes)
        Stream(_) if physical_equal(next.body, request.body) => "<same stream>"
        Stream(_) => "<other stream>"
      }
      let headers = next.headers.iter().map(pair => pair.0).to_array()
      "\{next.http_method} \{next.url} \{body} [\{headers.join(", ")}]"
    }
  }
}

///|
test "plan_redirect decides each hop" {
  let post = Request::post("https://h/a?q#f")
    .header("Content-Type", "text/plain")
    .header("Authorization", "Bearer t")
    .body_text("data")
  let cases = [
    (plan(post, 200, location="/b"), "stop"),
    (plan(post, 304, location="/b"), "stop"),
    (plan(post, 300, location="/b"), "stop"),
    (plan(post, 302), "stop"),
    (plan(post, 302, location="/b"), "GET https://h/b  [authorization]"),
    (
      plan(post, 307, location="/b#frag"),
      "POST https://h/b data [content-type, authorization]",
    ),
    (
      plan(post, 308, location="https://g/b"),
      "POST https://g/b data [content-type]",
    ),
    (plan(post, 303, location=""), "GET https://h/a?q  [authorization]"),
    (plan(post, 301, location="http://h/b"), "downgrade: http://h/b"),
    (
      plan(post, 301, location="http://h/b", allow_downgrade=true),
      "GET http://h/b  []",
    ),
    (
      plan(post, 301, location="/b", followed=9),
      "GET https://h/b  [authorization]",
    ),
    (plan(post, 301, location="/b", followed=10), "too many: 10 https://h/b"),
    (plan(post, 301, location="/b", max_redirects=0), "too many: 0 https://h/b"),
    (
      plan(post, 301, location="/b", max_redirects=-1),
      "too many: -1 https://h/b",
    ),
    (
      plan(post, 301, location="ftp://h/"),
      "bad: ftp://h/ not an http or https URL",
    ),
    // A refused downgrade wins over the count: the caller can only fix one.
    (
      plan(post, 301, location="http://h/b", followed=10),
      "downgrade: http://h/b",
    ),
  ]
  for case in cases {
    assert_eq(case.0, case.1)
  }
  // A GET with a body keeps it on 303, as Fetch does.
  let get = Request::get("https://h/a").body_text("x")
  assert_eq(plan(get, 303, location="/b"), "GET https://h/b x []")
}

///|
/// A stream that is never read: `plan_redirect` only asks whether it was taken.
priv struct Unread {}

///|
impl BodyStream for Unread with fn read_some(_) {
  None
}

///|
impl BodyStream for Unread with fn close(_) {
  ()
}

///|
test "plan_redirect refuses to resend a stream body that was sent" {
  let fresh = (http_method : String) => {
    Request::new(http_method, "https://h/a").body_stream(Unread::{ }, length=0)
  }
  let sent = (http_method : String) => {
    let request = fresh(http_method)
    guard! request.body is Stream(stream)
    ignore(stream.take())
    request
  }
  let cases = [
    // A redirect that keeps the method keeps the body: a sent stream is gone.
    (plan(sent("POST"), 307, location="/b"), "unreplayable: https://h/b"),
    (plan(sent("PUT"), 308, location="/b"), "unreplayable: https://h/b"),
    (plan(sent("PUT"), 301, location="/b"), "unreplayable: https://h/b"),
    (plan(sent("PUT"), 302, location="/b"), "unreplayable: https://h/b"),
    // One that turns the request into GET drops the body, so it is followed.
    (plan(sent("POST"), 301, location="/b"), "GET https://h/b  []"),
    (plan(sent("POST"), 302, location="/b"), "GET https://h/b  []"),
    (plan(sent("PUT"), 303, location="/b"), "GET https://h/b  []"),
    // A stream nobody has taken yet goes along unread.
    (plan(fresh("PUT"), 307, location="/b"), "PUT https://h/b <same stream> []"),
    // Refusals the caller must fix first still win.
    (plan(sent("POST"), 307, location="http://h/b"), "downgrade: http://h/b"),
    (
      plan(sent("POST"), 307, location="/b", max_redirects=0),
      "too many: 0 https://h/b",
    ),
    (plan(sent("POST"), 200, location="/b"), "stop"),
  ]
  for case in cases {
    assert_eq(case.0, case.1)
  }
}

///|
test "redirect_failure maps refusals to protocol errors" {
  let cases : Array[(RedirectError, String)] = [
    (Transport(Timeout(phase=Head, ms=5)), "Timeout(phase=Head, ms=5)"),
    (Transport(Connect("no route")), "Connect(\"no route\")"),
    (
      TooManyRedirects(max=3, location="https://h/x"),
      "Protocol(\"more than 3 redirects; last to https://h/x\")",
    ),
    (
      Downgrade(location="http://h/x"),
      "Protocol(\"refused redirect to http: http://h/x\")",
    ),
    (
      BadLocation(location="ftp://h", reason="not an http or https URL"),
      "Protocol(\"bad redirect Location \\\"ftp://h\\\": not an http or https URL\")",
    ),
    (
      UnreplayableBody(location="https://h/x"),
      "Protocol(\"refused redirect to https://h/x: the stream request body was already sent\")",
    ),
  ]
  for case in cases {
    assert_eq(@debug.to_string(redirect_failure(case.0)), case.1)
  }
}
