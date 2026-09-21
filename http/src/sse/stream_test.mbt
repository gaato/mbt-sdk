///|
struct TestStream {
  chunks : Array[Bytes]
  mut cursor : Int
  mut closes : Int
  fail_read : Bool
}

///|
suberror ScenarioError {
  Read
  Callback
} derive(Debug)

///|
impl @http.BodyStream for TestStream with fn read_some(self) {
  if self.fail_read {
    raise Read
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
// Compile-only here; execute with an async runtime in step 2c.
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
    Read => ()
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
}

///|
test "each_event scenarios compile without a runtime" {
  let _ : async () -> Unit = each_event_scenarios
}
