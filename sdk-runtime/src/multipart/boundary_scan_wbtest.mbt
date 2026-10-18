///|
/// Whether scanning `chunks` in turn finds `CRLF--boundary`.
fn scan_chunks(boundary : String, chunks : Array[Bytes]) -> Bool {
  let scan = BoundaryScan::new(@http.encode_utf8("\r\n--" + boundary))
  let mut found = false
  for chunk in chunks {
    found = scan.feed(chunk) || found
  }
  found
}

///|
test "BoundaryScan finds the delimiter as body_collides does" {
  let rows : Array[(Array[Bytes], Bool)] = [
    ([b"plain B content"], false),
    ([b"--B at the start"], true),
    ([b"-", b"-B split at the start"], true),
    ([b"x\r\n--B in the middle"], true),
    ([b"x\r", b"\n-", b"-", b"B across chunks"], true),
    ([b"x\r\n--", b"", b"B"], true),
    ([b"ends with \r\n--"], false),
    ([b"\r\n\r\n-", b"-B after a false start"], true),
    ([b"\r\r\n--B"], true),
    ([b"-x-B", b"\n--C"], false),
    ([], false),
    ([b""], false),
  ]
  for row in rows {
    let (chunks, expected) = row
    assert_eq(scan_chunks("B", chunks), expected, msg=@debug.to_string(chunks))
  }
}

///|
/// Cuts `body` at random points, sometimes leaving empty chunks between.
fn random_chunks(rand : @random.Rand, body : Bytes) -> Array[Bytes] {
  let chunks = []
  let mut start = 0
  while start < body.length() {
    let end = start + rand.int(limit=body.length() - start + 1)
    chunks.push(body[start:end].to_owned())
    start = end
  }
  chunks
}

///|
test "BoundaryScan agrees with body_collides however the body is chunked" {
  let boundary = "ab-ab"
  let delimiter = @http.encode_utf8("--" + boundary)
  let embedded = @http.encode_utf8("\r\n--" + boundary)
  // Bytes the delimiter is made of, so near misses are common.
  let alphabet = b"\r\n-ab"
  for seed in 0..<4 {
    let rand = @random.Rand::chacha8(seed=Bytes::make(32, seed.to_byte()))
    for trial in 0..<500 {
      let body = Bytes::makei(rand.int(limit=24), _ => {
        alphabet[rand.int(limit=alphabet.length())]
      })
      let expected = body_collides(body, delimiter, embedded)
      for _ in 0..<4 {
        let chunks = random_chunks(rand, body)
        assert_eq(
          scan_chunks(boundary, chunks),
          expected,
          msg="seed \{seed} trial \{trial} \{@debug.to_string(chunks)}",
        )
      }
    }
  }
}
