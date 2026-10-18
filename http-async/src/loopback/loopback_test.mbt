///|
// Every socket test uses this deadline, including server creation and teardown.
async fn with_server(
  handler : async (@ahttp.ServerConnection) -> Unit,
  run : async (String) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let server = @ahttp.Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        let (conn, _) = server.accept()
        defer conn.close()
        handler(conn)
      })
      run("http://127.0.0.1:\{server.addr.port()}")
    })
  })
}

///|
async fn reply(
  conn : @ahttp.ServerConnection,
  status : Int32,
  body : Bytes,
) -> Unit {
  conn.send_response(status, "test", extra_headers={ "X-MiXeD": "yes" })
  conn.write(body)
  conn.end_response()
}

///|
// Inspect raw header lines because the HTTP server parser collapses duplicates.
async fn with_raw_request(
  expected_user_agent : String,
  run : async (String) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        let (conn, _) = server.accept()
        defer conn.close()
        guard conn.read_until("\r\n\r\n") is Some(head) else {
          fail("missing request headers")
        }
        let mut count = 0
        for line in head.split("\r\n") {
          if line.to_lower().has_prefix("user-agent:") {
            count += 1
            assert_eq(line, "User-Agent: " + expected_user_agent)
          }
        }
        assert_eq(count, 1)
        conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      })
      run("http://127.0.0.1:\{server.addr.port()}")
    })
  })
}

///|
async test "custom User-Agent occurs exactly once on the wire" {
  with_raw_request("kbbi.mbt/0.1.0", url => {
    let response = @adapter.AsyncTransport::new().send(
      @http.Request::get(url).header("uSeR-aGeNt", "kbbi.mbt/0.1.0"),
    )
    assert_eq(response.status, 200)
  })
}

///|
async test "repeated User-Agent values keep the existing comma join" {
  with_raw_request("agent-a, agent-b", url => {
    let request = @http.Request::get(url)
      .header("User-Agent", "agent-a")
      .header("user-agent", "agent-b")
    assert_eq(@adapter.AsyncTransport::new().send(request).status, 200)
  })
}

///|
async test "default User-Agent occurs exactly once on the wire" {
  with_raw_request("moonbit-http-client/1.1", url => {
    let response = @adapter.AsyncTransport::new().send(@http.Request::get(url))
    assert_eq(response.status, 200)
  })
}

///|
async test "GET body and lowercase response header names" {
  with_server(
    conn => {
      let request = conn.read_request()
      assert_eq(request.meth, @ahttp.Get)
      assert_eq(request.path, "/hello?q=1")
      assert_eq(request.headers.get("x-mixed"), Some("request"))
      reply(conn, 200, b"hello")
    },
    url => {
      let request = @http.Request::get(url + "/hello?q=1#discard").header(
        "X-MiXeD", "request",
      )
      let request = { ..request, http_method: "gEt", }
      let result = @adapter.AsyncTransport::new().send(request)
      assert_eq(result.status, 200)
      assert_eq(result.body, b"hello")
      assert_eq(result.headers.get("x-mixed"), Some("yes"))
      for (name, _) in result.headers.iter() {
        assert_eq(name, name.to_lower())
      }
    },
  )
}

///|
async test "POST Japanese JSON bytes content-type and joined request headers" {
  let json : Json = { "message": "日本語" }
  let template = @http.Request::post("/").json_body(json)
  with_server(
    conn => {
      let request = conn.read_request()
      assert_eq(request.meth, @ahttp.Post)
      assert_eq(request.path, "/?query=1")
      assert_eq(request.headers.get("content-type"), Some("application/json"))
      assert_eq(request.headers.get("x-repeat"), Some("one, two"))
      // The caller's Content-Length is replaced by the body's own.
      assert_eq(
        request.headers.get("content-length"),
        template.body.length().map(length => length.to_string()),
      )
      assert_eq(request.headers.get("transfer-encoding"), None)
      let body = conn.read_all().binary()
      assert_eq(@http.Body::Bytes(body), template.body)
      reply(conn, 200, body)
    },
    url => {
      let request = @http.Request::post(url + "?query=1")
        .json_body(json)
        .header("Content-Length", "1")
        .header("X-Repeat", "one")
        .header("x-repeat", "two")
      assert_eq(
        @http.Body::Bytes(@adapter.AsyncTransport::new().send(request).body),
        template.body,
      )
    },
  )
}

///|
async test "404 500 and native redirects remain responses" {
  for status in [404, 500, 302] {
    with_server(
      conn => {
        ignore(conn.read_request())
        conn.send_response(status, "test", extra_headers={
          "Location": "/elsewhere",
        })
        conn.write(b"status body")
        conn.end_response()
      },
      url => {
        let result = @adapter.AsyncTransport::new().send(
          @http.Request::get(url),
        )
        assert_eq(result.status, status)
        assert_eq(result.body, b"status body")
      },
    )
  }
}

///|
async test "SSE flushed chunks split UTF-8 and CRLF" {
  with_server(
    conn => {
      ignore(conn.read_request())
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "text/event-stream",
      })
      for
        chunk in [
          b"id: 7\r\nevent: update\r\ndata: \xe6", b"\x97\xa5\r", b"\n\r\n", b"data: second\nretry: 42\n\n",
        ] {
        conn.write(chunk)
        conn.flush()
        @async.sleep(20)
      }
      conn.end_response()
    },
    url => {
      let (head, stream) = @adapter.AsyncTransport::new().send_stream(
        @http.Request::get(url),
      )
      assert_eq(head.status, 200)
      let events = []
      @sse.each_event(stream, event => events.push(event))
      assert_eq(events, [
        @sse.SseEvent::{
          event: "update",
          data: "日",
          id: Some("7"),
          retry: None,
        },
        @sse.SseEvent::{
          event: "message",
          data: "second",
          id: Some("7"),
          retry: Some(42),
        },
      ])
      assert_eq(stream.read_some(), None)
      stream.close()
    },
  )
}

///|
async test "early close releases an open response and is idempotent" {
  let closed = @async.Queue(kind=Unbounded)
  with_server(
    conn => {
      ignore(conn.read_request())
      conn.send_response(200, "OK")
      conn.write(b"still open")
      conn.flush()
      // Reading the next request observes peer EOF even while this body is open.
      try conn.read_request() catch {
        @io.ReaderClosed => closed.put(true)
        error => raise error
      } noraise {
        _ => fail("expected peer close")
      }
    },
    url => {
      let (_, stream) = @adapter.AsyncTransport::new().send_stream(
        @http.Request::get(url),
      )
      stream.close()
      stream.close()
      assert_eq(stream.read_some(), None)
      assert_true(closed.get())
    },
  )
}

///|
async test "response head timeout for buffered and streaming sends" {
  for streaming in [false, true] {
    with_server(
      conn => {
        ignore(conn.read_request())
        @async.sleep(2000)
      },
      url => {
        let transport = @adapter.AsyncTransport::new(timeout_ms=200)
        try {
          if streaming {
            ignore(transport.send_stream(@http.Request::get(url)))
          } else {
            ignore(transport.send(@http.Request::get(url)))
          }
        } catch {
          @http.HttpError::Timeout(phase=Head, ms~) => assert_eq(ms, 200)
          _ => fail("expected transport timeout")
        } noraise {
          _ => fail("expected timeout")
        }
      },
    )
  }
}

///|
async test "whole body timeout and streaming idle timeout close the connection" {
  for streaming in [false, true] {
    let closed = @async.Queue(kind=Unbounded)
    with_server(
      conn => {
        ignore(conn.read_request())
        conn.send_response(200, "OK")
        conn.write(b"first")
        conn.flush()
        try conn.read_request() catch {
          @io.ReaderClosed => closed.put(true)
          error => raise error
        } noraise {
          _ => fail("expected close on timeout")
        }
      },
      url => {
        let transport = @adapter.AsyncTransport::new(timeout_ms=200)
        let request = @http.Request::get(url)
        if streaming {
          let (_, stream) = transport.send_stream(request)
          assert_eq(stream.read_some(), Some(b"first"))
          try stream.read_some() catch {
            @http.HttpError::Timeout(phase=Body, ms~) => assert_eq(ms, 200)
            _ => fail("expected idle timeout")
          } noraise {
            _ => fail("expected timeout")
          }
          assert_eq(stream.read_some(), None)
          stream.close()
        } else {
          try transport.send(request) catch {
            @http.HttpError::Timeout(phase=Body, ms~) => assert_eq(ms, 200)
            _ => fail("expected whole body timeout")
          } noraise {
            _ => fail("expected timeout")
          }
        }
        assert_true(closed.get())
      },
    )
  }
}

///|
async test "stream timeout is per read rather than total lifetime" {
  with_server(
    conn => {
      ignore(conn.read_request())
      conn.send_response(200, "OK")
      // Each gap is well under the per-read limit, their sum well over it.
      for _ in 0..<5 {
        conn.write(b"x")
        conn.flush()
        @async.sleep(300)
      }
      conn.end_response()
    },
    url => {
      let (_, stream) = @adapter.AsyncTransport::new(timeout_ms=1000).send_stream(
        @http.Request::get(url),
      )
      defer stream.close()
      let chunks = []
      while stream.read_some() is Some(chunk) {
        chunks.push(chunk)
      }
      assert_eq(chunks, [b"x", b"x", b"x", b"x", b"x"])
    },
  )
}

///|
async test "a stream read returns at most 64 KiB however much has arrived" {
  let body = Bytes::make(1_000_000, b'x')
  with_server(
    conn => {
      ignore(conn.read_request())
      reply(conn, 200, body)
    },
    url => {
      let (_, stream) = @adapter.AsyncTransport::new().send_stream(
        @http.Request::get(url),
      )
      defer stream.close()
      let mut total = 0
      let mut largest = 0
      while stream.read_some() is Some(chunk) {
        total += chunk.length()
        largest = largest.max(chunk.length())
      }
      assert_eq(total, body.length())
      assert_true(largest <= 64 * 1024, msg="largest read: \{largest}")
    },
  )
}

///|
async test "closed loopback port is Connect" {
  @async.with_timeout(5000, () => {
    let server = @ahttp.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    server.close()
    try
      @adapter.AsyncTransport::new().send(
        @http.Request::get("http://127.0.0.1:\{port}"),
      )
    catch {
      @http.HttpError::Connect(_) => ()
      _ => fail("expected Connect")
    } noraise {
      _ => fail("expected connection failure")
    }
  })
}

///|
async test "outer cancellation bypasses catch and closes the in-flight request" {
  for streaming in [false, true] {
    let ready = @async.Queue(kind=Unbounded)
    let closed = @async.Queue(kind=Unbounded)
    let mut caught = false
    let mut cancelled = false
    with_server(
      conn => {
        ignore(conn.read_request())
        ready.put(true)
        try conn.read_request() catch {
          @io.ReaderClosed => closed.put(true)
          error => raise error
        } noraise {
          _ => fail("expected close on cancellation")
        }
      },
      url => {
        let result = @async.with_timeout_opt(200, () => {
          @async.with_task_group(group => {
            group.spawn_bg(() => {
              defer {
                cancelled = @async.is_being_cancelled()
              }
              let transport = @adapter.AsyncTransport::new(timeout_ms=2000)
              try {
                if streaming {
                  ignore(transport.send_stream(@http.Request::get(url)))
                } else {
                  ignore(transport.send(@http.Request::get(url)))
                }
              } catch {
                _ => caught = true
              }
            })
            assert_true(ready.get())
          })
        })
        assert_eq(result, None)
        assert_false(caught)
        assert_true(cancelled)
        assert_true(closed.get())
      },
    )
  }
}

///|
async test "max_body_bytes bounds buffered bodies but not streams" {
  // A body of exactly the limit passes.
  with_server(
    conn => {
      ignore(conn.read_request())
      reply(conn, 200, Bytes::make(1000, b'a'))
    },
    url => {
      let transport = @adapter.AsyncTransport::new(max_body_bytes=1000)
      let response = transport.send(@http.Request::get(url))
      assert_eq(response.body.length(), 1000)
    },
  )
  // One byte more fails and closes the connection.
  let closed = @async.Queue(kind=Unbounded)
  with_server(
    conn => {
      ignore(conn.read_request())
      // Writing into or reading from the closed connection may also see a reset.
      try {
        conn.send_response(200, "OK")
        conn.write(Bytes::make(600, b'a'))
        conn.flush()
        conn.write(Bytes::make(401, b'b'))
        conn.end_response()
        conn.read_request()
      } catch {
        _ => closed.put(true)
      } noraise {
        _ => fail("expected the client to close")
      }
    },
    url => {
      let transport = @adapter.AsyncTransport::new(max_body_bytes=1000)
      try transport.send(@http.Request::get(url)) |> ignore catch {
        @http.HttpError::Protocol(message) =>
          assert_eq(message, "response body larger than 1000 bytes")
        _ => fail("expected Protocol")
      } noraise {
        _ => fail("an oversized body was accepted")
      }
      assert_true(closed.get())
    },
  )
  // A stream's reader decides what to keep.
  with_server(
    conn => {
      ignore(conn.read_request())
      reply(conn, 200, Bytes::make(1001, b'a'))
    },
    url => {
      let transport = @adapter.AsyncTransport::new(max_body_bytes=10)
      let (_, stream) = transport.send_stream(@http.Request::get(url))
      let mut length = 0
      while stream.read_some() is Some(chunk) {
        length += chunk.length()
      }
      assert_eq(length, 1001)
    },
  )
}

///|
async test "max_body_bytes counts the decoded bytes of a gzip body" {
  // `gzip -n -9` of 1000 and 1001 bytes of 'a': 29 bytes each on the wire.
  let rows : Array[(String, Bytes, Result[Int32, String])] = [
    (
      "1000 decoded bytes at a limit of 1000",
      b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\x4b\x4c\x1c\x05\xa3\x60\x14\x0c\x77\x00\x00\x03\xda\x38\x9a\xe8\x03\x00\x00",
      Ok(1000),
    ),
    (
      "1001 decoded bytes at a limit of 1000",
      b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\x4b\x4c\x1c\x05\xa3\x60\x14\x0c\x7b\x00\x00\x23\xd7\x24\x71\xe9\x03\x00\x00",
      Err("response body larger than 1000 bytes"),
    ),
  ]
  for row in rows {
    let (label, gzipped, expected) = row
    with_server(
      conn => {
        ignore(conn.read_request())
        // The client may close before the response is written in full.
        try {
          conn.send_response(200, "OK", extra_headers={
            "Content-Encoding": "gzip",
          })
          conn.write(gzipped)
          conn.end_response()
        } catch {
          _ => ()
        }
      },
      url => {
        let transport = @adapter.AsyncTransport::new(max_body_bytes=1000)
        let outcome : Result[Int32, String] = try
          transport.send(@http.Request::get(url))
        catch {
          @http.HttpError::Protocol(message) => Err(message)
          error => Err("unexpected \{Repr(error)}")
        } noraise {
          response => Ok(response.body.length())
        }
        assert_eq(outcome, expected, msg=label)
      },
    )
  }
}
