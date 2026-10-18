///|
// A raw TCP proxy for one test, under the 5 s deadline of the other socket
// tests: each accepted connection goes to `handler`, which owns it. `run` gets
// the port and a count of the connections accepted so far.
async fn with_proxy(
  handler : async (@socket.Tcp) -> Unit,
  run : async (Int32, () -> Int32) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let accepted = Ref(0)
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        for ;; {
          let (conn, _) = server.accept()
          accepted.val += 1
          group.spawn_bg(no_wait=true, () => {
            defer conn.close()
            handler(conn) catch {
              _ => ()
            }
          })
        }
      })
      run(server.addr.port(), () => accepted.val)
    })
  })
}

///|
/// The request line of a raw request head, and the value of its header
/// `name`, or `-`.
fn head_summary(head : String, name : String) -> String {
  let lines = head.split("\r\n").to_array()
  let mut value = "-"
  for line in lines[1:] {
    if line.to_lower().has_prefix(name + ":") {
      value = line[name.length() + 1:].trim().to_owned()
    }
  }
  lines[0].to_owned() + " | " + value
}

///|
fn has_bytes(haystack : Bytes, needle : Bytes) -> Bool {
  for start in 0..<=(haystack.length() - needle.length()) {
    if haystack[start:start + needle.length()] == needle[:] {
      return true
    }
  }
  false
}

///|
/// What a failed `send` raised, without a message whose wording the OS
/// decides.
async fn failure_of(
  transport : @adapter.AsyncTransport,
  request : @http.Request,
) -> String {
  try transport.send(request) catch {
    @http.HttpError::Connect(_) as error =>
      "Connect, unsent=\{error.is_unsent()}"
    @http.HttpError::Proxy(status~, message~) as error =>
      "Proxy(status=\{status}, message=\{message}), unsent=\{error.is_unsent()}"
    error => @debug.to_string(error)
  } noraise {
    response => "status \{response.status}"
  }
}

///|
async test "an http request is forwarded to the proxy with its credentials" {
  let seen = []
  with_proxy(
    conn => {
      while conn.read_until("\r\n\r\n") is Some(head) {
        seen.push(head_summary(head, "proxy-authorization"))
        conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nforwarded")
      }
    },
    (port, connections) => {
      let transport = @adapter.AsyncTransport::new(
        proxy="http://user:se%40cret@127.0.0.1:\{port}",
        trust_env=false,
      )
      for path in ["/a?q=1", "/b"] {
        let response = transport.send(
          @http.Request::get("http://Origin.TEST" + path),
        )
        assert_eq(response.body, b"forwarded")
      }
      // Both requests went over one connection to the proxy, parked between.
      assert_eq(connections(), 1)
      assert_eq(transport.idle_connections(), 1)
      transport.close()
    },
  )
  assert_eq(seen, [
    "GET http://origin.test/a?q=1 HTTP/1.1 | Basic dXNlcjpzZUBjcmV0", "GET http://origin.test/b HTTP/1.1 | Basic dXNlcjpzZUBjcmV0",
  ])
}

///|
async test "an https request opens a CONNECT tunnel and runs TLS inside it" {
  let seen = []
  with_proxy(
    conn => {
      guard conn.read_until("\r\n\r\n") is Some(head) else { return }
      seen.push(head_summary(head, "proxy-authorization"))
      seen.push(head_summary(head, "user-agent"))
      conn.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
      // What the client sends next is for the origin: a TLS ClientHello
      // naming it.
      let tunnel = Buffer()
      while tunnel.length() < 16384 &&
            !has_bytes(tunnel.contents(), b"origin.test") {
        guard conn.read_some() is Some(chunk) else { break }
        tunnel.write_bytes(chunk)
      }
      let bytes = tunnel.contents()
      seen.push(
        "handshake=\{bytes.length() > 0 && bytes[0] == 0x16} sni=\{has_bytes(bytes, b"origin.test")}",
      )
    },
    (port, _) => {
      let transport = @adapter.AsyncTransport::new(
        proxy="http://alice:s3cret@127.0.0.1:\{port}",
        trust_env=false,
      )
      // The proxy hangs up mid-handshake, which fails the dial.
      assert_eq(
        failure_of(
          transport,
          @http.Request::get("https://origin.test/x").header(
            "User-Agent", "agent-t",
          ),
        ),
        "Connect, unsent=true",
      )
    },
  )
  assert_eq(seen, [
    "CONNECT origin.test:443 HTTP/1.1 | Basic YWxpY2U6czNjcmV0", "CONNECT origin.test:443 HTTP/1.1 | agent-t",
    "handshake=true sni=true",
  ])
}

///|
async test "a refused tunnel raises Proxy with the proxy's status" {
  with_proxy(
    conn => {
      ignore(conn.read_until("\r\n\r\n"))
      conn.write(
        b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"p\"\r\nContent-Length: 0\r\n\r\n",
      )
    },
    (port, _) => {
      let transport = @adapter.AsyncTransport::new(
        proxy="http://127.0.0.1:\{port}",
        trust_env=false,
      )
      assert_eq(
        failure_of(transport, @http.Request::get("https://origin.test/")),
        "Proxy(status=407, message=the proxy refused the tunnel: 407 Proxy Authentication Required), unsent=true",
      )
      // A forwarded request gets the proxy's answer as its response.
      assert_eq(
        failure_of(transport, @http.Request::get("http://origin.test/")),
        "status 407",
      )
    },
  )
}

///|
async test "a redirect to another origin is routed by its own URL" {
  let seen = []
  with_proxy(
    conn => {
      guard conn.read_until("\r\n\r\n") is Some(head) else { return }
      seen.push(head_summary(head, "host"))
      if head.has_prefix("CONNECT") {
        conn.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
      } else {
        conn.write(
          b"HTTP/1.1 302 Found\r\nLocation: https://secure.test/next\r\nContent-Length: 0\r\n\r\n",
        )
      }
    },
    (port, connections) => {
      let transport = @adapter.AsyncTransport::new(
        proxy="http://127.0.0.1:\{port}",
        trust_env=false,
      )
      let outcome = try {
        ignore(
          @http.follow_redirects(
            @http.Request::get("http://plain.test/start"),
            request => transport.send(request),
          ),
        )
        "followed"
      } catch {
        @http.RedirectError::Transport(Proxy(status~, ..)) => "Proxy \{status}"
        error => @debug.to_string(error)
      }
      assert_eq(outcome, "Proxy 403")
      assert_eq(connections(), 2)
    },
  )
  // The first request was forwarded, the redirect target tunnelled.
  // moonbitlang/async names the dialed proxy in `Host`; RFC 9112 §3.2.2
  // has a proxy take the target from the absolute form instead.
  assert_eq(seen.length(), 2)
  assert_true(seen[0].has_prefix("GET http://plain.test/start HTTP/1.1 | "))
  assert_true(seen[1].has_prefix("CONNECT secure.test:443 HTTP/1.1 | "))
}

///|
async test "a proxy that cannot be reached fails with Connect" {
  let port = @async.with_timeout(5000, () => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    server.close()
    port
  })
  let transport = @adapter.AsyncTransport::new(
    proxy="http://127.0.0.1:\{port}",
    trust_env=false,
    timeout_ms=2000,
  )
  for url in ["http://origin.test/", "https://origin.test/"] {
    assert_eq(
      failure_of(transport, @http.Request::get(url)),
      "Connect, unsent=true",
    )
  }
}

///|
async test "an unusable proxy URL fails the request before anything is sent" {
  let transport = @adapter.AsyncTransport::new(
    proxy="socks5://127.0.0.1:1080",
    trust_env=false,
  )
  assert_eq(
    failure_of(transport, @http.Request::get("https://origin.test/")),
    "Protocol(\"unsupported proxy scheme socks5: only http and https proxies are supported\")",
  )
}
