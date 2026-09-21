///|
/// Script verification errors. Transport calls raise HttpError::Protocol instead.
pub(all) suberror MockError {
  Unexpected(String)
  Mismatch(String)
  Unconsumed(Int)
  Violated(String)
} derive(Debug)

///|
/// Debug representation of a verification error.
pub extend MockError with @debug.Debug::{to_repr}

///|
priv enum Reply {
  Buffered(@http.Response)
  Streaming(@http.ResponseHead, Array[Bytes])
}

///|
priv struct Expectation {
  http_method : String
  url_suffix : String
  reply : Reply
}

///|
/// A FIFO transport script with request snapshots and a first-violation latch.
pub struct FakeTransport {
  priv expectations : Array[Expectation]
  priv requests : Array[@http.Request]
  priv mut cursor : Int
  priv mut violation : String?
  priv mut closed : Int
}

///|
/// Creates an empty script.
///
/// ```mbt check
/// test {
///   let fake = @mock.FakeTransport::new()
///   assert_eq(fake.sent(), [])
///   fake.assert_complete()
/// }
/// ```
pub fn FakeTransport::new() -> FakeTransport {
  { expectations: [], requests: [], cursor: 0, violation: None, closed: 0, }
}

///|
/// Appends a buffered response expectation, snapshotting its headers.
pub fn FakeTransport::expect(
  self : FakeTransport,
  http_method : String,
  url_suffix : String,
  response : @http.Response,
) -> Unit {
  self.expectations.push({
    http_method: http_method.to_lower(),
    url_suffix,
    reply: Buffered({ ..response, headers: copy_headers(response.headers), }),
  })
}

///|
/// Appends a stream expectation, snapshotting the head and chunk array.
pub fn FakeTransport::expect_stream(
  self : FakeTransport,
  http_method : String,
  url_suffix : String,
  head : @http.ResponseHead,
  chunks : Array[Bytes],
) -> Unit {
  self.expectations.push({
    http_method: http_method.to_lower(),
    url_suffix,
    reply: Streaming(
      { ..head, headers: copy_headers(head.headers), },
      chunks.copy(),
    ),
  })
}

///|
/// Returns independent request snapshots, including unsuccessful attempts.
pub fn FakeTransport::sent(self : FakeTransport) -> Array[@http.Request] {
  self.requests.map(request => request.body_bytes(request.body))
}

///|
/// Raises the first latched violation, otherwise reports remaining expectations.
pub fn FakeTransport::assert_complete(
  self : FakeTransport,
) -> Unit raise MockError {
  if self.violation is Some(message) {
    raise Violated(message)
  }
  let remaining = self.expectations.length() - self.cursor
  if remaining != 0 {
    raise Unconsumed(remaining)
  }
}

///|
/// Counts distinct returned streams explicitly closed, including early closes.
pub fn FakeTransport::streams_closed(self : FakeTransport) -> Int {
  self.closed
}

///|
/// Explicit transport methods for scripted sends.
pub extend FakeTransport with @http.Transport::{send, send_stream}

///|
fn copy_headers(headers : @http.Headers) -> @http.Headers {
  @http.Headers::from_array(headers.iter().to_array())
}

///|
fn[T] FakeTransport::reject(
  self : FakeTransport,
  message : String,
) -> T raise @http.HttpError {
  if self.violation is None {
    self.violation = Some(message)
  }
  raise @http.HttpError::Protocol(message)
}

///|
fn FakeTransport::take(
  self : FakeTransport,
  request : @http.Request,
  streaming : Bool,
) -> Reply raise @http.HttpError {
  self.requests.push(request.body_bytes(request.body))
  guard self.expectations.get(self.cursor) is Some(expected) else {
    return self.reject(
      "unexpected request: " + request.http_method + " " + request.url,
    )
  }
  // Every attempted request consumes its FIFO slot, even when it mismatches.
  self.cursor += 1
  if request.http_method.to_lower() != expected.http_method ||
    !request.url.has_suffix(expected.url_suffix) {
    return self.reject(
      "request mismatch: expected " +
      expected.http_method +
      " suffix " +
      expected.url_suffix +
      "; got " +
      request.http_method +
      " " +
      request.url,
    )
  }
  let expected_streaming = match expected.reply {
    Streaming(_, _) => true
    Buffered(_) => false
  }
  if streaming != expected_streaming {
    return self.reject(
      "response kind mismatch: send and send_stream must match the script",
    )
  }
  expected.reply
}

///|
/// Consumes the next buffered expectation, without interpreting its status.
pub impl @http.Transport for FakeTransport with fn send(self, request) {
  match self.take(request, false) {
    Buffered(response) => response
    Streaming(_, _) => self.reject("expected a buffered response")
  }
}

///|
/// Consumes the next stream expectation and returns a closable chunk stream.
pub impl @http.Transport for FakeTransport with fn send_stream(self, request) {
  match self.take(request, true) {
    Streaming(head, chunks) =>
      (head, ScriptStream::{ owner: self, chunks, cursor: 0, closed: false, })
    Buffered(_) => self.reject("expected a streaming response")
  }
}

///|
priv struct ScriptStream {
  owner : FakeTransport
  chunks : Array[Bytes]
  mut cursor : Int
  mut closed : Bool
}

///|
impl @http.BodyStream for ScriptStream with fn read_some(self) {
  if self.closed {
    return None
  }
  let chunk = self.chunks.get(self.cursor)
  if chunk is Some(_) {
    self.cursor += 1
  }
  chunk
}

///|
impl @http.BodyStream for ScriptStream with fn close(self) {
  if !self.closed {
    self.closed = true
    self.owner.closed += 1
  }
}
