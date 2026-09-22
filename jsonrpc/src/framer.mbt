///|
/// An incremental byte-oriented NDJSON line splitter. Create one per stream.
pub struct LineFramer {
  priv line : Array[Byte]
  priv max_line : Int?
  priv mut finished : Bool
}

///|
/// Creates an empty line framer. Omitting `max_line` allows unbounded lines.
///
/// ```mbt check
/// test {
///   let framer = @jsonrpc.LineFramer::new()
///   assert_eq(framer.feed(b"one\ntwo\n"), [b"one", b"two"])
/// }
/// ```
pub fn LineFramer::new(max_line? : Int) -> LineFramer {
  { line: [], max_line, finished: false, }
}

///|
/// Feeds an arbitrary byte chunk and returns complete nonblank lines in order.
/// A trailing carriage return is removed from each complete line.
pub fn LineFramer::feed(
  self : LineFramer,
  bytes : Bytes,
) -> Array[Bytes] raise DecodeError {
  let lines = []
  if self.finished {
    return lines
  }
  for byte in bytes {
    if byte == b'\n' {
      let line = take_line(self.line)
      if !blank(line) {
        lines.push(line)
      }
    } else {
      self.line.push(byte)
      if self.max_line is Some(limit) && self.line.length() > limit {
        self.finished = true
        self.line.clear()
        raise LineTooLong(limit)
      }
    }
  }
  lines
}

///|
/// Finishes the stream and returns a final nonblank unterminated line once.
pub fn LineFramer::finish(self : LineFramer) -> Bytes? {
  if self.finished {
    return None
  }
  self.finished = true
  let line = Bytes::from_array(self.line.copy())
  self.line.clear()
  if blank(line) {
    None
  } else {
    Some(line)
  }
}

///|
fn take_line(buffer : Array[Byte]) -> Bytes {
  let length = buffer.length()
  let content_length = if length > 0 && buffer[length - 1] == b'\r' {
    length - 1
  } else {
    length
  }
  let result = Bytes::from_array(buffer[:content_length].to_owned())
  buffer.clear()
  result
}

///|
fn blank(line : Bytes) -> Bool {
  for byte in line {
    if byte != b' ' && byte != b'\t' && byte != b'\r' {
      return false
    }
  }
  true
}
