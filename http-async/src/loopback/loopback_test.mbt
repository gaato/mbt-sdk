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
  status : Int,
  body : Bytes,
) -> Unit {
  conn.send_response(status, "test", extra_headers={ "X-MiXeD": "yes" })
  conn.write(body)
  conn.end_response()
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
      assert_eq(request.headers.get("content-length"), None)
      let body = conn.read_all().binary()
      assert_eq(body, template.body)
      reply(conn, 200, body)
    },
    url => {
      let request = @http.Request::post(url + "?query=1")
        .json_body(json)
        .header("Content-Length", "1")
        .header("X-Repeat", "one")
        .header("x-repeat", "two")
      assert_eq(
        @adapter.AsyncTransport::new().send(request).body,
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
          @http.HttpError::Timeout(ms) => assert_eq(ms, 200)
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
            @http.HttpError::Timeout(ms) => assert_eq(ms, 200)
            _ => fail("expected idle timeout")
          } noraise {
            _ => fail("expected timeout")
          }
          assert_eq(stream.read_some(), None)
          stream.close()
        } else {
          try transport.send(request) catch {
            @http.HttpError::Timeout(ms) => assert_eq(ms, 200)
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
      for _ in 0..<4 {
        conn.write(b"x")
        conn.flush()
        @async.sleep(100)
      }
      conn.end_response()
    },
    url => {
      let (_, stream) = @adapter.AsyncTransport::new(timeout_ms=250).send_stream(
        @http.Request::get(url),
      )
      defer stream.close()
      let chunks = []
      while stream.read_some() is Some(chunk) {
        chunks.push(chunk)
      }
      assert_eq(chunks, [b"x", b"x", b"x", b"x"])
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
