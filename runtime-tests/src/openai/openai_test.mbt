///|
fn json_response(
  body : String,
  status? : Int = 200,
  headers? : @http.Headers = @http.Headers::new(),
) -> @http.Response {
  { status, headers, body: @utf8.encode(body), }
}

///|
async fn bounded(f : async () -> Unit) -> Unit {
  @async.with_timeout(5000, f)
}

///|
fn assert_auth_header(request : @http.Request) -> Unit raise {
  assert_eq(request.headers.get("authorization"), Some("Bearer test-key"))
}

///|
async test "OpenAI operations send exact requests and decode spec examples" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/v1/models",
      json_response(
        "{\"object\":\"list\",\"data\":[{\"id\":\"model-id-0\",\"object\":\"model\",\"created\":2147483648,\"owned_by\":\"organization-owner\",\"future\":true}]}",
      ),
    )
    transport.expect(
      "GET",
      "/v1/models/gpt-4o-mini",
      json_response(
        "{\"id\":\"gpt-4o-mini\",\"object\":\"model\",\"created\":1686935002,\"owned_by\":\"openai\"}",
      ),
    )
    transport.expect(
      "POST",
      "/v1/embeddings",
      json_response(
        "{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"embedding\":[0.0023064255,-0.009327292],\"index\":0}],\"model\":\"text-embedding-ada-002\",\"usage\":{\"prompt_tokens\":8,\"total_tokens\":8}}",
      ),
    )
    transport.expect(
      "POST",
      "/v1/responses",
      json_response(
        "{\"id\":\"resp_67ccd2\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"gpt-4.1-2025-04-14\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"A short story.\"}]}],\"usage\":{\"input_tokens\":36,\"output_tokens\":87,\"total_tokens\":123},\"future\":true}",
      ),
    )
    let clock = @mock.FakeClock::new()
    let client = @openai_sdk.OpenAI::new(
      api_key="test-key",
      transport,
      clock,
      organization="org-test",
      project="proj-test",
    )

    let models = client.list_models()
    assert_eq(models, [
      {
        id: "model-id-0",
        created: Some(2147483648L),
        owned_by: Some("organization-owner"),
      },
    ])
    assert_eq(client.retrieve_model("gpt-4o-mini"), {
      id: "gpt-4o-mini",
      created: Some(1686935002L),
      owned_by: Some("openai"),
    })
    assert_eq(
      client.create_embeddings(
        @openai_sdk.EmbeddingRequest::new(
          model="text-embedding-ada-002",
          input=["The food was delicious"],
          dimensions=2,
          user="user-1234",
        ),
      ),
      {
        data: [{ index: 0, embedding: [0.0023064255, -0.009327292], }],
        model: "text-embedding-ada-002",
        prompt_tokens: 8,
        total_tokens: 8,
      },
    )
    let response = client.create_response(
      @openai_sdk.ResponseRequest::new(
        model="gpt-4.1",
        input="Tell me a short story.",
        instructions="Three sentences.",
        max_output_tokens=100,
        temperature=0.5,
        previous_response_id="resp_previous",
        extra={ "metadata": { "source": "test" } },
      ),
    )
    assert_eq(response.id, "resp_67ccd2")
    assert_eq(response.status, @openai_sdk.Completed)
    assert_eq(response.output_text, "A short story.")
    assert_eq(
      response.usage,
      Some({ input_tokens: 36, output_tokens: 87, total_tokens: 123, }),
    )

    let sent = transport.sent()
    assert_eq(sent.length(), 4)
    for request in sent {
      assert_auth_header(request)
      assert_eq(request.headers.get("openai-organization"), Some("org-test"))
      assert_eq(request.headers.get("openai-project"), Some("proj-test"))
    }
    assert_eq(sent[0].http_method, "GET")
    assert_eq(sent[0].url, "https://api.openai.com/v1/models")
    assert_eq(sent[0].body, b"")
    assert_eq(sent[0].headers.get("content-type"), None)
    assert_eq(sent[1].http_method, "GET")
    assert_eq(sent[1].url, "https://api.openai.com/v1/models/gpt-4o-mini")
    assert_eq(
      sent[2].body,
      @utf8.encode(
        "{\"model\":\"text-embedding-ada-002\",\"input\":[\"The food was delicious\"],\"dimensions\":2,\"user\":\"user-1234\"}",
      ),
    )
    assert_eq(sent[2].headers.get("content-type"), Some("application/json"))
    assert_eq(
      sent[3].body,
      @utf8.encode(
        "{\"model\":\"gpt-4.1\",\"input\":\"Tell me a short story.\",\"instructions\":\"Three sentences.\",\"max_output_tokens\":100,\"temperature\":0.5,\"previous_response_id\":\"resp_previous\",\"metadata\":{\"source\":\"test\"}}",
      ),
    )
    assert_eq(sent[3].headers.get("content-type"), Some("application/json"))
    assert_eq(clock.slept(), [])
    transport.assert_complete()
  })
}

///|
priv struct RecordingLimiter {
  acquired : Array[String]
  observed : Array[String]
}

///|
extend RecordingLimiter with @runtime.RateLimiter::{acquire, observe}

///|
impl @runtime.RateLimiter for RecordingLimiter with fn acquire(self, bucket) {
  self.acquired.push(bucket)
}

///|
impl @runtime.RateLimiter for RecordingLimiter with fn observe(
  self,
  bucket,
  _status,
  _headers,
  _now_unix_ms,
) {
  self.observed.push(bucket)
}

///|
async test "OpenAI assigns the contract bucket to every operation" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect("GET", "/models", json_response("{\"data\":[]}"))
    transport.expect(
      "GET",
      "/models/m",
      json_response("{\"id\":\"m\",\"created\":1,\"owned_by\":\"openai\"}"),
    )
    transport.expect(
      "POST",
      "/embeddings",
      json_response(
        "{\"data\":[],\"model\":\"e\",\"usage\":{\"prompt_tokens\":0,\"total_tokens\":0}}",
      ),
    )
    transport.expect(
      "POST",
      "/responses",
      json_response(
        "{\"id\":\"r\",\"status\":\"completed\",\"model\":\"g\",\"output\":[]}",
      ),
    )
    transport.expect_stream(
      "POST",
      "/responses",
      { status: 200, headers: @http.Headers::new(), },
      [b"data: [DONE]\n\n"],
    )
    let limiter = RecordingLimiter::{ acquired: [], observed: [], }
    let clock = @mock.FakeClock::new()
    let runtime = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
      limiter~,
    )
    let client = @openai_sdk.OpenAI::from_client(runtime)
    ignore(client.list_models())
    ignore(client.retrieve_model("m"))
    ignore(
      client.create_embeddings(
        @openai_sdk.EmbeddingRequest::new(model="e", input=[]),
      ),
    )
    ignore(
      client.create_response(
        @openai_sdk.ResponseRequest::new(model="g", input="i"),
      ),
    )
    client.stream_response(
      @openai_sdk.ResponseRequest::new(model="g", input="i"),
      _ => (),
    )
    assert_eq(limiter.acquired, [
      "models", "models", "embeddings", "responses", "responses",
    ])
    assert_eq(limiter.observed, limiter.acquired)
    limiter.acquire("direct-check")
    limiter.observe(
      "direct-check",
      200,
      @http.Headers::new(),
      clock.now_unix_ms(),
    )
    assert_eq(limiter.acquired.last(), Some("direct-check"))
    assert_eq(limiter.observed.last(), Some("direct-check"))
    assert_eq(transport.streams_closed(), 1)
    transport.assert_complete()
  })
}

///|
async test "HTTP errors expose API bodies and a 429 retries before success" {
  bounded(() => {
    let failures = @mock.FakeTransport::new()
    failures.expect(
      "GET",
      "/models",
      json_response(
        "{\"error\":{\"message\":\"bad key\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":\"invalid_api_key\"}}",
        status=401,
      ),
    )
    failures.expect(
      "POST",
      "/embeddings",
      json_response(
        "{\"error\":{\"message\":\"slow down\",\"type\":\"rate_limit_error\",\"param\":null,\"code\":\"rate_limit_exceeded\"}}",
        status=429,
      ),
    )
    let no_retry = @openai_sdk.OpenAI::new(
      api_key="key",
      failures,
      @mock.FakeClock::new(),
      retry=@runtime.RetryPolicy::none(),
    )
    try no_retry.list_models() catch {
      error =>
        assert_eq(
          @openai_sdk.api_error(error),
          Some({
            message: "bad key",
            type_: Some("invalid_request_error"),
            param: None,
            code: Some("invalid_api_key"),
          }),
        )
    } noraise {
      _ => fail("401 must fail")
    }
    try
      no_retry.create_embeddings(
        @openai_sdk.EmbeddingRequest::new(model="e", input=["x"]),
      )
    catch {
      error =>
        assert_eq(
          @openai_sdk.api_error(error),
          Some({
            message: "slow down",
            type_: Some("rate_limit_error"),
            param: None,
            code: Some("rate_limit_exceeded"),
          }),
        )
    } noraise {
      _ => fail("429 must fail when retries are disabled")
    }
    failures.assert_complete()

    let retrying = @mock.FakeTransport::new()
    retrying.expect(
      "POST",
      "/embeddings",
      json_response(
        "{\"error\":{\"message\":\"slow down\"}}",
        status=429,
        headers=@http.Headers::from_array([("retry-after", "0.25")]),
      ),
    )
    retrying.expect(
      "POST",
      "/embeddings",
      json_response(
        "{\"data\":[],\"model\":\"e\",\"usage\":{\"prompt_tokens\":0,\"total_tokens\":0}}",
      ),
    )
    let clock = @mock.FakeClock::new()
    let client = @openai_sdk.OpenAI::new(api_key="key", retrying, clock)
    ignore(
      client.create_embeddings(
        @openai_sdk.EmbeddingRequest::new(model="e", input=["x"]),
      ),
    )
    assert_eq(clock.slept(), [250])
    assert_eq(retrying.sent().length(), 2)
    retrying.assert_complete()
  })
}

///|
fn split_chunks(text : String, ends : Array[Int]) -> Array[Bytes] {
  let bytes = @utf8.encode(text)
  let chunks : Array[Bytes] = []
  let mut start = 0
  for end in ends {
    chunks.push(bytes[start:end].to_owned())
    start = end
  }
  if start < bytes.length() {
    chunks.push(bytes[start:].to_owned())
  }
  chunks
}

///|
async test "streaming decodes spec events across chunks and stops at DONE" {
  bounded(() => {
    let created = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_123\",\"status\":\"in_progress\",\"model\":\"gpt-4o\",\"output\":[]}}"
    let delta = "{\"type\":\"response.output_text.delta\",\"item_id\":\"msg_123\",\"output_index\":0,\"content_index\":0,\"delta\":\"In\"}"
    let done = "{\"type\":\"response.output_text.done\",\"item_id\":\"msg_123\",\"output_index\":0,\"content_index\":0,\"text\":\"In a grove.\"}"
    let unknown = "{\"type\":\"response.future\",\"value\":7}"
    let event_error = "{\"type\":\"error\",\"code\":\"ERR_SOMETHING\",\"message\":\"Something went wrong\",\"param\":null}"
    let completed = "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_123\",\"status\":\"completed\",\"model\":\"gpt-4o\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"In a grove.\"}]}]}}"
    let sse = "event: misleading\ndata: " +
      created +
      "\n\ndata: " +
      delta +
      "\n\ndata: " +
      done +
      "\n\ndata: " +
      unknown +
      "\n\ndata: " +
      event_error +
      "\n\ndata: " +
      completed +
      "\n\ndata: [DONE]\n\ndata: not-json\n\n"
    let transport = @mock.FakeTransport::new()
    transport.expect_stream(
      "POST",
      "/responses",
      { status: 200, headers: @http.Headers::new(), },
      split_chunks(sse, [1, 7, 19, 43, 101, 211]),
    )
    let client = @openai_sdk.OpenAI::new(
      api_key="test-key",
      transport,
      @mock.FakeClock::new(),
    )
    let events : Array[@openai_sdk.ResponseEvent] = []
    client.stream_response(
      @openai_sdk.ResponseRequest::new(model="gpt-4o", input="story"),
      event => events.push(event),
    )
    assert_eq(events.length(), 6)
    guard events[0] is @openai_sdk.Created(response) else {
      fail("expected created")
    }
    assert_eq(response.id, "resp_123")
    assert_eq(response.status, @openai_sdk.InProgress)
    assert_eq(events[1], @openai_sdk.OutputTextDelta("In"))
    assert_eq(events[2], @openai_sdk.OutputTextDone("In a grove."))
    guard events[3] is @openai_sdk.Other(kind, raw) else {
      fail("expected unknown event")
    }
    assert_eq(kind, "response.future")
    assert_eq(raw, @json.parse(unknown))
    assert_eq(
      events[4],
      @openai_sdk.Error({
        message: "Something went wrong",
        type_: None,
        param: None,
        code: Some("ERR_SOMETHING"),
      }),
    )
    guard events[5] is @openai_sdk.Completed(response) else {
      fail("expected completed")
    }
    assert_eq(response.output_text, "In a grove.")
    assert_eq(transport.streams_closed(), 1)
    let sent = transport.sent()
    assert_eq(sent.length(), 1)
    assert_auth_header(sent[0])
    assert_eq(sent[0].headers.get("accept"), Some("text/event-stream"))
    assert_eq(sent[0].headers.get("content-type"), Some("application/json"))
    assert_eq(
      sent[0].body,
      @utf8.encode("{\"model\":\"gpt-4o\",\"input\":\"story\",\"stream\":true}"),
    )
    transport.assert_complete()
  })
}

///|
priv suberror CallbackFailure {
  CallbackFailure
}

///|
async test "streaming closes on callback and decode errors" {
  bounded(() => {
    let created = "{\"type\":\"response.created\",\"response\":{\"id\":\"r\",\"status\":\"in_progress\",\"model\":\"g\",\"output\":[]}}"
    let callback_transport = @mock.FakeTransport::new()
    callback_transport.expect_stream(
      "POST",
      "/responses",
      { status: 200, headers: @http.Headers::new(), },
      [@utf8.encode("data: " + created + "\n\n")],
    )
    let callback_client = @openai_sdk.OpenAI::new(
      api_key="key",
      callback_transport,
      @mock.FakeClock::new(),
    )
    try
      callback_client.stream_response(
        @openai_sdk.ResponseRequest::new(model="g", input="i"),
        _ => raise CallbackFailure,
      )
    catch {
      CallbackFailure => ()
      _ => fail("callback error must propagate unchanged")
    } noraise {
      _ => fail("callback must fail")
    }
    assert_eq(callback_transport.streams_closed(), 1)
    callback_transport.assert_complete()

    let decode_transport = @mock.FakeTransport::new()
    decode_transport.expect_stream(
      "POST",
      "/responses",
      { status: 200, headers: @http.Headers::new(), },
      [b"data: {\n\n"],
    )
    let decode_client = @openai_sdk.OpenAI::new(
      api_key="key",
      decode_transport,
      @mock.FakeClock::new(),
    )
    try
      decode_client.stream_response(
        @openai_sdk.ResponseRequest::new(model="g", input="i"),
        _ => (),
      )
    catch {
      @runtime.Decode(body=b"{", ..) => ()
      _ => fail("invalid event data must become Decode")
    } noraise {
      _ => fail("invalid event data must fail")
    }
    assert_eq(decode_transport.streams_closed(), 1)
    decode_transport.assert_complete()
  })
}

///|
async test "missing required fields decode and extra collisions send nothing" {
  bounded(() => {
    let missing = @mock.FakeTransport::new()
    missing.expect(
      "POST",
      "/responses",
      json_response("{\"status\":\"completed\",\"model\":\"g\",\"output\":[]}"),
    )
    let client = @openai_sdk.OpenAI::new(
      api_key="key",
      missing,
      @mock.FakeClock::new(),
    )
    try
      client.create_response(
        @openai_sdk.ResponseRequest::new(model="g", input="i"),
      )
    catch {
      @runtime.Decode(body~, ..) => assert_true(body.length() > 0)
      _ => fail("missing id must become Decode")
    } noraise {
      _ => fail("missing id must fail")
    }
    missing.assert_complete()

    let collision_transport = @mock.FakeTransport::new()
    let collision_client = @openai_sdk.OpenAI::new(
      api_key="key",
      collision_transport,
      @mock.FakeClock::new(),
    )
    try
      collision_client.create_response(
        @openai_sdk.ResponseRequest::new(model="g", input="i", extra={
          "stream": false,
        }),
      )
    catch {
      @runtime.Config(message) => assert_true(message.contains("stream"))
      _ => fail("collision must become Config")
    } noraise {
      _ => fail("collision must fail")
    }
    assert_eq(collision_transport.sent(), [])
    collision_transport.assert_complete()
  })
}

///|
test "OpenAI Debug never contains the API key" {
  let key = "sk-runtime-test-secret"
  let client = @openai_sdk.OpenAI::new(
    api_key=key,
    @mock.FakeTransport::new(),
    @mock.FakeClock::new(),
  )
  let representation = @debug.Repr(client).to_string()
  assert_false(representation.contains(key))
  assert_true(representation.contains("redacted"))
}
