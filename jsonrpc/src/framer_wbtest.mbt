///|
fn finish_label(framer : LineFramer) -> String {
  try framer.finish() catch {
    error => "finish raise \{Repr(error)}"
  } noraise {
    line => "finish \{Repr(line.map(line => @utf8.decode_lossy(line)))}"
  }
}

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
  steps.push(finish_label(framer))
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
      "a blank unterminated tail whose CR goes over the limit",
      3,
      [b"  \t\r"],
      ["[]", "finish raise LineTooLong(3)"],
    ),
    (
      "an unterminated tail whose CR goes over the limit",
      3,
      [b"abc\r"],
      ["[]", "finish raise LineTooLong(3)"],
    ),
  ]
  for row in rows {
    let (label, max_line, chunks, expected) = row
    assert_eq(limited_transcript(max_line, chunks), expected, msg=label)
  }
}

///|
test "an overflow delivers the lines completed before it, then raises once" {
  let rows : Array[(String, Int32, Array[Bytes], Array[String])] = [
    (
      "overflow with no earlier line raises at once",
      3,
      [b"abcd\nef\n", b"gh\n"],
      ["raise LineTooLong(3)", "[]", "finish None"],
    ),
    (
      "earlier lines first, the raise on the next feed",
      3,
      [b"ab\n\ncd\nefgh\nij\n", b"", b"kl\n"],
      ["[\"ab\", \"cd\"]", "raise LineTooLong(3)", "[]", "finish None"],
    ),
    (
      "the next feed raises whatever it carries",
      3,
      [b"ab\nefgh", b"ij\n"],
      ["[\"ab\"]", "raise LineTooLong(3)", "finish None"],
    ),
    (
      "a deferred overflow at the end of the stream",
      3,
      [b"ab\nefgh"],
      ["[\"ab\"]", "finish raise LineTooLong(3)"],
    ),
    (
      "a CRLF line before the overflow",
      3,
      [b"abc\r\nabcd", b""],
      ["[\"abc\"]", "raise LineTooLong(3)", "finish None"],
    ),
  ]
  for row in rows {
    let (label, max_line, chunks, expected) = row
    assert_eq(limited_transcript(max_line, chunks), expected, msg=label)
  }
}
