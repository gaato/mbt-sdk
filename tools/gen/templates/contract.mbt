///|
test "generated default URL, bucket, HTTP and transport failures" {
  let backend = @client.from_fn((request, _) => {
    assert_eq(request.url, @http.join_url(__BASE_URL__, "/contract-test"))
    assert_eq(request.attributes.get(@client.rate_limit_bucket), Some(__PROVIDER__ + ":"))
    @http.Response::new(400, headers=@http.Headers::of([("x-test", "retained")]), body=Bytes(b"{\"error\":\"bad\"}"))
  })
  let sdk = __CLIENT__::new(backend, @sim.FakeClock::new())
  match @driver.run_sync(() => sdk.send(@http.Request::get("/contract-test"))) {
    Err(Http(error)) => {
      assert_eq(error.head.status, 400)
      assert_eq(error.head.headers.get("x-test"), Some("retained"))
      assert_eq(error.body, b"{\"error\":\"bad\"}")
    }
    _ => fail("expected HTTP failure")
  }
  let failing = @client.from_fn((_, _) => raise @http.TransportError(kind=Network, phase=Body, detail="offline test"))
  let sdk = __CLIENT__::new(failing, @sim.FakeClock::new(), retry=@client.RetryPolicy::none())
  match @driver.run_sync(() => sdk.send(@http.Request::post("/contract-test"))) {
    Err(Transport(@http.TransportError(kind~, phase~, ..))) => {
      assert_true(kind is Network)
      assert_true(phase is Body)
    }
    _ => fail("expected transport failure")
  }
}

///|
test "generated header whitespace is a validation failure before I/O" {
  let count = Ref(0)
  let backend = @client.from_fn((_, _) => {
    count.val += 1
    @http.Response::new(200)
  })
  let sdk = __CLIENT__::new(backend, @sim.FakeClock::new())
  for value in [" leading", "trailing\t"] {
    let request = @http.Request::post("/contract-test").header("idempotency-key", value)
    assert_true(@driver.run_sync(() => sdk.send(request)) is Err(Validation(parameter="headers", ..)))
// BEGIN SSE
    assert_true(@driver.run_sync(() => sdk.stream(request, _ => ())) is Err(Validation(parameter="headers", ..)))
// END SSE
  }
  assert_eq(count.val, 0)
}

///|
test "generated client returns a transport failure for invalid runtime default headers" {
  let count = Ref(0)
  let backend = @client.from_fn((_, _) => {
    count.val += 1
    @http.Response::new(200)
  })
  let runtime = @client.Client::new(backend, @sim.FakeClock::new(),
    headers=@http.Headers::of([("x-test", " invalid")]),
  )
  let sdk = __CLIENT__::from_client(runtime)
  let request = @http.Request::get("/contract-test")
  @driver.run_sync(() => {
    assert_true(sdk.send(request) is Err(Transport(@http.TransportError(kind=Invalid, phase=Pool, ..))))
// BEGIN SSE
    assert_true(sdk.stream(request, _ => abort("invalid request reached the SSE callback")) is Err(Transport(@http.TransportError(kind=Invalid, phase=Pool, ..))))
// END SSE
  })
  assert_eq(count.val, 0)
}

// BEGIN SSE
///|
test "generated stream propagates nested request validation from its callback" {
  let clock = @sim.FakeClock::new()
  let backend = @client.from_fn((_, _) => @http.Response::new(200, body=Bytes(b"data: callback\n\n")))
  let nested_backend = @client.from_fn((_, _) => abort("invalid nested request reached the backend"))
  let nested = @client.Client::new(nested_backend, clock)
  let sdk = __CLIENT__::new(backend, clock)
  @driver.run_sync(() => {
    let invalid = @http.Request::get("https://nested.example").header("x-test", " invalid")
    let outer = sdk.stream(@http.Request::get("/contract-test"), _ => {
      ignore(nested.send(@client.request(invalid).response(@client.as_bytes())))
    }) catch {
      @http.TransportError(kind=Invalid, phase=Pool, ..) => return
      error => raise error
    }
    fail("expected the nested request error to raise, got " + @debug.to_string(outer))
  })
}

// END SSE
///|
test "generated base override, paginator termination and SSE stop" {
  let count = Ref(0)
  let backend = @client.from_fn((request, _) => {
    assert_true(request.url.has_prefix("https://override.example/"))
    count.val += 1
    @http.Response::new(200, body=Bytes(if count.val == 1 {
      b"{\"results\":[1],\"next\":\"https://override.example/page2\"}"
    } else {
      b"{\"results\":[2],\"next\":null}"
    }))
  })
  let sdk = __CLIENT__::new(backend, @sim.FakeClock::new(), base_url="https://override.example")
  let pages : @client.Paginator[Json, Failure] = sdk.paginate(@http.Request::get("/page1"), kind=NextUrl, items="results", next="next")
  @driver.run_sync(() => {
    assert_true(pages.next_page() is Ok(Some(_)))
    assert_true(pages.next_page() is Ok(Some(_)))
    assert_true(pages.next_page() is Ok(None))
  })
  assert_eq(count.val, 2)
// BEGIN SSE
  let seen : Ref[Array[String]] = Ref([])
  let driver = @driver.Driver::new()
  let source = @sim.Feed::bytes(driver, [b"data: one\n\n", b"data: stop\n\n", b"data: unreachable\n\n"])
  let backend = @client.from_fn((_, _) => @http.Response::new(200,
    headers=@http.Headers::of([("content-type", "text/event-stream")]),
    body=Stream(@http.StreamBody::new(source))))
  let sdk = __CLIENT__::new(backend, @sim.FakeClock::new())
  assert_true(driver.run(() => sdk.stream(@http.Request::get("/stream"), event => { seen.val.push(event.data) }, stop=event => event.data == "stop")) is Ok(_))
  assert_eq(seen.val, ["one"])
  assert_eq(source.closes(), 1)
  assert_eq(source.reads(), 2)
// END SSE
}

///|
test "generated cursor pages replace the cursor and preserve failures" {
  let seen : Array[String] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.url)
    let body = match seen.length() {
      1 => b"{\"data\":[],\"next\":\"first\"}"
      2 => b"bad json"
      3 => b"{\"data\":[1],\"next\":\"last\"}"
      _ => b"{\"data\":[2],\"next\":null}"
    }
    @http.Response::new(200, body=Bytes(body))
  })
  let sdk = __CLIENT__::new(backend, @sim.FakeClock::new())
  let pages : @client.Paginator[Json, Failure] = sdk.paginate(@http.Request::get("/pages?cursor=old&limit=2"), kind=Cursor("cursor"), items="data", next="next")
  @driver.run_sync(() => {
    assert_true(pages.next_page() is Err(Decode(_)))
    assert_true(pages.next_page() is Ok(Some([Number(1, ..)])))
    assert_true(pages.next_page() is Ok(Some([Number(2, ..)])))
    assert_true(pages.next_page() is Ok(None))
  })
  assert_eq(seen.length(), 4)
  assert_eq(seen[1], seen[2])
  assert_true(seen[3].contains("cursor=last"))
  assert_true(seen[3].contains("limit=2"))
  assert_false(seen[3].contains("cursor=old"))
}

///|
test "generated default retry reaches the runtime" {
  let clock = @sim.FakeClock::new()
  let count = Ref(0)
  let backend = @client.from_fn((_, _) => {
    count.val += 1
    @http.Response::new(if count.val == 1 { 503 } else { 200 }, body=Bytes(b"ok"))
  })
  let sdk = __CLIENT__::new(backend, clock)
  ignore(@driver.run_sync(() => sdk.send(@http.Request::get("/contract-test"))))
  __RETRY_ASSERT__
}
