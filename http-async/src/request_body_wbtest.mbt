///|
test "content_length declares known lengths, and zero only where content is expected" {
  let stream = (length : Int64?) => {
    @http.Body::Stream(@http.StreamBody::new(Paced::new([]), length?))
  }
  let rows : Array[(String, @http.Body, Int64?)] = [
    ("POST", Bytes(b"abc"), Some(3L)),
    ("GET", Bytes(b"abc"), Some(3L)),
    ("PUT", stream(Some(5000000000L)), Some(5000000000L)),
    // An unknown length is left to the client: chunked, or nothing if empty.
    ("POST", stream(None), None),
    ("GET", stream(None), None),
    // No content: declared for methods that expect some (RFC 9110 §8.6).
    ("POST", Bytes(b""), Some(0L)),
    ("put", Bytes(b""), Some(0L)),
    ("PATCH", stream(Some(0L)), Some(0L)),
    ("GET", Bytes(b""), None),
    ("HEAD", Bytes(b""), None),
    ("DELETE", Bytes(b""), None),
    ("OPTIONS", stream(Some(0L)), None),
  ]
  for row in rows {
    let (http_method, body, expected) = row
    assert_eq(
      content_length(http_method, body),
      expected,
      msg="\{http_method} \{@debug.to_string(body)}",
    )
  }
}

///|
test "buffer_overflow refuses only past a buffering platform's limit" {
  let message = "a stream request body is buffered in memory on this platform, and this one exceeds 10 bytes; send it as bytes instead"
  let rows : Array[(Int64?, Int64, String?)] = [
    (None, 0L, None),
    (None, 9223372036854775807L, None),
    (Some(10L), 0L, None),
    (Some(10L), 10L, None),
    (Some(10L), 11L, Some(message)),
  ]
  for row in rows {
    let (limit, bytes, expected) = row
    assert_eq(
      buffer_overflow(limit, bytes),
      expected,
      msg=@debug.to_string(row),
    )
  }
}

///|
test "refuse_unbufferable refuses a stream declared past the limit up front" {
  let stream = (length : Int64?) => {
    @http.Body::Stream(@http.StreamBody::new(Paced::new([]), length?))
  }
  let rows : Array[(@http.Body, Int64?, Bool)] = [
    (stream(Some(11L)), Some(10L), true),
    (stream(Some(10L)), Some(10L), false),
    // An undeclared length is checked as it is read.
    (stream(None), Some(10L), false),
    (Bytes(Bytes::make(11, 0)), Some(10L), false),
    (stream(Some(11L)), None, false),
  ]
  for row in rows {
    let (body, limit, refused) = row
    let outcome = try refuse_unbufferable(body, limit) catch {
      Protocol(_) => true
      _ => false
    } noraise {
      _ => false
    }
    assert_eq(outcome, refused, msg=@debug.to_string(row))
  }
}

///|
/// A request body stream that waits `delay` ms on `clock` before each chunk,
/// and records being closed.
priv struct Paced {
  clock : @simclock.VirtualClock?
  reads : Array[(Int32, Bytes)]
  mut next : Int32
  mut closed : Bool
}

///|
fn Paced::new(
  reads : Array[(Int32, Bytes)],
  clock? : @simclock.VirtualClock,
) -> Paced {
  { clock, reads, next: 0, closed: false, }
}

///|
impl @http.BodyStream for Paced with fn read_some(self) {
  guard self.reads.get(self.next) is Some((delay, chunk)) else { return None }
  self.next += 1
  if self.clock is Some(clock) {
    clock.sleep(delay)
  }
  Some(chunk)
}

///|
impl @http.BodyStream for Paced with fn close(self) {
  self.closed = true
}

///|
/// Sends `body` with `send_body` under `limits`, each write taking
/// `write_ms` virtual milliseconds, and labels the outcome with the slice
/// lengths written and the virtual time it was reached at.
async fn run_send(
  clock : @simclock.VirtualClock,
  limits : Timeouts,
  body : @http.Body,
  write_ms~ : Int32 = 0,
  buffer_limit? : Int64,
) -> String {
  let timer = PhaseTimer::exchange(clock, limits)
  let written : Array[Int32] = []
  let outcome = Ref("pending")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let label = try {
        send_body(
          body,
          slice => {
            clock.sleep(write_ms)
            written.push(slice.length())
          },
          timer,
          buffer_limit~,
        )
        "done"
      } catch {
        error => @debug.to_string(error)
      }
      outcome.val = "\{label} at \{clock.now_unix_ms()} after \{@debug.to_string(written)}"
    })
    clock.advance(1_000_000)
  })
  outcome.val
}

///|
fn fresh() -> @simclock.VirtualClock {
  @simclock.VirtualClock(start_ms=0)
}

///|
fn limits(total~ : Int32 = 100000, write~ : Int32 = 100000) -> Timeouts {
  { total, pool: total, connect: total, write, read: total, }
}

///|
async test "send_body writes in slices of at most 64 KiB" {
  let k64 = 64 * 1024
  assert_eq(
    run_send(fresh(), limits(), Bytes(Bytes::make(2 * k64 + 1, b'x'))),
    "done at 0 after [65536, 65536, 1]",
  )
  assert_eq(run_send(fresh(), limits(), Bytes(b"")), "done at 0 after []")
  // A stream's chunks are cut the same way and never joined.
  let source = Paced::new([
    (0, Bytes::make(k64 + 1, b'a')),
    (0, b""),
    (0, b"b"),
    (0, Bytes::make(k64, b'c')),
  ])
  let body : @http.Body = Stream(@http.StreamBody::new(source))
  assert_eq(
    run_send(fresh(), limits(), body),
    "done at 0 after [65536, 1, 1, 65536]",
  )
  assert_true(source.closed)
  assert_false(body.is_replayable())
}

///|
async test "send_body sends every byte however the stream is chunked" {
  for seed in 0..<4 {
    let rand = @random.Rand::chacha8(seed=Bytes::make(32, seed.to_byte()))
    for trial in 0..<20 {
      let body = Bytes::from_array(
        Array::makei(rand.int(limit=200_000), _ => rand.int(limit=256).to_byte()),
      )
      let reads = random_chunks(rand, body).map(chunk => (0, chunk))
      let length = if rand.int(limit=2) == 0 {
        None
      } else {
        Some(body.length().to_int64())
      }
      let sent = Buffer()
      let clock = @simclock.VirtualClock(start_ms=0)
      let timer = PhaseTimer::exchange(clock, limits())
      let mut largest = 0
      send_body(
        Stream(@http.StreamBody::new(Paced::new(reads), length?)),
        slice => {
          largest = largest.max(slice.length())
          sent.write_bytesview(slice)
        },
        timer,
        buffer_limit=None,
      )
      assert_eq(sent.to_bytes(), body, msg="seed \{seed} trial \{trial}")
      assert_true(largest <= max_write_bytes)
    }
  }
}

///|
async test "each slice and each stream read is its own Write phase" {
  let chunk = Bytes::make(64 * 1024, b'x')
  // Three slices of 200 ms each fit a 300 ms write limit: it is per slice.
  let clock = @simclock.VirtualClock(start_ms=0)
  let body : @http.Body = Bytes(Bytes::make(3 * 64 * 1024, b'x'))
  assert_eq(
    run_send(clock, limits(write=300), body, write_ms=200),
    "done at 600 after [65536, 65536, 65536]",
  )
  // A slice the peer does not take within the limit times out.
  let clock = @simclock.VirtualClock(start_ms=0)
  assert_eq(
    run_send(clock, limits(write=300), body, write_ms=301),
    "Timeout(phase=Write, ms=300) at 300 after []",
  )
  // So does a stream that takes longer than the limit to produce a chunk,
  // after the chunks it produced in time went out; the stream is closed.
  let clock = @simclock.VirtualClock(start_ms=0)
  let source = Paced::new([(250, chunk), (250, chunk), (301, chunk)], clock~)
  assert_eq(
    run_send(clock, limits(write=300), Stream(@http.StreamBody::new(source))),
    "Timeout(phase=Write, ms=300) at 800 after [65536, 65536]",
  )
  assert_true(source.closed)
  // The exchange deadline cuts the upload short, reporting the total.
  let clock = @simclock.VirtualClock(start_ms=0)
  let source = Paced::new([(100, chunk), (100, chunk), (100, chunk)], clock~)
  assert_eq(
    run_send(
      clock,
      limits(total=1000, write=600),
      Stream(@http.StreamBody::new(source)),
      write_ms=300,
    ),
    "Timeout(phase=Write, ms=1000) at 1000 after [65536, 65536]",
  )
  assert_true(source.closed)
  assert_eq(clock.pending(), [], msg="every phase timer is cancelled")
}

///|
async test "send_body closes the stream however sending ends" {
  // A length broken mid-way, a buffer limit crossed, and a failed write.
  let short = Paced::new([(0, b"abc")])
  assert_eq(
    run_send(fresh(), limits(), Stream(@http.StreamBody::new(short, length=4))),
    "Protocol(\"request body stream ended after 3 of its declared 4 bytes\") at 0 after [3]",
  )
  assert_true(short.closed)
  let large = Paced::new([(0, b"0123456789"), (0, b"a")])
  assert_eq(
    run_send(
      fresh(),
      limits(),
      Stream(@http.StreamBody::new(large)),
      buffer_limit=10,
    ),
    "Protocol(\"a stream request body is buffered in memory on this platform, and this one exceeds 10 bytes; send it as bytes instead\") at 0 after [10]",
  )
  assert_true(large.closed)
  let broken = Paced::new([(0, b"abc")])
  let outcome = try {
    send_body(
      Stream(@http.StreamBody::new(broken)),
      _ => raise Broken("reset"),
      PhaseTimer::exchange(fresh(), limits()),
      buffer_limit=None,
    )
    "done"
  } catch {
    error => @debug.to_string(error)
  }
  assert_eq(outcome, "Network(phase=Write, message=\"reset\")")
  assert_true(broken.closed)
  // A stream already sent is refused before anything is written.
  let sent = @http.StreamBody::new(Paced::new([(0, b"x")]))
  ignore(sent.take())
  assert_eq(
    run_send(fresh(), limits(), Stream(sent)),
    "Protocol(\"the stream request body was already sent; a stream can be sent only once\") at 0 after []",
  )
}
