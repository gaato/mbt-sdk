///|
/// `gzip.compress(b"hello, hello, hello", mtime=0)` from CPython.
let hello_gzip : Bytes = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\xd7\x51\xc8\x40\xa2\x00\x9f\xa1\xca\x09\x13\x00\x00\x00"

///|
/// Serves `wire` under `Content-Encoding: encoding` (if not empty) with its
/// `Content-Length`, recording the request's `Accept-Encoding`.
async fn serve_coded(
  request : @ahttp.Request,
  conn : @ahttp.ServerConnection,
  encoding : String,
  wire : Bytes,
  accepted : Array[String?],
) -> Unit {
  accepted.push(request.headers.get("accept-encoding"))
  let headers : @ahttp.Headers = { "Content-Length": wire.length().to_string() }
  if encoding != "" {
    headers[@ahttp.CaseInsensitiveString("Content-Encoding")] = encoding
  }
  conn.send_response(200, "OK", extra_headers=headers)
  conn.write(wire)
  conn.end_response()
}

///|
/// The coding headers and body of the response `send` returns, or the
/// `Protocol` message it raises.
async fn coded_outcome(
  send : async () -> @http.Response,
) -> Result[(String?, String?, Bytes), String] {
  try send() catch {
    @http.HttpError::Protocol(message) => Err(message)
    error => Err("unexpected \{Repr(error)}")
  } noraise {
    response =>
      Ok(
        (
          response.headers.get("content-encoding"),
          response.headers.get("content-length"),
          response.body,
        ),
      )
  }
}

///|
async test "the transport offers gzip and deflate and undoes what it knows" {
  let hello = b"hello, hello, hello"
  let rows : Array[(String, Bytes, Result[(String?, String?, Bytes), String])] = [
    ("", hello, Ok((None, Some("19"), hello))),
    ("gzip", hello_gzip, Ok((None, None, hello))),
    (
      "deflate",
      b"\x78\x9c\xcb\x48\xcd\xc9\xc9\xd7\x51\xc8\x40\xa2\x00\x44\x28\x06\xd5",
      Ok((None, None, hello)),
    ),
    (
      "deflate",
      b"\xcb\x48\xcd\xc9\xc9\xd7\x51\xc8\x40\xa2\x00",
      Ok((None, None, hello)),
    ),
    (
      "deflate, gzip",
      b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xab\x98\x73\xda\xe3\xec\xc9\x93\xd7\x03\x4f\x38\x2c\x62\x70\xd1\x60\xbb\x0a\x00\x4f\x91\x4a\xd0\x11\x00\x00\x00",
      Ok((None, None, hello)),
    ),
    ("br, gzip", hello_gzip, Ok((Some("br"), None, hello))),
    // Before, the transport failed on any coding but gzip.
    ("br", b"\x0b\x02\x80", Ok((Some("br"), Some("3"), b"\x0b\x02\x80"))),
    (
      "gzip",
      hello_gzip[:20].to_owned(),
      Err("malformed gzip response body: gzip: truncated"),
    ),
    (
      "gzip, gzip, gzip, gzip, gzip, gzip",
      hello_gzip,
      Err("response has 6 content codings, more than 5"),
    ),
  ]
  for row in rows {
    let (encoding, wire, expected) = row
    let accepted = []
    with_keepalive_server(
      (request, conn) => serve_coded(request, conn, encoding, wire, accepted),
      (url, connections) => {
        let transport = @adapter.AsyncTransport::new()
        let outcome = coded_outcome(() => {
          transport.send(@http.Request::get(url))
        })
        assert_eq(outcome, expected, msg="buffered \{encoding}")
        let streamed = coded_outcome(() => {
          let (head, stream) = transport.send_stream(@http.Request::get(url))
          let body = Buffer()
          while stream.read_some() is Some(chunk) {
            body.write_bytes(chunk)
          }
          @http.Response::{
            status: head.status,
            headers: head.headers,
            body: body.to_bytes(),
          }
        })
        assert_eq(streamed, expected, msg="streamed \{encoding}")
        // A decoded body read to its end parks the connection; a failed one
        // closes it.
        assert_eq(connections(), if expected is Ok(_) { 1 } else { 2 })
        transport.close()
      },
    )
    assert_eq(accepted, [Some("gzip, deflate"), Some("gzip, deflate")])
  }
}

///|
async test "a request's own Accept-Encoding gets the body as sent" {
  let accepted = []
  with_keepalive_server(
    (request, conn) => serve_coded(request, conn, "gzip", hello_gzip, accepted),
    (url, _) => {
      let response = @adapter.AsyncTransport::new().send(
        @http.Request::get(url).header("Accept-Encoding", "gzip"),
      )
      assert_eq(response.headers.get("content-encoding"), Some("gzip"))
      assert_eq(response.body, hello_gzip)
    },
  )
  assert_eq(accepted, [Some("gzip")])
}

///|
async test "a decoded bomb stops at max_body_bytes and streams in 64 KiB reads" {
  // 32 gzip members of 64 KiB of zeros each: 2 MiB from a few KiB, without
  // compressing 2 MiB on the event loop the other socket tests share.
  let one_member = @gzip.compress(Bytes::make(64 * 1024, b'\x00'))
  let size = 32 * 64 * 1024
  let wire = Buffer()
  for _ in 0..<32 {
    wire.write_bytes(one_member)
  }
  let wire = wire.to_bytes()
  let accepted = []
  with_keepalive_server(
    (request, conn) => {
      // The client may close before the response is written in full.
      serve_coded(request, conn, "gzip", wire, accepted) catch {
        _ => ()
      }
    },
    (url, _) => {
      let transport = @adapter.AsyncTransport::new(max_body_bytes=256 * 1024)
      let outcome = coded_outcome(() => transport.send(@http.Request::get(url)))
      assert_eq(outcome, Err("response body larger than 262144 bytes"))
      let (_, stream) = transport.send_stream(@http.Request::get(url))
      defer stream.close()
      let mut total = 0
      let mut largest = 0
      while stream.read_some() is Some(chunk) {
        total += chunk.length()
        largest = largest.max(chunk.length())
      }
      assert_eq(total, size)
      assert_true(largest <= 64 * 1024, msg="largest read: \{largest}")
    },
  )
}

///|
async test "a flushed coded chunk decodes in full before the server writes again" {
  let size = 512 * 1024
  let wire = @gzip.compress(Bytes::make(size, b'e'))
  let release = @async.Queue(kind=Unbounded)
  with_server(
    conn => {
      ignore(conn.read_request())
      conn.send_response(200, "OK", extra_headers={ "Content-Encoding": "gzip" })
      conn.write(wire)
      conn.flush()
      // Silent until the client has read everything the chunk decodes to.
      let _ : Bool = release.get()
      conn.end_response()
    },
    url => {
      let transport = @adapter.AsyncTransport::new(timeout_ms=1000)
      let (_, stream) = transport.send_stream(@http.Request::get(url))
      defer stream.close()
      let mut total = 0
      while total < size {
        guard stream.read_some() is Some(chunk) else { fail("ended early") }
        total += chunk.length()
      }
      release.put(true)
      assert_eq(stream.read_some(), None)
      assert_eq(total, size)
    },
  )
}
