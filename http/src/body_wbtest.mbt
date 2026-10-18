///|
test "length_violation holds a stream to its declared length" {
  let rows : Array[(Int64?, Int64, Int32?, String?)] = [
    // Without a declared length any chunk and any end are fine.
    (None, 0L, Some(5), None),
    (None, 9L, None, None),
    // Up to the declared length, and ending on it.
    (Some(5L), 0L, Some(5), None),
    (Some(5L), 2L, Some(3), None),
    (Some(5L), 5L, Some(0), None),
    (Some(5L), 5L, None, None),
    (Some(0L), 0L, None, None),
    // One byte over, in the first chunk or a later one.
    (
      Some(5L),
      0L,
      Some(6),
      Some("request body stream is longer than its declared 5 bytes"),
    ),
    (
      Some(5L),
      5L,
      Some(1),
      Some("request body stream is longer than its declared 5 bytes"),
    ),
    // Ending short, including a declared body that never starts.
    (
      Some(5L),
      4L,
      None,
      Some("request body stream ended after 4 of its declared 5 bytes"),
    ),
    (
      Some(5L),
      0L,
      None,
      Some("request body stream ended after 0 of its declared 5 bytes"),
    ),
    // Lengths past Int32 are counted in Int64.
    (Some(4294967296L), 4294967295L, Some(1), None),
    (
      Some(4294967296L),
      4294967295L,
      None,
      Some(
        "request body stream ended after 4294967295 of its declared 4294967296 bytes",
      ),
    ),
  ]
  for row in rows {
    let (length, read, chunk, expected) = row
    assert_eq(
      length_violation(length, read, chunk),
      expected,
      msg=@debug.to_string(row),
    )
  }
}

///|
priv struct Silent {}

///|
impl BodyStream for Silent with fn read_some(_) {
  None
}

///|
impl BodyStream for Silent with fn close(_) {
  ()
}

///|
test "a stream body is taken once and is replayable only until then" {
  let stream = StreamBody::new(Silent::{ }, length=3)
  let body : Body = Stream(stream)
  assert_eq(body.length(), Some(3L))
  assert_eq(body.as_bytes(), None)
  assert_true(body.is_replayable())
  ignore(stream.take())
  assert_false(body.is_replayable())
  let second = try stream.take() catch {
    error => @debug.to_string(error)
  } noraise {
    _ => "taken twice"
  }
  assert_eq(
    second, "Protocol(\"the stream request body was already sent; a stream can be sent only once\")",
  )
  // Bytes are always replayable, an empty body included.
  let bytes : Body = Bytes(b"")
  assert_eq(bytes.length(), Some(0L))
  assert_eq(bytes.as_bytes(), Some(b""))
  assert_true(bytes.is_replayable())
  assert_eq(Stream(StreamBody::new(Silent::{ })).length(), None)
}

///|
test "stream bodies are equal only to themselves" {
  let stream = StreamBody::new(Silent::{ }, length=1)
  let request = Request::put("/u").body_stream(Silent::{ }, length=1)
  let same : Body = Stream(stream)
  assert_eq(same, Stream(stream))
  assert_true(same != Stream(StreamBody::new(Silent::{ }, length=1)))
  assert_true(same != Bytes(b"x"))
  // Builders share the stream, so a copy with other headers has an equal body.
  assert_eq(request.header("a", "1").body, request.body)
  assert_eq({ ..request, headers: request.headers, }, request)
  assert_true(request != request.body_stream(Silent::{ }, length=1))
  assert_eq(
    @debug.to_string(same),
    "Stream(StreamBody(length=Some(1), taken=false))",
  )
  ignore(stream.take())
  assert_eq(
    @debug.to_string(same),
    "Stream(StreamBody(length=Some(1), taken=true))",
  )
}
