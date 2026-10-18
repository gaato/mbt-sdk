///|
/// Reads and dispatches events until EOF, always closing the stream on exit.
/// Propagates both stream read errors and callback errors unchanged.
/// An event larger than `max_event_bytes` (16 MiB by default; see
/// `SseParser::new`) fails with `Protocol` once the read that carries it
/// exceeds the bound; events from earlier reads have already been dispatched.
pub async fn[E : Error] each_event(
  stream : &@http.BodyStream,
  f : async (SseEvent) -> Unit raise E,
  max_event_bytes~ : Int32 = default_max_event_bytes,
) -> Unit {
  defer stream.close()
  let parser = SseParser::new(max_event_bytes~)
  while stream.read_some() is Some(bytes) {
    for event in parser.feed(bytes) {
      f(event)
    }
  }
  ignore(parser.finish())
}
