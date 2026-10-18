///|
/// A keep-alive server that counts accepted client sockets.
async fn with_keepalive_server(
  handler : async (@ahttp.Request, @ahttp.ServerConnection) -> Unit,
  run : async (String, () -> Int32) -> Unit,
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
async test "pool reuses only connections with the same User-Agent" {
  with_keepalive_server(
    (request, conn) => {
      let expected = match request.path {
        "/first" | "/third" => "agent-a"
        "/second" => "agent-b"
        "/default" => "moonbit-http-client/1.1"
        _ => fail("unexpected path")
      }
      assert_eq(request.headers.get("user-agent"), Some(expected))
      pong(conn)
    },
    (url, connections) => {
      let transport = @adapter.AsyncTransport::new()
      ignore(
        transport.send(
          @http.Request::get(url + "/first").header("User-Agent", "agent-a"),
        ),
      )
      assert_eq(connections(), 1)
      ignore(
        transport.send(
          @http.Request::get(url + "/second").header("user-agent", "agent-b"),
        ),
      )
      assert_eq(connections(), 2)
      assert_eq(transport.idle_connections(), 2)
      ignore(
        transport.send(
          @http.Request::get(url + "/third").header("USER-AGENT", "agent-a"),
        ),
      )
      assert_eq(connections(), 2)
      assert_eq(transport.idle_connections(), 2)
      ignore(transport.send(@http.Request::get(url + "/default")))
      assert_eq(connections(), 3)
      assert_eq(transport.idle_connections(), 3)
      transport.close()
    },
  )
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
async test "a dropped parked connection is not replayed with a stream body it sent" {
  // As above: the server closes every connection after one response.
  with_keepalive_server(
    (_, conn) => {
      pong(conn)
      conn.close()
    },
    (url, connections) => {
      let transport = @adapter.AsyncTransport::new()
      ignore(transport.send(@http.Request::get(url)))
      assert_eq(transport.idle_connections(), 1)
      // PUT is idempotent, but the stream was read on the stale connection.
      let request = @http.Request::put(url).body_stream(generated(10L))
      try transport.send(request) catch {
        @http.HttpError::Network(..) => ()
        error => fail("expected Network, got \{@debug.to_string(error)}")
      } noraise {
        _ => fail("expected the dropped connection to surface")
      }
      assert_eq(connections(), 1)
      assert_false(request.body.is_replayable())
      // The same request with its body in memory is replayed.
      ignore(transport.send(@http.Request::get(url)))
      let replayed = transport.send(
        @http.Request::put(url).body_bytes(b"0123456789"),
      )
      assert_eq(replayed.status, 200)
      assert_eq(connections(), 3)
    },
  )
}

///|
async test "a replay that fails as well surfaces after one fresh connection" {
  // The first connection answers once and closes without saying so; every
  // later one closes on its first request without answering.
  let answered = Ref(false)
  with_keepalive_server(
    (_, conn) => {
      if !answered.val {
        answered.val = true
        pong(conn)
      }
      conn.close()
    },
    (url, connections) => {
      let transport = @adapter.AsyncTransport::new()
      ignore(transport.send(@http.Request::get(url)))
      assert_eq(transport.idle_connections(), 1)
      try transport.send(@http.Request::get(url)) catch {
        _ => ()
      } noraise {
        _ => fail("expected the failed replay to surface")
      }
      // The stale connection and one fresh one: the replay was not replayed.
      assert_eq(connections(), 2)
      assert_eq(transport.idle_connections(), 0)
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

///|
/// Answers `/hold` with a head and a first chunk, then keeps the body open
/// for 3 s; answers anything else with `pong`.
async fn hold_or_pong(
  request : @ahttp.Request,
  conn : @ahttp.ServerConnection,
) -> Unit {
  if request.path == "/hold" {
    conn.send_response(200, "OK")
    conn.write(b"x")
    conn.flush()
    @async.sleep(3000)
    conn.end_response()
  } else {
    pong(conn)
  }
}

///|
async test "a request over the connection cap waits for a slot until pool_timeout_ms" {
  with_keepalive_server(hold_or_pong, (url, connections) => {
    let transport = @adapter.AsyncTransport::new(
      max_connections_per_origin=1,
      pool_timeout_ms=200,
    )
    let (_, held) = transport.send_stream(@http.Request::get(url + "/hold"))
    try transport.send(@http.Request::get(url + "/ping")) catch {
      @http.HttpError::Timeout(phase=Pool, ms~) => assert_eq(ms, 200)
      error => fail("expected a Pool timeout, got \{@debug.to_string(error)}")
    } noraise {
      _ => fail("the cap was not applied")
    }
    assert_eq(connections(), 1)
    // Abandoning the stream closes its connection and frees the slot.
    held.close()
    assert_eq(transport.send(@http.Request::get(url + "/ping")).body, b"pong")
    assert_eq(connections(), 2)
  })
}

///|
async test "a queued request takes the connection its predecessor parks" {
  with_keepalive_server((_, conn) => pong(conn), (url, connections) => {
    let transport = @adapter.AsyncTransport::new(max_connections=1)
    let order : Array[Int32] = []
    @async.with_task_group(group => {
      for i in 0..<4 {
        group.spawn_bg(() => {
          ignore(transport.send(@http.Request::get(url + "/ping")))
          order.push(i)
        })
      }
    })
    assert_eq(order, [0, 1, 2, 3])
    assert_eq(connections(), 1)
    assert_eq(transport.idle_connections(), 1)
  })
}

///|
async test "closing the transport refuses the requests waiting for a slot" {
  with_keepalive_server(hold_or_pong, (url, _) => {
    let transport = @adapter.AsyncTransport::new(max_connections=1)
    let (_, held) = transport.send_stream(@http.Request::get(url + "/hold"))
    defer held.close()
    let outcome = Ref("pending")
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        outcome.val = try
          transport.send(@http.Request::get(url + "/ping"))
        catch {
          error => @debug.to_string(error)
        } noraise {
          _ => "sent"
        }
      })
      @async.sleep(50)
      transport.close()
    })
    assert_eq(outcome.val, "Connect(\"transport closed\")")
  })
  // A waiter handed a slot just before the close is refused as it resumes.
  with_keepalive_server(hold_or_pong, (url, connections) => {
    let transport = @adapter.AsyncTransport::new(max_connections=1)
    let (_, held) = transport.send_stream(@http.Request::get(url + "/hold"))
    let outcome = Ref("pending")
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        outcome.val = try
          transport.send(@http.Request::get(url + "/ping"))
        catch {
          error => @debug.to_string(error)
        } noraise {
          _ => "sent"
        }
      })
      @async.sleep(50)
      held.close()
      transport.close()
    })
    assert_eq(outcome.val, "Connect(\"transport closed\")")
    assert_eq(connections(), 1)
  })
}
