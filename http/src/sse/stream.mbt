///|
/// Reads and dispatches events until EOF, always closing the stream on exit.
/// Propagates both stream read errors and callback errors unchanged.
pub async fn[E : Error] each_event(
  stream : &@http.BodyStream,
  f : async (SseEvent) -> Unit raise E,
) -> Unit {
  defer stream.close()
  let parser = SseParser::new()
  while stream.read_some() is Some(bytes) {
    for event in parser.feed(bytes) {
      f(event)
    }
  }
  ignore(parser.finish())
}
