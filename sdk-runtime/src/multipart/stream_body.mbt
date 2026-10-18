///|
/// The body for `pieces`: one buffer when every piece is in memory, so a
/// request without stream parts goes out exactly as `encode` makes it, and
/// otherwise a stream with the total length when every stream part has one.
fn pieces_body(pieces : Array[Piece], boundary : String) -> @http.Body {
  let mut length : Int64? = Some(0L)
  let mut streamed = false
  let fixed : Array[Bytes] = []
  for piece in pieces {
    let size = match piece {
      Fixed(bytes) => {
        fixed.push(bytes)
        Some(bytes.length().to_int64())
      }
      Streamed(_, stream) => {
        streamed = true
        stream.length()
      }
    }
    // A negative part length is refused when the parts are taken; it must
    // not shrink the total into a plausible Content-Length meanwhile.
    length = match (length, size) {
      (Some(total), Some(size)) if size >= 0L => Some(total + size)
      _ => None
    }
  }
  guard streamed else { Bytes(join_segments(fixed)) }
  let stream = MultipartStream::{
    pieces,
    delimiter: @http.encode_utf8("\r\n--" + boundary),
    readers: None,
    next_reader: 0,
    next: 0,
    current: None,
    closed: false,
  }
  Stream(@http.StreamBody::new(stream, length?))
}

///|
/// The stream part being read: its reader, its name and its boundary scan.
priv struct Reading {
  reader : &@http.BodyStream
  name : String
  scan : BoundaryScan
}

///|
/// A multipart body read piece by piece: framing as it is, and each stream
/// part from its own stream, scanned for the delimiter. Every part stream is
/// taken at the first read, before any framing is returned, so a part that
/// cannot be sent fails before a byte of the request goes out. Holds nothing
/// but the pieces, their readers and the part being read.
priv struct MultipartStream {
  pieces : Array[Piece]
  delimiter : Bytes
  mut readers : Array[&@http.BodyStream]?
  mut next_reader : Int32
  mut next : Int32
  mut current : Reading?
  mut closed : Bool
}

///|
impl @http.BodyStream for MultipartStream with fn read_some(self) {
  if self.readers is None && !self.closed {
    self.readers = Some(self.take_parts())
  }
  for ;; {
    if self.closed {
      return None
    }
    if self.current is Some(part) {
      match part.reader.read_some() {
        Some(chunk) => {
          if part.scan.feed(chunk) {
            raise @http.HttpError::Protocol(
              "multipart part \{part.name.escape()} contains the boundary delimiter",
            )
          }
          if !chunk.is_empty() {
            return Some(chunk)
          }
        }
        None => {
          self.current = None
          part.reader.close()
        }
      }
      continue
    }
    guard self.pieces.get(self.next) is Some(piece) else { return None }
    self.next += 1
    match piece {
      Fixed(bytes) => return Some(bytes)
      Streamed(name, _) => {
        let readers = self.readers.unwrap_or([])
        let reader = readers[self.next_reader]
        self.next_reader += 1
        self.current = Some({
          reader,
          name,
          scan: BoundaryScan::new(self.delimiter),
        })
      }
    }
  }
}

///|
/// Takes every part stream, in order. If one cannot be taken, the ones taken
/// so far are closed, the body is closed and the error is raised.
fn MultipartStream::take_parts(
  self : MultipartStream,
) -> Array[&@http.BodyStream] raise @http.HttpError {
  let readers : Array[&@http.BodyStream] = []
  let mut index = 0
  errdefer {
    for reader in readers {
      reader.close()
    }
    // The parts after the one that failed are still this body's to close.
    for piece in self.pieces[index + 1:] {
      close_unclaimed(piece)
    }
    self.readers = Some([])
    self.closed = true
  }
  for i, piece in self.pieces {
    index = i
    if piece is Streamed(_, stream) {
      readers.push(stream.take())
    }
  }
  readers
}

///|
/// Closes a stream part no sender has taken; one another sender took is left
/// to it.
fn close_unclaimed(piece : Piece) -> Unit {
  if piece is Streamed(_, stream) {
    try stream.take() catch {
      _ => ()
    } noraise {
      reader => reader.close()
    }
  }
}

///|
/// Closes the part being read and every stream part not reached yet.
impl @http.BodyStream for MultipartStream with fn close(self) {
  if self.closed {
    return
  }
  self.closed = true
  if self.current is Some(part) {
    part.reader.close()
  }
  if self.readers is Some(readers) {
    for reader in readers[self.next_reader:] {
      reader.close()
    }
    return
  }
  for piece in self.pieces[self.next:] {
    close_unclaimed(piece)
  }
}
