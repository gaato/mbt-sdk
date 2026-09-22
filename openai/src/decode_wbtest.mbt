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
      "stream",
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
