///|
test "request body encodes text and raw blocks and rejects every known collision" {
  let raw_blocks : Array[Json] = [
    { "type": "image", "source": { "type": "base64", "data": "abc" } },
    { "type": "tool_result", "tool_use_id": "tool_1", "content": "ok" },
  ]
  let request = MessageRequest::new(
    model="claude-sonnet-4-5",
    max_tokens=64,
    messages=[
      Message::user("hello"),
      { role: User, content: Blocks(raw_blocks), },
    ],
    system="be brief",
    temperature=0.25,
    stop_sequences=["END"],
    extra={ "metadata": { "source": "test" } },
  )
  assert_eq(message_body(request, false), {
    "model": "claude-sonnet-4-5",
    "max_tokens": 64,
    "messages": [
      { "role": "user", "content": "hello" },
      { "role": "user", "content": raw_blocks },
    ],
    "system": "be brief",
    "temperature": 0.25,
    "stop_sequences": ["END"],
    "metadata": { "source": "test" },
  })
  let streaming = message_body(request, true)
  guard streaming is Object(fields) else { fail("body must be an object") }
  assert_eq(fields.get("stream"), Some(true.to_json()))
  for
    key in [
      "model", "max_tokens", "messages", "system", "temperature", "stop_sequences",
      "stream",
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
}

///|
test "response decoder handles documented and compatible-provider shapes" {
  let text =
    #|{
    #|  "id":"msg_01XFDUDYJgAACzvnptvVoYEL",
    #|  "type":"message",
    #|  "role":"assistant",
    #|  "model":"claude-sonnet-4-5",
    #|  "content":[
    #|    {"type":"text","text":"Hello!"},
    #|    {"type":"thinking","thinking":"Consider the request."},
    #|    {"type":"tool_use","id":"toolu_1","name":"weather","input":{"city":"Tokyo"}},
    #|    {"type":"future_block","value":7}
    #|  ],
    #|  "stop_reason":"future_reason",
    #|  "usage":{"input_tokens":12,"output_tokens":9,"cost":0.001},
    #|  "provider":"openrouter"
    #|}
    #|
  let raw = @json.parse(text)
  let response = decode_message_response(raw)
  assert_eq(response.id, "msg_01XFDUDYJgAACzvnptvVoYEL")
  assert_eq(response.model, "claude-sonnet-4-5")
  assert_eq(response.role, Assistant)
  assert_eq(response.content[0], Text("Hello!"))
  assert_eq(response.content[1], Thinking("Consider the request."))
  assert_eq(
    response.content[2],
    ToolUse(id="toolu_1", name="weather", input={ "city": "Tokyo" }),
  )
  assert_eq(
    response.content[3],
    Other("future_block", { "type": "future_block", "value": 7 }),
  )
  assert_eq(response.stop_reason, Some(Unknown("future_reason")))
  assert_eq(response.usage, { input_tokens: 12, output_tokens: 9, })
  assert_eq(response.text(), "Hello!")
  assert_eq(response.raw, raw)

  let no_stop = decode_message_response(
    @json.parse(
      "{\"id\":\"m\",\"model\":\"c\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}",
    ),
  )
  assert_eq(no_stop.stop_reason, None)
}

///|
test "event decoder trusts data type and retains unknown events and deltas" {
  let start = decode_message_event(
    @json.parse(
      "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"c\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":2,\"output_tokens\":0}}}",
    ),
  )
  guard start is MessageStart(message) else { fail("expected message_start") }
  assert_eq(message.content, [])
  assert_eq(
    decode_message_event(
      @json.parse(
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}",
      ),
    ),
    ContentBlockStart(index=0, block=Thinking("")),
  )
  assert_eq(
    decode_message_event(
      @json.parse(
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}",
      ),
    ),
    TextDelta(index=0, text="Hi"),
  )
  assert_eq(
    decode_message_event(
      @json.parse(
        "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"idea\"}}",
      ),
    ),
    ThinkingDelta(index=1, thinking="idea"),
  )
  assert_eq(
    decode_message_event(
      @json.parse(
        "{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\"}}",
      ),
    ),
    InputJsonDelta(index=2, partial_json="{\"city\":"),
  )
  assert_eq(
    decode_message_event(
      @json.parse(
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7,\"cost\":0.1}}",
      ),
    ),
    MessageDelta(stop_reason=Some(EndTurn), output_tokens=Some(7)),
  )
  assert_eq(
    decode_message_event(
      @json.parse(
        "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}",
      ),
    ),
    Error({ type_: "overloaded_error", message: "busy", }),
  )
  let unknown = @json.parse("{\"type\":\"future_event\",\"value\":7}")
  assert_eq(decode_message_event(unknown), Other("future_event", unknown))
  let unknown_delta = @json.parse(
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"citation_delta\",\"citation\":{}}}",
  )
  assert_eq(
    decode_message_event(unknown_delta),
    Other("content_block_delta", unknown_delta),
  )
  assert_eq(
    decode_message_event(@json.parse("{\"type\":\"message_stop\"}")),
    MessageStop,
  )
  assert_eq(decode_message_event(@json.parse("{\"type\":\"ping\"}")), Ping)
}

///|
test "missing required response and event fields fail decoding" {
  for
    value in [
      @json.parse(
        "{\"model\":\"c\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
      ),
      @json.parse(
        "{\"id\":\"m\",\"model\":\"c\",\"role\":\"future\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
      ),
    ] {
    try ignore(decode_message_response(value)) catch {
      @json.JsonDecodeError(_) => ()
    } noraise {
      _ => fail("invalid response must fail")
    }
  }
  let missing_event = @json.parse("{\"index\":0}")
  try ignore(decode_message_event(missing_event)) catch {
    @json.JsonDecodeError(_) => ()
  } noraise {
    _ => fail("missing event type must fail")
  }
}
