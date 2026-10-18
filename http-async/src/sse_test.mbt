///|
struct TestStream {
  chunks : Array[Bytes]
  mut cursor : Int32
  mut closes : Int32
  fail_read : Bool
}

///|
suberror ScenarioError {
  Callback
} derive(Debug)

///|
impl @http.BodyStream for TestStream with fn read_some(self) {
  if self.fail_read {
    raise @http.HttpError::Protocol("read failed")
  }
  let chunk = self.chunks.get(self.cursor)
  if chunk is Some(_) {
    self.cursor += 1
  }
  chunk
}

///|
impl @http.BodyStream for TestStream with fn close(self) {
  self.closes += 1
}

///|
// Executed copy of gaato/http/sse's compile-only scenarios.
async fn each_event_scenarios() -> Unit {
  let stream = TestStream::{
    chunks: [b"", b"data: a\r", b"\n\r\ndata: b\n\ndata: discarded"],
    cursor: 0,
    closes: 0,
    fail_read: false,
  }
  let events = []
  @sse.each_event(stream, event => events.push(event))
  assert_eq(events.map(event => event.data), ["a", "b"])
  assert_eq(stream.closes, 1)
  let failing = TestStream::{
    chunks: [],
    cursor: 0,
    closes: 0,
    fail_read: true,
  }
  try @sse.each_event(failing, _ => ()) catch {
    @http.HttpError::Protocol("read failed") => ()
    _ => fail("read error must propagate unchanged")
  } noraise {
    _ => fail("expected read error")
  }
  assert_eq(failing.closes, 1)
  let callback = TestStream::{
    chunks: [b"data: a\n\ndata: b\n\n", b"data: c\n\n"],
    cursor: 0,
    closes: 0,
    fail_read: false,
  }
  let seen = []
  let f : async (@sse.SseEvent) -> Unit raise ScenarioError = event => {
    seen.push(event.data)
    raise Callback
  }
  try @sse.each_event(callback, f) catch {
    Callback => ()
    _ => fail("callback error must propagate unchanged")
  } noraise {
    _ => fail("expected callback error")
  }
  assert_eq(seen, ["a"])
  assert_eq(callback.cursor, 1)
  assert_eq(callback.closes, 1)
  let oversized = TestStream::{
    chunks: [b"data: a\n\n", b"data: bb", b"data: never read\n\n"],
    cursor: 0,
    closes: 0,
    fail_read: false,
  }
  let delivered = []
  try
    @sse.each_event(
      oversized,
      event => delivered.push(event.data),
      max_event_bytes=7,
    )
  catch {
    @http.HttpError::Protocol("SSE event larger than 7 bytes") => ()
    _ => fail("an oversized event must fail with Protocol")
  } noraise {
    _ => fail("expected the oversized event to be refused")
  }
  assert_eq(delivered, ["a"])
  assert_eq(oversized.cursor, 2)
  assert_eq(oversized.closes, 1)
}

///|
async test "each_event scenarios execute" {
  each_event_scenarios()
}
