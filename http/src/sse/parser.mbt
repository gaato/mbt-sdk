///|
/// A dispatched event, with resolved type and the current last-event-id.
/// Retry is the last valid retry seen since the previous dispatched event.
pub(all) struct SseEvent {
  event : String
  data : String
  id : String?
  retry : Int32?
} derive(Eq, Debug)

///|
/// Compares all event fields.
pub extend SseEvent with Eq::{equal, not_equal}

///|
/// Debug representation of an event.
pub extend SseEvent with @debug.Debug::{to_repr}

///|
/// The default bound on one event: 16 MiB, far above any realistic event,
/// including a final `response.completed` that repeats a whole response
/// with base64 images, yet small enough that a stream which never ends a
/// line or an event cannot exhaust memory.
let default_max_event_bytes : Int32 = 16 * 1024 * 1024

///|
/// An incremental UTF-8 event-stream parser. Create one parser per stream.
pub struct SseParser {
  priv max_event_bytes : Int32
  priv line : Array[Byte]
  priv data : Array[String]
  // Raw bytes of the `data` lines in `data`, counted against the bound.
  priv mut data_bytes : Int32
  priv mut first_line : Bool
  priv mut skip_lf : Bool
  priv mut event_type : String
  priv mut last_id : String?
  priv mut retry : Int32?
  priv mut finished : Bool
}

///|
/// Creates an empty parser. `max_event_bytes` bounds one event: the raw bytes
/// of its `data` lines plus the line being read, line terminators excluded.
/// It defaults to 16 MiB.
///
/// ```mbt check
/// test {
///   let parser = @sse.SseParser::new()
///   assert_eq(parser.feed(b"data: hello\n\n")[0].data, "hello")
///   assert_eq(parser.finish(), [])
///   let _ = @sse.SseParser::new(max_event_bytes=1_048_576)
/// }
/// ```
pub fn SseParser::new(
  max_event_bytes~ : Int32 = default_max_event_bytes,
) -> SseParser {
  {
    max_event_bytes,
    line: [],
    data: [],
    data_bytes: 0,
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
///
/// Raises `Protocol` at the byte that takes an event past `max_event_bytes`,
/// discarding the events completed earlier in the same chunk, and finishes
/// the parser: the stream is refused rather than read without bound.
pub fn SseParser::feed(
  self : SseParser,
  bytes : Bytes,
) -> Array[SseEvent] raise @http.HttpError {
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
    } else if self.line.length() + self.data_bytes < self.max_event_bytes {
      self.line.push(byte)
    } else {
      ignore(self.finish())
      raise @http.HttpError::Protocol(
        "SSE event larger than \{self.max_event_bytes} bytes",
      )
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
  self.data_bytes = 0
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
  let line_bytes = self.line.length()
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
    self.data_bytes = 0
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
    "data" => {
      self.data.push(value)
      self.data_bytes += line_bytes
    }
    "event" => self.event_type = value
    "id" => if !value.contains("\u{0000}") { self.last_id = Some(value) }
    "retry" => if parse_retry(value) is Some(value) { self.retry = Some(value) }
    _ => ()
  }
}

///|
fn parse_retry(value : String) -> Int32? {
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
