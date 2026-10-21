///|
/// `SseParser` as the harness sees it: each event rendered by its debug
/// form, and an overflow as the kind `Protocol`.
struct SseFeeder {
  parser : @sse.SseParser
}

///|
fn sse_feeder(max_event_bytes? : Int32) -> SseFeeder {
  { parser: @sse.SseParser::new(max_event_bytes?), }
}

///|
fn render(events : Array[@sse.SseEvent]) -> Array[String] {
  events.map(event => "\{Repr(event)}")
}

///|
fn failed(error : Error) -> @harness.Failed {
  match error {
    @http.HttpError::Protocol(_) => Failed("Protocol")
    _ => Failed("unexpected")
  }
}

///|
impl @harness.Feeder for SseFeeder with fn feed(self, chunk) {
  render(self.parser.feed(chunk)) catch {
    error => raise failed(error)
  }
}

///|
impl @harness.Feeder for SseFeeder with fn finish(self) {
  render(self.parser.finish()) catch {
    error => raise failed(error)
  }
}

///|
fn event(
  data : String,
  kind~ : String = "message",
  id? : String,
  retry? : Int32,
) -> @sse.SseEvent {
  { event: kind, data, id, retry, }
}

///|
/// Characters for generated field values: separators that must survive,
/// multibyte text, a BOM away from the stream start, and NUL (which voids an id).
let value_chars : Array[Char] = [
  'a', 'Z', '0', ' ', ':', '\t', 'é', '日', '🌙', '\u{FEFF}', '\u{0000}',
]

///|
fn random_value(rand : @random.Rand) -> String {
  let value = StringBuilder()
  for _ in 0..<rand.int(limit=6) {
    value.write_char(value_chars[rand.int(limit=value_chars.length())])
  }
  value.to_string()
}

///|
/// A line setting `name` to `value`, in one of the spellings that mean it.
fn field_line(rand : @random.Rand, name : String, value : String) -> String {
  if value == "" && rand.boolean() {
    name
  } else if !value.has_prefix(" ") && rand.boolean() {
    name + ":" + value
  } else {
    name + ": " + value
  }
}

///|
/// A random stream and the events it means, tracked while writing it.
fn generate_stream(rand : @random.Rand) -> (Bytes, Array[@sse.SseEvent]) {
  let text = StringBuilder()
  let events = []
  let data : Array[String] = []
  let mut kind = ""
  let mut id : String? = None
  let mut retry : Int32? = None
  let mut after_cr = false
  if rand.int(limit=4) == 0 {
    text.write_char('\u{FEFF}')
  }
  for _ in 0..<rand.int(limit=40) {
    let line = match rand.int(limit=10) {
      0 | 1 | 2 => {
        if !data.is_empty() {
          events.push(
            event(
              data.join("\n"),
              kind=if kind == "" { "message" } else { kind },
              id?,
              retry?,
            ),
          )
          retry = None
        }
        data.clear()
        kind = ""
        ""
      }
      3 | 4 => {
        let value = random_value(rand)
        data.push(value)
        field_line(rand, "data", value)
      }
      5 => {
        let value = random_value(rand)
        kind = value
        field_line(rand, "event", value)
      }
      6 => {
        let value = random_value(rand)
        if !value.contains("\u{0000}") {
          id = Some(value)
        }
        field_line(rand, "id", value)
      }
      7 =>
        if rand.boolean() {
          let value = rand.int(limit=100000)
          retry = Some(value)
          "retry: " +
          (if rand.boolean() { "00" } else { "" }) +
          value.to_string()
        } else {
          let invalid = ["", "1x", "-1", " 1", "99999999999x"]
          "retry: " + invalid[rand.int(limit=invalid.length())]
        }
      8 => ":" + random_value(rand)
      _ => {
        let unknown = ["unknown", "Data", "dat", "retries"]
        field_line(rand, unknown[rand.int(limit=unknown.length())], "x")
      }
    }
    text.write_string(line)
    let terminator = ["\n", "\r", "\r\n"][rand.int(limit=3)]
    // A blank line ending in LF right after a lone CR would read as one CRLF.
    let terminator = if after_cr && line == "" && terminator == "\n" {
      "\r\n"
    } else {
      terminator
    }
    text.write_string(terminator)
    after_cr = terminator == "\r"
  }
  // An unterminated tail is never dispatched.
  if rand.boolean() {
    text.write_string(field_line(rand, "data", random_value(rand)))
  }
  (@utf8.encode(text.to_string()), events)
}
