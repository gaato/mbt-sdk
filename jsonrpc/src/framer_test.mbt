///|
fn frame_all(bytes : Bytes) -> Array[Bytes] raise {
  let framer = @jsonrpc.LineFramer::new()
  let result = framer.feed(bytes)
  if framer.finish() is Some(tail) {
    result.push(tail)
  }
  result
}

///|
test "every two-way split and single-byte chunks preserve framed lines" {
  let corpus = [
    @utf8.encode("one\r\n\r\n two \n日本語🌙\r\nlast"),
    b"\n \n\t\n\r\nvalue\n",
    @utf8.encode("α\nβ\nγ"),
  ]
  for bytes in corpus {
    let expected = frame_all(bytes)
    for i in 0..<=bytes.length() {
      let framer = @jsonrpc.LineFramer::new()
      let actual = framer.feed(bytes[:i].to_owned())
      actual.append(framer.feed(bytes[i:].to_owned()))
      if framer.finish() is Some(tail) {
        actual.push(tail)
      }
      assert_eq(actual, expected)
    }
    let framer = @jsonrpc.LineFramer::new()
    let actual = []
    for byte in bytes {
      actual.append(framer.feed(Bytes::from_array([byte])))
    }
    if framer.finish() is Some(tail) {
      actual.push(tail)
    }
    assert_eq(actual, expected)
  }
}

///|
test "CRLF blank lines max length and finish semantics" {
  let framer = @jsonrpc.LineFramer::new()
  assert_eq(framer.feed(b"a\r\n \t\r\nb\r\r\n"), [b"a", b"b\r"])
  assert_eq(framer.finish(), None)
  assert_eq(framer.finish(), None)
  assert_eq(framer.feed(b"later\n"), [])

  let tail = @jsonrpc.LineFramer::new()
  assert_eq(tail.feed(b"unterminated"), [])
  assert_eq(tail.finish(), Some(b"unterminated"))
  assert_eq(tail.finish(), None)

  let blank = @jsonrpc.LineFramer::new()
  assert_eq(blank.feed(b" \t\r"), [])
  assert_eq(blank.finish(), None)

  let limited = @jsonrpc.LineFramer::new(max_line=3)
  assert_eq(limited.feed(b"abc"), [])
  try limited.feed(b"d") catch {
    @jsonrpc.DecodeError::LineTooLong(limit) => assert_eq(limit, 3)
    _ => fail("expected LineTooLong")
  } noraise {
    _ => fail("expected LineTooLong")
  }
  assert_eq(limited.feed(b"ignored\n"), [])
  assert_eq(limited.finish(), None)
}
