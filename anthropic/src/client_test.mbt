///|
test "mttp sends Anthropic auth and version and retries overloaded responses" {
  @testing.run_sync(() => {
    let backend = @testing.BackendStub::new()
      .expect(_ => true, @testing.Canned::bytes(529))
      .expect(
        request => {
          request.meth == @model.Post &&
          request.url == "https://api.anthropic.com/v1/messages/count_tokens"
        },
        @testing.Canned::bytes(200, body=b"{\"input_tokens\":7}"),
      )
    let clock = @mock.FakeClock::new()
    let api = @anthropic.Anthropic::new(api_key="secret", backend, clock)
    let count = api.count_tokens(
      @anthropic.MessageRequest::new(model="m", max_tokens=32, messages=[
        @anthropic.Message::user("hi"),
      ]),
    )
    assert_eq(count, 7)
    let sent = backend.sent()
    assert_eq(sent.length(), 2)
    assert_eq(sent[0].body, sent[1].body)
    assert_eq(sent[0].request.headers.get("x-api-key"), Some("secret"))
    assert_eq(
      sent[0].request.headers.get("anthropic-version"),
      Some("2023-06-01"),
    )
    assert_eq(sent[0].options.timeout_ms, Some(600000))
    assert_eq(clock.slept().length(), 1)
    backend.verify()
  })
}

///|
test "mttp streaming skips gateway DONE and continues through EOF" {
  @testing.run_sync(() => {
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
    api.stream_message(
      @anthropic.MessageRequest::new(model="m", max_tokens=32, messages=[]),
      event => events.push(event),
    )
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
  @testing.run_sync(() => {
    let headers = @model.Headers::of([("request-id", "request-1")])
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(200, headers~, body=b"data: invalid\n\n"),
    )
    let api = @anthropic.Anthropic::new(
      api_key="secret",
      backend,
      @mock.FakeClock::new(),
    )
    try
      api.stream_message(
        @anthropic.MessageRequest::new(model="m", max_tokens=32, messages=[]),
        _ => (),
      )
    catch {
      @client.Deserialization(head, body~, ..) => {
        assert_eq(head.headers, headers)
        assert_eq(body, b"invalid")
      }
      error => fail(error.to_string())
    } noraise {
      _ => fail("invalid event must fail")
    }
    backend.verify()
  })
}
