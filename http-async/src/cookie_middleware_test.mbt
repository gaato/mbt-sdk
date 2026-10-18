// Executes gaato/http/cookie's middleware step against the scripted
// transport; gaato/http cannot run an async test itself.

///|
fn with_cookies(
  location : String?,
  set_cookie : Array[String],
) -> @http.Response {
  let headers = @http.Headers::new()
  if location is Some(location) {
    headers.append("Location", location)
  }
  for value in set_cookie {
    headers.append("Set-Cookie", value)
  }
  { status: if location is Some(_) { 302 } else { 200 }, headers, body: b"", }
}

///|
fn sent_cookies(fake : @mock.FakeTransport) -> Array[String] {
  fake
  .sent()
  .map(request => {
    let cookies = request.headers.get_all("cookie")
    request.url + " [" + cookies.join(" | ") + "]"
  })
}

///|
/// A stand-in for `@http.redirects`: it follows absolute `Location`s and
/// sends each hop through the inner steps with the caller's headers, as the
/// redirect step does for same-origin hops.
fn follow_hops() -> @http.Middleware {
  (request, next) => {
    let mut request = request
    for hops = 0; hops < 5; hops = hops + 1 {
      let response = next(request)
      guard response.status / 100 == 3 &&
        response.headers.get("location") is Some(location) else {
        return response
      }
      request = { ..request, url: location, }
    }
    raise @http.HttpError::Protocol("too many hops")
  }
}

///|
async test "cookies sends the jar's cookies and stores what responses set" {
  let jar = @cookie.CookieJar::new(@mock.FakeClock::new())
  let fake = @mock.FakeTransport::new()
  fake.expect(
    "GET",
    "https://a.example/login",
    with_cookies(None, ["sid=1; Path=/", "pref=x; Path=/login"]),
  )
  fake.expect("GET", "https://a.example/home", with_cookies(None, []))
  fake.expect("GET", "https://b.example/", with_cookies(None, []))
  let steps = [@cookie.cookies(jar)]
  for
    url in [
      "https://a.example/login", "https://a.example/home", "https://b.example/",
    ] {
    let response = @http.send_with(fake, steps, @http.Request::get(url))
    assert_eq(response.status, 200)
  }
  assert_eq(sent_cookies(fake), [
    "https://a.example/login []", "https://a.example/home [sid=1]", "https://b.example/ []",
  ])
  fake.assert_complete()
}

///|
async test "cookies leaves an explicit Cookie header alone but still stores" {
  let jar = @cookie.CookieJar::new(@mock.FakeClock::new())
  jar.store(
    @http.Headers::from_array([("Set-Cookie", "sid=1")]),
    "https://a.example/",
  )
  let fake = @mock.FakeTransport::new()
  fake.expect("GET", "https://a.example/", with_cookies(None, ["new=2"]))
  let request = @http.Request::get("https://a.example/").header(
    "Cookie", "mine=9",
  )
  let _ = @http.send_with(fake, [@cookie.cookies(jar)], request)
  assert_eq(sent_cookies(fake), ["https://a.example/ [mine=9]"])
  assert_eq(jar.header_for("https://a.example/"), Some("sid=1; new=2"))
}

///|
async test "cookies stores nothing when the request fails" {
  let jar = @cookie.CookieJar::new(@mock.FakeClock::new())
  let fake = @mock.FakeTransport::new()
  fake.expect_error("GET", "https://a.example/", @http.HttpError::Timeout(5))
  let failed = try
    @http.send_with(
      fake,
      [@cookie.cookies(jar)],
      @http.Request::get("https://a.example/"),
    )
  catch {
    Timeout(5) => true
    _ => false
  } noraise {
    _ => false
  }
  assert_true(failed)
  assert_eq(jar.length(), 0)
}

///|
async test "inside a redirect step every hop stores and sends its own cookies" {
  let jar = @cookie.CookieJar::new(@mock.FakeClock::new())
  let fake = @mock.FakeTransport::new()
  fake.expect(
    "GET",
    "https://a.example/start",
    with_cookies(Some("https://a.example/next"), ["a=1"]),
  )
  fake.expect(
    "GET",
    "https://a.example/next",
    with_cookies(Some("https://b.example/hop"), ["n=2; Path=/next"]),
  )
  fake.expect(
    "GET",
    "https://b.example/hop",
    with_cookies(Some("https://a.example/final"), ["b=3"]),
  )
  fake.expect("GET", "https://a.example/final", with_cookies(None, []))
  let response = @http.send_with(
    fake,
    [follow_hops(), @cookie.cookies(jar)],
    @http.Request::get("https://a.example/start"),
  )
  assert_eq(response.status, 200)
  assert_eq(sent_cookies(fake), [
    "https://a.example/start []", "https://a.example/next [a=1]", "https://b.example/hop []",
    "https://a.example/final [a=1]",
  ])
  assert_eq(jar.iter().map(cookie => cookie.name).collect(), ["a", "n", "b"])
  fake.assert_complete()
}

///|
async test "outside a redirect step intermediate cookies are lost" {
  let jar = @cookie.CookieJar::new(@mock.FakeClock::new())
  let fake = @mock.FakeTransport::new()
  fake.expect(
    "GET",
    "https://a.example/start",
    with_cookies(Some("https://a.example/next"), ["a=1"]),
  )
  fake.expect("GET", "https://a.example/next", with_cookies(None, []))
  let _ = @http.send_with(
    fake,
    [@cookie.cookies(jar), follow_hops()],
    @http.Request::get("https://a.example/start"),
  )
  assert_eq(sent_cookies(fake), [
    "https://a.example/start []", "https://a.example/next []",
  ])
  assert_eq(jar.length(), 0)
}

///|
async test "a streaming caller attaches before send_stream and stores the head" {
  let jar = @cookie.CookieJar::new(@mock.FakeClock::new())
  jar.store(
    @http.Headers::from_array([("Set-Cookie", "sid=1")]),
    "https://a.example/",
  )
  let fake = @mock.FakeTransport::new()
  fake.expect_stream(
    "GET",
    "https://a.example/events",
    {
      status: 200,
      headers: @http.Headers::from_array([("Set-Cookie", "seen=1")]),
    },
    [b"data: x\n\n"],
  )
  let request = @http.Request::get("https://a.example/events")
  let (head, body) = fake.send_stream(jar.attach(request))
  jar.store(head.headers, request.url)
  body.close()
  assert_eq(sent_cookies(fake), ["https://a.example/events [sid=1]"])
  assert_eq(jar.header_for("https://a.example/"), Some("sid=1; seen=1"))
}
