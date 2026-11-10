///|
const BASE = "https://badhttp.dev"

///|
async fn bounded(f : async () -> Unit) -> Unit {
  @async.with_timeout(25000, f)
}

///|
fn transport(timeout_ms~ : Int32 = 15000) -> @runtime.Client {
  @runtime.Client::new(
    @codings.Decompress::new(@backend.AsyncBackend::new()),
    @adapter.AsyncClock::new(),
    timeout_ms~,
    read_idle_ms=timeout_ms,
  )
}

///|
fn client(retry? : @runtime.RetryPolicy) -> @runtime.Client {
  @runtime.Client::new(
    @codings.Decompress::new(@backend.AsyncBackend::new()),
    @adapter.AsyncClock::new(),
    base_url=BASE,
    timeout_ms=15000,
    retry?,
  )
}

///|
/// Collects (event, data, id) triples of one SSE flavor.
async fn events(flavor : String) -> Array[(String, String, String?)] {
  let c = transport()
  defer c.close()
  let out = []
  let reply = c.send(
    @runtime.request(
      @http.Request::get("\{BASE}/sse/\{flavor}").header(
        "accept", "text/event-stream",
      ),
    ).response(
      @runtime.as_sse(event => out.push((event.event, event.data, event.id))),
    ),
  )
  assert_eq(reply.status, 200)
  reply.body.unwrap()
  out
}

///|
async test "sse ok, crlf and bare cr yield the same three events" {
  bounded(() => {
    for flavor in ["ok?events=3&interval=10", "crlf", "cr"] {
      let got = events(flavor)
      assert_eq(got.length(), 3, msg=flavor)
      for i, e in got {
        assert_eq(e.0, "tick", msg=flavor)
        assert_eq(e.2, Some((i + 1).to_string()), msg=flavor)
        assert_true(e.1.has_prefix("{\"n\":\{i + 1},\"of\":3,"), msg=flavor)
        assert_false(e.1.contains("\r"), msg=flavor)
      }
    }
  })
}

///|
async test "sse no-space strips exactly one leading space" {
  bounded(() => {
    let got = events("no-space").map(e => e.1)
    assert_eq(got, ["foo", " foo", "", ""])
  })
}

///|
async test "sse multiline joins data lines and keeps colons" {
  bounded(() => {
    let got = events("multiline").map(e => e.1)
    assert_eq(got, ["line one\nline two\nline three", "key: value ", "a\n\nb"])
  })
}

///|
async test "sse comments, BOM and unknown fields are ignored" {
  bounded(() => {
    let got = events("comments")
    assert_eq(got.map(e => e.1), ["{\"n\":1}", "{\"n\":2}", "{\"n\":3}"])
    assert_eq(got.map(e => e.2), [Some("1"), Some("2"), Some("3")])
  })
}

///|
async test "sse split-utf8 decodes characters split across chunks" {
  bounded(() => {
    let got = events("split-utf8").map(e => e.1)
    assert_eq(got, ["🐍 ok", "€ ok"])
  })
}

///|
async test "sse cut discards the incomplete trailing event" {
  bounded(() => {
    let got = events("cut").map(e => e.1)
    assert_eq(got, ["complete"])
  })
}

///|
async test "sse big delivers a 256 KiB data line intact" {
  bounded(() => {
    let got = events("big?bytes=262144")
    assert_eq(got.length(), 1)
    assert_eq(got[0].1.length(), 262144)
  })
}

///|
async test "sse stall trips the idle timeout as Timeout" {
  bounded(() => {
    let t = transport(timeout_ms=1500)
    defer t.close()
    let mut seen = 0
    try
      t.send(
        @runtime.request(@http.Request::get("\{BASE}/sse/stall?seconds=6")).response(
          @runtime.as_sse(_ => seen += 1),
        ),
      )
      |> ignore
    catch {
      @http.TransportError(kind=Timeout(ms=1500), phase=Body, ..) => ()
      error => fail("expected a Body timeout, got \{@debug.to_string(error)}")
    } noraise {
      _ => fail("expected the stall to time out")
    }
    assert_true(seen >= 1)
  })
}

///|
async test "truncate: a short body under a longer Content-Length is a Body protocol failure" {
  bounded(() => {
    try
      transport().send(
        @runtime.request(
          @http.Request::get("\{BASE}/truncate?length=1000&send=500"),
        ).response(@runtime.as_bytes()),
      )
    catch {
      @http.TransportError(kind=Protocol, phase=Body, ..) => ()
      error => fail("expected Protocol(Body), got \{@debug.to_string(error)}")
    } noraise {
      response => fail("expected an error, got status \{response.status}")
    }
  })
}

///|
async test "delay beyond the timeout is Timeout" {
  bounded(() => {
    let t = transport(timeout_ms=1000)
    defer t.close()
    try
      t.send(
        @runtime.request(@http.Request::get("\{BASE}/delay/3")).response(
          @runtime.as_bytes(),
        ),
      )
    catch {
      @http.TransportError(kind=Timeout(ms=1000), phase=Head, ..) => ()
      error => fail("expected a Head timeout, got \{@debug.to_string(error)}")
    } noraise {
      response => fail("expected an error, got status \{response.status}")
    }
  })
}

///|
async test "status 429 with retry-after classifies as RateLimited" {
  bounded(() => {
    let c = client(retry=@runtime.RetryPolicy::none())
    defer c.close()
    let reply = c.send(
      @runtime.request(@http.Request::get("/status/429?retry-after=1")).response(
        @runtime.as_bytes(),
      ),
    )
    guard reply.body is Err(@runtime.UnexpectedStatus(head, ..)) else {
      fail("expected status failure")
    }
    assert_eq(head.status, 429)
    assert_eq(@runtime.retry_after_ms(head.headers), Some(1000))
  })
}

///|
async test "generated badhttp fixture builds, decodes and classifies requests" {
  bounded(() => {
    let c = client(retry=@runtime.RetryPolicy::none())
    defer c.close()
    let headers_response = c.send(
      @runtime.request(@fixture.get_headers_request()).response(
        @runtime.as_bytes(),
      ),
    )
    assert_eq(headers_response.status, 200)
    guard @fixture.get_headers_decode(
        { status: headers_response.status, headers: headers_response.headers, },
        headers_response.body.unwrap(),
      )
      is Ok(Object(_)) else {
      fail("expected GET /headers to decode as a JSON object")
    }
    let echo_response = c.send(
      @runtime.request(@fixture.post_echo_request()).response(
        @runtime.as_bytes(),
      ),
    )
    assert_eq(echo_response.status, 200)
    guard @fixture.post_echo_decode(
        { status: echo_response.status, headers: echo_response.headers, },
        echo_response.body.unwrap(),
      )
      is Ok({ "method": String("POST"), .. }) else {
      fail("expected POST /echo to report method POST")
    }
    let limited = c.send(
      @runtime.request(@fixture.get_status_code_request("429", retry_after=1)).response(
        @runtime.as_bytes(),
      ),
    )
    assert_true(
      limited.body is Err(@runtime.UnexpectedStatus({ status: 429, .. }, ..)),
    )
    assert_eq(@runtime.retry_after_ms(limited.headers), Some(1000))
  })
}

///|
async test "status 503 then 200: the client retries and succeeds" {
  bounded(() => {
    // badhttp picks at random from a comma-separated list; with retries the
    // request eventually lands on 200. Short backoffs and many retries keep an
    // unlucky run of 503s (1 in 2^13 with 12 retries) inside the time bound.
    let default = @runtime.RetryPolicy::default().rule
    let policy = @runtime.RetryPolicy::from_rule({
      ..default,
      max_retries: 12,
      backoff: { ..default.backoff, base_ms: 50, max_ms: 200, },
    })
    let response = client(retry=policy).send(
      @runtime.request(@http.Request::get("/status/503,200")).response(
        @runtime.as_bytes(),
      ),
    )
    assert_eq(response.status, 200)
  })
}

///|
async test "badjson flavors become Decode, not a crash" {
  bounded(() => {
    for flavor in ["truncated", "trailing-comma", "single-quotes", "html"] {
      let c = client(retry=@runtime.RetryPolicy::none())
      defer c.close()
      let reply = c.send(
        @runtime.request(@http.Request::get("/badjson/\{flavor}")).response(
          @runtime.as_json_value(),
        ),
      )
      assert_true(
        reply.body is Err(@runtime.Deserialization(_, ..)),
        msg=flavor,
      )
    }
  })
}

///|
async test "redirects are returned as 3xx, not followed" {
  bounded(() => {
    let response = transport().send(
      @runtime.request(@http.Request::get("\{BASE}/redirect/2")).response(
        @runtime.as_bytes(),
      ),
    )
    assert_true(response.status >= 300 && response.status < 400)
    assert_true(response.headers.contains("location"))
  })
}

///|
fn header(map : Map[String, Json], name : String) -> Json {
  for k, v in map {
    if k.to_lower() == name {
      return v
    }
  }
  Json::null()
}

///|
async test "echo round-trips a Japanese JSON body and lowercases headers" {
  bounded(() => {
    let body : Json = { "message": "日本語のテスト", "n": 42 }
    let c = client(retry=@runtime.RetryPolicy::none())
    defer c.close()
    let json = c.send(
      @runtime.request(
        @http.Request::post("/echo").header("X-Probe", "MiXeD").body_json(body),
      ).response(@runtime.as_json_value()),
    ).body.unwrap()
    guard json is { "method": "POST", "body": echoed, "headers": headers, .. } else {
      fail("unexpected echo shape: \{json.stringify()}")
    }
    let echoed = match echoed {
      String(s) => @json.parse(s)
      other => other
    }
    assert_eq(echoed, body)
    guard headers is Object(map) else { fail("headers not an object") }
    let probe = header(map, "x-probe")
    assert_eq(probe, Json::string("MiXeD"))
    assert_true(
      header(map, "content-type").stringify().contains("application/json"),
    )
  })
}
