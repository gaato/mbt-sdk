///|
fn response(status? : Int = 200) -> @http.Response {
  {
    status,
    headers: @http.Headers::from_array([("X-Test", "original")]),
    body: b"body",
  }
}

///|
fn head() -> @http.ResponseHead {
  { status: 201, headers: @http.Headers::from_array([("X-Test", "original")]), }
}

///|
test "empty bookkeeping and outstanding buffered and stream expectations" {
  let fake = @mock.FakeTransport::new()
  fake.assert_complete()
  assert_eq(fake.sent(), [])
  assert_eq(fake.streams_closed(), 0)
  let sent = fake.sent()
  sent.push(@http.Request::get("/not-sent"))
  assert_eq(fake.sent(), [])
  fake.expect("GET", "/a", response())
  try fake.assert_complete() catch {
    @mock.MockError::Unconsumed(n) => assert_eq(n, 1)
    _ => fail("expected Unconsumed")
  } noraise {
    _ => fail("missing expectation was not reported")
  }
  fake.expect_stream("POST", "/b", head(), [b"a"])
  try fake.assert_complete() catch {
    @mock.MockError::Unconsumed(n) => assert_eq(n, 2)
    _ => fail("expected Unconsumed")
  } noraise {
    _ => fail("missing expectations were not reported")
  }
  assert_eq(fake.sent(), [])
}

///|
// Executed copy of gaato/http/mock's compile-only scenarios.
async fn fifo_and_snapshots() -> Unit {
  let fake = @mock.FakeTransport::new()
  let reply = response(status=503)
  fake.expect("gEt", "/one", reply)
  reply.headers.set("X-Test", "mutated")
  fake.expect("POST", "/two", response(status=404))
  let request = @http.Request::get("https://example.invalid/one").header(
    "X", "original",
  )
  assert_eq(fake.send(request), response(status=503))
  request.headers.set("X", "changed")
  let second = @http.Request::post("/two")
  assert_eq(fake.send(second), response(status=404))
  fake.assert_complete()
  let sent = fake.sent()
  assert_eq(sent, [
    @http.Request::get("https://example.invalid/one").header("X", "original"),
    second,
  ])
  sent[0].headers.set("X", "changed-again")
  sent.clear()
  assert_eq(fake.sent()[0].headers.get("x"), Some("original"))
  assert_eq(fake.sent().length(), 2)
}

///|
async fn scripted_streams() -> Unit {
  let fake = @mock.FakeTransport::new()
  let original_head = head()
  let chunks = [b"one", b"", b"two"]
  fake.expect_stream("gEt", "/stream", original_head, chunks)
  original_head.headers.set("X-Test", "changed")
  chunks.clear()
  let (actual_head, stream) = fake.send_stream(
    @http.Request::get("https://example.invalid/stream"),
  )
  assert_eq(actual_head, head())
  assert_eq(stream.read_some(), Some(b"one"))
  assert_eq(stream.read_some(), Some(b""))
  assert_eq(stream.read_some(), Some(b"two"))
  assert_eq(stream.read_some(), None)
  assert_eq(stream.read_some(), None)
  assert_eq(fake.streams_closed(), 0)
  stream.close()
  stream.close()
  assert_eq(fake.streams_closed(), 1)
  assert_eq(stream.read_some(), None)
  fake.expect_stream("GET", "/early", head(), [b"unread"])
  let (_, early) = fake.send_stream(@http.Request::get("/early"))
  early.close()
  assert_eq(early.read_some(), None)
  assert_eq(fake.streams_closed(), 2)
  fake.expect_stream("GET", "/empty", head(), [])
  let (_, empty) = fake.send_stream(@http.Request::get("/empty"))
  assert_eq(empty.read_some(), None)
  empty.close()
  assert_eq(fake.streams_closed(), 3)
  fake.assert_complete()
}

///|
fn latched(fake : @mock.FakeTransport, message : String) -> Unit raise {
  try fake.assert_complete() catch {
    @mock.MockError::Violated(actual) => assert_eq(actual, message)
    _ => fail("expected first violation")
  } noraise {
    _ => fail("swallowed transport error must remain latched")
  }
}

///|
async fn violations() -> Unit {
  // Method and URL mismatches each consume only the next FIFO entry.
  for request in [@http.Request::post("/one"), @http.Request::get("/two")] {
    let fake = @mock.FakeTransport::new()
    fake.expect("GET", "/one", response())
    fake.expect("GET", "/two", response(status=202))
    let first_message = try fake.send(request) catch {
      @http.HttpError::Protocol(message) => message
      _ => {
        fail("expected Protocol")
        ""
      }
    } noraise {
      _ => {
        fail("expected mismatch")
        ""
      }
    }
    latched(fake, first_message)
    assert_eq(fake.send(@http.Request::get("/two")), response(status=202))
    try fake.send(@http.Request::get("/unexpected")) catch {
      @http.HttpError::Protocol(_) => ()
      _ => fail("expected Protocol")
    } noraise {
      _ => fail("expected unexpected request error")
    }
    latched(fake, first_message)
    assert_eq(fake.sent().length(), 3)
  }
  // Both directions of response-kind mismatch and an empty stream script.
  for streaming in [false, true] {
    let fake = @mock.FakeTransport::new()
    if streaming {
      fake.expect("GET", "/x", response())
    } else {
      fake.expect_stream("GET", "/x", head(), [])
    }
    let message = try {
      if streaming {
        ignore(fake.send_stream(@http.Request::get("/x")))
      } else {
        ignore(fake.send(@http.Request::get("/x")))
      }
    } catch {
      @http.HttpError::Protocol(message) => message
      _ => {
        fail("expected Protocol")
        ""
      }
    } noraise {
      _ => {
        fail("expected kind mismatch")
        ""
      }
    }
    latched(fake, message)
    assert_eq(fake.streams_closed(), 0)
    assert_eq(fake.sent().length(), 1)
  }
  let empty = @mock.FakeTransport::new()
  let message = try empty.send_stream(@http.Request::get("/empty")) catch {
    @http.HttpError::Protocol(message) => message
    _ => {
      fail("expected Protocol")
      ""
    }
  } noraise {
    _ => {
      fail("expected unexpected request")
      ""
    }
  }
  latched(empty, message)
  assert_eq(empty.sent().length(), 1)
}

///|
async test "mock FIFO and snapshots execute" {
  fifo_and_snapshots()
}

///|
async test "mock scripted streams execute" {
  scripted_streams()
}

///|
async test "mock violations execute" {
  violations()
}
