///|
/// A dispatched event, with resolved type and the current last-event-id.
/// Retry is the last valid retry seen since the previous dispatched event.
pub(all) struct SseEvent {
  event : String
  data : String
  id : String?
  retry : Int?
} derive(Eq, Debug)

///|
/// Compares all event fields.
pub extend SseEvent with Eq::{equal, not_equal}

///|
/// Debug representation of an event.
pub extend SseEvent with @debug.Debug::{to_repr}

///|
/// An incremental UTF-8 event-stream parser. Create one parser per stream.
pub struct SseParser {
  priv line : Array[Byte]
  priv data : Array[String]
  priv mut first_line : Bool
  priv mut skip_lf : Bool
  priv mut event_type : String
  priv mut last_id : String?
  priv mut retry : Int?
  priv mut finished : Bool
}

///|
/// Creates an empty parser.
///
/// ```mbt check
/// test {
///   let parser = @sse.SseParser::new()
///   assert_eq(parser.feed(b"data: hello\n\n")[0].data, "hello")
///   assert_eq(parser.finish(), [])
/// }
/// ```
pub fn SseParser::new() -> SseParser {
  {
    line: [],
    data: [],
    first_line: true,
    skip_lf: false,
    event_type: "",
    last_id: None,
    retry: None,
    finished: false,
  }
}

///|
/// Feeds any byte chunk and returns complete events in order.
/// Malformed UTF-8 is replaced with U+FFFD. Feeding after finish is a no-op.
pub fn SseParser::feed(self : SseParser, bytes : Bytes) -> Array[SseEvent] {
  let events = []
  if self.finished {
    return events
  }
  for byte in bytes {
    if self.skip_lf {
      self.skip_lf = false
      if byte == b'\n' {
        continue
      }
    }
    if byte == b'\r' || byte == b'\n' {
      self.process_line(events)
      self.skip_lf = byte == b'\r'
    } else {
      self.line.push(byte)
    }
  }
  events
}

///|
/// Ends the stream, discarding any incomplete event; always returns [].
/// Repeated calls are harmless.
pub fn SseParser::finish(self : SseParser) -> Array[SseEvent] {
  self.finished = true
  self.line.clear()
  self.data.clear()
  self.event_type = ""
  self.retry = None
  []
}

///|
fn SseParser::process_line(self : SseParser, events : Array[SseEvent]) -> Unit {
  let line = @utf8.decode_lossy(
    Bytes::from_array(self.line),
    ignore_bom=self.first_line,
  )
  self.first_line = false
  self.line.clear()
  if line == "" {
    if !self.data.is_empty() {
      events.push({
        event: if self.event_type == "" {
          "message"
        } else {
          self.event_type
        },
        data: self.data.join("\n"),
        id: self.last_id,
        retry: self.retry,
      })
      self.retry = None
    }
    self.data.clear()
    self.event_type = ""
    return
  }
  if line.has_prefix(":") {
    return
  }
  let (field, value) = match line.split_once(":") {
    Some((field, value)) =>
      (field.to_owned(), value.strip_prefix(" ").unwrap_or(value).to_owned())
    None => (line, "")
  }
  match field {
    "data" => self.data.push(value)
    "event" => self.event_type = value
    "id" => if !value.contains("\u{0000}") { self.last_id = Some(value) }
    "retry" => if parse_retry(value) is Some(value) { self.retry = Some(value) }
    _ => ()
  }
}

///|
fn parse_retry(value : String) -> Int? {
  if value.is_empty() {
    return None
  }
  let mut result = 0
  for digit in value {
    if digit < '0' || digit > '9' {
      return None
    }
    let digit = digit.to_int() - 48
    if result > (2147483647 - digit) / 10 {
      return None
    }
    result = result * 10 + digit
  }
  Some(result)
}
