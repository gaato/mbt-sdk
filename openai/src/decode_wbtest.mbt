///|
test "model number decoding accepts values above Int32 and rejects invalid Int64 values" {
  let model_text =
    #|{"id":"future-model","created":2147483648,"owned_by":"openai","future":true}
    #|
  let model = decode_model(@json.parse(model_text))
  assert_eq(model, {
    id: "future-model",
    created: Some(2147483648L),
    owned_by: Some("openai"),
  })
  for created in ["1.5", "9223372036854775808", "-9223372036854775809"] {
    try
      decode_model(@json.parse("{\"id\":\"bad\",\"created\":" + created + "}"))
    catch {
      @json.JsonDecodeError(_) => ()
      _ => fail("unexpected error type")
    } noraise {
      _ => fail("invalid Int64 number must fail: " + created)
    }
  }
}

///|
test "response decoding concatenates output text and preserves open status and raw JSON" {
  let response_text =
    #|{
    #|  "id":"resp_1",
    #|  "status":"future_status",
    #|  "model":"gpt-4.1",
    #|  "output":[
    #|    {"type":"tool_call","future":true},
    #|    {"type":"message","content":[
    #|      {"type":"output_text","text":"hello "},
    #|      {"type":"refusal","refusal":"no"},
    #|      {"type":"output_text","text":"world"}
    #|    ]}
    #|  ],
    #|  "usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5},
    #|  "future":42
    #|}
    #|
  let raw = @json.parse(response_text)
  let response = decode_response(raw)
  assert_eq(response.id, "resp_1")
  assert_eq(response.status, Unknown("future_status"))
  assert_eq(response.output_text, "hello world")
  assert_eq(
    response.usage,
    Some({ input_tokens: 2, output_tokens: 3, total_tokens: 5, }),
  )
  assert_eq(response.raw, raw)
}

///|
test "embedding and event decoders use required fields and retain unknown events" {
  let embedding_text =
    #|{"object":"list","data":[{"object":"embedding","index":0,"embedding":[0.25,-0.5]}],"model":"text-embedding-3-small","usage":{"prompt_tokens":4,"total_tokens":4},"future":true}
    #|
  let embedding = decode_embedding_response(@json.parse(embedding_text))
  assert_eq(embedding, {
    data: [{ index: 0, embedding: [0.25, -0.5], }],
    model: "text-embedding-3-small",
    prompt_tokens: 4,
    total_tokens: 4,
  })
  assert_eq(
    decode_response_event(
      @json.parse(
        "{\"type\":\"response.output_text.delta\",\"delta\":\"In\",\"future\":1}",
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
      decode_response(
        @json.parse("{\"status\":\"completed\",\"model\":\"gpt\"}"),
      ),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("missing required response fields must fail")
  }
}

///|
test "request body builders omit None and reject every known extra collision" {
  assert_eq(
    embedding_body(
      EmbeddingRequest::new(model="embed", input=["one"], user="u"),
    ),
    { "model": "embed", "input": ["one"], "user": "u" },
  )
  let request = ResponseRequest::new(
    model="gpt",
    input="hello",
    instructions="brief",
    extra={ "metadata": { "x": 1 } },
  )
  assert_eq(response_body(request, true), {
    "model": "gpt",
    "input": "hello",
    "instructions": "brief",
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
    try response_body(collision, false) catch {
      @runtime.Config(message) => assert_true(message.contains(key))
      _ => fail("expected Config")
    } noraise {
      _ => fail("known extra key must fail")
    }
  }
}
