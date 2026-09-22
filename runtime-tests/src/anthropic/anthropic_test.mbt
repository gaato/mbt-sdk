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
async test "Anthropic sends exact request and decodes a compatible response" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-sonnet-4-5\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"},{\"type\":\"thinking\",\"thinking\":\"Reason\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":8,\"output_tokens\":5,\"cost\":0}}",
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
        model="claude-sonnet-4-5",
        max_tokens=64,
        messages=[@anthropic_sdk.Message::user("Hello")],
        system="Be brief",
        temperature=0.2,
        stop_sequences=["END"],
        extra={ "metadata": { "source": "test" } },
      ),
    )
    assert_eq(response.role, @anthropic_sdk.Assistant)
    assert_eq(response.text(), "Hello")
    assert_eq(response.usage, { input_tokens: 8, output_tokens: 5, })
    let sent = transport.sent()
    assert_eq(sent.length(), 1)
    assert_eq(sent[0].http_method, "POST")
    assert_eq(sent[0].url, "https://api.anthropic.com/v1/messages")
    assert_eq(sent[0].headers.get("x-api-key"), Some("test-key"))
    assert_eq(sent[0].headers.get("authorization"), None)
    assert_eq(sent[0].headers.get("anthropic-version"), Some("2024-01-01"))
    assert_eq(sent[0].headers.get("content-type"), Some("application/json"))
    assert_eq(
      sent[0].body,
      @utf8.encode(
        "{\"model\":\"claude-sonnet-4-5\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"system\":\"Be brief\",\"temperature\":0.2,\"stop_sequences\":[\"END\"],\"metadata\":{\"source\":\"test\"}}",
      ),
    )
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
async test "from_client uses Bearer configuration version and messages bucket" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/messages",
      json_response(
        "{\"id\":\"m\",\"model\":\"model\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}",
      ),
    )
    let limiter = RecordingLimiter::{ acquired: [], observed: [], }
    let runtime = @runtime.Client::new(
      transport,
      @mock.FakeClock::new(),
      base_url="https://openrouter.ai/api/v1",
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
    let sent = transport.sent()
    assert_eq(sent[0].url, "https://openrouter.ai/api/v1/messages")
    assert_eq(sent[0].headers.get("authorization"), Some("Bearer router-key"))
    assert_eq(sent[0].headers.get("x-api-key"), None)
    assert_eq(sent[0].headers.get("anthropic-version"), Some("2023-06-01"))
    assert_eq(limiter.acquired, ["messages"])
    assert_eq(limiter.observed, ["messages"])
    limiter.acquire("direct-check")
    limiter.observe(
      "direct-check",
      200,
      @http.Headers::new(),
      @mock.FakeClock::new().now_unix_ms(),
    )
    assert_eq(limiter.acquired.last(), Some("direct-check"))
    assert_eq(limiter.observed.last(), Some("direct-check"))
    transport.assert_complete()
  })
}

///|
async test "HTTP errors expose API bodies and 429 retries before success" {
  bounded(() => {
    let failures = @mock.FakeTransport::new()
    let error_body = "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"bad key\"}}"
    failures.expect("POST", "/messages", json_response(error_body, status=401))
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
      "/messages",
      json_response(
        "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}",
        status=429,
        headers=@http.Headers::from_array([("retry-after", "0.25")]),
      ),
    )
    retrying.expect(
      "POST",
      "/messages",
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
    let json_delta = "{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}"
    let block_stop = "{\"type\":\"content_block_stop\",\"index\":0}"
    let delta = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}"
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
      "/messages",
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
    assert_eq(events.length(), 11)
    assert_true(events[0] is @anthropic_sdk.MessageStart(_))
    assert_eq(
      events[1],
      @anthropic_sdk.ContentBlockStart(index=0, block=@anthropic_sdk.Text("")),
    )
    assert_eq(events[2], @anthropic_sdk.TextDelta(index=0, text="Hi"))
    assert_eq(events[3], @anthropic_sdk.ThinkingDelta(index=1, thinking="idea"))
    assert_eq(
      events[4],
      @anthropic_sdk.InputJsonDelta(index=2, partial_json="{}"),
    )
    assert_eq(events[5], @anthropic_sdk.ContentBlockStop(index=0))
    assert_eq(
      events[6],
      @anthropic_sdk.MessageDelta(
        stop_reason=Some(@anthropic_sdk.EndTurn),
        output_tokens=Some(3),
      ),
    )
    assert_true(events[7] is @anthropic_sdk.Other("future_event", _))
    assert_eq(
      events[8],
      @anthropic_sdk.Error({ type_: "overloaded_error", message: "busy", }),
    )
    assert_eq(events[9], @anthropic_sdk.MessageStop)
    assert_eq(events[10], @anthropic_sdk.Ping)
    assert_eq(transport.streams_closed(), 1)
    let sent = transport.sent()
    assert_eq(sent[0].headers.get("authorization"), Some("Bearer test-key"))
    assert_eq(sent[0].headers.get("accept"), Some("text/event-stream"))
    assert_eq(sent[0].headers.get("anthropic-version"), Some("2023-06-01"))
    assert_eq(
      sent[0].body,
      @utf8.encode(
        "{\"model\":\"model\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"stream\":true}",
      ),
    )
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
      "/messages",
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
      "/messages",
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
      "/messages",
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
