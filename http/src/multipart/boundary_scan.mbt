///|
/// Finds the multipart delimiter `CRLF--boundary` in a part body that arrives
/// in chunks, as `body_collides` does for a body in memory: the body is read
/// as if preceded by the CRLF that ends the part's headers, so a body that
/// starts with `--boundary` collides too. A match cannot straddle the part's
/// end, since the framing after a body starts with a CRLF, which neither the
/// boundary nor `--` contains. The CR that starts the pattern occurs nowhere
/// else in it, so after a mismatch a match can only restart at a CR: each
/// byte is looked at once, however the chunks fall.
priv struct BoundaryScan {
  pattern : Bytes
  mut matched : Int32
}

///|
/// A scan for `pattern`, which starts with CRLF, positioned after a CRLF.
fn BoundaryScan::new(pattern : Bytes) -> BoundaryScan {
  { pattern, matched: 2, }
}

///|
/// Feeds the next chunk; true once the pattern has been seen.
fn BoundaryScan::feed(self : BoundaryScan, chunk : BytesView) -> Bool {
  let pattern = self.pattern
  for byte in chunk {
    if self.matched == pattern.length() {
      return true
    }
    self.matched = if byte == pattern[self.matched] {
      self.matched + 1
    } else if byte == b'\r' {
      1
    } else {
      0
    }
  }
  self.matched == pattern.length()
}
