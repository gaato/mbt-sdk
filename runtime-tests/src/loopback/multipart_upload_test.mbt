///|
/// The byte at `index` of a generated file.
fn pattern(index : Int64) -> Byte {
  ((index * 31L) ^ (index >> 9)).to_byte()
}

///|
/// A file part body produced on demand in chunks of 100,003 bytes.
struct Generated {
  total : Int64
  mut produced : Int64
  mut closed : Bool
}

///|
impl @http.BodyStream for Generated with fn read_some(self) {
  let left = self.total - self.produced
  guard left > 0L else { return None }
  let size = left.min(100_003L).to_int()
  let start = self.produced
  self.produced += size.to_int64()
  Some(Bytes::makei(size, i => pattern(start + i.to_int64())))
}

///|
impl @http.BodyStream for Generated with fn close(self) {
  self.closed = true
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
async test "a 32 MiB streamed file part uploads intact through AsyncTransport" {
  let total = 32L * 1024 * 1024
  // What the server must receive: the framing around the generated file.
  let (_, framing) = @multipart.encode_segments(
    [
      @multipart.Part::text("note", "hi"),
      @multipart.Part::file(
        "upload", "big.bin", "application/octet-stream", b"",
      ),
    ],
    "mbt-boundary",
  )
  let framing = @multipart.join_segments(framing)
  let head_end = framing.length() - "\r\n--mbt-boundary--\r\n".length()
  let mut expected = fnv(2166136261U, framing[:head_end])
  for index = 0L; index < total; index = index + 1L {
    expected = (expected ^ pattern(index).to_uint()) * 16777619U
  }
  expected = fnv(expected, framing[head_end:])
  let expected_length = total + framing.length().to_int64()
  for known in [true, false] {
    @async.with_timeout(20000, () => {
      let server = @ahttp.Server(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      @async.with_task_group(group => {
        group.spawn_bg(no_wait=true, () => {
          let (conn, _) = server.accept()
          defer conn.close()
          let request = conn.read_request()
          let mut length = 0L
          let mut hash = 2166136261U
          while conn.read_some() is Some(chunk) {
            length += chunk.length().to_int64()
            hash = fnv(hash, chunk)
          }
          let declared = request.headers.get("content-length").unwrap_or("-")
          conn.send_response(200, "OK")
          conn.write("\{declared} \{length} \{hash}")
          conn.end_response()
        })
        let file = { total, produced: 0L, closed: false, }
        let length = if known { Some(total) } else { None }
        let request = @multipart.apply(
          @http.Request::post("http://127.0.0.1:\{server.addr.port()}/upload"),
          [
            @multipart.Part::text("note", "hi"),
            @multipart.Part::file_stream(
              "upload",
              "big.bin",
              "application/octet-stream",
              file,
              length?,
            ),
          ],
          "mbt-boundary",
        )
        let response = @adapter.AsyncTransport::new().send(request)
        let declared = if known { expected_length.to_string() } else { "-" }
        assert_eq(
          @utf8.decode(response.body),
          "\{declared} \{expected_length} \{expected}",
        )
        assert_true(file.closed)
      })
    })
  }
}
