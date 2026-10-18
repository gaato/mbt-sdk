///|
/// A request body stream over fixed chunks that records being closed.
struct Chunks {
  chunks : Array[Bytes]
  mut next : Int32
  mut closed : Bool
}

///|
fn chunks(parts : Array[Bytes]) -> Chunks {
  { chunks: parts, next: 0, closed: false, }
}

///|
impl @http.BodyStream for Chunks with fn read_some(self) {
  guard self.chunks.get(self.next) is Some(chunk) else { return None }
  self.next += 1
  Some(chunk)
}

///|
impl @http.BodyStream for Chunks with fn close(self) {
  self.closed = true
}

///|
fn ok() -> @http.Response {
  { status: 200, headers: @http.Headers::new(), body: b"ok", }
}

///|
/// The outcome of `send` as a label: the status, or the failure.
async fn outcome(fake : @mock.FakeTransport, request : @http.Request) -> String {
  try fake.send(request) catch {
    error => @debug.to_string(error)
  } noraise {
    response => "\{response.status}"
  }
}

///|
async test "a stream body is read once, to its declared length" {
  let fake = @mock.FakeTransport::new()
  fake.expect("PUT", "/a", ok())
  let source = chunks([b"ab", b"", b"cd"])
  let request = @http.Request::put("/a").body_stream(source, length=4)
  assert_eq(outcome(fake, request), "200")
  assert_true(source.closed)
  assert_false(request.body.is_replayable())
  assert_eq(fake.sent().map(request => request.body), [Bytes(b"abcd")])
  // Sending it again would send nothing of what was read: refused.
  assert_eq(
    outcome(fake, request),
    "Protocol(\"the stream request body was already sent; a stream can be sent only once\")",
  )
  // The refused send recorded nothing and consumed no expectation.
  assert_eq(fake.sent().length(), 1)
  fake.assert_complete()
}

///|
async test "a stream body that breaks its declared length fails" {
  let rows : Array[(Array[Bytes], Int64?, String)] = [
    ([b"abc"], Some(4L), "ended after 3 of its declared 4 bytes"),
    ([], Some(1L), "ended after 0 of its declared 1 bytes"),
    ([b"ab", b"cde"], Some(4L), "is longer than its declared 4 bytes"),
    ([b"ab", b"cd"], Some(4L), "200"),
    ([b"ab", b"cd"], None, "200"),
    ([], None, "200"),
  ]
  for row in rows {
    let (parts, length, expected) = row
    let fake = @mock.FakeTransport::new()
    fake.expect("POST", "/u", ok())
    let source = chunks(parts)
    let label = outcome(
      fake,
      @http.Request::post("/u").body_stream(source, length?),
    )
    let label = if label.has_prefix("Protocol") {
      label
      .strip_prefix("Protocol(\"request body stream ")
      .unwrap_or(label[:])
      .strip_suffix("\")")
      .unwrap_or(label[:])
      .to_owned()
    } else {
      label
    }
    assert_eq(label, expected, msg=@debug.to_string(row))
    assert_true(source.closed)
  }
}

///|
async test "a failure that proves nothing was sent leaves the stream to resend" {
  let fake = @mock.FakeTransport::new()
  fake.expect_error("POST", "/u", Connect("refused"))
  fake.expect_error("POST", "/u", Network(phase=Write, message="reset"))
  let source = chunks([b"x"])
  let request = @http.Request::post("/u").body_stream(source)
  assert_eq(outcome(fake, request), "Connect(\"refused\")")
  assert_true(request.body.is_replayable())
  assert_false(source.closed)
  assert_eq(outcome(fake, request), "Network(phase=Write, message=\"reset\")")
  assert_false(request.body.is_replayable())
  assert_true(source.closed)
  let sent = fake.sent()
  assert_eq(sent[0].body, request.body)
  assert_eq(sent[1].body, Bytes(b"x"))
  fake.assert_complete()
}

///|
async test "redirects that keep a sent stream body are refused" {
  let redirect = (status : Int32) => {
    let response : @http.Response = {
      status,
      headers: @http.Headers::from_array([("Location", "/b")]),
      body: b"",
    }
    response
  }
  let rows : Array[(String, Int32, String)] = [
    ("POST", 307, "UnreplayableBody(location=\"https://h/b\")"),
    ("PUT", 308, "UnreplayableBody(location=\"https://h/b\")"),
    ("PUT", 301, "UnreplayableBody(location=\"https://h/b\")"),
    ("POST", 303, "200 after GET"),
    ("POST", 302, "200 after GET"),
  ]
  for row in rows {
    let (http_method, status, expected) = row
    let fake = @mock.FakeTransport::new()
    fake.expect(http_method, "/a", redirect(status))
    fake.expect("GET", "/b", ok())
    let request = @http.Request::new(http_method, "https://h/a").body_stream(
      chunks([b"data"]),
    )
    let label = try
      @http.follow_redirects(request, request => fake.send(request))
    catch {
      error => @debug.to_string(error)
    } noraise {
      response => "\{response.status} after \{fake.sent()[1].http_method}"
    }
    assert_eq(label, expected, msg=@debug.to_string(row))
    // The refused redirect is not sent.
    assert_eq(
      fake.sent().length(),
      if expected.has_prefix("200") {
        2
      } else {
        1
      },
    )
  }
  // The middleware step reports the refusal as Protocol.
  let fake = @mock.FakeTransport::new()
  fake.expect("POST", "/a", redirect(307))
  let failure = try
    @http.send_with(
      fake,
      [@http.redirects()],
      @http.Request::post("https://h/a").body_stream(chunks([b"x"])),
    )
  catch {
    error => @debug.to_string(error)
  } noraise {
    _ => "followed"
  }
  assert_eq(
    failure, "Protocol(\"refused redirect to https://h/b: the stream request body was already sent\")",
  )
}

///|
async test "follow_redirects_stream refuses to resend a sent stream body" {
  let fake = @mock.FakeTransport::new()
  fake.expect_stream(
    "PUT",
    "/a",
    { status: 307, headers: @http.Headers::from_array([("Location", "/b")]), },
    [b"moved"],
  )
  let request = @http.Request::put("https://h/a").body_stream(chunks([b"x"]))
  let label = try
    @http.follow_redirects_stream(request, request => fake.send_stream(request))
  catch {
    error => @debug.to_string(error)
  } noraise {
    _ => "followed"
  }
  assert_eq(label, "UnreplayableBody(location=\"https://h/b\")")
  // The 3xx stream is closed unread.
  assert_eq(fake.streams_closed(), 1)
}
