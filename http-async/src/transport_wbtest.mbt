///|
/// Feeds `chunks` to `read_bounded` and labels the outcome with the number of
/// chunks it read.
async fn bounded_label(chunks : Array[Bytes], max_bytes : Int32) -> String {
  let mut reads = 0
  let read : async () -> Bytes? = () => {
    reads += 1
    chunks.get(reads - 1)
  }
  let outcome = try read_bounded(read, max_bytes) catch {
    @http.HttpError::Protocol(message) => message
    error => "unexpected \{Repr(error)}"
  } noraise {
    body => "\{body.length()} bytes"
  }
  "\{outcome} after \{reads} reads"
}

///|
async test "read_bounded stops at the chunk that crosses the limit" {
  let rows : Array[(Array[Bytes], Int32, String)] = [
    ([], 0, "0 bytes after 1 reads"),
    ([b"ab"], 2, "2 bytes after 2 reads"),
    ([b"a", b"", b"b"], 2, "2 bytes after 4 reads"),
    ([b"ab", b"c"], 2, "response body larger than 2 bytes after 2 reads"),
    ([b"abc", b"d"], 2, "response body larger than 2 bytes after 1 reads"),
    ([b"a"], 0, "response body larger than 0 bytes after 1 reads"),
  ]
  for row in rows {
    let (chunks, max_bytes, expected) = row
    assert_eq(bounded_label(chunks, max_bytes), expected)
  }
}

///|
/// What `read_bounded` makes of `chunks`: the body, or the `Protocol` message.
async fn bounded_outcome(
  chunks : Array[Bytes],
  max_bytes : Int32,
) -> Result[Bytes, String] {
  let mut next = 0
  let read : async () -> Bytes? = () => {
    next += 1
    chunks.get(next - 1)
  }
  try read_bounded(read, max_bytes) catch {
    @http.HttpError::Protocol(message) => Err(message)
    error => Err("unexpected \{Repr(error)}")
  } noraise {
    body => Ok(body)
  }
}

///|
/// Cuts `body` at random points, sometimes leaving empty chunks in between.
fn random_chunks(rand : @random.Rand, body : Bytes) -> Array[Bytes] {
  let chunks = []
  let mut start = 0
  while start < body.length() {
    let end = start + rand.int(limit=body.length() - start + 1)
    chunks.push(body[start:end].to_owned())
    start = end
  }
  if rand.int(limit=4) == 0 {
    chunks.push(b"")
  }
  chunks
}

///|
async test "read_bounded does not depend on how the body is chunked" {
  for seed in 0..<4 {
    let rand = @random.Rand::chacha8(seed=Bytes::make(32, seed.to_byte()))
    for trial in 0..<50 {
      let body = Bytes::from_array(
        Array::makei(rand.int(limit=40), _ => rand.int(limit=256).to_byte()),
      )
      let len = body.length()
      for max_bytes in [0, len - 1, len, len + 1] {
        guard max_bytes >= 0 else { continue }
        let whole = bounded_outcome([body], max_bytes)
        let oracle : Result[Bytes, String] = if len <= max_bytes {
          Ok(body)
        } else {
          Err("response body larger than \{max_bytes} bytes")
        }
        assert_eq(whole, oracle, msg="seed \{seed} trial \{trial}")
        for _ in 0..<8 {
          let chunks = random_chunks(rand, body)
          let lengths = chunks.map(chunk => chunk.length().to_string())
          assert_eq(
            bounded_outcome(chunks, max_bytes),
            whole,
            msg="seed \{seed} trial \{trial} limit \{max_bytes} chunks [\{lengths.join(",")}]",
          )
        }
      }
    }
  }
}

///|
/// `name: value` pairs in iteration order, joined by `"; "`.
fn pairs_label(pairs : Iter[(String, String)]) -> String {
  pairs.map(pair => "\{pair.0}: \{pair.1}").collect().join("; ")
}

///|
fn wire_label(headers : Array[(String, String)]) -> String {
  let (wire, user_agent) = wire_headers(@http.Headers::from_array(headers))
  let sent = pairs_label(wire.iter().map(pair => (pair.0.0, pair.1)))
  let user_agent = match user_agent {
    None => "no user agent"
    Some(value) => "user agent \{value}"
  }
  "[\{sent}] \{user_agent}"
}

///|
test "wire_headers joins duplicates and pulls out the user agent" {
  let rows : Array[(Array[(String, String)], String)] = [
    ([], "[] no user agent"),
    ([("accept", "*/*")], "[accept: */*] no user agent"),
    ([("user-agent", "a/1")], "[] user agent a/1"),
    (
      [("user-agent", "a/1"), ("accept", "*/*"), ("User-Agent", "b/2")],
      "[accept: */*] user agent a/1, b/2",
    ),
    ([("content-length", "3"), ("x", "y")], "[x: y] no user agent"),
    ([("transfer-encoding", "chunked"), ("x", "y")], "[x: y] no user agent"),
    ([("Content-Length", "3")], "[] no user agent"),
    (
      [("accept", "a"), ("x", "y"), ("accept", "b")],
      "[accept: a, b; x: y] no user agent",
    ),
    (
      [("X-Trace", "1"), ("x-trace", "2"), ("X-TRACE", "3")],
      "[x-trace: 1, 2, 3] no user agent",
    ),
  ]
  for row in rows {
    let (headers, expected) = row
    assert_eq(wire_label(headers), expected, msg=pairs_label(headers.iter()))
  }
}

///|
fn split_url_label(url : String) -> String {
  try split_url(url) catch {
    @http.HttpError::Protocol(message) => "error: \{message}"
    error => "unexpected \{Repr(error)}"
  } noraise {
    (origin, path) => "\{origin.text} \{path}"
  }
}

///|
test "split_url separates the origin from the request target" {
  let rows : Array[(String, String)] = [
    ("http://example.com", "http://example.com /"),
    ("https://example.com/", "https://example.com /"),
    ("HTTPS://Example.com/a", "https://example.com /a"),
    ("http://EXAMPLE.com:80/a", "http://example.com /a"),
    ("https://example.com:443", "https://example.com /"),
    ("http://example.com:443/", "http://example.com:443 /"),
    ("http://[2001:DB8:0:0:0:0:0:1]:8080/", "http://[2001:db8::1]:8080 /"),
    ("http://example.com:8080/a/b", "http://example.com:8080 /a/b"),
    ("http://example.com?q=1", "http://example.com /?q=1"),
    ("http://example.com/a?q=/b", "http://example.com /a?q=/b"),
    ("http://example.com/a#frag", "http://example.com /a"),
    ("http://example.com/a?q=1#f?g", "http://example.com /a?q=1"),
    ("http://example.com#/a", "http://example.com /"),
    ("http://user@example.com/", "http://example.com /"),
    ("http://a:b@EXAMPLE.com:80/x", "http://example.com /x"),
    ("example.com/a", "error: expected an absolute HTTP URL"),
    ("ftp://example.com/", "error: unsupported URL scheme: ftp"),
    ("ws://example.com/", "error: unsupported URL scheme: ws"),
    ("://example.com/", "error: unsupported URL scheme: "),
    (
      "http://[::1/", "error: invalid URL authority: IP literal without a closing bracket",
    ),
    ("http:///a", "error: empty URL authority"),
    ("http://?q=1", "error: empty URL authority"),
    ("http://#a", "error: empty URL authority"),
  ]
  for row in rows {
    let (url, expected) = row
    assert_eq(split_url_label(url), expected, msg=url)
  }
}

///|
test "request_method accepts the standard methods in any case" {
  let rows : Array[(String, @ahttp.RequestMethod?)] = [
    ("GET", Some(Get)),
    ("get", Some(Get)),
    ("Head", Some(Head)),
    ("POST", Some(Post)),
    ("put", Some(Put)),
    ("DELETE", Some(Delete)),
    ("CONNECT", Some(Connect)),
    ("options", Some(Options)),
    ("TRACE", Some(Trace)),
    ("PATCH", Some(Patch)),
    ("", None),
    ("PURGE", None),
    (" GET", None),
  ]
  for row in rows {
    let (meth, expected) = row
    let actual = try request_method(meth) catch {
      @http.HttpError::Protocol(message) => {
        assert_eq(message, "unknown HTTP method: " + meth, msg=meth)
        None
      }
      error => fail("unexpected \{Repr(error)}")
    } noraise {
      meth => Some(meth)
    }
    assert_eq(actual, expected, msg=meth)
  }
}

///|
fn response_head_label(
  code : Int32,
  headers : Array[(String, String)],
  cookies : Array[@ahttp.Cookie],
) -> String {
  let head = response_head({
    code,
    reason: "",
    headers: Map(
      headers.map(pair => (@ahttp.CaseInsensitiveString(pair.0), pair.1)),
    ),
    cookies,
  })
  "\{head.status} [\{pairs_label(head.headers.iter())}]"
}

///|
test "response_head keeps headers and serializes each cookie" {
  let rows : Array[
    (Int32, Array[(String, String)], Array[@ahttp.Cookie], String),
  ] = [
    (204, [], [], "204 []"),
    (
      200,
      [("Content-Type", "text/plain"), ("X-A", "1")],
      [],
      "200 [content-type: text/plain; x-a: 1]",
    ),
    (200, [], [@ahttp.Cookie("a", "1")], "200 [set-cookie: a=1]"),
    (200, [], [@ahttp.Cookie("a", "")], "200 [set-cookie: a=]"),
    (
      302,
      [("Location", "/")],
      [
        @ahttp.Cookie(
          "s",
          "v",
          path="/",
          expires_raw="Wed, 21 Oct 2026 07:28:00 GMT",
          max_age=60,
          domain="example.com",
          secure=true,
          http_only=true,
          extensions=["SameSite=Lax", "Partitioned"],
        ),
      ],
      "302 [location: /; set-cookie: s=v; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Max-Age=60; Domain=example.com; Secure; HttpOnly; SameSite=Lax; Partitioned]",
    ),
    (
      200,
      [],
      [@ahttp.Cookie("a", "1", secure=true), @ahttp.Cookie("b", "2", max_age=0)],
      "200 [set-cookie: a=1; Secure; set-cookie: b=2; Max-Age=0]",
    ),
  ]
  for row in rows {
    let (code, headers, cookies, expected) = row
    assert_eq(response_head_label(code, headers, cookies), expected)
  }
}

///|
test "the exchange timeout defaults to 30 s" {
  // The loopback tests check what the timeout bounds; this pins its default.
  assert_eq(AsyncTransport::new().limits.total, 30000)
}
