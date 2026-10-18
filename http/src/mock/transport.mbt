///|
/// Script verification errors. Transport calls raise HttpError::Protocol instead.
pub(all) suberror MockError {
  Unexpected(String)
  Mismatch(String)
  Unconsumed(Int32)
  Violated(String)
} derive(Debug)

///|
/// Debug representation of a verification error.
pub extend MockError with @debug.Debug::{to_repr}

///|
priv enum Reply {
  Failure(@http.HttpError)
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
  priv mut cursor : Int32
  priv mut violation : String?
  priv mut closed : Int32
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
/// A stream body appears as the bytes the fake read from it.
pub fn FakeTransport::sent(self : FakeTransport) -> Array[@http.Request] {
  self.requests.map(snapshot)
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
pub fn FakeTransport::streams_closed(self : FakeTransport) -> Int32 {
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
fn snapshot(request : @http.Request) -> @http.Request {
  { ..request, headers: copy_headers(request.headers), }
}

///|
/// `request` with a stream body read to its end, as a transport sends it:
/// a stream already taken, or one that breaks its declared length, raises
/// `Protocol` as `StreamBody::take` and its reader do.
async fn drained(
  request : @http.Request,
) -> @http.Request raise @http.HttpError {
  guard request.body is Stream(stream) else { return request }
  let reader = stream.take()
  defer reader.close()
  let body = Buffer()
  while reader.read_some() is Some(chunk) {
    body.write_bytes(chunk)
  }
  { ..request, body: Bytes(body.to_bytes()), }
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
/// Records `request` and consumes the next expectation. A stream body is read
/// first, unless the scripted reply is a failure that proves nothing was sent
/// (`HttpError::is_unsent`); a body that cannot be read raises before
/// anything is recorded or consumed.
async fn FakeTransport::take(
  self : FakeTransport,
  request : @http.Request,
  streaming : Bool,
) -> Reply raise @http.HttpError {
  let next = self.expectations.get(self.cursor)
  let request = match next {
    Some({ reply: Failure(error), .. }) if error.is_unsent() => request
    _ => drained(request)
  }
  self.requests.push(snapshot(request))
  guard next is Some(expected) else {
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
    Failure(_) => streaming
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
    Failure(error) => raise error
    Buffered(response) => response
    Streaming(_, _) => self.reject("expected a buffered response")
  }
}

///|
/// Consumes the next stream expectation and returns a closable chunk stream.
pub impl @http.Transport for FakeTransport with fn send_stream(self, request) {
  match self.take(request, true) {
    Failure(error) => raise error
    Streaming(head, chunks) =>
      (head, ScriptStream::{ owner: self, chunks, cursor: 0, closed: false, })
    Buffered(_) => self.reject("expected a streaming response")
  }
}

///|
priv struct ScriptStream {
  owner : FakeTransport
  chunks : Array[Bytes]
  mut cursor : Int32
  mut closed : Bool
}

///|
impl @http.BodyStream for ScriptStream with fn read_some(self) -> Bytes? raise @http.HttpError {
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

///|
/// Appends an error expectation accepted by either send or send_stream.
pub fn FakeTransport::expect_error(
  self : FakeTransport,
  http_method : String,
  url_suffix : String,
  error : @http.HttpError,
) -> Unit {
  self.expectations.push({
    http_method: http_method.to_lower(),
    url_suffix,
    reply: Failure(error),
  })
}
