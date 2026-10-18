// moonbitlang/async parses `Set-Cookie` into its own `Cookie` and drops the
// raw line; `response_head` rebuilds a line from those fields. These tests
// send raw lines over a socket and check that the cookie jar reads the
// rebuilt line as it reads the raw one.

///|
/// Serves one response whose head carries `set_cookie` as raw lines, then
/// runs `run` with the server's URL.
async fn with_set_cookies(
  set_cookie : Array[String],
  run : async (String) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        let (conn, _) = server.accept()
        defer conn.close()
        guard conn.read_until("\r\n\r\n") is Some(_) else {
          fail("missing request headers")
        }
        let head = StringBuilder()
        head.write_string("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n")
        for line in set_cookie {
          head.write_string("Set-Cookie: " + line + "\r\n")
        }
        head.write_string("\r\nok")
        conn.write(head.to_string())
      })
      run("http://127.0.0.1:\{server.addr.port()}")
    })
  })
}

///|
/// 2026-10-18T00:00:00Z.
const NOW : Int64 = 1_792_281_600_000L

///|
/// The cookies a fresh jar keeps from one `Set-Cookie` line. The request URL
/// is https so that Secure cookies are kept; only the parse is under test.
fn jar_reading(line : String) -> Array[@cookie.Cookie] {
  let jar = @cookie.CookieJar::new(@mock.FakeClock::new(start_unix_ms=NOW))
  jar.store(
    @http.Headers::from_array([("Set-Cookie", line)]),
    "https://www.example.com/dir/page",
  )
  jar.iter().collect()
}

///|
/// The rebuilt `Set-Cookie` lines of a response carrying `raw`.
async fn rebuilt(raw : Array[String]) -> Array[String] {
  let lines = []
  with_set_cookies(raw, url => {
    let response = @adapter.AsyncTransport::new().send(@http.Request::get(url))
    assert_eq(response.status, 200)
    lines.push_iter(response.headers.get_all("set-cookie").iter())
  })
  lines
}

///|
async test "rebuilt Set-Cookie lines keep SameSite and every other attribute" {
  let raw = [
    "s1=v; SameSite=Lax", "s2=v; SameSite=Strict; Secure", "s3=v; samesite=none; Secure; Partitioned",
    "s4=v; Path=/dir; Domain=.example.com; Max-Age=3600; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Secure; HttpOnly; SameSite=Lax; Priority=High",
    "s5=v; SameSite=Strict; HttpOnly; Path=/; Secure", "s6=v; Expires=Wed, 09 Jun 2027 10:18:14 GMT",
    "s7=a=b=c; path=/dir", "s8=v; Path=/a; Path=/dir", "s9=v; SameSite=Strict; SameSite=Lax",
    "s10=v; Max-Age=0", "s11=v;Path=/dir;HttpOnly;SameSite=Lax", "s12=", "s13=v; Domain=",
    "s14=v; Version=1; Comment=hi", "s15=v; Path", "s16=v; Secure=yes", "s17=v; Max-Age=-1; Domain=example.com",
    "s18=v; Expires=bogus; Max-Age=60",
  ]
  let lines = rebuilt(raw)
  assert_eq(lines.length(), raw.length())
  for i, line in raw {
    assert_eq(
      jar_reading(lines[i]),
      jar_reading(line),
      msg="\{line} -> \{lines[i]}",
    )
  }
  let same_site = raw[:3]
    .iter()
    .map(line => jar_reading(line)[0].same_site)
    .collect()
  assert_eq(same_site, [
    Some(@cookie.SameSite::Lax),
    Some(@cookie.SameSite::Strict),
    Some(@cookie.SameSite::NoRestriction),
  ])
}

///|
/// moonbitlang/async 0.22.5 keeps one value per attribute, the last, even an
/// empty or invalid one, where RFC 6265 §5.2 ignores those and keeps the
/// earlier valid value; it also reads `Max-Age=+60` as 60, which §5.2.2
/// ignores. The rebuilt line can only carry what was kept. Pinned here so
/// that an upstream fix shows up.
async test "attributes moonbitlang/async keeps only the last of are lost" {
  let raw = [
    "l1=v; Domain=example.com; Domain=", "l2=v; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Expires=bogus",
    "l3=v; Max-Age=+60",
  ]
  let lines = rebuilt(raw)
  assert_eq(lines, ["l1=v; Domain=", "l2=v; Expires=bogus", "l3=v; Max-Age=60"])
  let raw_read = raw.map(line => jar_reading(line)[0])
  let rebuilt_read = lines.map(line => jar_reading(line)[0])
  assert_eq(raw_read[0].domain, "example.com")
  assert_eq(rebuilt_read[0].domain, "www.example.com")
  assert_true(raw_read[1].expires_ms is Some(_))
  assert_eq(rebuilt_read[1].expires_ms, None)
  assert_eq(raw_read[2].expires_ms, None)
  assert_eq(rebuilt_read[2].expires_ms, Some(NOW + 60_000L))
}

///|
/// moonbitlang/async 0.22.5 refuses a whole response for a `Set-Cookie`
/// without `=` or with a `Max-Age` that is not an Int64, which RFC 6265 §5.2
/// ignores (the line, or the attribute). `send` raises `Protocol`; this
/// cannot be fixed after the parse. Pinned so that an upstream fix shows up.
async test "Set-Cookie lines moonbitlang/async refuses fail the whole response" {
  let refused = [
    "nameonly", "x=v; Max-Age=soon", "x=v; Max-Age=3600, c=d", "x=v; Max-Age=99999999999999999999",
  ]
  for line in refused {
    let outcome = try rebuilt([line]) catch {
      @http.HttpError::Protocol(_) => "Protocol"
      _ => "other error"
    } noraise {
      _ => "accepted"
    }
    assert_eq(outcome, "Protocol", msg=line)
  }
  // The jar itself ignores the first line and keeps the other cookies.
  assert_eq(refused.map(line => jar_reading(line).length()), [0, 1, 1, 1])
}
