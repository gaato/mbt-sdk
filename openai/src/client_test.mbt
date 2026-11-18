///|
test "mttp sends tenant headers and retries a buffered POST before decoding" {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new()
      .expect(_ => true, @testing.Canned::bytes(503))
      .expect(
        request => {
          request.meth == @http.Post &&
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
    let result = api
      .chat_completion(
        @openai.ChatRequest::new(model="m", messages=[
          @openai.ChatMessage::user("hi"),
        ]),
      )
      .unwrap()
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
  @driver.run_sync(() => {
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
    api
    .stream_chat_completion(@openai.ChatRequest::new(model="m", messages=[]), event => {
      events.push(event)
    })
    .unwrap()
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
  @driver.run_sync(() => {
    let headers = @http.Headers::of([("x-request-id", "request-1")])
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(200, headers~, body=b"invalid"),
    )
    let api = @openai.OpenAI::new(
      api_key="secret",
      backend,
      @mock.FakeClock::new(),
    )
    match api.list_models() {
      Err(@openai.Response(@client.Deserialization(head, body~, ..))) => {
        assert_eq(head.status, 200)
        assert_eq(head.headers, headers)
        assert_eq(body, b"invalid")
      }
      _ => fail("invalid response must return a decoding failure")
    }
    backend.verify()
  })
}

///|
test "OpenAI from_client strips and redacts authorization with an empty redirect credential list" {
  let origin = "https://openai.example"
  let other = "https://other.example/models"
  let seen = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request)
    if request.url.has_prefix(origin) {
      @http.Response::new(302, headers=@http.Headers::of([("location", other)]))
    } else {
      @http.Response::new(200, body=Bytes(b"{\"object\":\"list\",\"data\":[]}"))
    }
  })
  let runtime = @client.Client::new(
    backend,
    @mock.FakeClock::new(),
    base_url=origin,
    headers=@http.Headers::of([("authorization", "Bearer fixture-token")]),
    redirect={ ..@client.RedirectConfig::default(), credential_headers: [], },
  )
  let sdk = @openai.OpenAI::from_client(runtime)
  assert_true(@driver.run_sync(() => sdk.list_models()) is Ok(_))
  assert_eq(seen.length(), 2)
  assert_eq(seen[0].headers.get("authorization"), Some("Bearer fixture-token"))
  assert_true(
    seen[0].attributes
    .get(@http.credential_headers)
    .unwrap_or([])
    .contains("authorization"),
  )
  assert_false(
    @client.request(seen[0])
    .response(@client.as_bytes())
    .to_curl()
    .contains("fixture-token"),
  )
  assert_eq(seen[1].url, other)
  assert_eq(seen[1].headers.get("authorization"), None)
}

///|
test "OpenAI rejects explicit header whitespace as validation before I/O" {
  let backend = @testing.BackendStub::new()
  let clock = @mock.FakeClock::new()
  let tenant = @openai.OpenAI::new(
    api_key="fixture",
    backend,
    clock,
    organization=" org",
  )
  let project = @openai.OpenAI::new(
    api_key="fixture",
    backend,
    clock,
    project="proj\t",
  )
  let key = @openai.OpenAI::new(api_key=" fixture", backend, clock)
  for sdk in [tenant, project, key] {
    assert_true(
      @driver.run_sync(() => sdk.list_models())
      is Err(@openai.OpenAIFailure::Validation(_)),
    )
  }
  assert_true(backend.sent().is_empty())
}

///|
test "OpenAI propagates nested request validation from a streaming callback" {
  let backend = @testing.BackendStub::new().expect(
    _ => true,
    @testing.Canned::bytes(
      200,
      body=b"data: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"created\":1750000000,\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\n",
    ),
  )
  let clock = @mock.FakeClock::new()
  let sdk = @openai.OpenAI::new(api_key="fixture-key", backend, clock)
  let nested_backend = @testing.BackendStub::new()
  let nested = @client.Client::new(nested_backend, clock)
  @driver.run_sync(() => {
    let request = @http.Request::get("https://nested.example").header(
      "x-test", " invalid",
    )
    let outer = sdk.stream_chat_completion(
      @openai.ChatRequest::new(model="m", messages=[]),
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
