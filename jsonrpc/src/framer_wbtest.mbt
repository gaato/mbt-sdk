///|
/// Feeds `chunks` to a framer limited to `max_line`, then finishes it, and
/// renders each step's outcome.
fn limited_transcript(max_line : Int32, chunks : Array[Bytes]) -> Array[String] {
  let framer = LineFramer::new(max_line~)
  let steps = []
  for chunk in chunks {
    steps.push(
      try framer.feed(chunk) catch {
        error => "raise \{Repr(error)}"
      } noraise {
        lines => "\{Repr(lines.map(line => @utf8.decode_lossy(line)))}"
      },
    )
  }
  steps.push(
    "finish \{Repr(framer.finish().map(line => @utf8.decode_lossy(line)))}",
  )
  steps
}

///|
test "max_line bounds line content, not the CRLF terminator" {
  let rows : Array[(String, Int32, Array[Bytes], Array[String])] = [
    ("LF line at the limit", 3, [b"abc\n"], ["[\"abc\"]", "finish None"]),
    ("CRLF line at the limit", 3, [b"abc\r\n"], ["[\"abc\"]", "finish None"]),
    (
      "CRLF split between chunks",
      3,
      [b"abc\r", b"\n"],
      ["[]", "[\"abc\"]", "finish None"],
    ),
    (
      "content over the limit",
      3,
      [b"abcd\n"],
      ["raise LineTooLong(3)", "finish None"],
    ),
    (
      "a lone CR inside the line counts",
      3,
      [b"ab\rc\n"],
      ["raise LineTooLong(3)", "finish None"],
    ),
    (
      "a CR followed by content counts",
      3,
      [b"abc\r", b"d\n"],
      ["[]", "raise LineTooLong(3)", "finish None"],
    ),
    (
      "a CR before the CRLF is content",
      3,
      [b"ab\r\r\n"],
      ["[\"ab\\r\"]", "finish None"],
    ),
    (
      "a CR before the CRLF over the limit",
      2,
      [b"ab\r\r\n"],
      ["raise LineTooLong(2)", "finish None"],
    ),
    (
      "an unterminated tail at the limit",
      3,
      [b"abc"],
      ["[]", "finish Some(\"abc\")"],
    ),
    (
      "an unterminated tail whose CR goes over the limit",
      3,
      [b"abc\r"],
      ["[]", "finish None"],
    ),
  ]
  for row in rows {
    let (label, max_line, chunks, expected) = row
    assert_eq(limited_transcript(max_line, chunks), expected, msg=label)
  }
}
