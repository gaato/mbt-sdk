///|
fn parse(text : String) -> Json raise {
  @json.parse(text)
}

///|
test "request body is the generated encoding plus extra, and extra is validated" {
  let request = MessageRequest::new(
    model="claude-opus-5",
    max_tokens=64,
    messages=[
      Message::user("hello"),
      Message::user_blocks([
        @gen.InputContentBlock::Image(
          @gen.RequestImageBlock::new(
            type_="image",
            source=@gen.RequestImageBlockSource::Base64(
              @gen.Base64ImageSource::new(
                type_="base64",
                media_type=@gen.Base64ImageSourceMediaType::ImagePng,
                data="abc",
              ),
            ),
          ),
        ),
        @gen.InputContentBlock::Unknown("future_block", {
          "type": "future_block",
          "value": 1,
        }),
      ]),
    ],
    system="be brief",
    temperature=0.25,
    stop_sequences=["END"],
    metadata=@gen.Metadata::new(user_id="u1"),
    extra={ "top_p": 0.9, "provider": { "order": ["anthropic"] } },
  )
  let (params, body) = message_body(request, false)
  assert_eq(body, {
    "model": "claude-opus-5",
    "messages": [
      { "role": "user", "content": "hello" },
      {
        "role": "user",
        "content": [
          {
            "type": "image",
            "source": {
              "type": "base64",
              "media_type": "image/png",
              "data": "abc",
            },
          },
          { "type": "future_block", "value": 1 },
        ],
      },
    ],
    "max_tokens": 64,
    "metadata": { "user_id": "u1" },
    "stop_sequences": ["END"],
    "system": "be brief",
    "temperature": 0.25,
    "top_p": 0.9,
    "provider": { "order": ["anthropic"] },
  })
  // The generated request reflects the merged body, including extra keys it models.
  assert_eq(params.top_p, Some(0.9))
  let (_, streaming) = message_body(request, true)
  guard streaming is Object(fields) else { fail("body must be an object") }
  assert_eq(fields.get("stream"), Some(Json(true)))
  for
    key in [
      "model", "max_tokens", "messages", "system", "temperature", "stop_sequences",
      "tools", "tool_choice", "thinking", "output_config", "metadata", "stream",
    ] {
    let collision = MessageRequest::new(
      model="m",
      max_tokens=1,
      messages=[],
      extra=Map::from_array([(key, Json::null())]),
    )
    try message_body(collision, false) catch {
      @runtime.Config(message) => assert_true(message.contains(key))
      _ => fail("expected Config")
    } noraise {
      _ => fail("known extra key must fail")
    }
  }
  // Extra keys the schema models are validated against it.
  let invalid = MessageRequest::new(model="m", max_tokens=1, messages=[], extra={
    "top_p": "high",
  })
  try message_body(invalid, false) catch {
    @runtime.Config(message) => assert_true(message.contains("top_p"))
    _ => fail("expected Config")
  } noraise {
    _ => fail("schema violation in extra must fail")
  }
}

///|
test "typed request fields encode through the generated vocabulary" {
  let schema : Json = {
    "type": "object",
    "properties": { "city": { "type": "string" } },
    "required": ["city"],
  }
  let request = MessageRequest::new(
    model="claude",
    max_tokens=64,
    messages=[
      Message::assistant_blocks([
        @gen.InputContentBlock::ToolUse(
          @gen.RequestToolUseBlock::new(
            id="toolu_1",
            name="get_weather",
            input={ "city": "Tokyo" },
            type_="tool_use",
          ),
        ),
      ]),
      Message::tool_result(
        tool_use_id="toolu_1",
        content="sunny",
        is_error=false,
      ),
    ],
    tools=[
      ToolDef::new(
        name="get_weather",
        description="Get weather",
        input_schema=schema,
      ),
    ],
    tool_choice=tool_choice_tool("get_weather"),
    thinking=@gen.ThinkingConfigParam::Adaptive(
      @gen.ThinkingConfigAdaptive::new(type_="adaptive"),
    ),
  )
  let (_, body) = message_body(request, false)
  assert_eq(body, {
    "model": "claude",
    "messages": [
      {
        "role": "assistant",
        "content": [
          {
            "type": "tool_use",
            "id": "toolu_1",
            "name": "get_weather",
            "input": { "city": "Tokyo" },
          },
        ],
      },
      {
        "role": "user",
        "content": [
          {
            "type": "tool_result",
            "tool_use_id": "toolu_1",
            "content": "sunny",
            "is_error": false,
          },
        ],
      },
    ],
    "max_tokens": 64,
    "thinking": { "type": "adaptive" },
    "tool_choice": { "type": "tool", "name": "get_weather" },
    "tools": [
      {
        "name": "get_weather",
        "description": "Get weather",
        "input_schema": schema,
      },
    ],
  })
  let (_, counted) = count_tokens_body(request)
  guard counted is Object(fields) else { fail("body must be an object") }
  assert_eq(fields.get("max_tokens"), None)
  assert_eq(fields.get("model"), Some(Json("claude")))
  assert_eq(
    fields.get("tool_choice"),
    Some({ "type": "tool", "name": "get_weather" }),
  )
  assert_eq(tool_choice_auto().to_json(), { "type": "auto" })
  assert_eq(tool_choice_any(disable_parallel_tool_use=true).to_json(), {
    "type": "any",
    "disable_parallel_tool_use": true,
  })
  assert_eq(tool_choice_none().to_json(), { "type": "none" })
}

///|
test "generated model metadata distinguishes required null from missing" {
  let complete : Json = {
    "type": "model",
    "id": "test-model",
    "created_at": "2026-09-23T00:00:00Z",
    "display_name": "Test model",
    "capabilities": Json::null(),
    "max_input_tokens": Json::null(),
    "max_tokens": Json::null(),
  }
  let model : @gen.ModelInfo = @json.from_json(complete)
  assert_eq(model.max_tokens, None)
  guard complete is Object(fields) else { fail("expected object") }
  fields.remove("max_tokens")
  try (@json.from_json(complete) : @gen.ModelInfo) catch {
    @json.JsonDecodeError(_) => ()
  } noraise {
    _ => fail("missing required nullable field must fail")
  }
}

///|
test "response decoder handles documented and compatible-provider shapes" {
  let text =
    #|{
    #|  "id":"msg_01XFDUDYJgAACzvnptvVoYEL",
    #|  "type":"message",
    #|  "role":"assistant",
    #|  "model":"claude-opus-5",
    #|  "content":[
    #|    {"type":"text","text":"Hello!"},
    #|    {"type":"thinking","thinking":"Consider the request.","signature":"sig_1"},
    #|    {"type":"redacted_thinking","data":"opaque"},
    #|    {"type":"tool_use","id":"toolu_1","name":"weather","input":{"city":"Tokyo"}},
    #|    {"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"query":"x"}},
    #|    {"type":"future_block","value":7}
    #|  ],
    #|  "stop_reason":"future_reason",
    #|  "usage":{"input_tokens":12,"output_tokens":9,"cost":0.001},
    #|  "provider":"openrouter"
    #|}
    #|
  let raw = parse(text)
  let response = decode_message_response(raw)
  assert_eq(response.id, "msg_01XFDUDYJgAACzvnptvVoYEL")
  assert_eq(response.model, "claude-opus-5")
  assert_eq(response.role, Assistant)
  assert_eq(response.content[0], Text("Hello!"))
  assert_eq(
    response.content[1],
    Thinking(thinking="Consider the request.", signature="sig_1"),
  )
  assert_eq(response.content[2], RedactedThinking("opaque"))
  assert_eq(
    response.content[3],
    ToolUse(id="toolu_1", name="weather", input={ "city": "Tokyo" }),
  )
  guard response.content[4] is Other("server_tool_use", _) else {
    fail("known but unmapped blocks keep their type and JSON")
  }
  assert_eq(
    response.content[5],
    Other("future_block", { "type": "future_block", "value": 7 }),
  )
  assert_eq(response.stop_reason, Some(Unknown("future_reason")))
  assert_eq(response.usage.input_tokens, 12)
  assert_eq(response.usage.output_tokens, 9)
  assert_eq(response.text(), "Hello!")
  assert_eq(response.tool_uses(), [("toolu_1", "weather", { "city": "Tokyo" })])
  assert_eq(response.raw, raw)
  guard response.message.content[4] is @gen.ContentBlock::ServerToolUse(server) else {
    fail("the generated view keeps the typed block")
  }
  assert_eq(server.id, "srvtoolu_1")

  let no_stop = decode_message_response(
    parse(
      "{\"id\":\"m\",\"model\":\"c\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}",
    ),
  )
  assert_eq(no_stop.stop_reason, None)

  // Replaying the response as the next assistant turn keeps every block.
  let replay = Message::from_response(response)
  assert_eq(replay.role, Assistant)
  guard replay.content is Blocks(blocks) else { fail("expected blocks") }
  assert_eq(blocks.length(), 6)
  assert_true(blocks[1] is @gen.InputContentBlock::Thinking(_))
  assert_true(blocks[3] is @gen.InputContentBlock::ToolUse(_))
  assert_eq(
    blocks[5],
    @gen.InputContentBlock::Unknown("future_block", {
      "type": "future_block",
      "value": 7,
    }),
  )
}

///|
test "event decoder trusts data type and retains unknown events and deltas" {
  let start = decode_message_event(
    parse(
      "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"c\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":2,\"output_tokens\":0}}}",
    ),
  )
  guard start is MessageStart(message) else { fail("expected message_start") }
  assert_eq(message.content, [])
  assert_eq(
    decode_message_event(
      parse(
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}",
      ),
    ),
    ContentBlockStart(index=0, block=Thinking(thinking="", signature="")),
  )
  assert_eq(
    decode_message_event(
      parse(
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}",
      ),
    ),
    TextDelta(index=0, text="Hi"),
  )
  assert_eq(
    decode_message_event(
      parse(
        "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"idea\"}}",
      ),
    ),
    ThinkingDelta(index=1, thinking="idea"),
  )
  assert_eq(
    decode_message_event(
      parse(
        "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}",
      ),
    ),
    SignatureDelta(index=1, signature="sig"),
  )
  assert_eq(
    decode_message_event(
      parse(
        "{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\"}}",
      ),
    ),
    InputJsonDelta(index=2, partial_json="{\"city\":"),
  )
  let delta = decode_message_event(
    parse(
      "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7,\"cost\":0.1}}",
    ),
  )
  guard delta is MessageDelta(delta~, usage~) else {
    fail("expected message_delta")
  }
  assert_eq(delta.stop_reason, Some(EndTurn))
  assert_eq(usage.output_tokens, 7)
  assert_eq(
    decode_message_event(
      parse(
        "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}",
      ),
    ),
    Error({ type_: "overloaded_error", message: "busy", }),
  )
  assert_eq(
    decode_message_event(
      parse(
        "{\"type\":\"error\",\"error\":{\"type\":\"future_error\",\"message\":\"new\"}}",
      ),
    ),
    Error({ type_: "future_error", message: "new", }),
  )
  let unknown = parse("{\"type\":\"future_event\",\"value\":7}")
  assert_eq(decode_message_event(unknown), Other("future_event", unknown))
  let citations = parse(
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"citations_delta\",\"citation\":{\"type\":\"char_location\",\"cited_text\":\"x\",\"document_index\":0,\"document_title\":null,\"start_char_index\":0,\"end_char_index\":1,\"file_id\":null}}}",
  )
  assert_eq(
    decode_message_event(citations),
    Other("content_block_delta", citations),
  )
  let unknown_delta = parse(
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"future_delta\",\"value\":{}}}",
  )
  assert_eq(
    decode_message_event(unknown_delta),
    Other("content_block_delta", unknown_delta),
  )
  assert_eq(
    decode_message_event(parse("{\"type\":\"message_stop\"}")),
    MessageStop,
  )
  assert_eq(decode_message_event(parse("{\"type\":\"ping\"}")), Ping)
}

///|
test "missing required response and event fields fail decoding" {
  for
    value in [
      parse(
        "{\"model\":\"c\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
      ),
      parse("{\"id\":\"m\",\"model\":\"c\",\"content\":[],\"usage\":{}}"),
      parse(
        "{\"id\":\"m\",\"model\":\"c\",\"content\":[{\"type\":\"text\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
      ),
    ] {
    try ignore(decode_message_response(value)) catch {
      @json.JsonDecodeError(_) => ()
    } noraise {
      _ => fail("invalid response must fail")
    }
  }
  for
    value in [
      parse("{\"index\":0}"),
      parse("{\"type\":\"content_block_delta\",\"index\":0}"),
      parse("{\"type\":\"message_delta\",\"delta\":{}}"),
    ] {
    try ignore(decode_message_event(value)) catch {
      @json.JsonDecodeError(_) => ()
    } noraise {
      _ => fail("invalid event must fail")
    }
  }
}

///|
test "ToolUseAccumulator reconstructs partial JSON and reports invalid JSON at finish" {
  let accumulator = ToolUseAccumulator::new()
  accumulator.feed(
    ContentBlockStart(
      index=2,
      block=ToolUse(id="toolu_1", name="get_weather", input={}),
    ),
  )
  accumulator.feed(InputJsonDelta(index=2, partial_json="{\"city\":"))
  accumulator.feed(InputJsonDelta(index=2, partial_json="\"Tok"))
  accumulator.feed(InputJsonDelta(index=2, partial_json="yo\"}"))
  accumulator.feed(ContentBlockStop(index=2))
  assert_eq(accumulator.finish(), [
    ("toolu_1", "get_weather", { "city": "Tokyo" }),
  ])

  let invalid = ToolUseAccumulator::new()
  invalid.feed(
    ContentBlockStart(
      index=0,
      block=ToolUse(id="toolu_bad", name="bad", input={}),
    ),
  )
  invalid.feed(InputJsonDelta(index=0, partial_json="{"))
  invalid.feed(ContentBlockStop(index=0))
  try ignore(invalid.finish()) catch {
    @json.InvalidEof => ()
    _ => fail("expected InvalidEof")
  } noraise {
    _ => fail("invalid accumulated JSON must fail from finish")
  }
}
