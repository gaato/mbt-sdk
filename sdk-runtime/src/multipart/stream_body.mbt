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
    length = match (length, size) {
      (Some(total), Some(size)) => Some(total + size)
      _ => None
    }
  }
  guard streamed else { Bytes(join_segments(fixed)) }
  let stream = MultipartStream::{
    pieces,
    delimiter: @http.encode_utf8("\r\n--" + boundary),
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
/// part from its own stream, taken when reached and scanned for the
/// delimiter. Holds nothing but the pieces and the part being read.
priv struct MultipartStream {
  pieces : Array[Piece]
  delimiter : Bytes
  mut next : Int32
  mut current : Reading?
  mut closed : Bool
}

///|
impl @http.BodyStream for MultipartStream with fn read_some(self) {
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
      Streamed(name, stream) =>
        self.current = Some({
          reader: stream.take(),
          name,
          scan: BoundaryScan::new(self.delimiter),
        })
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
  for piece in self.pieces[self.next:] {
    if piece is Streamed(_, stream) {
      // A stream another sender took is that sender's to close.
      try stream.take() catch {
        _ => ()
      } noraise {
        reader => reader.close()
      }
    }
  }
}
