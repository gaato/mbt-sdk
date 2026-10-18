///|
// One raw TCP connection per test, under the same 5 s deadline as the other
// socket tests. The handler owns the socket; `run` gets the port.
async fn with_raw_server(
  handler : async (@socket.Tcp) -> Unit,
  run : async (Int32) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        let (conn, _) = server.accept()
        defer conn.close()
        handler(conn)
      })
      run(server.addr.port())
    })
  })
}

///|
/// What `send`, or `send_stream` and reading the stream to its end, makes of
/// `request`: the failure, without a message whose wording the OS decides, or
/// the body length.
async fn phase_outcome(
  transport : @adapter.AsyncTransport,
  request : @http.Request,
  streaming~ : Bool = false,
) -> String {
  try {
    if streaming {
      let (_, stream) = transport.send_stream(request)
      defer stream.close()
      let mut length = 0
      while stream.read_some() is Some(chunk) {
        length += chunk.length()
      }
      "\{length} bytes"
    } else {
      "\{transport.send(request).body.length()} bytes"
    }
  } catch {
    @http.HttpError::Network(phase~, ..) =>
      "Network(phase=\{@debug.to_string(phase)})"
    @http.HttpError::Protocol(_) => "Protocol"
    error => @debug.to_string(error)
  }
}

///|
async test "a TLS handshake that never completes times out in Dial" {
  with_raw_server(_ => @async.sleep(3000), port => {
    let transport = @adapter.AsyncTransport::new(timeout_ms=200)
    let outcome = phase_outcome(
      transport,
      @http.Request::get("https://127.0.0.1:\{port}/"),
    )
    assert_eq(outcome, "Timeout(phase=Dial, ms=200)")
  })
}

///|
/// A body larger than the socket buffers of both ends, so writing it blocks
/// until the server reads.
let large_body : Bytes = Bytes::make(64 * 1024 * 1024, b'x')

///|
async test "a server that never reads the request times out in Write" {
  with_raw_server(_ => @async.sleep(3000), port => {
    let transport = @adapter.AsyncTransport::new(timeout_ms=300)
    let request = @http.Request::post("http://127.0.0.1:\{port}/").body_bytes(
      large_body,
    )
    assert_eq(phase_outcome(transport, request), "Timeout(phase=Write, ms=300)")
  })
}

///|
async test "a connection reset while the request is written is Network in Write" {
  with_raw_server(conn => conn.close(), port => {
    let request = @http.Request::post("http://127.0.0.1:\{port}/").body_bytes(
      large_body,
    )
    assert_eq(
      phase_outcome(@adapter.AsyncTransport::new(), request),
      "Network(phase=Write)",
    )
  })
}

///|
async test "a connection closed before the head is Network in Head" {
  for streaming in [false, true] {
    with_raw_server(conn => ignore(conn.read_until("\r\n\r\n")), port => {
      let outcome = phase_outcome(
        @adapter.AsyncTransport::new(),
        @http.Request::get("http://127.0.0.1:\{port}/"),
        streaming~,
      )
      assert_eq(outcome, "Network(phase=Head)")
    })
  }
}

///|
async test "a body cut short is Network in Body" {
  for streaming in [false, true] {
    with_raw_server(
      conn => {
        ignore(conn.read_until("\r\n\r\n"))
        conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nonly ten b")
      },
      port => {
        let outcome = phase_outcome(
          @adapter.AsyncTransport::new(),
          @http.Request::get("http://127.0.0.1:\{port}/"),
          streaming~,
        )
        assert_eq(outcome, "Network(phase=Body)")
      },
    )
  }
}

///|
async test "a malformed head is Protocol" {
  with_raw_server(
    conn => {
      ignore(conn.read_until("\r\n\r\n"))
      conn.write(b"HTTP/1.1 OK\r\n\r\n")
    },
    port => {
      let outcome = phase_outcome(
        @adapter.AsyncTransport::new(),
        @http.Request::get("http://127.0.0.1:\{port}/"),
      )
      assert_eq(outcome, "Protocol")
    },
  )
}
