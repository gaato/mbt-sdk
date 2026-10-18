// Executes gaato/http's redirect step against the scripted transport;
// gaato/http cannot run an async test itself.

///|
fn redirect_to(status : Int32, location : String) -> @http.Response {
  {
    status,
    headers: @http.Headers::from_array([("Location", location)]),
    body: b"moved",
  }
}

///|
fn final_ok() -> @http.Response {
  { status: 200, headers: @http.Headers::new(), body: b"done", }
}

///|
fn send_via(
  fake : @mock.FakeTransport,
) -> async (@http.Request) -> @http.Response raise @http.HttpError {
  request => fake.send(request)
}

///|
fn summary(request : @http.Request) -> String {
  let headers = request.headers.iter().map(pair => pair.0).to_array()
  "\{request.http_method} \{request.url} \{@utf8.decode_lossy(request.body)} [\{headers.join(", ")}]"
}

///|
async test "follow_redirects rewrites, strips and reports each hop" {
  let fake = @mock.FakeTransport::new()
  fake.expect(
    "POST",
    "https://api.example/upload",
    redirect_to(302, "/v2/upload?x=é#frag"),
  )
  fake.expect(
    "GET",
    "https://api.example/v2/upload?x=%C3%A9",
    redirect_to(307, "https://cdn.example/o"),
  )
  fake.expect(
    "GET",
    "https://cdn.example/o",
    redirect_to(308, "http://cdn.example/plain"),
  )
  let request = @http.Request::post("https://api.example/upload")
    .header("Authorization", "Bearer t")
    .header("Content-Type", "application/json")
    .header("Accept", "application/json")
    .body_text("{}")
  let hops = []
  let refused = try
    @http.follow_redirects(request, send_via(fake), on_redirect=hop => {
      hops.push(hop)
    })
  catch {
    Downgrade(location~) => location
    _ => "unexpected error"
  } noraise {
    _ => "followed a downgrade"
  }
  assert_eq(refused, "http://cdn.example/plain")
  assert_eq(fake.sent().map(summary), [
    "POST https://api.example/upload {} [authorization, content-type, accept]", "GET https://api.example/v2/upload?x=%C3%A9  [authorization, accept]",
    "GET https://cdn.example/o  [accept]",
  ])
  assert_eq(hops.map(hop => hop.response.status), [302, 307])
  assert_eq(hops.map(hop => hop.request.url), [
    "https://api.example/upload", "https://api.example/v2/upload?x=%C3%A9",
  ])
  assert_eq(hops.map(hop => hop.next.url), [
    "https://api.example/v2/upload?x=%C3%A9", "https://cdn.example/o",
  ])
  fake.assert_complete()
}

///|
async test "307 and 308 resend the method and body; a final response ends the chain" {
  let fake = @mock.FakeTransport::new()
  fake.expect("PUT", "/a", redirect_to(307, "/b"))
  fake.expect("PUT", "/b", redirect_to(308, "/c"))
  fake.expect("PUT", "/c", redirect_to(303, "/d"))
  fake.expect("GET", "/d", final_ok())
  let request = @http.Request::put("http://h/a")
    .header("Content-Type", "text/plain")
    .body_text("payload")
  let response = @http.follow_redirects(request, send_via(fake))
  assert_eq(response.body, b"done")
  assert_eq(fake.sent().map(summary), [
    "PUT http://h/a payload [content-type]", "PUT http://h/b payload [content-type]",
    "PUT http://h/c payload [content-type]", "GET http://h/d  []",
  ])
  fake.assert_complete()
}

///|
async test "a 3xx without Location, or one not followed, is returned as it is" {
  let fake = @mock.FakeTransport::new()
  let no_location : @http.Response = {
    status: 302,
    headers: @http.Headers::new(),
    body: b"",
  }
  fake.expect("GET", "/a", no_location)
  fake.expect("GET", "/b", redirect_to(304, "/elsewhere"))
  let send = send_via(fake)
  assert_eq(
    @http.follow_redirects(@http.Request::get("http://h/a"), send),
    no_location,
  )
  assert_eq(
    @http.follow_redirects(@http.Request::get("http://h/b"), send).status,
    304,
  )
  fake.assert_complete()
}

///|
async test "redirects stop at max_redirects, 10 by default" {
  for max in [None, Some(0), Some(2)] {
    let limit = max.unwrap_or(10)
    let fake = @mock.FakeTransport::new()
    for i in 0..<=limit {
      fake.expect("GET", "/r\{i}", redirect_to(301, "/r\{i + 1}"))
    }
    let hops = []
    let error = try
      @http.follow_redirects(
        @http.Request::get("https://h/r0"),
        send_via(fake),
        max_redirects?=max,
        on_redirect=hop => hops.push(hop),
      )
    catch {
      TooManyRedirects(max~, location~) => (max, location)
      _ => (-1, "unexpected error")
    } noraise {
      _ => (-1, "no error")
    }
    assert_eq(error, (limit, "https://h/r\{limit + 1}"))
    // The limit is followed; the response one past it is not.
    assert_eq(hops.length(), limit)
    assert_eq(fake.sent().length(), limit + 1)
    fake.assert_complete()
  }
}

///|
async test "allow_downgrade follows https to http without credentials" {
  let fake = @mock.FakeTransport::new()
  fake.expect("GET", "https://h/a", redirect_to(301, "http://h/b"))
  fake.expect("GET", "http://h/b", redirect_to(301, "https://h/c"))
  fake.expect("GET", "https://h/c", final_ok())
  let request = @http.Request::get("https://h/a")
    .header("Authorization", "Bearer t")
    .header("Cookie", "c=1")
    .header("X-Api-Key", "k")
  let _ = @http.follow_redirects(
    request,
    send_via(fake),
    allow_downgrade=true,
    credential_headers=["x-api-key"],
  )
  // Stripped at the downgrade; the upgrade back does not restore them.
  assert_eq(fake.sent().map(summary), [
    "GET https://h/a  [authorization, cookie, x-api-key]", "GET http://h/b  []",
    "GET https://h/c  []",
  ])
  fake.assert_complete()
}

///|
async test "a same-host upgrade to https keeps credentials" {
  let fake = @mock.FakeTransport::new()
  fake.expect("GET", "http://h/a", redirect_to(301, "https://h/a"))
  fake.expect("GET", "https://h/a", redirect_to(302, "https://other/a"))
  fake.expect("GET", "https://other/a", final_ok())
  let request = @http.Request::get("http://h/a")
    .header("Authorization", "Bearer t")
    .header("Host", "h")
  let _ = @http.follow_redirects(request, send_via(fake))
  assert_eq(fake.sent().map(summary), [
    "GET http://h/a  [authorization, host]", "GET https://h/a  [authorization]",
    "GET https://other/a  []",
  ])
  fake.assert_complete()
}

///|
async test "redirects as middleware maps refusals to Protocol and passes transport errors" {
  let fake = @mock.FakeTransport::new()
  fake.expect("GET", "/a", redirect_to(302, "/b"))
  fake.expect("GET", "/b", final_ok())
  fake.expect("GET", "/c", redirect_to(302, "/d"))
  fake.expect_error("GET", "/d", @http.HttpError::Timeout(7))
  fake.expect("GET", "/e", redirect_to(302, "ftp://h/f"))
  fake.expect("GET", "/g", redirect_to(302, "/h"))
  let hops = []
  let seen = []
  let log : @http.Middleware = (request, next) => {
    seen.push(request.url)
    next(request)
  }
  let chain = [@http.redirects(max_redirects=0), log]
  let follow = [@http.redirects(on_redirect=hop => hops.push(hop)), log]
  let response = @http.send_with(fake, follow, @http.Request::get("http://h/a"))
  assert_eq(response.body, b"done")
  assert_eq(hops.length(), 1)
  // Every hop goes through the steps after the redirect step.
  assert_eq(seen, ["http://h/a", "http://h/b"])
  let failure = async fn(steps, url) {
    try @http.send_with(fake, steps, @http.Request::get(url)) catch {
      error => @debug.to_string(error)
    } noraise {
      _ => "no error"
    }
  }
  assert_eq(failure(follow, "http://h/c"), "Timeout(7)")
  assert_eq(
    failure(follow, "http://h/e"),
    "Protocol(\"bad redirect Location \\\"ftp://h/f\\\": not an http or https URL\")",
  )
  assert_eq(
    failure(chain, "http://h/g"),
    "Protocol(\"more than 0 redirects; last to http://h/h\")",
  )
  fake.assert_complete()
}

///|
async test "a transport failure mid-chain is RedirectError::Transport" {
  let fake = @mock.FakeTransport::new()
  fake.expect("GET", "/a", redirect_to(302, "/b"))
  fake.expect_error("GET", "/b", @http.HttpError::Connect("refused"))
  let error = try
    @http.follow_redirects(@http.Request::get("http://h/a"), send_via(fake))
  catch {
    Transport(error) => @debug.to_string(error)
    _ => "unexpected error"
  } noraise {
    _ => "no error"
  }
  assert_eq(error, "Connect(\"refused\")")
  fake.assert_complete()
}

///|
/// Wraps a stream to count its reads and every `close` call, repeats included.
struct CountedStream {
  inner : &@http.BodyStream
  url : String
  log : Array[String]
}

///|
impl @http.BodyStream for CountedStream with fn read_some(self) {
  self.log.push("read " + self.url)
  self.inner.read_some()
}

///|
impl @http.BodyStream for CountedStream with fn close(self) {
  self.log.push("close " + self.url)
  self.inner.close()
}

///|
fn stream_via(
  fake : @mock.FakeTransport,
  log : Array[String],
) -> async (@http.Request) -> (@http.ResponseHead, &@http.BodyStream) raise @http.HttpError {
  request => {
    let (head, stream) = fake.send_stream(request)
    (head, CountedStream::{ inner: stream, url: request.url, log, })
  }
}

///|
fn moved(status : Int32, location : String) -> @http.ResponseHead {
  { status, headers: @http.Headers::from_array([("Location", location)]), }
}

///|
async fn read_all(stream : &@http.BodyStream) -> Bytes raise @http.HttpError {
  let buffer = Buffer()
  while stream.read_some() is Some(chunk) {
    buffer.write_bytes(chunk)
  }
  buffer.to_bytes()
}

///|
async test "follow_redirects_stream closes each 3xx unread and returns the final stream" {
  let fake = @mock.FakeTransport::new()
  let log = []
  fake.expect_stream("POST", "https://api.example/a", moved(302, "/b"), [
    b"moved",
  ])
  fake.expect_stream(
    "GET",
    "https://api.example/b",
    moved(307, "https://objects.example/f?sig=1"),
    [b"moved"],
  )
  fake.expect_stream(
    "GET",
    "https://objects.example/f?sig=1",
    { status: 200, headers: @http.Headers::new(), },
    [b"he", b"llo"],
  )
  let request = @http.Request::post("https://api.example/a")
    .header("Authorization", "Bearer t")
    .header("Content-Type", "text/plain")
    .header("Accept", "*/*")
    .body_text("x")
  let hops = []
  let (head, stream) = @http.follow_redirects_stream(
    request,
    stream_via(fake, log),
    on_redirect=hop => {
      log.push("hop \{hop.head.status} \{hop.next.url}")
      hops.push(hop)
    },
  )
  assert_eq(head.status, 200)
  // Each intermediate stream is closed once, before its hop is reported and
  // the next request sent; none is read.
  assert_eq(log, [
    "close https://api.example/a", "hop 302 https://api.example/b", "close https://api.example/b",
    "hop 307 https://objects.example/f?sig=1",
  ])
  assert_eq(read_all(stream), b"hello")
  stream.close()
  assert_eq(fake.streams_closed(), 3)
  assert_eq(fake.sent().map(summary), [
    "POST https://api.example/a x [authorization, content-type, accept]", "GET https://api.example/b  [authorization, accept]",
    "GET https://objects.example/f?sig=1  [accept]",
  ])
  assert_eq(hops.map(hop => hop.request.url), [
    "https://api.example/a", "https://api.example/b",
  ])
  fake.assert_complete()
}

///|
async test "follow_redirects_stream closes the 3xx it refuses" {
  // (max_redirects, allow_downgrade, script, expected outcome)
  let cases : Array[(Int32?, Bool, Array[(String, @http.ResponseHead)], String)] = [
    (
      Some(1),
      false,
      [("https://h/0", moved(301, "/1")), ("https://h/1", moved(301, "/2"))],
      "too many: 1 https://h/2",
    ),
    (
      None,
      false,
      [("https://h/0", moved(308, "http://h/1"))],
      "downgrade: http://h/1",
    ),
    (
      None,
      false,
      [("https://h/0", moved(302, "mailto:x@y"))],
      "bad: not an http or https URL",
    ),
    (
      Some(0),
      false,
      [("https://h/0", moved(303, "/1"))],
      "too many: 0 https://h/1",
    ),
  ]
  for case in cases {
    let (max, allow_downgrade, script, expected) = case
    let fake = @mock.FakeTransport::new()
    let log = []
    for step in script {
      fake.expect_stream("GET", step.0, step.1, [b"moved"])
    }
    let outcome = try
      @http.follow_redirects_stream(
        @http.Request::get("https://h/0"),
        stream_via(fake, log),
        max_redirects?=max,
        allow_downgrade~,
      )
    catch {
      TooManyRedirects(max~, location~) => "too many: \{max} \{location}"
      Downgrade(location~) => "downgrade: " + location
      BadLocation(reason~, ..) => "bad: " + reason
      Transport(_) => "transport"
    } noraise {
      _ => "followed"
    }
    assert_eq(outcome, expected)
    assert_eq(log, script.map(step => "close " + step.0))
    fake.assert_complete()
  }
}

///|
async test "follow_redirects_stream stops at 10 redirects by default" {
  let fake = @mock.FakeTransport::new()
  let log = []
  for i in 0..<=10 {
    fake.expect_stream("GET", "/r\{i}", moved(302, "/r\{i + 1}"), [])
  }
  let outcome = try
    @http.follow_redirects_stream(
      @http.Request::get("https://h/r0"),
      stream_via(fake, log),
    )
  catch {
    TooManyRedirects(max~, ..) => max
    _ => -1
  } noraise {
    _ => -2
  }
  assert_eq(outcome, 10)
  assert_eq(log.length(), 11)
  assert_eq(log.filter(line => line.has_prefix("close")).length(), 11)
  fake.assert_complete()
}

///|
async test "follow_redirects_stream downgrades on request, without credentials" {
  let fake = @mock.FakeTransport::new()
  let log = []
  fake.expect_stream("GET", "https://h/a", moved(301, "http://h/b"), [])
  fake.expect_stream(
    "GET",
    "http://h/b",
    { status: 404, headers: @http.Headers::new(), },
    [b"gone"],
  )
  let request = @http.Request::get("https://h/a")
    .header("Authorization", "Bearer t")
    .header("X-Api-Key", "k")
  let (head, stream) = @http.follow_redirects_stream(
    request,
    stream_via(fake, log),
    allow_downgrade=true,
    credential_headers=["X-Api-Key"],
  )
  // A non-redirect status is a final response like any other.
  assert_eq(head.status, 404)
  assert_eq(read_all(stream), b"gone")
  stream.close()
  assert_eq(fake.sent().map(summary), [
    "GET https://h/a  [authorization, x-api-key]", "GET http://h/b  []",
  ])
  assert_eq(log, [
    "close https://h/a", "read http://h/b", "read http://h/b", "close http://h/b",
  ])
  fake.assert_complete()
}

///|
async test "follow_redirects_stream leaves no stream open on a later failure or cancellation" {
  // A transport failure on the second hop.
  let fake = @mock.FakeTransport::new()
  let log = []
  fake.expect_stream("GET", "/a", moved(302, "/b"), [])
  fake.expect_error("GET", "/b", @http.HttpError::Connect("refused"))
  let outcome = try
    @http.follow_redirects_stream(
      @http.Request::get("http://h/a"),
      stream_via(fake, log),
    )
  catch {
    Transport(error) => @debug.to_string(error)
    _ => "unexpected error"
  } noraise {
    _ => "no error"
  }
  assert_eq(outcome, "Connect(\"refused\")")
  assert_eq(log, ["close http://h/a"])
  fake.assert_complete()
  // Cancelled while the second request waits.
  let fake = @mock.FakeTransport::new()
  let log = []
  fake.expect_stream("GET", "/a", moved(302, "/b"), [])
  let send = stream_via(fake, log)
  let stalled : async (@http.Request) -> (@http.ResponseHead, &@http.BodyStream) raise @http.HttpError = request => {
    if request.url.has_suffix("/b") {
      @async.sleep(60_000)
    }
    send(request)
  }
  let result = @async.with_timeout_opt(20, () => {
    @http.follow_redirects_stream(@http.Request::get("http://h/a"), stalled)
  })
  assert_true(result is None)
  assert_eq(log, ["close http://h/a"])
  assert_eq(fake.streams_closed(), 1)
  fake.assert_complete()
}

///|
async test "follow_redirects_stream returns a 3xx without Location open" {
  let fake = @mock.FakeTransport::new()
  let log = []
  fake.expect_stream(
    "GET",
    "/a",
    { status: 302, headers: @http.Headers::new(), },
    [b"body"],
  )
  let (head, stream) = @http.follow_redirects_stream(
    @http.Request::get("http://h/a"),
    stream_via(fake, log),
  )
  assert_eq(head.status, 302)
  assert_eq(log, [])
  assert_eq(read_all(stream), b"body")
  stream.close()
  assert_eq(fake.streams_closed(), 1)
  fake.assert_complete()
}
