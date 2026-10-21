// badhttp.dev's responses, recorded by scripts/capture_badhttp.mbtx, played
// back byte for byte by a loopback server, so the transport, the content
// decoders, the cookie jar, the SSE parser and redirects meet them without
// the network. The snapshots say what each layer makes of each response;
// the comments say why that is right, or record where it is not.

///|
fn unhex(text : String) -> Bytes {
  let digit = (c : UInt16) => {
    let c = c.to_int()
    if c >= '0'.to_int() && c <= '9'.to_int() {
      c - '0'.to_int()
    } else {
      c - 'a'.to_int() + 10
    }
  }
  Bytes::makei(text.length() / 2, i => {
    (digit(text[2 * i]) * 16 + digit(text[2 * i + 1])).to_byte()
  })
}

///|
fn capture(key : String) -> Bytes {
  unhex(captures[key])
}

///|
/// The body of a recorded response framed by `Content-Length`.
fn plain_body(raw : Bytes) -> Bytes {
  let text = @utf8.decode_lossy(raw)
  guard text.find("\r\n\r\n") is Some(_) else { abort("no head") }
  let mut end = 0
  for i in 0..<(raw.length() - 3) {
    if raw[i] == b'\r' &&
      raw[i + 1] == b'\n' &&
      raw[i + 2] == b'\r' &&
      raw[i + 3] == b'\n' {
      end = i + 4
      break
    }
  }
  raw[end:].to_owned()
}

///|
/// Serves `raw` to one connection, after reading its request head, then
/// closes it, and runs `client` with the server's port.
async fn replay(raw : Bytes, client : async (Int32) -> Unit) -> Unit {
  @async.with_timeout(10000, () => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(conn.read_until("\r\n\r\n"))
        conn.write(raw)
      })
      client(server.addr.port())
    })
  })
}

///|
fn transport() -> @adapter.AsyncTransport {
  @adapter.AsyncTransport::new(
    timeout_ms=5000,
    max_body_bytes=1024 * 1024,
    trust_env=false,
  )
}

///|
fn failure(error : Error) -> String {
  match error {
    @http.HttpError::Protocol(_) => "Protocol"
    @http.HttpError::Network(phase~, ..) => "Network(\{Repr(phase)})"
    @http.HttpError::Timeout(phase~, ..) => "Timeout(\{Repr(phase)})"
    @http.HttpError::Connect(_) => "Connect"
    _ => "other error"
  }
}

///|
/// What `send` makes of a recorded `compress` response: the body, named
/// when it is the document every flavor encodes, and the
/// `Content-Encoding` left on the head.
async fn compress_outcome(key : String, document : Bytes) -> String {
  let outcome = Ref("")
  replay(capture(key), port => {
    let response = transport().send(
      @http.Request::get("http://127.0.0.1:\{port}/compress"),
    ) catch {
      error => {
        outcome.val = failure(error)
        return
      }
    }
    let body = response.body
    let described = if body == document {
      "the document"
    } else if body.length() >= 2 && body[0] == b'\x1f' && body[1] == b'\x8b' {
      "gzip bytes (\{body.length()})"
    } else {
      "\{body.length()} other bytes"
    }
    let coding = match response.headers.get("content-encoding") {
      Some(value) => ", content-encoding \{value}"
      None => ""
    }
    outcome.val = described + coding
  })
  outcome.val
}

///|
async test "recorded compress responses decode as RFC 9110 and the codings define" {
  let document = plain_body(capture("compress.identity"))
  assert_eq(document.length(), 4096)
  let rows = []
  for
    flavor in [
      "ok", "br", "zstd", "deflate", "deflate-raw", "uppercase", "x-gzip", "double",
      "multi-member", "not-compressed", "undeclared", "truncated", "corrupt", "bad-crc",
      "trailing-garbage", "double-hidden", "unknown-coding", "empty", "wrong-length",
      "gzip-file", "bomb",
    ] {
    rows.push("\{flavor}: \{compress_outcome("compress.\{flavor}", document)}")
  }
  // Undone as declared, in any case and through the x-gzip alias and both
  // deflate shapes (RFC 9110 §8.4.1), two members included (RFC 1952 §2.2).
  // A body that is not what its coding says, is cut, corrupt, fails its CRC
  // or has bytes after the end is refused; an undeclared or doubly hidden
  // gzip body is left as it came; an unknown coding is left on the body
  // and the head. gzip-file is a download wrongly labelled Content-Encoding:
  // gzip, which is decoded as labelled; a caller that wants the file sets
  // Accept-Encoding itself, and the transport then leaves the body alone.
  // wrong-length ends before its Content-Length; bomb passes max_body_bytes.
  debug_inspect(
    rows,
    content=(
      #|[
      #|  "ok: the document",
      #|  "br: the document",
      #|  "zstd: the document",
      #|  "deflate: the document",
      #|  "deflate-raw: the document",
      #|  "uppercase: the document",
      #|  "x-gzip: the document",
      #|  "double: the document",
      #|  "multi-member: the document",
      #|  "not-compressed: Protocol",
      #|  "undeclared: gzip bytes (269)",
      #|  "truncated: Protocol",
      #|  "corrupt: Protocol",
      #|  "bad-crc: Protocol",
      #|  "trailing-garbage: Protocol",
      #|  "double-hidden: gzip bytes (269)",
      #|  "unknown-coding: the document, content-encoding badhttp",
      #|  "empty: 0 other bytes",
      #|  "wrong-length: Network(Body)",
      #|  "gzip-file: the document",
      #|  "bomb: Protocol",
      #|]
    ),
  )
}

///|
/// What a jar keeps from a recorded `cookies` response received through the
/// transport, for the request URL badhttp.dev answered.
async fn cookies_outcome(flavor : String) -> String {
  let outcome = Ref("")
  replay(capture("cookies.\{flavor}"), port => {
    let response = transport().send(
      @http.Request::get("http://127.0.0.1:\{port}/cookies/\{flavor}"),
    ) catch {
      error => {
        outcome.val = failure(error)
        return
      }
    }
    let jar = @cookie.CookieJar::new(
      @mock.FakeClock::new(start_unix_ms=1_792_540_800_000L),
    )
    jar.store(response.headers, "https://badhttp.dev/cookies/\{flavor}")
    let kept = jar
      .iter()
      .map(cookie => {
        let lifetime = match cookie.expires_ms {
          None => "session"
          Some(_) => "persistent"
        }
        let flags = [
          if cookie.secure {
            " secure"
          } else {
            ""
          },
          if cookie.host_only {
            ""
          } else {
            " domain=\{cookie.domain}"
          },
        ].join("")
        let value = if cookie.value.length() > 24 {
          "\{cookie.value.length()} bytes"
        } else {
          cookie.value
        }
        "\{cookie.name}=\{value} path=\{cookie.path} \{lifetime}\{flags}"
      })
      .collect()
    outcome.val = if kept.is_empty() { "nothing" } else { kept.join(" | ") }
  })
  outcome.val
}

///|
async test "recorded cookies responses reach the jar as RFC 6265bis-22 stores them" {
  let rows = []
  for
    flavor in [
      "ok", "folded", "many", "duplicate", "on-redirect", "conflicting-expiry", "bad-expires",
      "far-future", "wrong-domain", "public-suffix", "domain", "path-prefix", "name-prefixes",
      "quoted", "utf8", "nameless", "huge",
    ] {
    rows.push("\{flavor}: \{cookies_outcome(flavor)}")
  }
  // folded is one cookie whose value holds the comma (fields are never
  // split, RFC 6265 erratum 6093); quoted keeps the quotes and stops at the
  // first semicolon; Max-Age wins over a 1970 Expires; an ISO 8601 Expires
  // is ignored; 9999 is cut to 400 days; Domain=example.com and Domain=dev
  // are refused; of name-prefixes only the two valid ones stay; huge is
  // exactly 4096 bytes of name and value. nameless fails in the transport:
  // moonbitlang/async refuses a Set-Cookie without "=", which the jar would
  // keep (see loopback/cookie_roundtrip_test.mbt in http-async).
  debug_inspect(
    rows,
    content=(
      #|[
      #|  "ok: badhttp_ok=1 path=/cookies persistent",
      #|  "folded: badhttp_folded_a=1, badhttp_folded_b=2 path=/cookies persistent",
      #|  "many: badhttp_many_01=1 path=/cookies persistent | badhttp_many_02=1 path=/cookies persistent | badhttp_many_03=1 path=/cookies persistent | badhttp_many_04=1 path=/cookies persistent | badhttp_many_05=1 path=/cookies persistent | badhttp_many_06=1 path=/cookies persistent | badhttp_many_07=1 path=/cookies persistent | badhttp_many_08=1 path=/cookies persistent | badhttp_many_09=1 path=/cookies persistent | badhttp_many_10=1 path=/cookies persistent",
      #|  "duplicate: badhttp_dup=deep path=/cookies/echo persistent | badhttp_dup=shallow path=/cookies persistent",
      #|  "on-redirect: badhttp_redirect=1 path=/cookies persistent",
      #|  "conflicting-expiry: badhttp_conflict=alive path=/cookies persistent",
      #|  "bad-expires: badhttp_bad_expires=1 path=/cookies session",
      #|  "far-future: badhttp_far_future=1 path=/cookies persistent",
      #|  "wrong-domain: nothing",
      #|  "public-suffix: nothing",
      #|  "domain: badhttp_domain_dot=1 path=/cookies persistent domain=badhttp.dev | badhttp_domain=1 path=/cookies persistent domain=badhttp.dev",
      #|  "path-prefix: badhttp_path_prefix=1 path=/cookie persistent",
      #|  "name-prefixes: __Host-badhttp_good=1 path=/ persistent secure | __Secure-badhttp_good=1 path=/cookies persistent secure",
      #|  "quoted: badhttp_quoted=\"hello world\" path=/cookies persistent | badhttp_semi=\"semi path=/cookies persistent",
      #|  "utf8: badhttp_utf8=☃ path=/cookies persistent",
      #|  "nameless: Protocol",
      #|  "huge: badhttp_huge=4084 bytes path=/cookies persistent",
      #|]
    ),
  )
}

///|
/// The events, or the failure, `each_event` gives for a recorded `sse`
/// response read through `send_stream`.
async fn sse_outcome(flavor : String) -> String {
  let events = []
  let outcome = Ref("")
  replay(capture("sse.\{flavor}"), port => {
    let (head, stream) = transport().send_stream(
      @http.Request::get("http://127.0.0.1:\{port}/sse/\{flavor}"),
    ) catch {
      error => {
        outcome.val = failure(error)
        return
      }
    }
    let content_type = head.headers.get("content-type").unwrap_or("none")
    @sse.each_event(stream, event => {
      let data = if event.data.length() > 24 {
        "\{event.data.length()} bytes"
      } else {
        Repr(event.data).to_string()
      }
      events.push("\{event.event}:\{data}")
    }) catch {
      error => {
        outcome.val = "\{content_type}; \{events.join(" ")}; then \{failure(error)}"
        return
      }
    }
    outcome.val = "\{content_type}; \{events.join(" ")}"
  })
  outcome.val
}

///|
async test "recorded sse responses parse as the WHATWG event stream defines" {
  let rows = []
  for
    flavor in [
      "ok", "cut", "drop", "crlf", "cr", "no-space", "multiline", "comments", "split-utf8",
      "wrong-type", "error-event", "resume",
    ] {
    rows.push("\{flavor}: \{sse_outcome(flavor)}")
  }
  // cut drops the event no blank line ended; drop delivers what arrived,
  // then the reset; one space after the colon is stripped and no more; an
  // event named "error" is an ordinary event; resume is one connection
  // (each_event does not reconnect). wrong-type is parsed: each_event does
  // not check Content-Type, where a browser's EventSource would fail.
  debug_inspect(
    rows,
    content=(
      #|[
      #|  "ok: text/event-stream; charset=utf-8; tick:32 bytes tick:32 bytes tick:32 bytes tick:32 bytes tick:32 bytes",
      #|  "cut: text/event-stream; charset=utf-8; message:\"complete\"",
      #|  "drop: text/event-stream; charset=utf-8; tick:\"{\\\"n\\\":1}\"; then Network(Body)",
      #|  "crlf: text/event-stream; charset=utf-8; tick:32 bytes tick:32 bytes tick:32 bytes",
      #|  "cr: text/event-stream; charset=utf-8; tick:32 bytes tick:32 bytes tick:32 bytes",
      #|  "no-space: text/event-stream; charset=utf-8; message:\"foo\" message:\" foo\" message:\"\" message:\"\"",
      #|  "multiline: text/event-stream; charset=utf-8; message:28 bytes message:\"key: value \" message:\"a\\n\\nb\"",
      #|  "comments: text/event-stream; charset=utf-8; message:\"{\\\"n\\\":1}\" message:\"{\\\"n\\\":2}\" message:\"{\\\"n\\\":3}\"",
      #|  "split-utf8: text/event-stream; charset=utf-8; message:\"🐍 ok\" message:\"€ ok\"",
      #|  "wrong-type: text/plain; charset=utf-8; tick:32 bytes tick:32 bytes tick:32 bytes",
      #|  "error-event: text/event-stream; charset=utf-8; tick:\"{\\\"n\\\":1}\" error:80 bytes tick:\"{\\\"n\\\":3}\"",
      #|  "resume: text/event-stream; charset=utf-8; tick:\"{\\\"n\\\":1}\" tick:\"{\\\"n\\\":2}\" tick:\"{\\\"n\\\":3}\"",
      #|]
    ),
  )
}

///|
/// The status line and headers of a recorded response, with its
/// `Content-Length` body. The crosshost responses have no other framing.
fn parse_response(raw : Bytes) -> @http.Response {
  let body = plain_body(raw)
  let head = @utf8.decode_lossy(raw[:raw.length() - body.length()].to_owned())
  let lines = head.split("\r\n").map(line => line.to_owned()).collect()
  let status = @string.parse_int(lines[0][9:12].to_owned()) catch {
    _ => abort("bad status line")
  }
  let headers = @http.Headers::new()
  for line in lines[1:] {
    if line.split_once(":") is Some((name, value)) {
      headers.append(name.to_owned(), value.trim(chars=" ").to_owned())
    }
  }
  { status, headers, body, }
}

///|
/// The requests `follow_redirects` makes for a crosshost chain, with which
/// credentials each carries, and how the chain ends.
async fn crosshost_outcome(start : String) -> String {
  let hops = []
  let jar = @cookie.CookieJar::new(
    @mock.FakeClock::new(start_unix_ms=1_792_540_800_000L),
  )
  let send = fn(
    request : @http.Request,
  ) -> @http.Response raise @http.HttpError {
    let carried = [
      if request.headers.contains("authorization") {
        " authorization"
      } else {
        ""
      },
      match jar.header_for(request.url) {
        Some(cookies) => " cookie(\{cookies})"
        None => ""
      },
    ].join("")
    hops.push("\{request.url}\{carried}")
    guard captures.get(request.url) is Some(raw) else {
      raise @http.HttpError::Connect("not recorded")
    }
    let response = parse_response(unhex(raw))
    jar.store(response.headers, request.url)
    response
  }
  let request = @http.Request::get(start).header("Authorization", "Bearer t")
  let end = try @http.follow_redirects(request, r => send(r)) catch {
    error => "refused: \{Repr(error)}"
  } noraise {
    response => "\{response.status}"
  }
  "\{hops.join(" -> ")} => \{end}"
}

///|
async test "recorded crosshost redirects drop credentials at the boundaries" {
  let rows = []
  for
    path in [
      "https://badhttp.dev/crosshost/same-origin", "https://badhttp.dev/crosshost/to-subdomain",
      "https://alt.badhttp.dev/crosshost/from-subdomain", "https://badhttp.dev/crosshost/boomerang",
      "http://badhttp.dev/crosshost/scheme-upgrade", "https://badhttp.dev/crosshost/scheme-downgrade",
      "https://badhttp.dev/crosshost/port-change", "https://badhttp.dev/crosshost/relative-authority",
      "https://badhttp.dev/crosshost/jar",
    ] {
    rows.push(crosshost_outcome(path))
  }
  // Authorization goes only to the origin it was given for. It survives
  // the http:80 to https:443 upgrade of the same host, as httpx allows,
  // and is dropped for a subdomain, a parent domain, another port and a
  // protocol-relative location, and not restored when a chain returns. A
  // downgrade to http is refused. The jar sends the Domain=badhttp.dev
  // cookie to alt.badhttp.dev.
  debug_inspect(
    rows,
    content=(
      #|[
      #|  "https://badhttp.dev/crosshost/same-origin authorization -> https://badhttp.dev/crosshost/land authorization => 200",
      #|  "https://badhttp.dev/crosshost/to-subdomain authorization -> https://alt.badhttp.dev/crosshost/land => 200",
      #|  "https://alt.badhttp.dev/crosshost/from-subdomain authorization -> https://badhttp.dev/crosshost/land => 200",
      #|  "https://badhttp.dev/crosshost/boomerang authorization -> https://alt.badhttp.dev/crosshost/boomerang-return -> https://badhttp.dev/crosshost/land => 200",
      #|  "http://badhttp.dev/crosshost/scheme-upgrade authorization -> https://badhttp.dev/crosshost/land authorization => 200",
      #|  "https://badhttp.dev/crosshost/scheme-downgrade authorization => refused: Downgrade(location=\"http://badhttp.dev/crosshost/land\")",
      #|  "https://badhttp.dev/crosshost/port-change authorization -> https://badhttp.dev:8443/crosshost/land => 200",
      #|  "https://badhttp.dev/crosshost/relative-authority authorization -> https://alt.badhttp.dev/crosshost/land => 200",
      #|  "https://badhttp.dev/crosshost/jar authorization -> https://alt.badhttp.dev/crosshost/land cookie(badhttp_domain=domain-scoped-value) => 200",
      #|]
    ),
  )
}
