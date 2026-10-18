///|
// A raw HTTP/1.1 server answering every request on every connection with
// `body`, under the 5 s deadline of the socket tests. `run` gets its port,
// the request lines it has seen, and a count of the connections it accepted.
async fn with_counting_server(
  body : String,
  run : async (Int32, Array[String], () -> Int32) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let seen = []
    let accepted = Ref(0)
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        for ;; {
          let (conn, _) = server.accept()
          accepted.val += 1
          group.spawn_bg(no_wait=true, () => {
            defer conn.close()
            try {
              while conn.read_until("\r\n\r\n") is Some(head) {
                seen.push(head.split("\r\n").to_array()[0].to_owned())
                conn.write(
                  "HTTP/1.1 200 OK\r\nContent-Length: \{body.length()}\r\n\r\n\{body}",
                )
              }
            } catch {
              _ => ()
            }
          })
        }
      })
      run(server.addr.port(), seen, () => accepted.val)
    })
  })
}

///|
async test "NO_PROXY sends its hosts direct and the rest through the proxy" {
  with_counting_server("direct", (origin_port, at_origin, origin_connections) => {
    with_counting_server("proxied", (proxy_port, at_proxy, proxy_connections) => {
      let env = Map::from_array([
        ("HTTP_PROXY", "127.0.0.1:\{proxy_port}"),
        ("NO_PROXY", "127.0.0.1"),
      ])
      let transport = {
        ..AsyncTransport::new(trust_env=false),
        proxies: configure_proxies(None, trust_env=true, name => env.get(name)),
      }
      for _ in 0..<2 {
        let direct = transport.send(
          @http.Request::get("http://127.0.0.1:\{origin_port}/d"),
        )
        assert_eq(direct.body, b"direct")
        // Same server, but by a name NO_PROXY does not list.
        let proxied = transport.send(
          @http.Request::get("http://localhost:\{origin_port}/p"),
        )
        assert_eq(proxied.body, b"proxied")
      }
      // Each route kept its own connection.
      assert_eq(origin_connections(), 1)
      assert_eq(proxy_connections(), 1)
      assert_eq(transport.idle_connections(), 2)
      transport.close()
      assert_eq(at_origin, ["GET /d HTTP/1.1", "GET /d HTTP/1.1"])
      assert_eq(at_proxy, [
        "GET http://localhost:\{origin_port}/p HTTP/1.1",
        "GET http://localhost:\{origin_port}/p HTTP/1.1",
      ])
    })
  })
}
