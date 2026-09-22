///|
fn json_response(
  body : String,
  status? : Int = 200,
  headers? : @http.Headers = @http.Headers::new(),
) -> @http.Response {
  { status, headers, body: @utf8.encode(body), }
}

///|
fn sent_json(request : @http.Request) -> Json raise {
  @json.parse(@utf8.decode(request.body))
}

///|
async fn bounded(f : async () -> Unit) -> Unit {
  @async.with_timeout(5000, f)
}

///|
async test "Anthropic sends the generated request and decodes a compatible response" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-opus-5\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"},{\"type\":\"thinking\",\"thinking\":\"Reason\",\"signature\":\"sig\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":8,\"output_tokens\":5,\"cost\":0}}",
      ),
    )
    let clock = @mock.FakeClock::new()
    let client = @anthropic_sdk.Anthropic::new(
      api_key="test-key",
      transport,
      clock,
      version="2024-01-01",
    )
    let response = client.create_message(
      @anthropic_sdk.MessageRequest::new(
        model="claude-opus-5",
        max_tokens=64,
        messages=[@anthropic_sdk.Message::user("Hello")],
        system="Be brief",
        temperature=0.2,
        stop_sequences=["END"],
        metadata=@anthropic_gen.Metadata::new(user_id="u1"),
        extra={ "top_p": 0.9 },
      ),
    )
    assert_eq(response.role, @anthropic_sdk.Assistant)
    assert_eq(response.text(), "Hello")
    assert_eq(
      response.content[1],
      @anthropic_sdk.Thinking(thinking="Reason", signature="sig"),
    )
    assert_eq(response.usage.input_tokens, 8)
    assert_eq(response.usage.output_tokens, 5)
    assert_eq(response.stop_reason, Some(@anthropic_sdk.StopReason::EndTurn))
    let sent = transport.sent()
    assert_eq(sent.length(), 1)
    assert_eq(sent[0].http_method, "POST")
    assert_eq(sent[0].url, "https://api.anthropic.com/v1/messages")
    assert_eq(sent[0].headers.get("x-api-key"), Some("test-key"))
    assert_eq(sent[0].headers.get("authorization"), None)
    assert_eq(sent[0].headers.get("anthropic-version"), Some("2024-01-01"))
    assert_eq(sent[0].headers.get("content-type"), Some("application/json"))
    assert_eq(sent_json(sent[0]), {
      "model": "claude-opus-5",
      "max_tokens": 64,
      "messages": [{ "role": "user", "content": "Hello" }],
      "system": "Be brief",
      "temperature": 0.2,
      "stop_sequences": ["END"],
      "metadata": { "user_id": "u1" },
      "top_p": 0.9,
    })
    assert_eq(clock.slept(), [])
    transport.assert_complete()
  })
}

///|
async test "Anthropic tool use round trip and stream accumulator use FakeTransport" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{\"id\":\"msg_tool\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"get_weather\",\"input\":{\"city\":\"Tokyo\"}}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":8,\"output_tokens\":5}}",
      ),
    )
    let start = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_2\",\"name\":\"get_weather\",\"input\":{}}}"
    let delta1 = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\"}}"
    let delta2 = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"Tok\"}}"
    let delta3 = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"yo\\\"}\"}}"
    let stop = "{\"type\":\"content_block_stop\",\"index\":0}"
    let sse = "data: " +
      start +
      "\n\ndata: " +
      delta1 +
      "\n\ndata: " +
      delta2 +
      "\n\ndata: " +
      delta3 +
      "\n\ndata: " +
      stop +
      "\n\ndata: {\"type\":\"message_stop\"}\n\n"
    transport.expect_stream(
      "POST",
      "/v1/messages",
      { status: 200, headers: @http.Headers::new(), },
      split_chunks(sse, [2, 31, 117, 233]),
    )
    let client = @anthropic_sdk.Anthropic::from_client(
      @runtime.Client::new(
        transport,
        @mock.FakeClock::new(),
        base_url="https://api.test",
      ),
    )
    let schema : Json = {
      "type": "object",
      "properties": { "city": { "type": "string" } },
    }
    let response = client.create_message(
      @anthropic_sdk.MessageRequest::new(
        model="claude",
        max_tokens=64,
        messages=[
          @anthropic_sdk.Message::tool_result(
            tool_use_id="toolu_previous",
            content="sunny",
          ),
        ],
        tools=[
          @anthropic_sdk.ToolDef::new(
            name="get_weather",
            description="Get weather",
            input_schema=schema,
          ),
        ],
        tool_choice=@anthropic_sdk.tool_choice_auto(),
      ),
    )
    assert_eq(response.stop_reason, Some(@anthropic_sdk.StopReason::ToolUse))
    assert_eq(
      response.content[0],
      @anthropic_sdk.ToolUse(id="toolu_1", name="get_weather", input={
        "city": "Tokyo",
      }),
    )
    assert_eq(response.tool_uses(), [
      ("toolu_1", "get_weather", { "city": "Tokyo" }),
    ])
    // The response replays as the next assistant turn with its typed tool_use block.
    let replay = @anthropic_sdk.Message::from_response(response)
    guard replay.content is @anthropic_sdk.Blocks([@anthropic_gen.ToolUse(block)]) else {
      fail("expected one typed tool_use block")
    }
    assert_eq(block.id, "toolu_1")
    let accumulator = @anthropic_sdk.ToolUseAccumulator::new()
    client.stream_message(
      @anthropic_sdk.MessageRequest::new(model="claude", max_tokens=64, messages=[
        @anthropic_sdk.Message::user("weather"),
      ]),
      event => accumulator.feed(event),
    )
    assert_eq(accumulator.finish(), [
      ("toolu_2", "get_weather", { "city": "Tokyo" }),
    ])
    let sent = transport.sent()
    assert_eq(sent[0].url, "https://api.test/v1/messages")
    assert_eq(sent_json(sent[0]), {
      "model": "claude",
      "max_tokens": 64,
      "messages": [
        {
          "role": "user",
          "content": [
            {
              "type": "tool_result",
              "tool_use_id": "toolu_previous",
              "content": "sunny",
            },
          ],
        },
      ],
      "tools": [
        {
          "name": "get_weather",
          "description": "Get weather",
          "input_schema": schema,
        },
      ],
      "tool_choice": { "type": "auto" },
    })
    assert_eq(sent_json(sent[1]), {
      "model": "claude",
      "max_tokens": 64,
      "messages": [{ "role": "user", "content": "weather" }],
      "stream": true,
    })
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
async test "from_client uses Bearer configuration, version, and per-operation buckets" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{\"id\":\"m\",\"model\":\"model\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}",
      ),
    )
    transport.expect(
      "GET",
      "/v1/models?limit=2",
      json_response(
        "{\"data\":[{\"type\":\"model\",\"id\":\"claude-opus-5\",\"display_name\":\"Claude Opus 5\",\"created_at\":\"2026-04-01T00:00:00Z\"},{\"type\":\"model\",\"id\":\"claude-haiku-4-5\",\"display_name\":\"Claude Haiku 4.5\",\"created_at\":\"2025-10-01T00:00:00Z\",\"max_tokens\":64000}],\"has_more\":true,\"first_id\":\"claude-opus-5\",\"last_id\":\"claude-haiku-4-5\"}",
      ),
    )
    transport.expect(
      "GET",
      "/v1/models/claude-haiku-4-5",
      json_response(
        "{\"type\":\"model\",\"id\":\"claude-haiku-4-5\",\"display_name\":\"Claude Haiku 4.5\",\"created_at\":\"2025-10-01T00:00:00Z\"}",
      ),
    )
    let limiter = RecordingLimiter::{ acquired: [], observed: [], }
    let runtime = @runtime.Client::new(
      transport,
      @mock.FakeClock::new(),
      base_url="https://openrouter.ai/api",
      auth=@runtime.Bearer("router-key"),
      limiter~,
    )
    let client = @anthropic_sdk.Anthropic::from_client(
      runtime,
      version="2023-06-01",
    )
    ignore(
      client.create_message(
        @anthropic_sdk.MessageRequest::new(model="model", max_tokens=1, messages=[]),
      ),
    )
    let models = client.list_models(limit=2)
    assert_eq(models.data.map(model => model.id), [
      "claude-opus-5", "claude-haiku-4-5",
    ])
    assert_eq(models.has_more, true)
    assert_eq(models.last_id, Some("claude-haiku-4-5"))
    assert_eq(models.data[1].max_tokens, Some(64000))
    let model = client.retrieve_model("claude-haiku-4-5")
    assert_eq(model.display_name, "Claude Haiku 4.5")
    let sent = transport.sent()
    assert_eq(sent[0].url, "https://openrouter.ai/api/v1/messages")
    assert_eq(sent[0].headers.get("authorization"), Some("Bearer router-key"))
    assert_eq(sent[0].headers.get("x-api-key"), None)
    assert_eq(sent[0].headers.get("anthropic-version"), Some("2023-06-01"))
    assert_eq(sent[1].url, "https://openrouter.ai/api/v1/models?limit=2")
    assert_eq(sent[1].headers.get("anthropic-version"), Some("2023-06-01"))
    assert_eq(sent[2].url, "https://openrouter.ai/api/v1/models/claude-haiku-4-5")
    assert_eq(limiter.acquired, ["messages", "models", "models"])
    assert_eq(limiter.observed, ["messages", "models", "models"])
    transport.assert_complete()
  })
}

///|
async test "HTTP errors expose API bodies and 429 retries before success" {
  bounded(() => {
    let failures = @mock.FakeTransport::new()
    let error_body = "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"bad key\"},\"request_id\":\"req_1\"}"
    failures.expect("POST", "/v1/messages", json_response(error_body, status=401))
    let no_retry = @anthropic_sdk.Anthropic::new(
      api_key="key",
      failures,
      @mock.FakeClock::new(),
      retry=@runtime.RetryPolicy::none(),
    )
    try
      no_retry.create_message(
        @anthropic_sdk.MessageRequest::new(model="m", max_tokens=1, messages=[]),
      )
    catch {
      error =>
        assert_eq(
          @anthropic_sdk.api_error(error),
          Some({ type_: "authentication_error", message: "bad key", }),
        )
    } noraise {
      _ => fail("401 must fail")
    }
    failures.assert_complete()

    let retrying = @mock.FakeTransport::new()
    retrying.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}",
        status=429,
        headers=@http.Headers::from_array([("retry-after", "0.25")]),
      ),
    )
    retrying.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{\"id\":\"m\",\"model\":\"model\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}",
      ),
    )
    let clock = @mock.FakeClock::new()
    let client = @anthropic_sdk.Anthropic::new(api_key="key", retrying, clock)
    ignore(
      client.create_message(
        @anthropic_sdk.MessageRequest::new(model="model", max_tokens=1, messages=[]),
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
async test "stream decodes every event across chunks and reads past message_stop" {
  bounded(() => {
    let start = "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"model\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":2,\"output_tokens\":0}}}"
    let block_start = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
    let text_delta = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}"
    let thinking_delta = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"idea\"}}"
    let signature_delta = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}"
    let json_delta = "{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}"
    let block_stop = "{\"type\":\"content_block_stop\",\"index\":0}"
    let delta = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":3}}"
    let unknown = "{\"type\":\"future_event\",\"value\":7}"
    let event_error = "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}"
    let sse = "event: misleading\ndata: " +
      start +
      "\n\ndata: " +
      block_start +
      "\n\ndata: " +
      text_delta +
      "\n\ndata: " +
      thinking_delta +
      "\n\ndata: " +
      signature_delta +
      "\n\ndata: " +
      json_delta +
      "\n\ndata: " +
      block_stop +
      "\n\ndata: " +
      delta +
      "\n\ndata: " +
      unknown +
      "\n\ndata: " +
      event_error +
      "\n\ndata: {\"type\":\"message_stop\"}\n\ndata: {\"type\":\"ping\"}\n\n" +
      // OpenAI-compatible gateways (OpenRouter) append this sentinel; Anthropic itself does not.
      "data: [DONE]\n\n"
    let transport = @mock.FakeTransport::new()
    transport.expect_stream(
      "POST",
      "/v1/messages",
      { status: 200, headers: @http.Headers::new(), },
      split_chunks(sse, [1, 8, 33, 101, 227]),
    )
    let client = @anthropic_sdk.Anthropic::new(
      api_key="test-key",
      transport,
      @mock.FakeClock::new(),
      auth_header=@anthropic_sdk.Bearer,
    )
    let events : Array[@anthropic_sdk.MessageEvent] = []
    client.stream_message(
      @anthropic_sdk.MessageRequest::new(model="model", max_tokens=64, messages=[
        @anthropic_sdk.Message::user("hello"),
      ]),
      event => events.push(event),
    )
    assert_eq(events.length(), 12)
    guard events[0] is @anthropic_sdk.MessageStart(started) else {
      fail("expected MessageStart")
    }
    assert_eq(started.id, "m")
    assert_eq(started.usage.input_tokens, 2)
    assert_eq(
      events[1],
      @anthropic_sdk.ContentBlockStart(index=0, block=@anthropic_sdk.Text("")),
    )
    assert_eq(events[2], @anthropic_sdk.TextDelta(index=0, text="Hi"))
    assert_eq(events[3], @anthropic_sdk.ThinkingDelta(index=1, thinking="idea"))
    assert_eq(events[4], @anthropic_sdk.SignatureDelta(index=1, signature="sig"))
    assert_eq(
      events[5],
      @anthropic_sdk.InputJsonDelta(index=2, partial_json="{}"),
    )
    assert_eq(events[6], @anthropic_sdk.ContentBlockStop(index=0))
    guard events[7] is @anthropic_sdk.MessageDelta(delta~, usage~) else {
      fail("expected MessageDelta")
    }
    assert_eq(delta.stop_reason, Some(@anthropic_sdk.StopReason::EndTurn))
    assert_eq(usage.output_tokens, 3)
    assert_true(events[8] is @anthropic_sdk.Other("future_event", _))
    assert_eq(
      events[9],
      @anthropic_sdk.Error({ type_: "overloaded_error", message: "busy", }),
    )
    assert_eq(events[10], @anthropic_sdk.MessageStop)
    assert_eq(events[11], @anthropic_sdk.Ping)
    assert_eq(transport.streams_closed(), 1)
    let sent = transport.sent()
    assert_eq(sent[0].headers.get("authorization"), Some("Bearer test-key"))
    assert_eq(sent[0].headers.get("accept"), Some("text/event-stream"))
    assert_eq(sent[0].headers.get("anthropic-version"), Some("2023-06-01"))
    assert_eq(sent_json(sent[0]), {
      "model": "model",
      "max_tokens": 64,
      "messages": [{ "role": "user", "content": "hello" }],
      "stream": true,
    })
    transport.assert_complete()
  })
}

///|
priv suberror CallbackFailure {
  CallbackFailure
}

///|
async test "stream closes on callback and decode errors" {
  bounded(() => {
    let callback_transport = @mock.FakeTransport::new()
    callback_transport.expect_stream(
      "POST",
      "/v1/messages",
      { status: 200, headers: @http.Headers::new(), },
      [b"data: {\"type\":\"ping\"}\n\n"],
    )
    let callback_client = @anthropic_sdk.Anthropic::new(
      api_key="key",
      callback_transport,
      @mock.FakeClock::new(),
    )
    try
      callback_client.stream_message(
        @anthropic_sdk.MessageRequest::new(model="m", max_tokens=1, messages=[]),
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
      "/v1/messages",
      { status: 200, headers: @http.Headers::new(), },
      [b"data: {\n\n"],
    )
    let decode_client = @anthropic_sdk.Anthropic::new(
      api_key="key",
      decode_transport,
      @mock.FakeClock::new(),
    )
    try
      decode_client.stream_message(
        @anthropic_sdk.MessageRequest::new(model="m", max_tokens=1, messages=[]),
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
async test "missing fields decode and extra collisions send nothing" {
  bounded(() => {
    let missing = @mock.FakeTransport::new()
    missing.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{\"model\":\"m\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
      ),
    )
    let client = @anthropic_sdk.Anthropic::new(
      api_key="key",
      missing,
      @mock.FakeClock::new(),
    )
    try
      client.create_message(
        @anthropic_sdk.MessageRequest::new(model="m", max_tokens=1, messages=[]),
      )
    catch {
      @runtime.Decode(body~, ..) => assert_true(body.length() > 0)
      _ => fail("missing id must become Decode")
    } noraise {
      _ => fail("missing id must fail")
    }
    missing.assert_complete()

    let collision_transport = @mock.FakeTransport::new()
    let collision_client = @anthropic_sdk.Anthropic::new(
      api_key="key",
      collision_transport,
      @mock.FakeClock::new(),
    )
    try
      collision_client.create_message(
        @anthropic_sdk.MessageRequest::new(
          model="m",
          max_tokens=1,
          messages=[],
          extra={ "stream": false },
        ),
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
async test "count_tokens and the generated passthrough share the transport" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/v1/messages/count_tokens",
      json_response("{\"input_tokens\":21}"),
    )
    transport.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-opus-5\",\"content\":[{\"type\":\"text\",\"text\":\"ok\",\"citations\":null}],\"stop_reason\":\"end_turn\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cache_creation_input_tokens\":null,\"cache_read_input_tokens\":null}}",
      ),
    )
    transport.expect_stream(
      "POST",
      "/v1/messages",
      { status: 200, headers: @http.Headers::new(), },
      [
        b"data: {\"type\":\"ping\"}\n\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n",
      ],
    )
    let client = @anthropic_sdk.Anthropic::new(
      api_key="key",
      transport,
      @mock.FakeClock::new(),
    )
    let request = @anthropic_sdk.MessageRequest::new(
      model="claude-opus-5",
      max_tokens=64,
      messages=[@anthropic_sdk.Message::user("hello")],
      system="brief",
      thinking=@anthropic_gen.ThinkingConfigParam::Adaptive(
        @anthropic_gen.ThinkingConfigAdaptive::new(type_="adaptive"),
      ),
    )
    assert_eq(client.count_tokens(request), 21)
    let params = @anthropic_gen.CreateMessageParams::new(
      model="claude-opus-5",
      max_tokens=8,
      messages=[
        @anthropic_gen.InputMessage::new(
          role=@anthropic_gen.InputMessageRole::User,
          content=@anthropic_gen.InputMessageContent::Text("hello"),
        ),
      ],
      service_tier=@anthropic_gen.CreateMessageParamsServiceTier::StandardOnly,
      stream=true,
    )
    let message = client.create_message_params(params)
    assert_eq(message.id, "m")
    assert_eq(message.stop_reason, Some(@anthropic_gen.StopReason::EndTurn))
    let events : Array[@anthropic_gen.MessageStreamEvent] = []
    client.stream_message_params(params, event => events.push(event))
    assert_eq(events.length(), 3)
    assert_true(events[0] is @anthropic_gen.MessageStreamEvent::Unknown("ping", _))
    guard events[1] is @anthropic_gen.MessageStreamEvent::ContentBlockDelta(delta) else {
      fail("expected a generated delta event")
    }
    assert_eq(delta.index, 0)
    assert_true(events[2] is @anthropic_gen.MessageStreamEvent::MessageStop(_))
    let sent = transport.sent()
    assert_eq(sent[0].url, "https://api.anthropic.com/v1/messages/count_tokens")
    assert_eq(sent_json(sent[0]), {
      "model": "claude-opus-5",
      "messages": [{ "role": "user", "content": "hello" }],
      "system": "brief",
      "thinking": { "type": "adaptive" },
    })
    // The buffered passthrough drops `stream`; the streaming one forces it on.
    assert_eq(sent_json(sent[1]), {
      "model": "claude-opus-5",
      "max_tokens": 8,
      "messages": [{ "role": "user", "content": "hello" }],
      "service_tier": "standard_only",
    })
    assert_eq(sent[2].headers.get("accept"), Some("text/event-stream"))
    assert_eq(sent_json(sent[2]), {
      "model": "claude-opus-5",
      "max_tokens": 8,
      "messages": [{ "role": "user", "content": "hello" }],
      "service_tier": "standard_only",
      "stream": true,
    })
    transport.assert_complete()
  })
}
