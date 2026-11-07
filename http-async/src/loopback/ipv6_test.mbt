// IPv6 literal hosts, as origins and as proxies, over the IPv6 loopback.

///|
/// Whether this host can dial the IPv6 loopback. moonbitlang/async resolves
/// every host, literals too, with getaddrinfo and `AI_ADDRCONFIG`, which
/// glibc answers with no address for `::1` when loopback is the host's only
/// IPv6 address, as in a Docker container without IPv6 (CI). There a test
/// prints a `skip:` line and passes, as the live tests do without their
/// credentials.
async fn ipv6_loopback(name : String) -> Bool {
  try {
    @socket.TcpServer(@socket.Addr::parse("[::1]:0")).close()
    ignore(@socket.Addr::resolve("::1", port=0))
  } catch {
    _ => {
      println("skip: \{name}: this host cannot dial the IPv6 loopback")
      return false
    }
  }
  true
}

///|
async test "an IPv6 literal origin is dialled and named in Host with brackets" {
  guard ipv6_loopback("IPv6 origin") else { return }
  let seen = []
  let port = Ref(0)
  with_proxy(
    bind="[::1]:0",
    conn => {
      guard conn.read_until("\r\n\r\n") is Some(head) else { return }
      seen.push(head_summary(head, "host"))
      conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    },
    (bound, _) => {
      port.val = bound
      let transport = @adapter.AsyncTransport::new(trust_env=false)
      // A non-canonical spelling of the same address.
      let response = transport.send(
        @http.Request::get("http://[0:0::1]:\{bound}/v6?q=1"),
      )
      assert_eq(response.status, 200)
      assert_eq(response.body, b"ok")
      transport.close()
    },
  )
  assert_eq(seen, ["GET /v6?q=1 HTTP/1.1 | [::1]:\{port.val}"])
}

///|
async test "an IPv6 literal proxy forwards and tunnels to IPv6 literal origins" {
  guard ipv6_loopback("IPv6 proxy") else { return }
  let seen = []
  with_proxy(
    bind="[::1]:0",
    conn => {
      while conn.read_until("\r\n\r\n") is Some(head) {
        seen.push(head_summary(head, "proxy-authorization"))
        if head.has_prefix("CONNECT") {
          conn.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        } else {
          conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nforwarded")
        }
      }
    },
    (port, connections) => {
      let transport = @adapter.AsyncTransport::new(
        proxy="http://user:pw@[::1]:\{port}",
        trust_env=false,
      )
      let response = transport.send(
        @http.Request::get("http://[2001:DB8::1]:8080/f"),
      )
      assert_eq(response.body, b"forwarded")
      // The CONNECT authority keeps the brackets (RFC 9112 §3.2.3); the
      // proxy's refusal shows the tunnel reached it.
      assert_eq(
        failure_of(transport, @http.Request::get("https://[2001:db8::1]/t")),
        "Proxy(status=403, message=the proxy refused the tunnel: 403 Forbidden), unsent=true",
      )
      assert_eq(connections(), 2)
      transport.close()
    },
  )
  assert_eq(seen, [
    "GET http://[2001:db8::1]:8080/f HTTP/1.1 | Basic dXNlcjpwdw==", "CONNECT [2001:db8::1]:443 HTTP/1.1 | Basic dXNlcjpwdw==",
  ])
}
