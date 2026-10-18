///|
struct SlowTransport {}

///|
impl @http.Transport for SlowTransport with fn send(_self, _request) {
  @async.sleep(100)
  { status: 200, headers: @http.Headers::new(), body: b"ok", }
}

///|
impl @http.Transport for SlowTransport with fn send_stream(_self, _request) {
  @async.sleep(100)
  raise @http.HttpError::Protocol("late head")
}

///|
async test "deadline bounds buffered exchange and streaming head" {
  let transport = @adapter.DeadlineTransport::new(
    SlowTransport::{ },
    timeout_ms=5,
  )
  for streaming in [false, true] {
    try {
      if streaming {
        ignore(transport.send_stream(@http.Request::get("/")))
      } else {
        ignore(transport.send(@http.Request::get("/")))
      }
    } catch {
      @http.HttpError::Timeout(phase=Unknown, ms~) => assert_eq(ms, 5)
      _ => fail("expected deadline timeout")
    } noraise {
      _ => fail("expected timeout")
    }
  }
}

///|
async test "deadline passes responses and original errors through" {
  let fake = @mock.FakeTransport::new()
  fake.expect("GET", "/", {
    status: 201,
    headers: @http.Headers::new(),
    body: b"ok",
  })
  let transport = @adapter.DeadlineTransport::new(fake, timeout_ms=1000)
  assert_eq(transport.send(@http.Request::get("/")).body, b"ok")
  for streaming in [false, true] {
    for
      error in [
        @http.HttpError::Connect("offline"),
        @http.HttpError::Protocol("bad"),
        @http.HttpError::Timeout(phase=Head, ms=42),
        @http.HttpError::Network(phase=Body, message="reset"),
      ] {
      fake.expect_error("GET", "/", error)
      try {
        if streaming {
          ignore(transport.send_stream(@http.Request::get("/")))
        } else {
          ignore(transport.send(@http.Request::get("/")))
        }
      } catch {
        actual => assert_eq(@debug.to_string(actual), @debug.to_string(error))
      } noraise {
        _ => fail("expected inner error")
      }
    }
  }
  fake.expect_stream(
    "GET",
    "/",
    { status: 202, headers: @http.Headers::new(), },
    [b"chunk"],
  )
  let short = @adapter.DeadlineTransport::new(fake, timeout_ms=5)
  let (head, stream) = short.send_stream(@http.Request::get("/"))
  assert_eq(head.status, 202)
  @async.sleep(10)
  assert_eq(stream.read_some(), Some(b"chunk"))
  stream.close()
  fake.assert_complete()
}

///|
async test "nonpositive deadlines expire before invoking inner transport" {
  let fake = @mock.FakeTransport::new()
  for ms in [0, -1] {
    let transport = @adapter.DeadlineTransport::new(fake, timeout_ms=ms)
    try transport.send(@http.Request::get("/")) catch {
      @http.HttpError::Timeout(phase=Unknown, ms=actual) =>
        assert_eq(actual, ms)
      _ => fail("expected immediate timeout")
    } noraise {
      _ => fail("expected timeout")
    }
  }
  assert_eq(fake.sent(), [])
}
