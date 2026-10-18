// Sending a request body. Bytes and streams go out the same way: in writes of
// at most `max_write_bytes`, each its own `Write` phase, so `write_timeout_ms`
// bounds the time one slice takes to leave, as httpx's write timeout does, and
// the exchange deadline bounds the whole upload.

///|
/// The most bytes one write puts on a connection. A chunk from the caller's
/// stream, or a body held in memory, is cut to this size, so one `Write`
/// phase sends at most 64 KiB however large the chunks the stream returns.
let max_write_bytes : Int32 = 64 * 1024

///|
/// The `Content-Length` to declare for `body`, or `None` to leave the framing
/// to the client: chunked once bytes are written, nothing for an empty body.
/// A known length is declared; an empty one only for a method that expects
/// content (RFC 9110 §8.6: a user agent should not send `Content-Length` when
/// there is no content and the method does not anticipate any).
fn content_length(http_method : String, body : @http.Body) -> Int64? {
  match body.length() {
    Some(0L) =>
      if http_method.to_upper() is ("POST" | "PUT" | "PATCH") {
        Some(0L)
      } else {
        None
      }
    length => length
  }
}

///|
/// The `Protocol` message for a stream body of `bytes` bytes on a platform
/// that buffers stream bodies up to `limit` bytes, or `None` when it fits.
fn buffer_overflow(limit : Int64?, bytes : Int64) -> String? {
  guard limit is Some(limit) && bytes > limit else { return None }
  Some(
    "a stream request body is buffered in memory on this platform, and this one exceeds \{limit} bytes; send it as bytes instead",
  )
}

///|
/// Raises `Protocol`, before anything is sent, for a stream body declared
/// longer than a buffering platform's `limit`.
fn refuse_unbufferable(
  body : @http.Body,
  limit : Int64?,
) -> Unit raise @http.HttpError {
  guard body is Stream(stream) else { return }
  if buffer_overflow(limit, stream.length().unwrap_or(0L)) is Some(message) {
    raise @http.HttpError::Protocol(message)
  }
}

///|
/// Sends `body` through `write` as `Write` phases of `timer`: each slice of
/// at most `max_write_bytes`, and for a stream each read from it, is one
/// phase. A stream is taken here and closed when sending ends, however it
/// ends; one that grows past `buffer_limit` raises `Protocol`.
async fn send_body(
  body : @http.Body,
  write : async (BytesView) -> Unit,
  timer : PhaseTimer,
  buffer_limit~ : Int64?,
) -> Unit raise @http.HttpError {
  match body {
    Bytes(bytes) => write_slices(bytes, write, timer)
    Stream(stream) => {
      let reader = stream.take()
      defer reader.close()
      let mut sent = 0L
      while timer.run(Write, () => reader.read_some()) is Some(chunk) {
        sent += chunk.length().to_int64()
        if buffer_overflow(buffer_limit, sent) is Some(message) {
          raise @http.HttpError::Protocol(message)
        }
        write_slices(chunk, write, timer)
      }
    }
  }
}

///|
/// Writes `bytes` in slices of at most `max_write_bytes`, each one `Write`
/// phase of `timer`.
async fn write_slices(
  bytes : Bytes,
  write : async (BytesView) -> Unit,
  timer : PhaseTimer,
) -> Unit raise @http.HttpError {
  for start = 0; start < bytes.length(); start = start + max_write_bytes {
    let slice = bytes[start:(start + max_write_bytes).min(bytes.length())]
    timer.run(Write, () => write(slice))
  }
}
