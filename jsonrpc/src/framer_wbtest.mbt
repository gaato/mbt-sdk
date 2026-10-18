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

///|
/// Builds a random stream of short lines, blank lines, lines over `max_line`
/// and stray carriage returns, with LF or CRLF terminators and maybe a tail.
fn random_stream(rand : @random.Rand, max_line : Int32) -> Bytes {
  let alphabet = [b'a', b'b', b' ', b'\t', b'\r']
  let bytes = []
  for _ in 0..<rand.int(limit=6) {
    for _ in 0..<rand.int(limit=max_line + 3) {
      bytes.push(alphabet[rand.int(limit=alphabet.length())])
    }
    if rand.boolean() {
      bytes.push(b'\r')
    }
    bytes.push(b'\n')
  }
  for _ in 0..<rand.int(limit=3) {
    bytes.push(alphabet[rand.int(limit=alphabet.length())])
  }
  Bytes::from_array(bytes)
}

///|
/// Feeds `chunks` in order, then an empty chunk to surface a pending overflow,
/// then finishes. Delivered lines and the raise appear in stream order, so the
/// result does not depend on which `feed` call they came from.
fn stream_events(max_line : Int32, chunks : Array[Bytes]) -> Array[String] {
  let framer = LineFramer::new(max_line~)
  let events = []
  for chunk in [..chunks, b""] {
    let lines = framer.feed(chunk) catch {
      error => {
        events.push("raise \{Repr(error)}")
        continue
      }
    }
    for line in lines {
      events.push("\{Repr(@utf8.decode_lossy(line))}")
    }
  }
  events.push(finish_label(framer))
  events
}

///|
test "random chunkings frame like one chunk, overflow included" {
  let rand = @random.Rand::chacha8(seed=b"jsonrpc line framer chunkings 01")
  for case in 0..<300 {
    let max_line = 1 + rand.int(limit=6)
    let stream = random_stream(rand, max_line)
    let expected = stream_events(max_line, [stream])
    for _ in 0..<20 {
      let chunks = []
      let mut start = 0
      while start < stream.length() {
        let end = (start + rand.int(limit=5)).min(stream.length())
        chunks.push(stream[start:end].to_owned())
        start = end
      }
      assert_eq(
        stream_events(max_line, chunks),
        expected,
        msg="case \{case} max_line=\{max_line} stream=\{Repr(@utf8.decode_lossy(stream))} chunks=\{Repr(chunks.map(chunk => chunk.length()))}",
      )
    }
  }
}
