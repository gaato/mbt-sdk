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
