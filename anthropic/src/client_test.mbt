///|
test "mttp sends Anthropic auth and version and retries overloaded responses" {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new()
      .expect(_ => true, @testing.Canned::bytes(529))
      .expect(
        request => {
          request.meth == @http.Post &&
          request.url == "https://api.anthropic.com/v1/messages/count_tokens"
        },
        @testing.Canned::bytes(200, body=b"{\"input_tokens\":7}"),
      )
    let clock = @mock.FakeClock::new()
    let api = @anthropic.Anthropic::new(api_key="secret", backend, clock)
    let count = api
      .count_tokens(
        @anthropic.MessageRequest::new(model="m", max_tokens=32, messages=[
          @anthropic.Message::user("hi"),
        ]),
      )
      .unwrap()
    assert_eq(count, 7)
    let sent = backend.sent()
    assert_eq(sent.length(), 2)
    assert_eq(sent[0].body, sent[1].body)
    assert_eq(sent[0].request.headers.get("x-api-key"), Some("secret"))
    assert_eq(
      sent[0].request.headers.get("anthropic-version"),
      Some("2026-10-21"),
    )
    assert_eq(sent[0].options.timeout_ms, Some(600000))
    assert_eq(clock.slept().length(), 1)
    backend.verify()
  })
}

///|
test "mttp streaming skips gateway DONE and continues through EOF" {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(
        200,
        body=b"data: [DONE]\n\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n",
      ),
    )
    let api = @anthropic.Anthropic::new(
      api_key="secret",
      backend,
      @mock.FakeClock::new(),
      auth_header=Bearer,
    )
    let events : Array[@anthropic.MessageEvent] = []
    api
    .stream_message(
      @anthropic.MessageRequest::new(model="m", max_tokens=32, messages=[]),
      event => events.push(event),
    )
    .unwrap()
    assert_eq(events.length(), 2)
    assert_eq(
      backend.sent()[0].request.headers.get("authorization"),
      Some("Bearer secret"),
    )
    assert_eq(backend.sent()[0].request.headers.get("x-api-key"), None)
    backend.verify()
  })
}

///|
test "mttp SSE decode failure retains the original response head" {
  @driver.run_sync(() => {
    let headers = @http.Headers::of([("request-id", "request-1")])
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(200, headers~, body=b"data: invalid\n\n"),
    )
    let api = @anthropic.Anthropic::new(
      api_key="secret",
      backend,
      @mock.FakeClock::new(),
    )
    let result = api.stream_message(
      @anthropic.MessageRequest::new(model="m", max_tokens=32, messages=[]),
      _ => (),
    )
    match result {
      Err(@anthropic.Response(@client.Deserialization(head, body~, ..))) => {
        assert_eq(head.headers, headers)
        assert_eq(body, b"invalid")
      }
      _ => fail("invalid event must return a decoding failure")
    }
    backend.verify()
  })
}

///|
/// Sends one count_tokens call through a stub that answers with `status` and
/// `location` first, and returns what the stub recorded.
fn redirected_count_tokens(
  status : Int32,
  location : String,
  auth_header~ : @anthropic.AuthHeader = XApiKey,
) -> Array[@testing.Recorded] raise {
  let backend = @testing.BackendStub::new()
    .expect(
      _ => true,
      @testing.Canned::bytes(
        status,
        headers=@http.Headers::of([("location", location)]),
      ),
    )
    .expect(
      _ => true,
      @testing.Canned::bytes(200, body=b"{\"input_tokens\":7}"),
    )
  @driver.run_sync(() => {
    let api = @anthropic.Anthropic::new(
      api_key="secret",
      backend,
      @mock.FakeClock::new(),
      auth_header~,
    )
    let count = api
      .count_tokens(
        @anthropic.MessageRequest::new(model="m", max_tokens=32, messages=[
          @anthropic.Message::user("hi"),
        ]),
      )
      .unwrap()
    assert_eq(count, 7)
  })
  backend.verify()
  backend.sent()
}

///|
test "redirects keep the API key on the same origin and drop it on another" {
  let other = "https://gateway.example/v1/messages/count_tokens"
  for status in [307, 302] {
    let sent = redirected_count_tokens(status, other)
    assert_eq(sent[0].request.headers.get("x-api-key"), Some("secret"))
    assert_eq(sent[1].request.url, other)
    assert_eq(sent[1].request.headers.get("x-api-key"), None)
    assert_eq(
      sent[1].request.headers.get("anthropic-version"),
      Some("2026-10-21"),
    )
  }
  let bearer = redirected_count_tokens(307, other, auth_header=Bearer)
  assert_eq(bearer[1].request.headers.get("authorization"), None)
  let same = "https://api.anthropic.com/v1/messages/count_tokens?beta=true"
  let sent = redirected_count_tokens(307, same)
  assert_eq(sent[1].request.url, same)
  assert_eq(sent[1].request.headers.get("x-api-key"), Some("secret"))
}

///|
test "Anthropic from_client strips and redacts authentication with an empty redirect credential list" {
  let origin = "https://anthropic.example"
  let other = "https://other.example/v1/messages/count_tokens"
  for
    (name, value) in [
      ("x-api-key", "fixture-key"),
      ("authorization", "Bearer fixture-key"),
    ] {
    let seen = []
    let backend = @client.from_fn((request, _) => {
      seen.push(request)
      if request.url.has_prefix(origin) {
        @http.Response::new(
          307,
          headers=@http.Headers::of([("location", other)]),
        )
      } else {
        @http.Response::new(200, body=Bytes(b"{\"input_tokens\":7}"))
      }
    })
    let runtime = @client.Client::new(
      backend,
      @mock.FakeClock::new(),
      base_url=origin,
      headers=@http.Headers::of([(name, value)]),
      redirect={ ..@client.RedirectConfig::default(), credential_headers: [], },
    )
    let sdk = @anthropic.Anthropic::from_client(runtime)
    let result = @driver.run_sync(() => {
      sdk.count_tokens(
        @anthropic.MessageRequest::new(model="m", max_tokens=32, messages=[
          @anthropic.Message::user("hi"),
        ]),
      )
    })
    assert_true(result is Ok(7))
    assert_eq(seen.length(), 2)
    assert_eq(seen[0].headers.get(name), Some(value))
    assert_true(
      seen[0].attributes
      .get(@http.credential_headers)
      .unwrap_or([])
      .contains(name),
    )
    assert_false(
      @client.request(seen[0])
      .response(@client.as_bytes())
      .to_curl()
      .contains("fixture-key"),
    )
    assert_eq(seen[1].url, other)
    assert_eq(seen[1].headers.get(name), None)
  }
}

///|
test "Anthropic rejects explicit header whitespace as validation before I/O" {
  let backend = @testing.BackendStub::new()
  let clock = @mock.FakeClock::new()
  let key = @anthropic.Anthropic::new(api_key="fixture\t", backend, clock)
  let bearer = @anthropic.Anthropic::new(
    api_key=" fixture",
    backend,
    clock,
    auth_header=Bearer,
  )
  let version = @anthropic.Anthropic::new(
    api_key="fixture",
    backend,
    clock,
    version=" 2026-10-21",
  )
  for sdk in [key, bearer, version] {
    assert_true(
      @driver.run_sync(() => sdk.list_models())
      is Err(@anthropic.AnthropicFailure::Validation(_)),
    )
  }
  assert_true(backend.sent().is_empty())
}

///|
test "mttp credential marks retain the same-host default-port HTTPS upgrade exception" {
  let start = "http://origin.example/probe"
  let secure = "https://origin.example/probe"
  assert_false(@http.Url::parse(start).same_origin(@http.Url::parse(secure)))
  let seen = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.headers.get("x-api-key"))
    if request.url == start {
      @http.Response::new(
        307,
        headers=@http.Headers::of([("location", secure)]),
      )
    } else {
      @http.Response::new(200)
    }
  })
  let runtime = @client.Client::new(backend, @mock.FakeClock::new(), redirect={
    ..@client.RedirectConfig::default(),
    credential_headers: [],
  })
  let request = @http.Request::get(start).credential("x-api-key", "fixture-key")
  assert_eq(
    @driver.run_sync(() => {
      runtime.send(@client.request(request).response(@client.as_bytes()))
    }).status,
    200,
  )
  assert_eq(seen, [Some("fixture-key"), Some("fixture-key")])
}

///|
test "Anthropic propagates nested request validation from a streaming callback" {
  let backend = @testing.BackendStub::new().expect(
    _ => true,
    @testing.Canned::bytes(
      200,
      body=b"data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n",
    ),
  )
  let clock = @mock.FakeClock::new()
  let sdk = @anthropic.Anthropic::new(api_key="fixture-key", backend, clock)
  let nested_backend = @testing.BackendStub::new()
  let nested = @client.Client::new(nested_backend, clock)
  @driver.run_sync(() => {
    let request = @http.Request::get("https://nested.example").header(
      "x-test", " invalid",
    )
    let outer = sdk.stream_message(
      @anthropic.MessageRequest::new(model="m", max_tokens=32, messages=[]),
      _ => {
        ignore(
          nested.send(@client.request(request).response(@client.as_bytes())),
        )
      },
    ) catch {
      @http.TransportError(kind=Invalid, phase=Pool, ..) => return
      error => raise error
    }
    fail(
      "expected the nested request error to raise, got \{@debug.to_string(outer)}",
    )
  })
  backend.verify()
  assert_true(nested_backend.sent().is_empty())
}
