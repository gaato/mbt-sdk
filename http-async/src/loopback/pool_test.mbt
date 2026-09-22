///|
/// A keep-alive server that counts accepted client sockets.
async fn with_keepalive_server(
  handler : async (@ahttp.Request, @ahttp.ServerConnection) -> Unit,
  run : async (String, () -> Int) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let server = @ahttp.Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let accepted = Ref(0)
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        for ;; {
          let (conn, _) = server.accept()
          accepted.val += 1
          group.spawn_bg(no_wait=true, () => {
            defer conn.close()
            try {
              for ;; {
                let request = conn.read_request()
                ignore(conn.read_all().binary())
                handler(request, conn)
              }
            } catch {
              _ => ()
            }
          })
        }
      })
      run("http://127.0.0.1:\{server.addr.port()}", () => accepted.val)
    })
  })
}

///|
async fn pong(conn : @ahttp.ServerConnection) -> Unit {
  conn.send_response(200, "OK")
  conn.write(b"pong")
  conn.end_response()
}

///|
async test "sequential requests reuse one parked connection" {
  with_keepalive_server((_, conn) => pong(conn), (url, connections) => {
    let transport = @adapter.AsyncTransport::new()
    for _ in 0..<3 {
      let response = transport.send(@http.Request::get(url + "/ping"))
      assert_eq(response.status, 200)
      assert_eq(response.body, b"pong")
    }
    assert_eq(connections(), 1)
    assert_eq(transport.idle_connections(), 1)
    transport.close()
    assert_eq(transport.idle_connections(), 0)
  })
}

///|
async test "Connection: close and disabled reuse dial per request" {
  with_keepalive_server(
    (_, conn) => {
      conn.send_response(200, "OK", extra_headers={ "Connection": "close" })
      conn.write(b"bye")
      conn.end_response()
    },
    (url, connections) => {
      let transport = @adapter.AsyncTransport::new()
      ignore(transport.send(@http.Request::get(url)))
      ignore(transport.send(@http.Request::get(url)))
      assert_eq(connections(), 2)
      assert_eq(transport.idle_connections(), 0)
    },
  )
  with_keepalive_server((_, conn) => pong(conn), (url, connections) => {
    let transport = @adapter.AsyncTransport::new(max_idle_per_origin=0)
    ignore(transport.send(@http.Request::get(url)))
    ignore(transport.send(@http.Request::get(url)))
    assert_eq(connections(), 2)
    assert_eq(transport.idle_connections(), 0)
  })
  with_keepalive_server((_, conn) => pong(conn), (url, connections) => {
    let transport = @adapter.AsyncTransport::new(idle_max_ms=0)
    ignore(transport.send(@http.Request::get(url)))
    ignore(transport.send(@http.Request::get(url)))
    assert_eq(connections(), 2)
    assert_eq(transport.idle_connections(), 0)
  })
}

///|
async test "parked connections older than idle_max_ms are not reused" {
  with_keepalive_server((_, conn) => pong(conn), (url, connections) => {
    let transport = @adapter.AsyncTransport::new(idle_max_ms=20)
    ignore(transport.send(@http.Request::get(url)))
    assert_eq(transport.idle_connections(), 1)
    @async.sleep(60)
    ignore(transport.send(@http.Request::get(url)))
    assert_eq(connections(), 2)
    assert_eq(transport.idle_connections(), 1)
  })
}

///|
async test "a dropped parked connection is replayed for GET but surfaces for POST" {
  // The server closes every connection after one response, without saying so.
  with_keepalive_server(
    (_, conn) => {
      pong(conn)
      conn.close()
    },
    (url, connections) => {
      let transport = @adapter.AsyncTransport::new()
      ignore(transport.send(@http.Request::get(url)))
      assert_eq(transport.idle_connections(), 1)
      let replayed = transport.send(@http.Request::get(url))
      assert_eq(replayed.status, 200)
      assert_eq(connections(), 2)
      assert_eq(transport.idle_connections(), 1)
      try transport.send(@http.Request::post(url).body_text("x")) catch {
        _ => ()
      } noraise {
        _ => fail("expected the dropped connection to surface for POST")
      }
      assert_eq(connections(), 2)
      assert_eq(transport.idle_connections(), 0)
      // A POST with an Idempotency-Key is replayable.
      ignore(transport.send(@http.Request::get(url)))
      let keyed = transport.send(
        @http.Request::post(url).body_text("x").header("Idempotency-Key", "k1"),
      )
      assert_eq(keyed.status, 200)
      assert_eq(connections(), 4)
    },
  )
}

///|
async test "closed transport refuses requests" {
  with_keepalive_server((_, conn) => pong(conn), (url, _) => {
    let transport = @adapter.AsyncTransport::new()
    transport.close()
    try transport.send(@http.Request::get(url)) catch {
      @http.HttpError::Connect(_) => ()
      _ => fail("expected Connect")
    } noraise {
      _ => fail("expected a closed transport to refuse")
    }
  })
}

///|
async test "streams park the connection only when read to the end" {
  with_keepalive_server(
    (_, conn) => {
      conn.send_response(200, "OK")
      conn.write(b"one")
      conn.flush()
      conn.write(b"two")
      conn.end_response()
    },
    (url, connections) => {
      let transport = @adapter.AsyncTransport::new()
      let (head, stream) = transport.send_stream(@http.Request::get(url))
      assert_eq(head.status, 200)
      let collected = Buffer()
      while stream.read_some() is Some(chunk) {
        collected.write_bytes(chunk)
      }
      assert_eq(collected.contents(), b"onetwo")
      assert_eq(transport.idle_connections(), 1)
      let (_, early) = transport.send_stream(@http.Request::get(url))
      ignore(early.read_some())
      early.close()
      assert_eq(transport.idle_connections(), 0)
      assert_eq(connections(), 1)
      ignore(transport.send(@http.Request::get(url)))
      assert_eq(connections(), 2)
    },
  )
}

///|
async test "max_idle_per_origin bounds parked connections, not concurrency" {
  with_keepalive_server(
    (_, conn) => {
      @async.sleep(30)
      pong(conn)
    },
    (url, connections) => {
      let transport = @adapter.AsyncTransport::new(max_idle_per_origin=1)
      @async.with_task_group(group => {
        for _ in 0..<3 {
          group.spawn_bg(() => ignore(transport.send(@http.Request::get(url))))
        }
      })
      assert_eq(connections(), 3)
      assert_eq(transport.idle_connections(), 1)
    },
  )
}
