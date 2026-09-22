///|
fn json_response(
  body : String,
  status? : Int = 200,
  headers? : @http.Headers = @http.Headers::new(),
) -> @http.Response {
  { status, headers, body: @utf8.encode(body), }
}

///|
fn response_fixture(
  id : String,
  status : String,
  model : String,
  output : String,
  usage? : String = "null",
) -> String {
  "{\"metadata\":{},\"temperature\":1.0,\"top_p\":1.0,\"previous_response_id\":null,\"model\":\"" +
  model +
  "\",\"reasoning\":null,\"max_output_tokens\":null,\"instructions\":null,\"tools\":[],\"tool_choice\":\"auto\",\"id\":\"" +
  id +
  "\",\"object\":\"response\",\"status\":\"" +
  status +
  "\",\"created_at\":1750000000,\"error\":null,\"incomplete_details\":null,\"output\":" +
  output +
  ",\"usage\":" +
  usage +
  ",\"parallel_tool_calls\":true}"
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
        response_fixture(
          "resp_67ccd2",
          "completed",
          "gpt-4.1-2025-04-14",
          "[{\"type\":\"reasoning\",\"id\":\"reasoning-1\",\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"Think.\"}]},{\"type\":\"message\",\"id\":\"message-1\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"A short story.\"}]}]",
          usage="{\"input_tokens\":36,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":87,\"output_tokens_details\":{\"reasoning_tokens\":1},\"total_tokens\":123}",
        ),
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
    assert_eq(@json.parse(@utf8.decode(sent[2].body)), {
      "input": ["The food was delicious"],
      "model": "text-embedding-ada-002",
      "dimensions": 2,
      "user": "user-1234",
    })
    assert_eq(sent[2].headers.get("content-type"), Some("application/json"))
    assert_eq(@json.parse(@utf8.decode(sent[3].body)), {
      "temperature": 0.5,
      "previous_response_id": "resp_previous",
      "model": "gpt-4.1",
      "max_output_tokens": 100,
      "instructions": "Three sentences.",
      "input": "Tell me a short story.",
      "metadata": { "source": "test" },
    })
    assert_eq(sent[3].headers.get("content-type"), Some("application/json"))
    assert_eq(clock.slept(), [])
    transport.assert_complete()
  })
}

///|
fn chat_fixture(
  content : String,
  finish_reason : String,
  usage? : String = "null",
) -> String {
  "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"created\":1750000000,\"model\":\"gpt-chat\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":" +
  content +
  ",\"refusal\":null},\"finish_reason\":\"" +
  finish_reason +
  "\",\"logprobs\":null}],\"usage\":" +
  usage +
  "}"
}

///|
async test "chat completions send exact JSON and retain nullable and unknown response values" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/v1/chat/completions",
      json_response(
        chat_fixture(
          "\"Hello.\"",
          "stop",
          usage="{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5}",
        ),
      ),
    )
    transport.expect(
      "POST",
      "/v1/chat/completions",
      json_response(chat_fixture("null", "length")),
    )
    transport.expect(
      "POST",
      "/v1/chat/completions",
      json_response(chat_fixture("\"future\"", "future_reason")),
    )
    let client = @openai_sdk.OpenAI::new(
      api_key="test-key",
      transport,
      @mock.FakeClock::new(),
    )
    let normal = client.chat_completion(
      @openai_sdk.ChatRequest::new(
        model="gpt-chat",
        messages=[
          @openai_sdk.ChatMessage::system("Be concise."),
          @openai_sdk.ChatMessage::user("Hello"),
        ],
        max_tokens=16,
        temperature=0.25,
        extra={ "seed": 7 },
      ),
    )
    assert_eq(normal.id, "chatcmpl-1")
    assert_eq(normal.model, "gpt-chat")
    assert_eq(normal.text, "Hello.")
    assert_eq(normal.finish_reason, Some(@openai_sdk.Stop))
    assert_eq(
      normal.usage,
      Some({ input_tokens: 3, output_tokens: 2, total_tokens: 5, }),
    )
    assert_eq(
      normal.raw,
      @json.parse(
        chat_fixture(
          "\"Hello.\"",
          "stop",
          usage="{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5}",
        ),
      ),
    )
    let null_content = client.chat_completion(
      @openai_sdk.ChatRequest::new(model="gpt-chat", messages=[
        @openai_sdk.ChatMessage::user("Hello"),
      ]),
    )
    assert_eq(null_content.text, "")
    assert_eq(null_content.finish_reason, Some(@openai_sdk.Length))
    let unknown = client.chat_completion(
      @openai_sdk.ChatRequest::new(model="gpt-chat", messages=[
        @openai_sdk.ChatMessage::user("Hello"),
      ]),
    )
    assert_eq(unknown.finish_reason, Some(@openai_sdk.Unknown("future_reason")))
    let sent = transport.sent()
    assert_eq(@json.parse(@utf8.decode(sent[0].body)), {
      "model": "gpt-chat",
      "messages": [
        { "role": "system", "content": "Be concise." },
        { "role": "user", "content": "Hello" },
      ],
      "temperature": 0.25,
      "max_tokens": 16,
      "seed": 7,
    })
    assert_eq(sent[0].headers.get("content-type"), Some("application/json"))
    transport.assert_complete()
  })
}

///|
async test "chat completion streaming handles split reasoning usage and DONE" {
  bounded(() => {
    let chunk1 = "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"created\":1750000000,\"model\":\"gpt-chat\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\",\"reasoning_content\":\"Think\"},\"finish_reason\":null}]}"
    let chunk2 = "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"created\":1750000000,\"model\":\"gpt-chat\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\" more\"},\"finish_reason\":null}]}"
    let chunk3 = "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"created\":1750000000,\"model\":\"gpt-chat\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"
    let usage = "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"created\":1750000000,\"model\":\"gpt-chat\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"total_tokens\":6}}"
    let sse = "data: " +
      chunk1 +
      "\n\ndata: " +
      chunk2 +
      "\n\ndata: " +
      chunk3 +
      "\n\ndata: " +
      usage +
      "\n\ndata: [DONE]\n\ndata: not-json\n\n"
    let transport = @mock.FakeTransport::new()
    transport.expect_stream(
      "POST",
      "/chat/completions",
      { status: 200, headers: @http.Headers::new(), },
      split_chunks(sse, [1, 5, 17, 61, 157, 311]),
    )
    let client = @openai_sdk.OpenAI::from_client(
      @runtime.Client::new(
        transport,
        @mock.FakeClock::new(),
        base_url="https://api.test",
      ),
    )
    let events : Array[@openai_sdk.ChatEvent] = []
    client.stream_chat_completion(
      @openai_sdk.ChatRequest::new(model="gpt-chat", messages=[
        @openai_sdk.ChatMessage::user("Hello"),
      ]),
      event => events.push(event),
    )
    assert_eq(events, [
      @openai_sdk.Delta("Hel"),
      @openai_sdk.ReasoningDelta("Think"),
      @openai_sdk.ReasoningDelta(" more"),
      @openai_sdk.Finished(@openai_sdk.Stop),
      @openai_sdk.Usage({ input_tokens: 4, output_tokens: 2, total_tokens: 6, }),
    ])
    assert_eq(transport.streams_closed(), 1)
    let sent = transport.sent()
    assert_eq(sent.length(), 1)
    assert_eq(sent[0].headers.get("accept"), Some("text/event-stream"))
    assert_eq(@json.parse(@utf8.decode(sent[0].body)), {
      "model": "gpt-chat",
      "messages": [{ "role": "user", "content": "Hello" }],
      "stream": true,
      "stream_options": { "include_usage": true },
    })
    transport.assert_complete()
  })
}

///|
async test "tool calls decode from OpenAI and Ollama fixtures and stream in wire order" {
  bounded(() => {
    let documented =
      #|{"id":"chatcmpl-tool","object":"chat.completion","created":1750000000,"model":"gpt-chat","choices":[{"index":0,"message":{"role":"assistant","content":null,"refusal":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Tokyo\"}"}}]},"finish_reason":"tool_calls","logprobs":null}],"usage":null}
      #|
    let ollama =
      #|{"id":"chatcmpl-ollama","object":"chat.completion","created":1750000000,"model":"qwen","choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_ollama","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Osaka\"}"}}]},"finish_reason":"tool_calls"}],"usage":null}
      #|
    let chunk1 =
      #|{"id":"chatcmpl-stream","object":"chat.completion.chunk","created":1750000000,"model":"gpt-chat","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_stream","type":"function","function":{"name":"get_weather","arguments":"{\"city\":"}}]},"finish_reason":null}]}
      #|
    let chunk2 =
      #|{"id":"chatcmpl-stream","object":"chat.completion.chunk","created":1750000000,"model":"gpt-chat","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"type":"function","function":{"arguments":"\"Tok"}}]},"finish_reason":null}]}
      #|
    let chunk3 =
      #|{"id":"chatcmpl-stream","object":"chat.completion.chunk","created":1750000000,"model":"gpt-chat","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"type":"function","function":{"arguments":"yo\"}"}}]},"finish_reason":null}]}
      #|
    let finished =
      #|{"id":"chatcmpl-stream","object":"chat.completion.chunk","created":1750000000,"model":"gpt-chat","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
      #|
    let transport = @mock.FakeTransport::new()
    transport.expect("POST", "/chat/completions", json_response(documented))
    transport.expect("POST", "/chat/completions", json_response(ollama))
    transport.expect_stream(
      "POST",
      "/chat/completions",
      { status: 200, headers: @http.Headers::new(), },
      split_chunks(
        "data: " +
        chunk1 +
        "\n\ndata: " +
        chunk2 +
        "\n\ndata: " +
        chunk3 +
        "\n\ndata: " +
        finished +
        "\n\ndata: [DONE]\n\n",
        [3, 47, 191, 337],
      ),
    )
    let client = @openai_sdk.OpenAI::from_client(
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
    let documented_response = client.chat_completion(
      @openai_sdk.ChatRequest::new(
        model="gpt-chat",
        messages=[@openai_sdk.ChatMessage::user("weather")],
        tools=[
          @openai_sdk.ToolDef::new(
            name="get_weather",
            parameters=schema,
            description="Get weather",
          ),
        ],
        tool_choice="auto",
      ),
    )
    assert_eq(documented_response.text, "")
    assert_eq(documented_response.finish_reason, Some(@openai_sdk.ToolCalls))
    assert_eq(documented_response.tool_calls, [
      { id: "call_1", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}", },
    ])
    assert_eq(documented_response.tool_calls[0].arguments_json(), {
      "city": "Tokyo",
    })
    let ollama_response = client.chat_completion(
      @openai_sdk.ChatRequest::new(model="qwen", messages=[
        @openai_sdk.ChatMessage::user("weather"),
      ]),
    )
    assert_eq(ollama_response.tool_calls[0].id, "call_ollama")
    assert_eq(ollama_response.tool_calls[0].name, "get_weather")

    let events : Array[@openai_sdk.ChatEvent] = []
    let accumulator = @openai_sdk.ToolCallAccumulator::new()
    client.stream_chat_completion(
      @openai_sdk.ChatRequest::new(model="gpt-chat", messages=[
        @openai_sdk.ChatMessage::user("weather"),
      ]),
      event => {
        events.push(event)
        if event is @openai_sdk.ToolCallDelta(index~, id~, name~, arguments~) {
          accumulator.feed(index~, id?, name?, arguments~)
        }
      },
    )
    assert_eq(events, [
      @openai_sdk.ToolCallDelta(
        index=0,
        id=Some("call_stream"),
        name=Some("get_weather"),
        arguments="{\"city\":",
      ),
      @openai_sdk.ToolCallDelta(index=0, id=None, name=None, arguments="\"Tok"),
      @openai_sdk.ToolCallDelta(index=0, id=None, name=None, arguments="yo\"}"),
      @openai_sdk.Finished(@openai_sdk.ToolCalls),
    ])
    assert_eq(accumulator.finish(), [
      {
        id: "call_stream",
        name: "get_weather",
        arguments: "{\"city\":\"Tokyo\"}",
      },
    ])
    let sent = transport.sent()
    assert_eq(@json.parse(@utf8.decode(sent[0].body)), {
      "model": "gpt-chat",
      "messages": [{ "role": "user", "content": "weather" }],
      "tools": [
        {
          "type": "function",
          "function": {
            "name": "get_weather",
            "description": "Get weather",
            "parameters": schema,
          },
        },
      ],
      "tool_choice": "auto",
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
      json_response(response_fixture("r", "completed", "g", "[]")),
    )
    transport.expect(
      "POST",
      "/chat/completions",
      json_response(chat_fixture("\"ok\"", "stop")),
    )
    transport.expect_stream(
      "POST",
      "/responses",
      { status: 200, headers: @http.Headers::new(), },
      [b"data: [DONE]\n\n"],
    )
    transport.expect_stream(
      "POST",
      "/chat/completions",
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
    ignore(
      client.chat_completion(
        @openai_sdk.ChatRequest::new(model="g", messages=[
          @openai_sdk.ChatMessage::user("i"),
        ]),
      ),
    )
    client.stream_response(
      @openai_sdk.ResponseRequest::new(model="g", input="i"),
      _ => (),
    )
    client.stream_chat_completion(
      @openai_sdk.ChatRequest::new(model="g", messages=[
        @openai_sdk.ChatMessage::user("i"),
      ]),
      _ => (),
    )
    assert_eq(limiter.acquired, [
      "models", "models", "embeddings", "responses", "chat", "responses", "chat",
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
    assert_eq(transport.streams_closed(), 2)
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
    let created = "{\"type\":\"response.created\",\"response\":" +
      response_fixture("resp_123", "in_progress", "gpt-4o", "[]") +
      "}"
    let delta = "{\"type\":\"response.output_text.delta\",\"item_id\":\"msg_123\",\"output_index\":0,\"content_index\":0,\"delta\":\"In\"}"
    let done = "{\"type\":\"response.output_text.done\",\"item_id\":\"msg_123\",\"output_index\":0,\"content_index\":0,\"text\":\"In a grove.\"}"
    let unknown = "{\"type\":\"response.future\",\"value\":7}"
    let event_error = "{\"type\":\"error\",\"code\":\"ERR_SOMETHING\",\"message\":\"Something went wrong\",\"param\":null}"
    let completed = "{\"type\":\"response.completed\",\"response\":" +
      response_fixture(
        "resp_123", "completed", "gpt-4o", "[{\"type\":\"message\",\"id\":\"message-1\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"In a grove.\"}]}]",
      ) +
      "}"
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
    assert_eq(@json.parse(@utf8.decode(sent[0].body)), {
      "model": "gpt-4o",
      "input": "story",
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
async test "streaming closes on callback and decode errors" {
  bounded(() => {
    let created = "{\"type\":\"response.created\",\"response\":" +
      response_fixture("r", "in_progress", "g", "[]") +
      "}"
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
      [
        b"data: {\"type\":\"response.output_text.delta\",\"delta\":\"missing generated fields\"}\n\n",
      ],
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
      @runtime.Decode(
        body=b"{\"type\":\"response.output_text.delta\",\"delta\":\"missing generated fields\"}",
        ..
      ) => ()
      _ => fail("invalid generated event payload must become Decode")
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
