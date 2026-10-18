///|
/// The byte at `index` of a generated upload.
fn pattern(index : Int64) -> Byte {
  ((index * 31L) ^ (index >> 9)).to_byte()
}

///|
/// FNV-1a over `bytes`, continuing from `hash`.
fn fnv(hash : UInt32, bytes : BytesView) -> UInt32 {
  let mut hash = hash
  for byte in bytes {
    hash = (hash ^ byte.to_uint()) * 16777619U
  }
  hash
}

///|
let fnv_basis : UInt32 = 2166136261U

///|
/// A request body produced on demand: `total` pattern bytes in chunks of
/// `chunk` bytes, which need not divide 64 KiB. Records being closed and how
/// many bytes it handed out.
struct Generated {
  total : Int64
  chunk : Int32
  mut produced : Int64
  mut closed : Bool
}

///|
fn generated(total : Int64, chunk~ : Int32 = 100_003) -> Generated {
  { total, chunk, produced: 0L, closed: false, }
}

///|
impl @http.BodyStream for Generated with fn read_some(self) {
  let left = self.total - self.produced
  guard left > 0L else { return None }
  let size = left.min(self.chunk.to_int64()).to_int()
  let start = self.produced
  self.produced += size.to_int64()
  Some(Bytes::makei(size, i => pattern(start + i.to_int64())))
}

///|
impl @http.BodyStream for Generated with fn close(self) {
  self.closed = true
}

///|
/// The FNV-1a hash of the first `total` pattern bytes.
fn pattern_hash(total : Int64) -> UInt32 {
  let mut hash = fnv_basis
  for index = 0L; index < total; index = index + 1L {
    hash = (hash ^ pattern(index).to_uint()) * 16777619U
  }
  hash
}

///|
/// Serves one request: answers with its framing headers, the number of body
/// bytes received and their hash, reading the body without keeping it.
async fn count_upload(conn : @ahttp.ServerConnection) -> Unit {
  let request = conn.read_request()
  let mut length = 0L
  let mut hash = fnv_basis
  while conn.read_some() is Some(chunk) {
    length += chunk.length().to_int64()
    hash = fnv(hash, chunk)
  }
  let framing = [
    "content-length=\{request.headers.get("content-length").unwrap_or("-")}",
    "transfer-encoding=\{request.headers.get("transfer-encoding").unwrap_or("-")}",
  ]
  conn.send_response(200, "OK")
  conn.write("\{framing.join(" ")} received=\{length} hash=\{hash}")
  conn.end_response()
}

///|
async test "a 32 MiB stream uploads intact, chunked or with its length" {
  let total = 32L * 1024 * 1024
  let expected_hash = pattern_hash(total)
  for known in [false, true] {
    with_server(count_upload, url => {
      let source = generated(total)
      let length = if known { Some(total) } else { None }
      let response = @adapter.AsyncTransport::new().send(
        @http.Request::put(url + "/upload").body_stream(source, length?),
      )
      let framing = if known {
        "content-length=\{total} transfer-encoding=-"
      } else {
        "content-length=- transfer-encoding=chunked"
      }
      assert_eq(
        @utf8.decode(response.body),
        "\{framing} received=\{total} hash=\{expected_hash}",
      )
      assert_true(source.closed)
    })
  }
}

///|
async test "bytes bodies declare their length, and an empty one only for POST" {
  let rows : Array[(@http.Request, String)] = [
    (
      @http.Request::post("/").body_bytes(b"abc"),
      "content-length=3 transfer-encoding=- received=3",
    ),
    (
      @http.Request::post("/"),
      "content-length=0 transfer-encoding=- received=0",
    ),
    (@http.Request::get("/"), "content-length=- transfer-encoding=- received=0"),
    (
      @http.Request::post("/").body_stream(generated(0L)),
      "content-length=- transfer-encoding=- received=0",
    ),
  ]
  for row in rows {
    let (template, expected) = row
    with_server(count_upload, url => {
      let response = @adapter.AsyncTransport::new().send({
        ..template,
        url: url + "/",
      })
      let text = @utf8.decode(response.body)
      assert_eq(text[:text.find(" hash=").unwrap()].to_owned(), expected)
    })
  }
}

///|
async test "a server that stops reading times out the upload in Write" {
  with_raw_server(_ => @async.sleep(3000), port => {
    let transport = @adapter.AsyncTransport::new(write_timeout_ms=200)
    let source = generated(1024L * 1024 * 1024)
    let request = @http.Request::put("http://127.0.0.1:\{port}/").body_stream(
      source,
    )
    assert_eq(phase_outcome(transport, request), "Timeout(phase=Write, ms=200)")
    assert_true(source.closed)
    // It stopped where the socket buffers filled, far short of the body.
    assert_true(source.produced < 256L * 1024 * 1024)
  })
}

///|
async test "a stream shorter than its declared length fails without a response" {
  with_raw_server(conn => ignore(conn.read_until("\r\n\r\n")), port => {
    let source = generated(1000L)
    let request = @http.Request::put("http://127.0.0.1:\{port}/").body_stream(
      source,
      length=1001,
    )
    assert_eq(
      phase_outcome(@adapter.AsyncTransport::new(), request),
      "Protocol",
    )
    assert_true(source.closed)
  })
}

///|
async test "a stream sent once is refused before its request reaches the server" {
  let heads = Ref(0)
  let finished : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
  with_raw_server(
    conn => {
      while conn.read_until("\r\n\r\n") is Some(_) {
        heads.val += 1
        conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
      }
      finished.put(())
    },
    port => {
      let url = "http://127.0.0.1:\{port}/"
      let transport = @adapter.AsyncTransport::new()
      let request = @http.Request::post(url).body_stream(
        generated(0L),
        length=0,
      )
      ignore(transport.send(request))
      // The refused send closes the reused connection without writing to it.
      assert_eq(phase_outcome(transport, request), "Protocol")
      finished.get()
      assert_eq(heads.val, 1)
    },
  )
}

///|
async test "a stream declared empty that is not fails before its head goes out" {
  let heads = Ref(0)
  let finished : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
  with_raw_server(
    conn => {
      while conn.read_until("\r\n\r\n") is Some(_) {
        heads.val += 1
      }
      finished.put(())
    },
    port => {
      let source = generated(5L)
      let request = @http.Request::post("http://127.0.0.1:\{port}/").body_stream(
        source,
        length=0,
      )
      assert_eq(
        phase_outcome(@adapter.AsyncTransport::new(), request),
        "Protocol",
      )
      assert_true(source.closed)
      finished.get()
      assert_eq(heads.val, 0)
    },
  )
}

///|
/// A stream that ends at once and refuses any read after its end, as the
/// `BodyStream` contract allows.
struct EndsOnce {
  mut ended : Bool
}

///|
impl @http.BodyStream for EndsOnce with fn read_some(self) {
  if self.ended {
    raise @http.HttpError::Protocol("read after the end")
  }
  self.ended = true
  None
}

///|
impl @http.BodyStream for EndsOnce with fn close(_) {
  ()
}

///|
async test "an empty stream is read to its end once, with or without a length" {
  for length in [Some(0L), None] {
    with_server(count_upload, url => {
      let request = @http.Request::post(url + "/").body_stream(
        EndsOnce::{ ended: false, },
        length?,
      )
      let response = @adapter.AsyncTransport::new().send(request)
      let text = @utf8.decode(response.body)
      assert_true(text.contains("received=0"), msg=text)
    })
  }
}
