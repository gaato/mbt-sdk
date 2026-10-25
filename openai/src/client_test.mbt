///|
test "mttp sends tenant headers and retries a buffered POST before decoding" {
  @testing.run_sync(() => {
    let backend = @testing.BackendStub::new()
      .expect(_ => true, @testing.Canned::bytes(503))
      .expect(
        request => {
          request.meth == @model.Post &&
          request.url == "https://api.openai.com/v1/chat/completions"
        },
        @testing.Canned::bytes(
          200,
          body=b"{\"id\":\"c\",\"object\":\"chat.completion\",\"created\":1750000000,\"model\":\"m\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hello\",\"refusal\":null},\"logprobs\":null,\"finish_reason\":\"stop\"}]}",
        ),
      )
    let clock = @mock.FakeClock::new()
    let api = @openai.OpenAI::new(
      api_key="secret",
      backend,
      clock,
      organization="org",
      project="proj",
    )
    let result = api.chat_completion(
      @openai.ChatRequest::new(model="m", messages=[
        @openai.ChatMessage::user("hi"),
      ]),
    )
    assert_eq(result.text, "hello")
    let sent = backend.sent()
    assert_eq(sent.length(), 2)
    assert_eq(sent[0].body, sent[1].body)
    assert_eq(
      sent[0].request.headers.get("authorization"),
      Some("Bearer secret"),
    )
    assert_eq(sent[0].request.headers.get("openai-organization"), Some("org"))
    assert_eq(sent[0].request.headers.get("openai-project"), Some("proj"))
    assert_eq(sent[0].options.timeout_ms, Some(600000))
    assert_eq(clock.slept().length(), 1)
    backend.verify()
  })
}

///|
test "mttp streaming stops at DONE before decoding a following invalid event" {
  @testing.run_sync(() => {
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(
        200,
        body=b"data: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"created\":1750000000,\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\ndata: not-json\n\n",
      ),
    )
    let api = @openai.OpenAI::new(
      api_key="secret",
      backend,
      @mock.FakeClock::new(),
    )
    let events : Array[@openai.ChatEvent] = []
    api.stream_chat_completion(
      @openai.ChatRequest::new(model="m", messages=[]),
      event => events.push(event),
    )
    assert_eq(events.length(), 1)
    assert_eq(
      backend.sent()[0].request.headers.get("accept"),
      Some("text/event-stream"),
    )
    backend.verify()
  })
}

///|
test "mttp decode failures retain real response headers and bytes" {
  @testing.run_sync(() => {
    let headers = @model.Headers::of([("x-request-id", "request-1")])
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(200, headers~, body=b"invalid"),
    )
    let api = @openai.OpenAI::new(
      api_key="secret",
      backend,
      @mock.FakeClock::new(),
    )
    try api.list_models() |> ignore catch {
      @client.Deserialization(head, body~, ..) => {
        assert_eq(head.status, 200)
        assert_eq(head.headers, headers)
        assert_eq(body, b"invalid")
      }
      error => fail(error.to_string())
    } noraise {
      _ => fail("invalid response must fail")
    }
    backend.verify()
  })
}
