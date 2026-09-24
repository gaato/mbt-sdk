///|
const BASE = "https://badhttp.dev"

///|
async fn bounded(f : async () -> Unit) -> Unit {
  @async.with_timeout(25000, f)
}

///|
fn transport() -> @adapter.AsyncTransport {
  @adapter.AsyncTransport::new(timeout_ms=15000)
}

///|
fn client(retry? : @runtime.RetryPolicy) -> @runtime.Client {
  let retry : &@runtime.RetryDecider? = retry.map(policy => policy)
  @runtime.Client::new(
    transport(),
    @adapter.AsyncClock::new(),
    base_url=BASE,
    retry?,
  )
}

///|
/// Collects (event, data, id) triples of one SSE flavor.
async fn events(flavor : String) -> Array[(String, String, String?)] {
  let (head, stream) = transport().send_stream(
    @http.Request::get("\{BASE}/sse/\{flavor}").header(
      "accept", "text/event-stream",
    ),
  )
  assert_eq(head.status, 200)
  let out = []
  @sse.each_event(stream, event => out.push((event.event, event.data, event.id)))
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
    let t = @adapter.AsyncTransport::new(timeout_ms=1500)
    let (head, stream) = t.send_stream(
      @http.Request::get("\{BASE}/sse/stall?seconds=6"),
    )
    assert_eq(head.status, 200)
    let mut seen = 0
    try @sse.each_event(stream, _ => seen += 1) catch {
      @http.HttpError::Timeout(1500) => ()
      error => fail("expected Timeout(1500), got \{@debug.to_string(error)}")
    } noraise {
      _ => fail("expected the stall to time out")
    }
    assert_true(seen >= 1)
  })
}

///|
async test "truncate: a short body under a longer Content-Length is Protocol" {
  bounded(() => {
    try
      transport().send(
        @http.Request::get("\{BASE}/truncate?length=1000&send=500"),
      )
    catch {
      @http.HttpError::Protocol(_) => ()
      error => fail("expected Protocol, got \{@debug.to_string(error)}")
    } noraise {
      response => fail("expected an error, got status \{response.status}")
    }
  })
}

///|
async test "delay beyond the timeout is Timeout" {
  bounded(() => {
    let t = @adapter.AsyncTransport::new(timeout_ms=1000)
    try t.send(@http.Request::get("\{BASE}/delay/3")) catch {
      @http.HttpError::Timeout(1000) => ()
      error => fail("expected Timeout(1000), got \{@debug.to_string(error)}")
    } noraise {
      response => fail("expected an error, got status \{response.status}")
    }
  })
}

///|
async test "status 429 with retry-after classifies as RateLimited" {
  bounded(() => {
    try
      client(retry=@runtime.RetryPolicy::none()).send(
        @http.Request::get("/status/429?retry-after=1"),
      )
    catch {
      @runtime.RateLimited(retry_after_ms~, ..) =>
        assert_eq(retry_after_ms, Some(1000))
      error => fail("expected RateLimited, got \{@debug.to_string(error)}")
    } noraise {
      response => fail("expected an error, got status \{response.status}")
    }
  })
}

///|
async test "generated badhttp fixture builds, decodes and classifies requests" {
  bounded(() => {
    let c = client(retry=@runtime.RetryPolicy::none())
    let headers_response = c.send(@fixture.get_headers_request())
    assert_eq(headers_response.status, 200)
    guard @fixture.get_headers_decode(headers_response) is Object(_) else {
      fail("expected GET /headers to decode as a JSON object")
    }
    let echo_response = c.send(@fixture.post_echo_request())
    assert_eq(echo_response.status, 200)
    guard @fixture.post_echo_decode(echo_response)
      is { "method": String("POST"), .. } else {
      fail("expected POST /echo to report method POST")
    }
    try c.send(@fixture.get_status_code_request("429", retry_after=1)) catch {
      @runtime.RateLimited(retry_after_ms~, ..) =>
        assert_eq(retry_after_ms, Some(1000))
      error => fail("expected RateLimited, got \{@debug.to_string(error)}")
    } noraise {
      response => fail("expected an error, got status \{response.status}")
    }
  })
}

///|
async test "status 503 then 200: the client retries and succeeds" {
  bounded(() => {
    // badhttp picks at random from a comma-separated list; with retries the
    // request eventually lands on 200. Two 503s in a row cost two backoffs.
    let policy = { ..@runtime.RetryPolicy::default(), max_retries: 6, }
    let response = client(retry=policy).send(
      @http.Request::get("/status/503,200"),
    )
    assert_eq(response.status, 200)
  })
}

///|
async test "badjson flavors become Decode, not a crash" {
  bounded(() => {
    for flavor in ["truncated", "trailing-comma", "single-quotes", "html"] {
      try
        client(retry=@runtime.RetryPolicy::none()).send_json(
          @http.Request::get("/badjson/\{flavor}"),
        )
      catch {
        @runtime.Decode(..) => ()
        error =>
          fail("\{flavor}: expected Decode, got \{@debug.to_string(error)}")
      } noraise {
        json => fail("\{flavor}: expected Decode, got \{json.stringify()}")
      }
    }
  })
}

///|
async test "redirects are returned as 3xx, not followed" {
  bounded(() => {
    let response = transport().send(@http.Request::get("\{BASE}/redirect/2"))
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
    let json = client(retry=@runtime.RetryPolicy::none()).send_json(
      @http.Request::post("/echo").header("X-Probe", "MiXeD").json_body(body),
    )
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
