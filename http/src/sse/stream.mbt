///|
/// The most bytes of one read fed to the parser at once. A transport may
/// return a read of any size, so each slice's events are dispatched before
/// the next slice is parsed: the events held at once are bounded by one
/// slice, not by one read.
let slice_bytes : Int32 = 64 * 1024

///|
/// The slice of `chunk` that starts at `start`, without a copy when the
/// whole chunk fits in one.
fn slice_at(chunk : Bytes, start : Int32) -> Bytes {
  if start == 0 && chunk.length() <= slice_bytes {
    chunk
  } else {
    chunk[start:(start + slice_bytes).min(chunk.length())].to_owned()
  }
}

///|
/// Reads and dispatches events until EOF, always closing the stream on exit.
/// Propagates both stream read errors and callback errors unchanged.
/// An event larger than `max_event_bytes` (16 MiB by default; see
/// `SseParser::new`) fails with `Protocol` after every event before it has
/// been dispatched, without reading further.
pub async fn[E : Error] each_event(
  stream : &@http.BodyStream,
  f : async (SseEvent) -> Unit raise E,
  max_event_bytes~ : Int32 = default_max_event_bytes,
) -> Unit {
  defer stream.close()
  let parser = SseParser::new(max_event_bytes~)
  while stream.read_some() is Some(bytes) {
    for start = 0; start < bytes.length(); start = start + slice_bytes {
      for event in parser.feed(slice_at(bytes, start)) {
        f(event)
      }
      // Surfaces an overflow that followed those events in the same slice.
      ignore(parser.feed(b""))
    }
  }
  ignore(parser.finish())
}
