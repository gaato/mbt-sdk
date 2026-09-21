///|
fn event(
  data : String,
  kind? : String = "message",
  id? : String,
  retry? : Int,
) -> @sse.SseEvent {
  { event: kind, data, id, retry, }
}

///|
fn parse(text : String) -> Array[@sse.SseEvent] {
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
