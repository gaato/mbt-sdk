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
  // Raw bytes of the lines behind `data`, `event_type` and `last_id`,
  // counted against the bound with the line being read.
  priv mut data_bytes : Int32
  priv mut event_bytes : Int32
  priv mut id_bytes : Int32
  priv mut first_line : Bool
  priv mut skip_lf : Bool
  priv mut event_type : String
  priv mut last_id : String?
  priv mut retry : Int32?
  priv mut finished : Bool
  // An overflow found after events completed in the same chunk, raised by
  // the next `feed` or `finish` so those events are returned first.
  priv mut overflow : Bool
}

///|
/// Creates an empty parser. `max_event_bytes` bounds one event: the raw bytes
/// of its `data` lines, of the `event` and `id` lines in effect, and of the
/// line being read, line terminators excluded. It defaults to 16 MiB. An
/// `event` or `id` line that replaces an earlier one replaces its count too,
/// and the `id` persists into later events, as the spec says, so it counts
/// against each of them until replaced.
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
    event_bytes: 0,
    id_bytes: 0,
    first_line: true,
    skip_lf: false,
    event_type: "",
    last_id: None,
    retry: None,
    finished: false,
    overflow: false,
  }
}

///|
/// Feeds any byte chunk and returns complete events in order.
/// Malformed UTF-8 is replaced with U+FFFD. Feeding after finish is a no-op.
///
/// An event over `max_event_bytes` raises `Protocol` and ends the stream,
/// which is refused rather than read without bound. When the same chunk
/// completed events before it, those are returned first and the next `feed`
/// or `finish` raises, so feed an empty chunk to observe it without waiting
/// for more input.
pub fn SseParser::feed(
  self : SseParser,
  bytes : Bytes,
) -> Array[SseEvent] raise @http.HttpError {
  self.raise_overflow()
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
    } else if self.line.length() + self.kept_bytes() < self.max_event_bytes {
      self.line.push(byte)
    } else {
      self.end()
      self.overflow = true
      if events.is_empty() {
        self.raise_overflow()
      }
      return events
    }
  }
  events
}

///|
/// Ends the stream, discarding any incomplete event; always returns [].
/// Repeated calls are harmless. Raises `Protocol` if `feed` left an
/// overflow unreported, so an oversized event at the end is never lost.
pub fn SseParser::finish(
  self : SseParser,
) -> Array[SseEvent] raise @http.HttpError {
  self.end()
  self.raise_overflow()
  []
}

///|
/// Raises a pending overflow once.
fn SseParser::raise_overflow(self : SseParser) -> Unit raise @http.HttpError {
  if self.overflow {
    self.overflow = false
    raise @http.HttpError::Protocol(
      "SSE event larger than \{self.max_event_bytes} bytes",
    )
  }
}

///|
/// Every kept line value counts, so an event cannot hold several bounds' worth
/// spread over its fields. A completed line never raises the count by more
/// than its own length, so checking bytes as they arrive is enough.
fn SseParser::kept_bytes(self : SseParser) -> Int32 {
  self.data_bytes + self.event_bytes + self.id_bytes
}

///|
fn SseParser::end(self : SseParser) -> Unit {
  self.finished = true
  self.line.clear()
  self.data.clear()
  self.data_bytes = 0
  self.event_type = ""
  self.event_bytes = 0
  self.retry = None
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
    self.event_bytes = 0
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
    "event" => {
      self.event_type = value
      self.event_bytes = line_bytes
    }
    "id" =>
      if !value.contains("\u{0000}") {
        self.last_id = Some(value)
        self.id_bytes = line_bytes
      }
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
