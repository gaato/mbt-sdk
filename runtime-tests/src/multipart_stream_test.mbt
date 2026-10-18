///|
/// A part stream over fixed chunks that records being closed.
struct Parts {
  chunks : Array[Bytes]
  mut next : Int32
  mut closed : Bool
}

///|
fn parts_of(chunks : Array[Bytes]) -> Parts {
  { chunks, next: 0, closed: false, }
}

///|
impl @http.BodyStream for Parts with fn read_some(self) {
  guard self.chunks.get(self.next) is Some(chunk) else { return None }
  self.next += 1
  Some(chunk)
}

///|
impl @http.BodyStream for Parts with fn close(self) {
  self.closed = true
}

///|
/// Reads a request body to its end, or the failure, as a label.
async fn read_body(body : @http.Body) -> Result[Bytes, String] {
  match body {
    Bytes(bytes) => Ok(bytes)
    Stream(stream) =>
      try {
        let reader = stream.take()
        defer reader.close()
        let out = Buffer()
        while reader.read_some() is Some(chunk) {
          out.write_bytes(chunk)
        }
        Ok(out.to_bytes())
      } catch {
        error => Err(@debug.to_string(error))
      }
  }
}

///|
/// Cuts `body` at random points, sometimes leaving empty chunks between.
fn cut(rand : @random.Rand, body : Bytes) -> Array[Bytes] {
  let chunks = []
  let mut start = 0
  while start < body.length() {
    let end = start + rand.int(limit=body.length() - start + 1)
    chunks.push(body[start:end].to_owned())
    start = end
    if rand.int(limit=4) == 0 {
      chunks.push(b"")
    }
  }
  chunks
}

///|
async test "streamed and buffered multipart encodings are byte-identical" {
  for seed in 0..<4 {
    let rand = @random.Rand::chacha8(seed=Bytes::make(32, seed.to_byte()))
    for trial in 0..<40 {
      let buffered : Array[@multipart.Part] = []
      let streamed : Array[@multipart.Part] = []
      let sources : Array[Parts] = []
      for index in 0..<rand.int(limit=5) {
        let body = Bytes::makei(rand.int(limit=3000), _ => {
          rand.int(limit=256).to_byte()
        })
        let name = "f\{index}"
        buffered.push(@multipart.Part::file(name, "a.bin", "x/y", body))
        if rand.int(limit=2) == 0 {
          streamed.push(@multipart.Part::file(name, "a.bin", "x/y", body))
        } else {
          let source = parts_of(cut(rand, body))
          sources.push(source)
          let length = if rand.int(limit=2) == 0 {
            None
          } else {
            Some(body.length().to_int64())
          }
          streamed.push(
            @multipart.Part::file_stream(name, "a.bin", "x/y", source, length?),
          )
        }
      }
      let (content_type, expected) = @multipart.encode(buffered, "B-x")
      let (streamed_type, body) = @multipart.encode_body(streamed, "B-x")
      assert_eq(streamed_type, content_type)
      let label = "seed \{seed} trial \{trial}"
      assert_eq(read_body(body), Ok(expected), msg=label)
      if body.length() is Some(length) {
        assert_eq(length, expected.length().to_int64(), msg=label)
      }
      assert_true(sources.iter().all(source => source.closed), msg=label)
    }
  }
}

///|
async test "a stream part containing the boundary fails before the collision is sent" {
  let colliding = parts_of([b"safe ", b"bytes\r", b"\n--B and the rest"])
  let later = parts_of([b"never read"])
  let (_, body) = @multipart.encode_body(
    [
      @multipart.Part::file_stream("upload", "a.bin", "x/y", colliding),
      @multipart.Part::file_stream("later", "b.bin", "x/y", later),
    ],
    "B",
  )
  guard body is Stream(stream) else { fail("expected a stream body") }
  let reader = stream.take()
  let sent = Buffer()
  let failure = try {
    while reader.read_some() is Some(chunk) {
      sent.write_bytes(chunk)
    }
    "ended"
  } catch {
    error => @debug.to_string(error)
  }
  reader.close()
  assert_eq(
    failure, "Protocol(\"multipart part \\\"upload\\\" contains the boundary delimiter\")",
  )
  // The framing and the chunks before the collision went out, not the rest.
  assert_true(@utf8.decode(sent.to_bytes()).has_suffix("safe bytes\r"))
  assert_true(colliding.closed)
  assert_true(later.closed)
  assert_eq(later.next, 0)
}

///|
async test "a multipart stream breaks on a part that breaks its length" {
  let short = parts_of([b"abc"])
  let (_, body) = @multipart.encode_body(
    [@multipart.Part::file_stream("f", "a", "x/y", short, length=4)],
    "B",
  )
  assert_eq(
    read_body(body),
    Err(
      "Protocol(\"request body stream ended after 3 of its declared 4 bytes\")",
    ),
  )
  assert_true(short.closed)
  // A multipart body whose parts were already sent cannot be sent again.
  let part = @multipart.Part::file_stream("f", "a", "x/y", parts_of([b"x"]))
  let (_, first) = @multipart.encode_body([part], "B")
  ignore(read_body(first))
  let (_, second) = @multipart.encode_body([part], "B")
  assert_eq(
    read_body(second),
    Err(
      "Protocol(\"the stream request body was already sent; a stream can be sent only once\")",
    ),
  )
}

///|
async test "closing a multipart stream closes the parts it did not reach, once" {
  let first = parts_of([b"one"])
  let unreached = parts_of([b"two"])
  let (_, body) = @multipart.encode_body(
    [
      @multipart.Part::file_stream("a", "a", "x/y", first),
      @multipart.Part::file_stream("b", "b", "x/y", unreached),
    ],
    "B",
  )
  guard body is Stream(multipart) else { fail("expected a stream body") }
  let reader = multipart.take()
  // The framing, then the first part's only chunk.
  ignore(reader.read_some())
  assert_eq(reader.read_some(), Some(b"one"))
  reader.close()
  assert_true(first.closed)
  assert_true(unreached.closed)
  assert_eq(unreached.next, 0)
  // Closed, it reads as ended, and closing again changes nothing.
  assert_eq(reader.read_some(), None)
  reader.close()
}

///|
async test "a part another sender took fails the first read, before any framing" {
  let first = parts_of([b"one"])
  let elsewhere = parts_of([b"three"])
  let taken = @multipart.Part::file_stream("c", "c", "x/y", elsewhere)
  guard taken.body is Stream(stream) else { fail("expected a stream part") }
  let other = stream.take()
  let (_, body) = @multipart.encode_body(
    [@multipart.Part::file_stream("a", "a", "x/y", first), taken],
    "B",
  )
  guard body is Stream(multipart) else { fail("expected a stream body") }
  let reader = multipart.take()
  let outcome = try reader.read_some() catch {
    @http.HttpError::Protocol(_) => "Protocol"
    error => "unexpected \{Repr(error)}"
  } noraise {
    _ => "read"
  }
  assert_eq(outcome, "Protocol")
  // The parts it took are closed; the one another sender took is left to it.
  assert_true(first.closed)
  assert_false(elsewhere.closed)
  other.close()
  assert_eq(reader.read_some(), None)
}

///|
async test "a part with a negative length fails the first read and declares no length" {
  let negative = parts_of([b""])
  let after = parts_of([b"x"])
  let (_, body) = @multipart.encode_body(
    [
      @multipart.Part::file_stream("a", "a", "x/y", negative, length=-1),
      @multipart.Part::file_stream("b", "b", "x/y", after),
    ],
    "B",
  )
  guard body is Stream(multipart) else { fail("expected a stream body") }
  assert_eq(multipart.length(), None)
  let reader = multipart.take()
  let outcome = try reader.read_some() catch {
    @http.HttpError::Protocol(_) => "Protocol"
    error => "unexpected \{Repr(error)}"
  } noraise {
    _ => "read"
  }
  assert_eq(outcome, "Protocol")
  // Both sources are closed: the refused one and the one after it.
  assert_true(negative.closed)
  assert_true(after.closed)
}

///|
async test "closing an unread multipart body closes a negative-length part" {
  let negative = parts_of([b""])
  let (_, body) = @multipart.encode_body(
    [@multipart.Part::file_stream("a", "a", "x/y", negative, length=-1)],
    "B",
  )
  guard body is Stream(multipart) else { fail("expected a stream body") }
  multipart.take().close()
  assert_true(negative.closed)
}

///|
async test "closing a multipart stream before reading it closes every part" {
  let first = parts_of([b"one"])
  let second = parts_of([b"two"])
  let elsewhere = parts_of([b"three"])
  let taken = @multipart.Part::file_stream("c", "c", "x/y", elsewhere)
  guard taken.body is Stream(stream) else { fail("expected a stream part") }
  let other = stream.take()
  let (_, body) = @multipart.encode_body(
    [
      @multipart.Part::file_stream("a", "a", "x/y", first),
      @multipart.Part::file_stream("b", "b", "x/y", second),
      taken,
    ],
    "B",
  )
  guard body is Stream(multipart) else { fail("expected a stream body") }
  multipart.take().close()
  assert_true(first.closed)
  assert_true(second.closed)
  // A part another sender took is left to it.
  assert_false(elsewhere.closed)
  other.close()
}

///|
async test "a failed part take closes the parts after it too" {
  let first = parts_of([b"one"])
  let elsewhere = parts_of([b"two"])
  let last = parts_of([b"three"])
  let taken = @multipart.Part::file_stream("b", "b", "x/y", elsewhere)
  guard taken.body is Stream(stream) else { fail("expected a stream part") }
  let other = stream.take()
  let (_, body) = @multipart.encode_body(
    [
      @multipart.Part::file_stream("a", "a", "x/y", first),
      taken,
      @multipart.Part::file_stream("c", "c", "x/y", last),
    ],
    "B",
  )
  guard body is Stream(multipart) else { fail("expected a stream body") }
  let reader = multipart.take()
  let failed = try reader.read_some() catch {
    @http.HttpError::Protocol(_) => true
    _ => false
  } noraise {
    _ => false
  }
  assert_true(failed)
  assert_true(first.closed)
  assert_true(last.closed)
  assert_false(elsewhere.closed)
  other.close()
}
