///|
/// An incremental byte-oriented NDJSON line splitter. Create one per stream.
pub struct LineFramer {
  priv line : Array[Byte]
  priv max_line : Int32?
  priv mut finished : Bool
  priv mut overflow : Int32?
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
pub fn LineFramer::new(max_line? : Int32) -> LineFramer {
  { line: [], max_line, finished: false, overflow: None, }
}

///|
/// Feeds an arbitrary byte chunk and returns complete nonblank lines in order.
/// A trailing carriage return is removed from each complete line.
///
/// `max_line` bounds a line's content: the carriage return of a CRLF
/// terminator is exempt, while any other carriage return counts. A line over
/// it raises `LineTooLong` and ends the stream. When the same chunk completed
/// lines before it, those are returned first and the next `feed` raises, so
/// feed an empty chunk to observe it without waiting for more input.
pub fn LineFramer::feed(
  self : LineFramer,
  bytes : Bytes,
) -> Array[Bytes] raise DecodeError {
  if self.overflow is Some(limit) {
    self.overflow = None
    raise LineTooLong(limit)
  }
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
      if self.max_line is Some(limit) && overlong(self.line, limit) {
        self.finished = true
        self.line.clear()
        if lines.is_empty() {
          raise LineTooLong(limit)
        }
        self.overflow = Some(limit)
        return lines
      }
    }
  }
  lines
}

///|
/// Finishes the stream and returns a final nonblank unterminated line once.
/// A final line over `max_line` is dropped, because this cannot raise; that
/// happens only when its last byte is a carriage return no newline followed.
pub fn LineFramer::finish(self : LineFramer) -> Bytes? {
  if self.finished {
    return None
  }
  self.finished = true
  let line = Bytes::from_array(self.line.copy())
  self.line.clear()
  if blank(line) || (self.max_line is Some(limit) && line.length() > limit) {
    None
  } else {
    Some(line)
  }
}

///|
/// Reports whether a partial line holds more than `limit` content bytes. A
/// final carriage return gets one byte of slack: it may yet be the start of a
/// CRLF terminator, which `take_line` strips.
fn overlong(line : Array[Byte], limit : Int32) -> Bool {
  let length = line.length()
  length > limit && !(length - 1 == limit && line[length - 1] == b'\r')
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
