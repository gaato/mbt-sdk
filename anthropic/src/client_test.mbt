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
