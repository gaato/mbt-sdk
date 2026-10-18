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
/// `brotli.compress(b"hello, hello, hello")` from Python's brotli 1.2.0,
/// which declares a 4 MiB window.
let hello_br : Bytes = b"\x1b\x12\x00\xf8\x8d\x94\x6e\xde\x44\x09\x52\x86\x96\x6c\x2c\x6f\x11\x4f\x24\xd0\x71\x00"

///|
/// The same with `lgwin=24`: RFC 7932's largest window, 16 MiB.
let hello_br_16m : Bytes = b"\x1f\x12\x00\xf8\x8d\x94\x6e\xde\x44\x09\x52\x86\x96\x6c\x2c\x6f\x11\x4f\x24\xd0\x71\x00"

///|
/// The same with `lgwin=10`, the smallest window, 1 KiB.
let hello_br_1k : Bytes = b"\xa1\x90\x00\xc0\x6f\xa4\x74\xf3\x26\x4a\x90\x32\xb4\x64\x63\x79\x8b\x78\x22\x81\x8e\x03"

///|
/// `brotli.compress(gzip.compress(b"hello, hello, hello", mtime=0))`: the
/// body of `Content-Encoding: gzip, br`.
let hello_gzip_br : Bytes = b"\x0b\x0e\x80\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\xd7\x51\xc8\x40\xa2\x00\x9f\xa1\xca\x09\x13\x00\x00\x00\x03"

///|
/// `brotli.compress(b"a" * 512 * 1024)`: 14 bytes that decode to 512 KiB.
let a_512k_br : Bytes = b"\x5b\xff\xff\x87\x5f\x22\x2c\x1e\x0b\x04\x72\xef\x0f\x00"

///|
/// `brotli.compress(bytes(2 * 1024 * 1024), lgwin=24)`: 14 bytes that decode
/// to 2 MiB of zeros, declaring a 16 MiB window.
let zeros_2m_br : Bytes = b"\x9f\xff\xff\x1f\xf8\x27\x00\xe2\xb1\x40\x20\xf7\xfe\x03"

///|
/// `zstandard.ZstdCompressor(level=3).compress(b"hello, hello, hello")` from
/// Python's zstandard 0.25.0: one frame with its content size.
let hello_zstd : Bytes = b"\x28\xb5\x2f\xfd\x20\x13\x6d\x00\x00\x38\x68\x65\x6c\x6c\x6f\x2c\x20\x01\x00\xe2\x8a\x11"

///|
/// The same through `compressobj` with `write_checksum=True`, as a server
/// streaming its response writes it: no content size, a 2 MiB window and
/// a checksum.
let hello_zstd_stream : Bytes = b"\x28\xb5\x2f\xfd\x04\x58\x6d\x00\x00\x38\x68\x65\x6c\x6c\x6f\x2c\x20\x01\x00\xe2\x8a\x11\x75\xf3\x98\x8e"

///|
/// The same with `window_log=23`: RFC 9659's largest window, 8 MiB.
let hello_zstd_8m : Bytes = b"\x28\xb5\x2f\xfd\x00\x68\x6d\x00\x00\x38\x68\x65\x6c\x6c\x6f\x2c\x20\x01\x00\xe2\x8a\x11"

///|
/// The same with `window_log=24`, over RFC 9659's limit.
let hello_zstd_16m : Bytes = b"\x28\xb5\x2f\xfd\x00\x70\x6d\x00\x00\x38\x68\x65\x6c\x6c\x6f\x2c\x20\x01\x00\xe2\x8a\x11"

///|
/// `ZstdCompressor(level=3).compress(gzip.compress(b"hello, hello, hello",
/// mtime=0))`: the body of `Content-Encoding: gzip, zstd`.
let hello_gzip_zstd : Bytes = b"\x28\xb5\x2f\xfd\x20\x1d\xe9\x00\x00\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\xd7\x51\xc8\x40\xa2\x00\x9f\xa1\xca\x09\x13\x00\x00\x00"

///|
/// `ZstdCompressor(level=19).compress(b"a" * 512 * 1024)`: 33 bytes that
/// decode to 512 KiB.
let a_512k_zstd : Bytes = b"\x28\xb5\x2f\xfd\xa0\x00\x00\x08\x00\x4c\x00\x00\x08\x61\x01\x00\xfc\xff\x39\x10\x02\x02\x00\x10\x61\x02\x00\x10\x61\x03\x00\x10\x61"

///|
/// `ZstdCompressor(level=19, write_checksum=True)` through `compressobj` of
/// `bytes(2 * 1024 * 1024)`: 85 bytes that decode to 2 MiB of zeros,
/// declaring an 8 MiB window.
let zeros_2m_zstd : Bytes = b"\x28\xb5\x2f\xfd\x04\x68\x4c\x00\x00\x08\x00\x01\x00\xfc\xff\x39\x10\x02\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x02\x00\x10\x00\x01\x00\x00\xdb\x23\x8e\xf8"

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
    ("br", [Brotli], hello_br, hello),
    ("br declaring a 16 MiB window", [Brotli], hello_br_16m, hello),
    ("br declaring a 1 KiB window", [Brotli], hello_br_1k, hello),
    ("gzip, br: br undone first", [Brotli, Gzip], hello_gzip_br, hello),
    (
      "br, gzip: gzip undone first",
      [Gzip, Brotli],
      @gzip.compress(hello_br),
      hello,
    ),
    ("an empty br body", [Brotli], b"", empty),
    ("br of nothing", [Brotli], b"\x3b", empty),
    ("zstd", [Zstd], hello_zstd, hello),
    ("zstd streamed, with a checksum", [Zstd], hello_zstd_stream, hello),
    ("zstd declaring an 8 MiB window", [Zstd], hello_zstd_8m, hello),
    (
      "zstd frames in a row",
      [Zstd],
      hello_zstd + hello_zstd_stream,
      Ok(b"hello, hello, hellohello, hello, hello"),
    ),
    ("gzip, zstd: zstd undone first", [Zstd, Gzip], hello_gzip_zstd, hello),
    (
      "zstd, br: br undone first",
      [Brotli, Zstd],
      b"\x8b\x0a\x80" + hello_zstd + b"\x03",
      hello,
    ),
    ("an empty zstd body", [Zstd], b"", empty),
    ("zstd of nothing", [Zstd], b"\x28\xb5\x2f\xfd\x20\x00\x01\x00\x00", empty),
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
      "a truncated br body",
      [Brotli],
      hello_br[:hello_br.length() - 1].to_owned(),
      Err("malformed br response body: the stream ends early"),
    ),
    (
      "data after a br body",
      [Brotli],
      hello_br + b"x",
      Err("malformed br response body: data after the end of the stream"),
    ),
    (
      "a corrupt br body",
      [Brotli],
      b"hello, world",
      Err("malformed br response body: invalid code length code"),
    ),
    (
      "a large-window br stream, which is not RFC 7932",
      [Brotli],
      b"\x11",
      Err("malformed br response body: large-window streams are not RFC 7932"),
    ),
    (
      "an inner br stream with data after it",
      [Gzip, Brotli],
      @gzip.compress(hello_br + b"x"),
      Err("malformed br response body: data after the end of the stream"),
    ),
    (
      "a truncated zstd body",
      [Zstd],
      hello_zstd[:hello_zstd.length() - 1].to_owned(),
      Err("malformed zstd response body: the stream ends inside a frame"),
    ),
    (
      "data after a zstd body",
      [Zstd],
      hello_zstd + b"junk",
      Err(
        "malformed zstd response body: data after the last frame that starts no frame",
      ),
    ),
    (
      "a zstd checksum mismatch",
      [Zstd],
      hello_zstd_stream[:hello_zstd_stream.length() - 1].to_owned() + b"\x00",
      Err(
        "malformed zstd response body: the frame's content checksum does not match",
      ),
    ),
    (
      "a zstd window over 8 MiB",
      [Zstd],
      hello_zstd_16m,
      Err(
        "malformed zstd response body: the frame needs a 16777216-byte window, over the 8388608-byte limit",
      ),
    ),
    (
      "not zstd at all",
      [Zstd],
      b"hello, world",
      Err("malformed zstd response body: not a zstd stream"),
    ),
    (
      "an inner zstd stream with data after it",
      [Gzip, Zstd],
      @gzip.compress(hello_zstd + b"junk"),
      Err(
        "malformed zstd response body: data after the last frame that starts no frame",
      ),
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
/// Three rounds of a sentence, 1000 bytes cycling through 0..250, and a long
/// run of one byte: text for Brotli's dictionary and runs that cross slices.
fn mixed_body() -> Bytes {
  let body = Buffer()
  for round in 0..<3 {
    for _ in 0..<20 {
      body.write_bytes(b"The quick brown fox jumps over the lazy dog. ")
    }
    for i in 0..<1000 {
      body.write_byte((i * 31 % 251).to_byte())
    }
    body.write_bytes(Bytes::make(40_000 + round * 15_000, round.to_byte()))
  }
  body.to_bytes()
}

///|
/// `brotli.compress` of `mixed_body()` from Python's brotli 1.2.0.
let mixed_br : Bytes = b"\x5b\xcb\x9a\x02\xc8\xa2\xc0\x6e\x38\x36\x52\xa7\x6f\x8d\x03\x06\x46\x7c\x0e\x9b\x11\x40\x88\x06\xcf\x11\x2e\x08\x26\x34\xe7\x89\x57\x3d\x22\x47\xd6\xb5\xa3\x5e\x2a\x10\x42\xca\x80\x5b\x83\x34\x6c\xdc\x9e\x81\x18\xb6\x0d\x18\xeb\xb0\x6a\xb1\x58\x51\x46\xc5\x73\xc3\x54\x09\xc9\x98\x45\x11\xff\xf0\xec\xeb\xe4\xc0\xe1\x02\x79\x11\x51\xeb\xe7\x4b\x80\x1a\x38\xe6\x29\x0b\x42\x91\x6d\xa6\x3d\xb2\x17\xe5\x04\xfc\x70\x12\x25\xcb\x85\x0c\x31\xc1\xe1\x88\x58\xf0\x3f\x20\xf1\x0a\x8a\x3f\x77\x0a\x00\xf2\xcc\x2b\xae\xaf\x26\xbe\xdf\x35\xda\x5f\xca\xc8\xd8\x7b\x7f\xb9\xcb\x82\x75\x2e\x9d\xf1\x22\xf6\xa5\x36\x36\xbb\x23\xef\xf6\xb5\xab\xd5\x3b\xc6\x61\x52\x5d\x2e\xd6\xa4\x55\xfa\xa2\x90\x16\x98\x89\x51\x9a\xf5\x53\x58\x8f\x31\xa4\xcc\x07\x40\xf0\xed\x27\xef\x9f\x36\x71\xd4\x3d\x3e\xde\xaa\xe8\x3c\xc7\x60\x7d\xc8\x43\x4d\xae\xdd\xe9\x2a\xf1\xe7\x3e\xb5\xfa\x93\xe0\x09\xa2\xaf\x37\x7b\xd6\x69\x73\x53\x29\x37\x94\x4d\x85\xb2\x98\x2d\x71\x33\x77\x59\x2e\xcc\x10\x03\x31\x31\x6d\x7f\x10\x41\xec\x7e\xf5\xfc\x75\xc9\xab\x1f\x7e\x7e\xd4\xb1\x75\xcf\xe1\xf6\x54\x84\xfb\xda\x7a\xf3\x4d\x1a\x28\x63\x6e\x0f\x67\x91\x37\xca\xd0\x68\x0f\x9c\xcb\x95\xb6\x5a\x6d\x69\xbb\x8e\x55\x29\x5f\x11\x16\xc1\x79\x3e\xce\x51\x23\xb5\x49\xc6\x4d\x20\x8c\xb4\x67\xfa\x8d\xee\xfc\x49\x00\xc0\x05\xa1\xbc\x8f\x21\xad\xa1\x53\x85\x15\xa7\xd6\xd0\xd2\x91\xce\x00\x90\xb4\xde\x36\x47\x11\x71\xcb\x49\x6d\x52\xf9\xef\x01\xa7\x24\x04\x20\x02"

///|
test "a br body decodes the same however the wire is chunked" {
  let body = mixed_body()
  assert_eq(decode_chunks([Brotli], [mixed_br]), Ok(body))
  for seed in 0..<4 {
    let rand = @random.Rand::chacha8(
      seed=Bytes::make(32, (seed + 32).to_byte()),
    )
    for trial in 0..<10 {
      // Up to two flate codings applied on top of br.
      let codings = Array::makei(rand.int(limit=3), _ => rand.int(limit=3))
      let undo = undo_of(codings)
      undo.push(Brotli)
      let wire = encode_codings(mixed_br, codings)
      let label = "seed \{seed} trial \{trial} codings \{codings_label(codings)}"
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
/// `ZstdCompressor(level=19, write_checksum=True).compress(mixed_body())`
/// from Python's zstandard 0.25.0.
let mixed_zstd : Bytes = b"\x28\xb5\x2f\xfd\xa4\xcc\x9a\x02\x00\x74\x0a\x00\x84\x12\x54\x68\x65\x20\x71\x75\x69\x63\x6b\x20\x62\x72\x6f\x77\x6e\x20\x66\x6f\x78\x20\x6a\x75\x6d\x70\x73\x20\x6f\x76\x65\x72\x20\x74\x6c\x61\x7a\x79\x20\x64\x6f\x67\x2e\x20\x00\x1f\x3e\x5d\x7c\x9b\xba\xd9\xf8\x1c\x3b\x5a\x79\x98\xb7\xd6\xf5\x19\x38\x57\x76\x95\xb4\xd3\xf2\x16\x35\x54\x73\x92\xb1\xd0\xef\x13\x32\x51\x70\x8f\xae\xcd\xec\x10\x2f\x4e\x6d\x8c\xab\xca\xe9\x0d\x2c\x4b\x6a\x89\xa8\xc7\xe6\x0a\x29\x48\x67\x86\xa5\xc4\xe3\x07\x26\x45\x64\x83\xa2\xc1\xe0\x04\x23\x42\x61\x80\x9f\xbe\xdd\x01\x20\x3f\x5e\x7d\x9c\xbb\xda\xf9\x1d\x3c\x5b\x7a\x99\xb8\xd7\xf6\x1a\x39\x58\x77\x96\xb5\xd4\xf3\x17\x36\x55\x74\x93\xb2\xd1\xf0\x14\x33\x52\x71\x90\xaf\xce\xed\x11\x30\x4f\x6e\x8d\xac\xcb\xea\x0e\x2d\x4c\x6b\x8a\xa9\xc8\xe7\x0b\x2a\x49\x68\x87\xa6\xc5\xe4\x08\x27\x46\x65\x84\xa3\xc2\xe1\x05\x24\x43\x62\x81\xa0\xbf\xde\x02\x21\x40\x5f\x7e\x9d\xbc\xdb\xfa\x1e\x3d\x5c\x7b\x9a\xb9\xd8\xf7\x1b\x3a\x59\x78\x97\xb6\xd5\xf4\x18\x37\x56\x75\x94\xb3\xd2\xf1\x15\x34\x53\x72\x91\xb0\xcf\xee\x12\x31\x50\x6f\x8e\xad\xcc\xeb\x0f\x2e\x4d\x6c\x8b\xaa\xc9\xe8\x0c\x2b\x4a\x69\x88\xa7\xc6\xe5\x09\x28\x47\x66\x85\xa4\xc3\xe2\x06\x25\x44\x63\x82\xa1\xc0\xdf\x03\x22\x41\x60\x7f\x9e\xbd\xdc\x00\x01\x02\x08\x00\xa0\xb6\xbb\x4b\xda\x47\xde\xf1\x03\xb5\xd5\xd5\x2f\xed\xd7\xd1\xf8\x83\x87\x83\xeb\x77\xaf\xce\x6f\x2a\x49\x15\xaa\x0a\x41\x00\xea\x09\x63\xd6\x04\x02\x31\x36\xb9\xad"

///|
test "a zstd body decodes the same however the wire is chunked" {
  let body = mixed_body()
  assert_eq(decode_chunks([Zstd], [mixed_zstd]), Ok(body))
  for seed in 0..<4 {
    let rand = @random.Rand::chacha8(
      seed=Bytes::make(32, (seed + 48).to_byte()),
    )
    for trial in 0..<10 {
      // Up to two flate codings applied on top of zstd.
      let codings = Array::makei(rand.int(limit=3), _ => rand.int(limit=3))
      let undo = undo_of(codings)
      undo.push(Zstd)
      let wire = encode_codings(mixed_zstd, codings)
      let label = "seed \{seed} trial \{trial} codings \{codings_label(codings)}"
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
  let cases : Array[(String, Bytes, Array[Coding], Int32)] = [
    ("br", zeros_2m_br, [Brotli], 2 * zeros.length()),
    ("zstd", zeros_2m_zstd, [Zstd], 2 * zeros.length()),
    (
      "br, gzip",
      encode_codings(zeros_2m_br, [0]),
      [Gzip, Brotli],
      2 * zeros.length(),
    ),
  ]
  for codings in [[0], [1], [2], [0, 0], [2, 0, 1]] {
    cases.push(
      (
        codings_label(codings),
        encode_codings(zeros, codings),
        undo_of(codings),
        zeros.length(),
      ),
    )
  }
  for case in cases {
    let (label, wire, undo, size) = case
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
    assert_eq(decoded, size, msg=label)
    assert_true(slices >= size / decoded_slice_bytes, msg=label)
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
async test "read_bounded refuses a br or zstd bomb one slice past the limit" {
  for coded in [(zeros_2m_br, Coding::Brotli), (zeros_2m_zstd, Zstd)] {
    refuses_bomb_one_slice_past(coded.0, coded.1)
  }
}

///|
/// `wire` packs 2 MiB in a few dozen bytes: all of it arrives before the
/// limit, so count what is decoded instead of what is read.
async fn refuses_bomb_one_slice_past(wire : Bytes, coding : Coding) -> Unit {
  let chunks = wire.iter().map(byte => Bytes::from_array([byte])).collect()
  let mut reads = 0
  let read : async () -> Bytes? = () => {
    reads += 1
    chunks.get(reads - 1)
  }
  let decoder = Some(ContentDecoder::new([coding]))
  let mut decoded = 0
  let outcome = try
    read_bounded(
      () => {
        let slice = read_decoded(read, decoder)
        decoded += slice.map_or(0, Bytes::length)
        slice
      },
      256 * 1024,
    )
  catch {
    @http.HttpError::Protocol(message) => message
    error => "unexpected \{Repr(error)}"
  } noraise {
    body => "\{body.length()} bytes"
  }
  assert_eq(outcome, "response body larger than 262144 bytes")
  assert_eq(decoded, 256 * 1024 + decoded_slice_bytes)
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
  let steps = Bytes::makei(512 * 1024, i => (i / 4096 % 7).to_byte())
  let a_512k = Bytes::make(512 * 1024, b'a')
  let cases : Array[(String, Bytes, Bytes, Array[Coding])] = [
    ("br", a_512k, a_512k_br, [Brotli]),
    ("zstd", a_512k, a_512k_zstd, [Zstd]),
    ("br, gzip", a_512k, encode_codings(a_512k_br, [0]), [Gzip, Brotli]),
  ]
  for codings in [[0], [1], [2], [0, 0], [2, 0, 1], [1, 2]] {
    cases.push(
      (
        codings_label(codings),
        steps,
        encode_codings(steps, codings),
        undo_of(codings),
      ),
    )
  }
  for case in cases {
    let (label, body, wire, undo) = case
    let decoder = ContentDecoder::new(undo)
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
          assert_eq(decoded, body.length(), msg=label)
          decoder.end()
        }
        Done => break
      }
    }
    assert_eq(decoded, body.length(), msg=label)
  }
}

///|
async test "read_decoded drains a chunk without reading again" {
  let body = Bytes::make(512 * 1024, b'a')
  let cases : Array[(String, Bytes, Array[Coding])] = [
    ("br", a_512k_br, [Brotli]),
    ("zstd", a_512k_zstd, [Zstd]),
    ("br, deflate", encode_codings(a_512k_br, [1]), [Deflate, Brotli]),
  ]
  for codings in [[0], [1], [2], [0, 1]] {
    cases.push(
      (codings_label(codings), encode_codings(body, codings), undo_of(codings)),
    )
  }
  for case in cases {
    let (label, wire, undo) = case
    let mut reads = 0
    // A server that flushed the chunk and is now silent.
    let read : async () -> Bytes? = () => {
      reads += 1
      if reads > 1 {
        fail("read again after \{label}")
      }
      Some(wire)
    }
    let decoder = Some(ContentDecoder::new(undo))
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
