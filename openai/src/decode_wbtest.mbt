///|
fn test_response(body : String) -> @http.Response {
  { status: 200, headers: @http.Headers::new(), body: @utf8.encode(body), }
}

///|
fn openrouter_response_fixture() -> String {
  (
    #|{
    #|  "metadata": {},
    #|  "temperature": 1.0,
    #|  "top_p": 1.0,
    #|  "previous_response_id": null,
    #|  "model": "openai/gpt-5",
    #|  "reasoning": null,
    #|  "max_output_tokens": null,
    #|  "instructions": null,
    #|  "tools": [],
    #|  "tool_choice": "auto",
    #|  "id": "resp_openrouter_fixture",
    #|  "object": "response",
    #|  "status": "future_status",
    #|  "created_at": 1750000000,
    #|  "error": null,
    #|  "incomplete_details": null,
    #|  "output": [
    #|    {
    #|      "type": "reasoning",
    #|      "id": "reasoning-1",
    #|      "summary": [],
    #|      "content": [{"type":"reasoning_text","text":"Think carefully."}]
    #|    },
    #|    {"type":"future_output","value":42},
    #|    {
    #|      "type": "message",
    #|      "id": "message-1",
    #|      "role": "assistant",
    #|      "status": "completed",
    #|      "content": [
    #|        {"type":"output_text","text":"hello "},
    #|        {"type":"refusal","refusal":"no"},
    #|        {"type":"output_text","text":"world"}
    #|      ]
    #|    }
    #|  ],
    #|  "usage": {
    #|    "input_tokens": 2,
    #|    "input_tokens_details": {"cached_tokens": 0},
    #|    "output_tokens": 3,
    #|    "output_tokens_details": {"reasoning_tokens": 1},
    #|    "total_tokens": 5
    #|  },
    #|  "parallel_tool_calls": true,
    #|  "future": 42
    #|}
  )
}

///|
test "model number decoding accepts values above Int32 and rejects invalid Int64 values" {
  let model_text =
    #|{"id":"future-model","created":2147483648,"owned_by":"openai","future":true}
    #|
  let generated : @gen.Model = @json.from_json(@json.parse(model_text))
  assert_eq(model_from_generated(generated), {
    id: "future-model",
    created: Some(2147483648L),
    owned_by: Some("openai"),
  })
  for created in ["1.5", "9223372036854775808", "-9223372036854775809"] {
    try {
      let _ : @gen.Model = @json.from_json(
        @json.parse("{\"id\":\"bad\",\"created\":" + created + "}"),
      )
    } catch {
      @json.JsonDecodeError(_) => ()
      _ => fail("unexpected error type")
    } noraise {
      _ => fail("invalid Int64 number must fail: " + created)
    }
  }
}

///|
test "generated response conversion skips reasoning and unknown output items" {
  let text = openrouter_response_fixture()
  let raw = @json.parse(text)
  let response = decode_response(test_response(text))
  assert_eq(response.id, "resp_openrouter_fixture")
  assert_eq(response.status, Unknown("future_status"))
  assert_eq(response.output_text, "hello world")
  assert_eq(
    response.usage,
    Some({ input_tokens: 2, output_tokens: 3, total_tokens: 5, }),
  )
  assert_eq(response.raw, raw)
}

///|
test "generated event conversion retains unknown events and rejects malformed known payloads" {
  assert_eq(
    decode_response_event(
      @json.parse(
        "{\"type\":\"response.output_text.delta\",\"item_id\":\"m\",\"output_index\":0,\"content_index\":0,\"delta\":\"In\",\"future\":1}",
      ),
    ),
    OutputTextDelta("In"),
  )
  let unknown = @json.parse("{\"type\":\"response.future\",\"value\":7}")
  assert_eq(decode_response_event(unknown), Other("response.future", unknown))
  assert_eq(
    decode_response_event(
      @json.parse(
        "{\"type\":\"error\",\"code\":\"ERR\",\"message\":\"failed\",\"param\":null}",
      ),
    ),
    Error({ message: "failed", type_: None, param: None, code: Some("ERR"), }),
  )
  try
    ignore(
      decode_response_event(
        @json.parse(
          "{\"type\":\"response.output_text.delta\",\"delta\":\"missing generated fields\"}",
        ),
      ),
    )
  catch {
    @json.JsonDecodeError(_) => ()
    _ => fail("expected generated decoding failure")
  } noraise {
    _ => fail("malformed known event payload must fail")
  }
}

///|
test "request body builder uses generated JSON and rejects every known extra collision" {
  let request = ResponseRequest::new(
    model="gpt",
    input="hello",
    instructions="brief",
    extra={ "metadata": { "x": 1 } },
  )
  assert_eq(response_parts(request, true).1, {
    "model": "gpt",
    "instructions": "brief",
    "input": "hello",
    "stream": true,
    "metadata": { "x": 1 },
  })
  for
    key in [
      "model", "input", "instructions", "max_output_tokens", "temperature", "previous_response_id",
      "tools", "tool_choice", "stream",
    ] {
    let collision = ResponseRequest::new(
      model="gpt",
      input="hello",
      extra=Map::from_array([(key, Json::null())]),
    )
    try response_parts(collision, false) catch {
      @runtime.Config(message) => assert_true(message.contains(key))
      _ => fail("expected Config")
    } noraise {
      _ => fail("known extra key must fail")
    }
  }
}

///|
test "chat request conversion validates roles and uses explicit tool_call_id" {
  let tool : ChatMessage = {
    role: "tool",
    content: "result",
    name: Some("weather_result"),
    tool_calls: None,
    tool_call_id: Some("call_1"),
  }
  assert_eq(
    chat_parts(
      ChatRequest::new(model="g", messages=[tool], extra={ "seed": 2 }),
      true,
    ).1,
    {
      "model": "g",
      "messages": [
        {
          "role": "tool",
          "content": "result",
          "name": "weather_result",
          "tool_call_id": "call_1",
        },
      ],
      "stream": true,
      "stream_options": { "include_usage": true },
      "seed": 2,
    },
  )
  for
    key in [
      "model", "messages", "max_tokens", "temperature", "reasoning_effort", "tools",
      "tool_choice", "stream", "stream_options",
    ] {
    try
      ignore(
        chat_parts(
          ChatRequest::new(
            model="g",
            messages=[ChatMessage::user("hello")],
            extra=Map::from_array([(key, Json::null())]),
          ),
          false,
        ),
      )
    catch {
      @runtime.Config(message) => assert_true(message.contains(key))
      _ => fail("expected Config")
    } noraise {
      _ => fail("known chat key must fail")
    }
  }
  try
    ignore(
      chat_parts(
        ChatRequest::new(model="g", messages=[
          {
            role: "future",
            content: "hello",
            name: None,
            tool_calls: None,
            tool_call_id: None,
          },
        ]),
        false,
      ),
    )
  catch {
    @runtime.Config(message) => assert_true(message.contains("future"))
    _ => fail("expected Config")
  } noraise {
    _ => fail("unknown role must fail")
  }
}

///|
test "tool request encoding is exact for chat and responses" {
  let schema : Json = {
    "type": "object",
    "properties": { "city": { "type": "string" } },
    "required": ["city"],
  }
  let tool = ToolDef::new(
    name="get_weather",
    description="Get weather",
    parameters=schema,
    strict=true,
  )
  let call : ToolCall = {
    id: "call_1",
    name: "get_weather",
    arguments: "{\"city\":\"Tokyo\"}",
  }
  let choice : Json = {
    "type": "function",
    "function": { "name": "get_weather" },
  }
  assert_eq(
    chat_parts(
      ChatRequest::new(
        model="gpt",
        messages=[
          ChatMessage::assistant_tool_calls([call]),
          ChatMessage::tool(tool_call_id="call_1", content="sunny"),
        ],
        tools=[tool],
        tool_choice=choice,
      ),
      false,
    ).1,
    {
      "model": "gpt",
      "messages": [
        {
          "role": "assistant",
          "tool_calls": [
            {
              "id": "call_1",
              "type": "function",
              "function": {
                "name": "get_weather",
                "arguments": "{\"city\":\"Tokyo\"}",
              },
            },
          ],
        },
        { "role": "tool", "content": "sunny", "tool_call_id": "call_1" },
      ],
      "tools": [
        {
          "type": "function",
          "function": {
            "name": "get_weather",
            "description": "Get weather",
            "parameters": schema,
            "strict": true,
          },
        },
      ],
      "tool_choice": choice,
    },
  )
  assert_eq(
    response_parts(
      ResponseRequest::new(
        model="gpt",
        input="weather",
        tools=[tool],
        tool_choice="auto",
      ).with_tool_outputs([("call_1", "sunny")]),
      false,
    ).1,
    {
      "model": "gpt",
      "input": [
        { "role": "user", "content": "weather" },
        {
          "type": "function_call_output",
          "call_id": "call_1",
          "output": "sunny",
        },
      ],
      "tools": [
        {
          "type": "function",
          "name": "get_weather",
          "description": "Get weather",
          "parameters": schema,
          "strict": true,
        },
      ],
      "tool_choice": "auto",
    },
  )
}

///|
test "responses decode function calls and function argument events" {
  let text =
    #|{
    #|  "metadata":{},"temperature":1,"top_p":1,"previous_response_id":null,
    #|  "model":"gpt","reasoning":null,"max_output_tokens":null,"instructions":null,
    #|  "tools":[],"tool_choice":"auto","id":"resp_1","object":"response",
    #|  "status":"completed","created_at":1,"error":null,"incomplete_details":null,
    #|  "output":[{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":"{\"city\":\"Tokyo\"}","status":"completed"}],
    #|  "usage":null,"parallel_tool_calls":true
    #|}
    #|
  let response = decode_response(test_response(text))
  assert_eq(response.tool_calls, [
    { id: "call_1", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}", },
  ])
  assert_eq(
    decode_response_event(
      @json.parse(
        "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"output_index\":0,\"delta\":\"{\"}",
      ),
    ),
    FunctionCallArgumentsDelta(item_id="fc_1", delta="{"),
  )
  assert_eq(
    decode_response_event(
      @json.parse(
        "{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_1\",\"output_index\":0,\"arguments\":\"{}\"}",
      ),
    ),
    FunctionCallArgumentsDone(item_id="fc_1", arguments="{}"),
  )
}

///|
test "chat decoding retains invalid tool argument JSON as raw text" {
  let text =
    #|{"id":"chatcmpl-bad-args","object":"chat.completion","created":1,"model":"gpt","choices":[{"index":0,"message":{"role":"assistant","content":null,"refusal":null,"tool_calls":[{"id":"call_bad","type":"function","function":{"name":"lookup","arguments":"{"}}]},"finish_reason":"tool_calls","logprobs":null}],"usage":null}
    #|
  let completion = decode_chat_completion(test_response(text))
  assert_eq(completion.tool_calls[0].arguments, "{")
  try ignore(completion.tool_calls[0].arguments_json()) catch {
    @json.InvalidEof => ()
    _ => fail("expected InvalidEof")
  } noraise {
    _ => fail("invalid arguments_json must fail only when parsed explicitly")
  }
}

///|
test "reasoning_effort passes through the open enum, including values newer than the spec" {
  for effort in ["low", "xhigh", "none"] {
    let (_, body) = chat_parts(
      ChatRequest::new(
        model="g",
        messages=[ChatMessage::user("hi")],
        reasoning_effort=effort,
      ),
      false,
    )
    guard body is Object(fields) else { fail("object body") }
    assert_eq(fields.get("reasoning_effort"), Some(Json(effort)))
  }
  let (_, body) = chat_parts(
    ChatRequest::new(model="g", messages=[ChatMessage::user("hi")]),
    false,
  )
  guard body is Object(fields) else { fail("object body") }
  assert_false(fields.contains("reasoning_effort"))
}
