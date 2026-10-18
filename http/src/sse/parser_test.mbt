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
fn parse(text : String) -> Array[@sse.SseEvent] raise {
  let parser = @sse.SseParser::new()
  let result = parser.feed(@utf8.encode(text))
  result.append(parser.finish())
  result
}

///|
test "WHATWG introduction examples" {
  assert_eq(
    parse(
      "data: This is the first message.\n\ndata: This is the second message, it\ndata: has two lines.\n\ndata: This is the third message.\n\n",
    ),
    [
      event("This is the first message."),
      event("This is the second message, it\nhas two lines."),
      event("This is the third message."),
    ],
  )
  assert_eq(
    parse(
      "event: add\ndata: 73857293\n\nevent: remove\ndata: 2153\n\nevent: add\ndata: 113411\n\n",
    ),
    [
      event("73857293", kind="add"),
      event("2153", kind="remove"),
      event("113411", kind="add"),
    ],
  )
}

///|
test "WHATWG interpretation examples" {
  assert_eq(parse("data: YHOO\ndata: +2\ndata: 10\n\n"), [event("YHOO\n+2\n10")])
  assert_eq(
    parse(
      ": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n",
    ),
    [
      event("first event", id="1"),
      event("second event", id=""),
      event(" third event", id=""),
    ],
  )
  assert_eq(parse("data\n\ndata\ndata\n\ndata:\n"), [event(""), event("\n")])
  assert_eq(parse("data:test\n\ndata: test\n\n"), [event("test"), event("test")])
}

///|
test "line endings including CRLF split across chunks" {
  for separator in ["\n", "\r", "\r\n"] {
    assert_eq(
      parse(
        "data: a" + separator + separator + "data: b" + separator + separator,
      ),
      [event("a"), event("b")],
    )
  }
  let parser = @sse.SseParser::new()
  assert_eq(parser.feed(b"data: a\r"), [])
  assert_eq(parser.feed(b""), [])
  assert_eq(parser.feed(b"\ndata: b\r"), [])
  assert_eq(parser.feed(b"\n\r"), [event("a\nb")])
  assert_eq(parser.feed(b"\n"), [])
}

///|
test "BOM only at stream start and lossy UTF-8" {
  assert_eq(parse("\u{FEFF}data: 日本語🌙\n\n"), [event("日本語🌙")])
  assert_eq(
    parse(
      "\u{FEFF}\u{FEFF}data: ignored\ndata: ok\n\n\u{FEFF}data: ignored\ndata: \u{FEFF}kept\n\n",
    ),
    [event("ok"), event("\u{FEFF}kept")],
  )
  let parser = @sse.SseParser::new()
  assert_eq(parser.feed(b"data: \xff\xe3\x81\n\n"), [event("\u{FFFD}\u{FFFD}")])
}

///|
test "fields comments spaces event reset id persistence and null rejection" {
  assert_eq(
    parse(
      ": comment\nunknown: x\nData: ignored\nevent: ignored\nid: first\n\ndata: one\n\nevent: custom\nevent: last\nid: bad\u{0000}id\ndata:  two:three\ndata:\n\ndata\nevent\n\nid\ndata: [DONE]\n\n",
    ),
    [
      event("one", id="first"),
      event(" two:three\n", kind="last", id="first"),
      event("", id="first"),
      event("[DONE]", id=""),
    ],
  )
  assert_eq(parse("data:\tvalue\n\n"), [event("\tvalue")])
}

///|
test "retry is pending until dispatch then resets and ignores invalid values" {
  assert_eq(parse("retry: 0012\n\nevent: ignored\n\ndata: a\n\ndata: b\n\n"), [
    event("a", retry=12),
    event("b"),
  ])
  for
    invalid in [
      "", "-1", "+1", "1.0", "1x", " 1", "1 ", "１２", "2147483648", "999999999999999999999999999999999",
    ] {
    assert_eq(
      parse("retry: 7\nretry: " + invalid + "\ndata: x\n\ndata: y\n\n"),
      [event("x", retry=7), event("y")],
    )
    assert_eq(parse("retry: " + invalid + "\ndata: x\n\n"), [event("x")])
  }
  assert_eq(
    parse(
      "retry: 2147483647\ndata: max\n\nretry: 0000000000000000000000000000\ndata: zero\n\nretry: 1\nretry: 2\ndata: last\n\n",
    ),
    [
      event("max", retry=2147483647),
      event("zero", retry=0),
      event("last", retry=2),
    ],
  )
}

///|
test "finish discards incomplete events and permanently ends parsing" {
  for
    input in [
      "data: pending", "data: pending\n", "event: x\nid: y\nretry: 3\ndata: pending\n",
      "",
    ] {
    let parser = @sse.SseParser::new()
    assert_eq(parser.feed(@utf8.encode(input)), [])
    assert_eq(parser.finish(), [])
    assert_eq(parser.finish(), [])
    assert_eq(parser.feed(b"\ndata: later\n\n"), [])
  }
}

///|
test "every two-way byte split and single-byte chunks preserve events" {
  let corpus = [
    @utf8.encode("data: a\r\ndata: b\r\n\r\ndata: c\r\n\r\n"),
    @utf8.encode("data: a\r\rdata: b\r\r"),
    @utf8.encode("\u{FEFF}data: 日本語🌙\n\n"),
    @utf8.encode("data: one\ndata:\ndata: three\n\ndata\n\n"),
    @utf8.encode(": comment\r\nunknown: ignored\rdata: x\n\n"),
    @utf8.encode(
      "id: abc\nretry: 123\n\ndata: x\n\nid: a\u{0000}b\ndata: y\n\n",
    ),
    @utf8.encode("\u{FEFF}\u{FEFF}data: no\ndata: yes\n\ndata: incomplete"),
    b"data: \xf0\x9f\x8c\x99\xff\xe3\x81\r\n\r\n",
  ]
  for bytes in corpus {
    let whole = @sse.SseParser::new()
    let expected = whole.feed(bytes)
    expected.append(whole.finish())
    for i in 0..<=bytes.length() {
      let parser = @sse.SseParser::new()
      let actual = parser.feed(bytes[:i].to_owned())
      actual.append(parser.feed(bytes[i:].to_owned()))
      actual.append(parser.finish())
      assert_eq(actual, expected)
    }
    let parser = @sse.SseParser::new()
    let actual = []
    for byte in bytes {
      actual.append(parser.feed(Bytes::from_array([byte])))
    }
    actual.append(parser.finish())
    assert_eq(actual, expected)
  }
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
          let invalid = ["", "1x", "-1", " 1", "2147483648"]
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

///|
fn events_of_chunks(chunks : Array[Bytes]) -> Array[@sse.SseEvent] raise {
  let parser = @sse.SseParser::new()
  let events = []
  for chunk in chunks {
    events.append(parser.feed(chunk))
  }
  events.append(parser.finish())
  events
}

///|
/// Cuts `bytes` into chunks of 0 to 7 bytes, empty chunks included.
fn random_chunks(rand : @random.Rand, bytes : Bytes) -> Array[Bytes] {
  let chunks = []
  let mut start = 0
  while start < bytes.length() {
    let end = (start + rand.int(limit=8)).min(bytes.length())
    chunks.push(bytes[start:end].to_owned())
    start = end
  }
  chunks
}

///|
/// Cuts after every CR and every non-ASCII byte, so each CRLF and each
/// multibyte character straddles a chunk boundary.
fn hostile_chunks(bytes : Bytes) -> Array[Bytes] {
  let chunks = []
  let mut start = 0
  for i, byte in bytes {
    if byte == b'\r' || byte >= b'\x80' {
      chunks.push(bytes[start:i + 1].to_owned())
      start = i + 1
    }
  }
  chunks.push(bytes[start:].to_owned())
  chunks
}

///|
fn seeded(seed : Int32) -> @random.Rand {
  @random.Rand::chacha8(seed=Bytes::make(32, seed.to_byte()))
}

///|
test "generated streams parse to their events under any chunking" {
  for seed in 0..<4 {
    let rand = seeded(seed)
    for case in 0..<100 {
      let (bytes, expected) = generate_stream(rand)
      let label = "seed \{seed} case \{case}"
      assert_eq(events_of_chunks([bytes]), expected, msg="\{label} whole")
      assert_eq(
        events_of_chunks(hostile_chunks(bytes)),
        expected,
        msg="\{label} hostile",
      )
      for round in 0..<4 {
        assert_eq(
          events_of_chunks(random_chunks(rand, bytes)),
          expected,
          msg="\{label} random \{round}",
        )
      }
    }
  }
}

///|
/// Raw bytes around the parser's edges: terminators, field punctuation,
/// fragments of multibyte characters and a BOM, and invalid UTF-8.
let raw_alphabet : Array[Byte] = [
  b'd', b'a', b't', b'i', b'r', b'e', b'y', b':', b' ', b'1', b'\r', b'\n', b'\n',
  b'\x00', b'\xe6', b'\x97', b'\xa5', b'\xef', b'\xbb', b'\xbf', b'\xff',
]

///|
test "random bytes parse the same under any chunking" {
  for seed in 4..<8 {
    let rand = seeded(seed)
    for case in 0..<100 {
      let bytes = Bytes::makei(rand.int(limit=64), _ => {
        raw_alphabet[rand.int(limit=raw_alphabet.length())]
      })
      let expected = events_of_chunks([bytes])
      let label = "seed \{seed} case \{case}"
      assert_eq(
        events_of_chunks(hostile_chunks(bytes)),
        expected,
        msg="\{label} hostile",
      )
      for round in 0..<4 {
        assert_eq(
          events_of_chunks(random_chunks(rand, bytes)),
          expected,
          msg="\{label} random \{round}",
        )
      }
    }
  }
}

///|
/// The data of each event fed through a bounded parser, and the refusal
/// message if the parser refused the stream.
fn bounded_outcome(
  limit : Int32,
  chunks : Array[String],
) -> (Array[String], String?) {
  let parser = @sse.SseParser::new(max_event_bytes=limit)
  let data = []
  try {
    for chunk in chunks {
      for event in parser.feed(@utf8.encode(chunk)) {
        data.push(event.data)
      }
    }
    ignore(parser.finish())
    (data, None)
  } catch {
    @http.HttpError::Protocol(message) => (data, Some(message))
    _ => (data, Some("unexpected error"))
  }
}

///|
test "one event is bounded by its data lines plus the line being read" {
  let refused = Some("SSE event larger than 12 bytes")
  let x = (n : Int32) => "x".repeat(n)
  let rows : Array[(String, Int32, Array[String], (Array[String], String?))] = [
    ("line at limit", 12, ["data:" + x(7) + "\n\n"], ([x(7)], None)),
    ("line at limit + 1", 12, ["data:" + x(8) + "\n\n"], ([], refused)),
    ("endless line at limit", 12, [x(12)], ([], None)),
    ("endless line at limit + 1", 12, [x(13)], ([], refused)),
    (
      "endless line at limit + 1 over chunks",
      12,
      [x(5), x(7), "x"],
      ([], refused),
    ),
    ("data lines at limit", 12, ["data:a\ndata:a\n\n"], (["a\na"], None)),
    ("data lines at limit + 1", 12, ["data:a\ndata:ab\n\n"], ([], refused)),
    (
      "endless data lines at limit + 1",
      12,
      ["data:a\n", "data:a\n", "d"],
      ([], refused),
    ),
    (
      "terminators are not counted",
      12,
      ["data:" + x(7) + "\r\n\r\n"],
      ([x(7)], None),
    ),
    (
      "other lines do not accumulate",
      12,
      [
        ": comment!!\nevent: abcde\nid: abcdefgh\nretry: 1000\ndata:" +
        x(7) +
        "\n\n",
      ],
      ([x(7)], None),
    ),
    (
      "a blank line resets the count",
      12,
      ["data:" + x(7) + "\n\ndata:" + x(7) + "\n\n"],
      ([x(7), x(7)], None),
    ),
    ("bytes, not characters", 12, ["data:日日a\n\n"], (["日日a"], None)),
    ("bytes, not characters + 1", 12, ["data:日日é\n\n"], ([], refused)),
    (
      "events in earlier chunks survive",
      12,
      ["data: a\n\n", x(13)],
      (["a"], refused),
    ),
    (
      "events earlier in the refused chunk are delivered, then the raise",
      12,
      ["data: a\n\n" + x(13)],
      (["a"], refused),
    ),
    ("zero allows blank lines", 0, ["\n\r\n\r"], ([], None)),
    (
      "zero refuses any field",
      0,
      ["d"],
      ([], Some("SSE event larger than 0 bytes")),
    ),
  ]
  for row in rows {
    let (label, limit, chunks, expected) = row
    assert_eq(bounded_outcome(limit, chunks), expected, msg=label)
  }
}

///|
test "a refused stream stays finished" {
  let parser = @sse.SseParser::new(max_event_bytes=4)
  try parser.feed(b"data: a") catch {
    _ => ()
  } noraise {
    _ => fail("expected the event to be refused")
  }
  assert_eq(parser.feed(b"\n\ndata: b\n\n"), [])
}

///|
test "an overflow after events in the same chunk raises on the next call" {
  let next_feed = @sse.SseParser::new(max_event_bytes=4)
  assert_eq(next_feed.feed(b"data\n\ndata: a"), [event("")])
  try next_feed.feed(b"") catch {
    @http.HttpError::Protocol(_) => ()
    _ => fail("expected Protocol")
  } noraise {
    _ => fail("the next feed must raise")
  }
  assert_eq(next_feed.feed(b"data\n\n"), [])
  assert_eq(next_feed.finish(), [])
  let at_finish = @sse.SseParser::new(max_event_bytes=4)
  assert_eq(at_finish.feed(b"data\n\ndata: a"), [event("")])
  try at_finish.finish() catch {
    @http.HttpError::Protocol(_) => ()
    _ => fail("expected Protocol")
  } noraise {
    _ => fail("finish must raise an overflow at the end of the stream")
  }
  assert_eq(at_finish.finish(), [])
}

///|
test "the bound refuses generated streams the same way under any chunking" {
  for seed in 8..<12 {
    let rand = seeded(seed)
    for case in 0..<100 {
      let (bytes, unbounded) = generate_stream(rand)
      let limit = rand.int(limit=40)
      let label = "seed \{seed} case \{case} limit \{limit}"
      // Byte by byte, every event completed before the overflow is returned.
      let (before, refused) = bounded_events(
        limit,
        bytes.iter().map(byte => Bytes::make(1, byte)).collect(),
      )
      assert_true(is_prefix(before, unbounded), msg="\{label} reference prefix")
      assert_true(refused || before == unbounded, msg="\{label} reference all")
      for chunks in [[bytes], hostile_chunks(bytes), random_chunks(rand, bytes)] {
        let (events, chunked_refused) = bounded_events(limit, chunks)
        assert_eq(chunked_refused, refused, msg="\{label} refused")
        assert_eq(events, before, msg="\{label} events")
      }
    }
  }
}

///|
fn bounded_events(
  limit : Int32,
  chunks : Array[Bytes],
) -> (Array[@sse.SseEvent], Bool) {
  let parser = @sse.SseParser::new(max_event_bytes=limit)
  let events = []
  try {
    for chunk in chunks {
      events.append(parser.feed(chunk))
    }
    events.append(parser.finish())
    (events, false)
  } catch {
    _ => (events, true)
  }
}

///|
fn is_prefix(
  prefix : Array[@sse.SseEvent],
  whole : Array[@sse.SseEvent],
) -> Bool {
  prefix.length() <= whole.length() &&
  prefix == whole[:prefix.length()].to_owned()
}
