///|
/// `LineFramer` as the harness sees it: each line rendered by its debug
/// form, and an overlong line as the kind `LineTooLong`.
struct LineFeeder {
  framer : @jsonrpc.LineFramer
}

///|
fn line_feeder(max_line? : Int32) -> LineFeeder {
  { framer: @jsonrpc.LineFramer::new(max_line?), }
}

///|
fn render(lines : Array[Bytes]) -> Array[String] {
  lines.map(line => "\{Repr(line)}")
}

///|
fn failed(error : @jsonrpc.DecodeError) -> @harness.Failed {
  match error {
    LineTooLong(_) => Failed("LineTooLong")
    _ => Failed("unexpected")
  }
}

///|
impl @harness.Feeder for LineFeeder with fn feed(self, chunk) {
  render(self.framer.feed(chunk)) catch {
    error => raise failed(error)
  }
}

///|
impl @harness.Feeder for LineFeeder with fn finish(self) {
  let tail = self.framer.finish() catch { error => raise failed(error) }
  match tail {
    Some(line) => render([line])
    None => []
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
