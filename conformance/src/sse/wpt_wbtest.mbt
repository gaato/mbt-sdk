// web-platform-tests' eventsource/format-*.js (see NOTICE), as the stream
// each test's server script writes and the events the test expects from
// it. resources/message.py writes the message, then "\n\n" unless
// `newline=none`, then "\n"; resources/last-event-id.py and
// last-event-id2.py write fixed streams. The tests' reconnection timing
// (format-field-retry*.js) is out of scope, since the parser does not
// reconnect; the retry hint they set is checked instead.

///|
fn message_py(message : String, newline~ : Bool = true) -> Bytes {
  @utf8.encode(message + (if newline { "\n\n" } else { "" }) + "\n")
}

///|
let wpt_streams : Array[(String, Bytes, Array[@sse.SseEvent])] = [
  (
    "format-bom",
    message_py("\u{FEFF}data:1\n\n\u{FEFF}data:2\n\ndata:3"),
    [event("1"), event("3")],
  ),
  (
    "format-bom-2",
    message_py("\u{FEFF}\u{FEFF}data:1\n\ndata:2\n\ndata:3"),
    [event("2"), event("3")],
  ),
  (
    "format-comments",
    message_py(
      "data:1\r:\u{0}\n:\r\ndata:2\n:" +
      "x".repeat(2048) +
      "\rdata:3\n:data:fail\r:" +
      "x".repeat(2048) +
      "\ndata:4\n",
      newline=false,
    ),
    [event("1\n2\n3\n4")],
  ),
  (
    "format-data-before-final-empty-line",
    message_py("retry:1000\ndata:test1\n\nid:test\ndata:test2", newline=false),
    [event("test1", retry=1000)],
  ),
  (
    "format-field-data",
    message_py("data:\n\ndata\ndata\n\ndata:test"),
    [event(""), event("\n"), event("test")],
  ),
  (
    "format-field-event-empty",
    message_py("event: \ndata:data"),
    [event("data")],
  ),
  (
    "format-field-event",
    message_py("event:test\ndata:x\n\ndata:x"),
    [event("x", kind="test"), event("x")],
  ),
  (
    "format-field-id",
    @utf8.encode("id: \u{2026}\nretry: 200\ndata: hello\n\n"),
    [event("hello", id="\u{2026}", retry=200)],
  ),
  (
    "format-field-id-3 persists",
    @utf8.encode("id: 1\ndata: 1\n\ndata: 2\n\nid: 2\ndata:3\n\ndata:4\n\n"),
    [
      event("1", id="1"),
      event("2", id="1"),
      event("3", id="2"),
      event("4", id="2"),
    ],
  ),
  (
    "format-field-id-3 resets",
    @utf8.encode("id: 1\ndata: 1\n\nid:\ndata:2\n\ndata:3\n\n"),
    [event("1", id="1"), event("2", id=""), event("3", id="")],
  ),
  (
    "format-field-id-3 resets without a colon",
    @utf8.encode("id: 1\ndata: 1\n\nid\ndata:2\n\ndata:3\n\n"),
    [event("1", id="1"), event("2", id=""), event("3", id="")],
  ),
  (
    "format-field-parsing",
    message_py(
      "data:\u{0}\ndata:  2\rData:1\ndata\u{0}:2\ndata:1\r\u{0}data:4\nda-ta:3\rdata_5\ndata:3\rdata:\r\n data:32\ndata:4\n",
      newline=false,
    ),
    [event("\u{0}\n 2\n1\n3\n\n4")],
  ),
  (
    "format-field-retry",
    message_py("retry:03000\ndata:x"),
    [event("x", retry=3000)],
  ),
  (
    "format-field-retry-bogus",
    message_py("retry:3000\nretry:1000x\ndata:x"),
    [event("x", retry=3000)],
  ),
  ("format-field-retry-empty", message_py("retry\ndata:test"), [event("test")]),
  (
    "format-field-unknown",
    message_py(
      "data:test\n data\ndata\nfoobar:xxx\njustsometext\n:thisisacommentyay\ndata:test",
    ),
    [event("test\n\ntest")],
  ),
  (
    "format-leading-space",
    message_py("data:\ttest\rdata: \ndata:test"),
    [event("\ttest\n\ntest")],
  ),
  (
    "format-newlines",
    message_py("data:test\r\ndata\ndata:test\r\n\r", newline=false),
    [event("test\n\ntest")],
  ),
  ("format-null-character", message_py("data:\u{0}\n\n"), [event("\u{0}")]),
  ("format-utf-8", message_py("data:ok\u{2026}"), [event("ok\u{2026}")]),
]

///|
/// format-field-id-null.window.js: an id with NUL in it is ignored.
let wpt_null_ids : Array[String] = [
  "\u{0}\u{0}", "x\u{0}", "\u{0}x", "x\u{0}x", " \u{0}",
]

///|
test "the parser gives the events web-platform-tests expect" {
  let rand = @harness.seeded(30)
  let streams = wpt_streams.copy()
  for value in wpt_null_ids {
    streams.push(
      (
        "format-field-id-null \{Repr(value)}",
        @utf8.encode("id: \{value}\nretry: 200\ndata: hello\n\n"),
        [event("hello", retry=200)],
      ),
    )
  }
  for row in streams {
    let (name, input, expected) = row
    let whole = @harness.check_rules(
      () => sse_feeder(),
      input,
      rand,
      label=name,
    )
    assert_eq(whole, { results: render(expected), error: None, }, msg=name)
  }
}
