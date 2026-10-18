///|
/// Decodes the wire `chunks` undoing `undo`: the body, or the `Protocol`
/// message. A slice that is empty or larger than `decoded_slice_bytes` is
/// reported instead of the body.
fn decode_chunks(
  undo : Array[Coding],
  chunks : Array[Bytes],
) -> Result[Bytes, String] {
  let decoder = ContentDecoder::new(undo)
  let body = Buffer()
  let mut next = 0
  for ;; {
    let pulled = decoder.pull() catch {
      @http.HttpError::Protocol(message) => return Err(message)
      error => return Err("unexpected \{Repr(error)}")
    }
    match pulled {
      Slice(slice) => {
        guard slice.length() > 0 && slice.length() <= decoded_slice_bytes else {
          return Err("a slice of \{slice.length()} bytes")
        }
        body.write_bytes(slice)
      }
      NeedInput =>
        if next < chunks.length() {
          decoder.feed(chunks[next])
          next += 1
        } else {
          decoder.end()
        }
      Done => return Ok(body.to_bytes())
    }
  }
}

///|
/// `gzip.compress(b"hello, hello, hello", mtime=0)` from CPython.
let hello_gzip : Bytes = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\xd7\x51\xc8\x40\xa2\x00\x9f\xa1\xca\x09\x13\x00\x00\x00"

///|
/// `zlib.compress(b"hello, hello, hello")` from CPython.
let hello_zlib : Bytes = b"\x78\x9c\xcb\x48\xcd\xc9\xc9\xd7\x51\xc8\x40\xa2\x00\x44\x28\x06\xd5"

///|
/// The same as raw DEFLATE (`wbits=-15`).
let hello_raw : Bytes = b"\xcb\x48\xcd\xc9\xc9\xd7\x51\xc8\x40\xa2\x00"

///|
test "ContentDecoder undoes each coding and chain" {
  let hello : Result[Bytes, String] = Ok(b"hello, hello, hello")
  let empty : Result[Bytes, String] = Ok(b"")
  let rows : Array[(String, Array[Coding], Bytes, Result[Bytes, String])] = [
    ("gzip", [Gzip], hello_gzip, hello),
    ("deflate as zlib", [Deflate], hello_zlib, hello),
    ("deflate as raw DEFLATE", [Deflate], hello_raw, hello),
    (
      "gzip members in a row",
      [Gzip],
      b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x4b\x4c\x02\x00\x6d\x48\x83\x9e\x02\x00\x00\x00\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x4b\x4e\x01\x00\xda\x8f\xd6\x45\x02\x00\x00\x00",
      Ok(b"abcd"),
    ),
    (
      "deflate, gzip: gzip undone first",
      [Gzip, Deflate],
      b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xab\x98\x73\xda\xe3\xec\xc9\x93\xd7\x03\x4f\x38\x2c\x62\x70\xd1\x60\xbb\x0a\x00\x4f\x91\x4a\xd0\x11\x00\x00\x00",
      hello,
    ),
    ("an empty gzip body", [Gzip], b"", empty),
    ("an empty deflate body", [Deflate], b"", empty),
    ("an empty chained body", [Gzip, Deflate], b"", empty),
    (
      "gzip of nothing",
      [Gzip],
      b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00",
      empty,
    ),
    ("zlib of nothing", [Deflate], b"\x78\x9c\x03\x00\x00\x00\x00\x01", empty),
    ("raw DEFLATE of nothing", [Deflate], b"\x03\x00", empty),
    (
      "a truncated gzip body",
      [Gzip],
      hello_gzip[:hello_gzip.length() - 4].to_owned(),
      Err("malformed gzip response body: gzip: truncated"),
    ),
    (
      "a deflate body of one byte",
      [Deflate],
      b"\x78",
      Err("malformed deflate response body: the stream ends after one byte"),
    ),
    (
      "a truncated zlib body",
      [Deflate],
      hello_zlib[:hello_zlib.length() - 1].to_owned(),
      Err("malformed deflate response body: zlib: truncated trailer"),
    ),
    (
      "a truncated raw DEFLATE body",
      [Deflate],
      hello_raw[:hello_raw.length() - 1].to_owned(),
      Err("malformed deflate response body: unexpected end of input"),
    ),
    (
      "data after a gzip body",
      [Gzip],
      hello_gzip + b"x",
      Err("malformed gzip response body: data after the end of the stream"),
    ),
    (
      "a gzip member cut after its magic",
      [Gzip],
      hello_gzip + b"\x1f\x8b",
      Err("malformed gzip response body: gzip: truncated"),
    ),
    (
      "data after a zlib body",
      [Deflate],
      hello_zlib + b"x",
      Err("malformed deflate response body: data after the end of the stream"),
    ),
    (
      "data after a raw DEFLATE body",
      [Deflate],
      hello_raw + b"x",
      Err("malformed deflate response body: data after the end of the stream"),
    ),
    (
      "a zlib checksum mismatch",
      [Deflate],
      hello_zlib[:hello_zlib.length() - 1].to_owned() + b"\x00",
      Err("malformed deflate response body: zlib: Adler-32 mismatch"),
    ),
    (
      "not gzip at all",
      [Gzip],
      b"hello, world",
      Err("malformed gzip response body: gzip: bad magic"),
    ),
    (
      "an inner stream with data after it",
      [Gzip, Deflate],
      @gzip.compress(hello_zlib + b"x"),
      Err("malformed deflate response body: data after the end of the stream"),
    ),
  ]
  for row in rows {
    let (label, undo, wire, expected) = row
    assert_eq(decode_chunks(undo, [wire]), expected, msg=label)
    let bytes = wire.iter().map(byte => Bytes::from_array([byte])).collect()
    assert_eq(decode_chunks(undo, bytes), expected, msg="\{label}, bytewise")
  }
}

///|
test "zlib_header tells zlib from raw DEFLATE" {
  let rows : Array[(Byte, Byte, Bool)] = [
    (b'\x78', b'\x9c', true), // default compression
    (b'\x78', b'\x01', true), // no compression
    (b'\x78', b'\xda', true), // best compression
    (b'\x08', b'\x1d', true), // 256-byte window
    (b'\x78', b'\x9d', false), // check bits off
    (b'\x88', b'\x98', false), // window over 32 KiB
    (b'\x79', b'\xd8', false), // not DEFLATE
    (b'\xcb', b'\x48', false), // raw DEFLATE of "hello"
    (b'\x03', b'\x00', false), // raw DEFLATE of nothing
  ]
  for row in rows {
    let (cmf, flg, expected) = row
    assert_eq(zlib_header(cmf, flg), expected, msg="\{cmf} \{flg}")
  }
}

///|
/// Applies `codings`, first applied first: 0 is gzip, 1 zlib, 2 raw DEFLATE.
fn encode_codings(body : Bytes, codings : Array[Int32]) -> Bytes {
  codings.fold(init=body, (coded, coding) => {
    match coding {
      0 => @gzip.compress(coded, level=1)
      1 => @zlib.compress(coded, level=1)
      _ => @flate.deflate_all(coded, level=1)
    }
  })
}

///|
/// What a decoder undoes for `encode_codings(_, codings)`.
fn undo_of(codings : Array[Int32]) -> Array[Coding] {
  codings.rev().map(coding => if coding == 0 { Coding::Gzip } else { Deflate })
}

///|
fn codings_label(codings : Array[Int32]) -> String {
  codings.map(coding => coding.to_string()).join(",")
}

///|
test "ContentDecoder does not depend on how the wire is chunked" {
  for seed in 0..<4 {
    let rand = @random.Rand::chacha8(
      seed=Bytes::make(32, (seed + 16).to_byte()),
    )
    for trial in 0..<25 {
      // Runs of one byte compress well, so long bodies cross slice bounds.
      let body = Buffer()
      for _ in 0..<rand.int(limit=6) {
        if rand.int(limit=2) == 0 {
          body.write_bytes(
            Bytes::make(rand.int(limit=40_000), rand.int(limit=256).to_byte()),
          )
        } else {
          for _ in 0..<rand.int(limit=300) {
            body.write_byte(rand.int(limit=256).to_byte())
          }
        }
      }
      let body = body.to_bytes()
      let codings = Array::makei(1 + rand.int(limit=3), _ => rand.int(limit=3))
      let undo = undo_of(codings)
      let wire = encode_codings(body, codings)
      let label = "seed \{seed} trial \{trial} codings \{codings_label(codings)}"
      assert_eq(decode_chunks(undo, [wire]), Ok(body), msg=label)
      for _ in 0..<4 {
        assert_eq(
          decode_chunks(undo, random_chunks(rand, wire)),
          Ok(body),
          msg=label,
        )
      }
    }
  }
}

///|
test "a decompression bomb comes out one bounded slice per pull" {
  let zeros = Bytes::make(1024 * 1024, b'\x00')
  for codings in [[0], [1], [2], [0, 0], [2, 0, 1]] {
    let wire = encode_codings(zeros, codings)
    let undo = undo_of(codings)
    let decoder = ContentDecoder::new(undo)
    let mut fed = false
    let mut decoded = 0
    let mut slices = 0
    for ;; {
      match decoder.pull() {
        Slice(slice) => {
          assert_true(slice.length() <= decoded_slice_bytes)
          decoded += slice.length()
          slices += 1
        }
        NeedInput =>
          // The whole wire at once, then the end of input.
          if fed {
            decoder.end()
          } else {
            decoder.feed(wire)
            fed = true
          }
        Done => break
      }
    }
    assert_eq(decoded, zeros.length(), msg=codings_label(codings))
    assert_true(
      slices >= zeros.length() / decoded_slice_bytes,
      msg=codings_label(codings),
    )
  }
}

///|
async test "read_bounded refuses a decoded bomb without reading it all" {
  let wire = encode_codings(Bytes::make(2 * 1024 * 1024, b'\x00'), [0])
  let chunks = []
  for start = 0; start < wire.length(); start = start + 64 {
    chunks.push(wire[start:wire.length().min(start + 64)].to_owned())
  }
  let mut reads = 0
  let read : async () -> Bytes? = () => {
    reads += 1
    chunks.get(reads - 1)
  }
  let decoder = Some(ContentDecoder::new([Gzip]))
  let outcome = try
    read_bounded(() => read_decoded(read, decoder), 256 * 1024)
  catch {
    @http.HttpError::Protocol(message) => message
    error => "unexpected \{Repr(error)}"
  } noraise {
    body => "\{body.length()} bytes"
  }
  assert_eq(outcome, "response body larger than 262144 bytes")
  // About an eighth of the wire decodes to the limit.
  assert_true(reads < chunks.length() / 4, msg="\{reads} of \{chunks.length()}")
}

///|
async test "read_decoded passes reads through without a decoder" {
  let chunks = [b"ab", b"", b"c"]
  let mut reads = 0
  let read : async () -> Bytes? = () => {
    reads += 1
    chunks.get(reads - 1)
  }
  let seen = []
  while read_decoded(read, None) is Some(chunk) {
    seen.push(chunk)
  }
  assert_eq(seen, chunks)
}

///|
test "a pull never asks for input while decoded output is pending" {
  // 512 KiB that packs into far less than one 64 KiB slice of input.
  let body = Bytes::makei(512 * 1024, i => (i / 4096 % 7).to_byte())
  for codings in [[0], [1], [2], [0, 0], [2, 0, 1], [1, 2]] {
    let wire = encode_codings(body, codings)
    let decoder = ContentDecoder::new(undo_of(codings))
    let mut fed = false
    let mut decoded = 0
    for ;; {
      match decoder.pull() {
        Slice(slice) => decoded += slice.length()
        NeedInput if !fed => {
          decoder.feed(wire)
          fed = true
        }
        NeedInput => {
          // Asked again: everything the wire held must be out by now.
          assert_eq(decoded, body.length(), msg=codings_label(codings))
          decoder.end()
        }
        Done => break
      }
    }
    assert_eq(decoded, body.length(), msg=codings_label(codings))
  }
}

///|
async test "read_decoded drains a chunk without reading again" {
  let body = Bytes::make(512 * 1024, b'a')
  for codings in [[0], [1], [2], [0, 1]] {
    let wire = encode_codings(body, codings)
    let mut reads = 0
    // A server that flushed the chunk and is now silent.
    let read : async () -> Bytes? = () => {
      reads += 1
      if reads > 1 {
        fail("read again after \{codings_label(codings)}")
      }
      Some(wire)
    }
    let decoder = Some(ContentDecoder::new(undo_of(codings)))
    let mut decoded = 0
    while decoded < body.length() {
      guard read_decoded(read, decoder) is Some(slice) else {
        fail("ended early")
      }
      decoded += slice.length()
    }
    assert_eq(decoded, body.length())
    assert_eq(reads, 1)
  }
}
