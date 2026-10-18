///|
/// `total` zero bytes in chunks of 1 MiB, recording what was handed out.
struct Zeros {
  total : Int64
  mut produced : Int64
  mut closed : Bool
}

///|
impl @http.BodyStream for Zeros with fn read_some(self) {
  let left = self.total - self.produced
  guard left > 0L else { return None }
  let size = left.min(1024L * 1024).to_int()
  self.produced += size.to_int64()
  Some(Bytes::make(size, 0))
}

///|
impl @http.BodyStream for Zeros with fn close(self) {
  self.closed = true
}

///|
/// What sending a stream of `total` bytes, declared or not, to a closed port
/// makes of it: refused before fetch (`Protocol`), or sent and failed there.
async fn js_upload(total : Int64, declared : Bool) -> (String, Zeros) {
  let source = { total, produced: 0L, closed: false, }
  let length = if declared { Some(total) } else { None }
  let request = @http.Request::post("http://127.0.0.1:9/").body_stream(
    source,
    length?,
  )
  let label = try
    @adapter.AsyncTransport::new(timeout_ms=5000).send(request)
  catch {
    @http.HttpError::Protocol(message) => "Protocol: " + message
    @http.HttpError::Network(phase~, ..) =>
      "Network(phase=\{@debug.to_string(phase)})"
    error => @debug.to_string(error)
  } noraise {
    _ => "sent"
  }
  (label, source)
}

///|
let refused : String = "Protocol: a stream request body is buffered in memory on this platform, and this one exceeds 16777216 bytes; send it as bytes instead"

///|
async test "JS buffers a stream body up to 16 MiB before fetch sends it" {
  let limit = 16L * 1024 * 1024
  // A declared length over the limit is refused before reading anything.
  let (label, source) = js_upload(limit + 1, true)
  assert_eq(label, refused)
  assert_eq(source.produced, 0L)
  // An undeclared one is refused at the chunk that crosses it.
  let (label, source) = js_upload(limit + 1, false)
  assert_eq(label, refused)
  assert_eq(source.produced, limit + 1)
  assert_true(source.closed)
  // Up to the limit it is buffered and handed to fetch, which fails here
  // because nothing listens on the port.
  let (label, source) = js_upload(limit, false)
  assert_eq(label, "Network(phase=Unknown)")
  assert_true(source.closed)
}
