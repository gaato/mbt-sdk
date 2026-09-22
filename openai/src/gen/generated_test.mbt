///|
fn response(body : String) -> @http.Response {
  { status: 200, headers: @http.Headers::new(), body: @utf8.encode(body), }
}

///|
test "generated model decoders accept spec fixtures and Int64 above Int32" {
  let listed = @gen.list_models_decode(
    response(
      "{\"object\":\"list\",\"data\":[{\"id\":\"model-id-0\",\"object\":\"model\",\"created\":2147483648,\"owned_by\":\"organization-owner\"}]}",
    ),
  )
  assert_eq(listed.data.length(), 1)
  assert_eq(listed.data[0].id, "model-id-0")
  assert_eq(listed.data[0].created, 2147483648L)
  assert_eq(listed.data[0].owned_by, Some("organization-owner"))

  let model = @gen.retrieve_model_decode(
    response(
      "{\"id\":\"gpt-4o-mini\",\"object\":\"model\",\"created\":1686935002,\"owned_by\":\"openai\"}",
    ),
  )
  assert_eq(model.id, "gpt-4o-mini")
}

///|
test "generated embedding response decoder accepts the M3 fixture" {
  let decoded = @gen.create_embedding_decode(
    response(
      "{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"embedding\":[0.0023064255,-0.009327292],\"index\":0}],\"model\":\"text-embedding-ada-002\",\"usage\":{\"prompt_tokens\":8,\"total_tokens\":8}}",
    ),
  )
  assert_eq(decoded.model, "text-embedding-ada-002")
  assert_eq(decoded.data.length(), 1)
  assert_eq(decoded.data[0].index, 0)
  assert_eq(decoded.data[0].embedding, [0.0023064255, -0.009327292])
  assert_eq(decoded.usage.prompt_tokens, 8)
  assert_eq(decoded.usage.total_tokens, 8)
}

///|
test "embedding request input variants round-trip and unknown request enums survive" {
  let inputs : Array[@gen.CreateEmbeddingRequestInput] = [
    @gen.Text("hello"),
    @gen.TextArray(["one", "two"]),
    @gen.IntArray([1212, 318]),
    @gen.IntArrayArray([[1212], [318, 257]]),
  ]
  for input in inputs {
    let original : @gen.CreateEmbeddingRequest = {
      input,
      model: "text-embedding-3-small",
      encoding_format: Some(@gen.Custom("future-format")),
      dimensions: Some(2),
      user: None,
    }
    let request = @gen.create_embedding_request(original)
    let decoded : @gen.CreateEmbeddingRequest = @json.from_json(
      @json.parse(@utf8.decode(request.body)),
    )
    match (input, decoded.input) {
      (@gen.Text(expected), @gen.Text(actual)) => assert_eq(actual, expected)
      (@gen.TextArray(expected), @gen.TextArray(actual)) =>
        assert_eq(actual, expected)
      (@gen.IntArray(expected), @gen.IntArray(actual)) =>
        assert_eq(actual, expected)
      (@gen.IntArrayArray(expected), @gen.IntArrayArray(actual)) =>
        assert_eq(actual, expected)
      _ => fail("embedding input variant changed during round-trip")
    }
    match decoded.encoding_format {
      Some(@gen.Custom(value)) => assert_eq(value, "future-format")
      _ => fail("unknown enum value was not retained as Custom")
    }
  }
}

///|
test "missing required generated response field becomes SdkError Decode" {
  try
    @gen.retrieve_model_decode(
      response("{\"created\":1,\"owned_by\":\"openai\"}"),
    )
  catch {
    @runtime.Decode(message~, body~) => {
      assert_eq(body, b"{\"created\":1,\"owned_by\":\"openai\"}")
      assert_true(message.contains("required だが欠落: "))
      assert_true(message.contains("id"))
    }
    _ => fail("expected SdkError::Decode")
  } noraise {
    _ => fail("missing id must fail")
  }
}

///|
test "retrieve model request percent-encodes every non-unreserved path byte" {
  let request = @gen.retrieve_model_request("model/id with space")
  assert_eq(request.http_method, "GET")
  assert_eq(request.url, "/models/model%2Fid%20with%20space")
}

///|
fn responses_fixture() -> String {
  let fixture =
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
    #|  "status": "completed",
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
    #|    {
    #|      "type": "message",
    #|      "id": "message-1",
    #|      "role": "assistant",
    #|      "status": "completed",
    #|      "content": [{"type":"output_text","text":"Done."}]
    #|    }
    #|  ],
    #|  "usage": {
    #|    "input_tokens": 11,
    #|    "input_tokens_details": {"cached_tokens": 2},
    #|    "output_tokens": 7,
    #|    "output_tokens_details": {"reasoning_tokens": 3},
    #|    "total_tokens": 18
    #|  },
    #|  "parallel_tool_calls": true
    #|}
  fixture
}

///|
test "generated Responses decoder reads OpenRouter reasoning and message items" {
  let decoded = @gen.create_response_decode(response(responses_fixture()))
  assert_eq(decoded.output.length(), 2)
  match decoded.output[0] {
    @gen.Reasoning(item) =>
      match item.content {
        Some([first, ..]) => assert_eq(first.text, "Think carefully.")
        _ => fail("expected reasoning_text content")
      }
    _ => fail("expected reasoning output item")
  }
  match decoded.output[1] {
    @gen.Message(item) =>
      match item.content[0] {
        @gen.OutputText(content) => assert_eq(content.text, "Done.")
        _ => fail("expected output_text content")
      }
    _ => fail("expected message output item")
  }
  match decoded.usage {
    Some(usage) => {
      assert_eq(usage.input_tokens_details.cached_tokens, 2)
      assert_eq(usage.output_tokens_details.reasoning_tokens, 3)
    }
    None => fail("expected usage")
  }
}

///|
test "unknown Responses output item retains its tag and JSON" {
  let decoded : @gen.OutputItem = @json.from_json(
    @json.parse("{\"type\":\"future_output\",\"value\":42}"),
  )
  match decoded {
    @gen.Unknown(tag, raw) => {
      assert_eq(tag, "future_output")
      assert_eq(raw.stringify(), "{\"type\":\"future_output\",\"value\":42}")
    }
    _ => fail("expected unknown output item")
  }
}

///|
test "InputItem message candidates round-trip and unknown tags stay raw" {
  let user = @gen.InputItem::EasyInputMessage(
    @gen.EasyInputMessage::new(
      role=@gen.EasyInputMessageRole::User,
      content=@gen.EasyInputMessageContent::Text("hello"),
      type_="message",
    ),
  )
  let user_json = user.to_json()
  let decoded_user : @gen.InputItem = @json.from_json(user_json)
  match decoded_user {
    @gen.EasyInputMessage(message) =>
      match message.content {
        @gen.Text(text) => assert_eq(text, "hello")
        _ => fail("expected text input")
      }
    _ => fail("expected easy user input message")
  }
  assert_eq(decoded_user.to_json(), user_json)

  let assistant = @gen.InputItem::OutputMessage(
    @gen.OutputMessage::new(
      id="message-1",
      type_="message",
      content=[],
      status=@gen.OutputMessageStatus::Completed,
    ),
  )
  let assistant_json = assistant.to_json()
  let decoded_assistant : @gen.InputItem = @json.from_json(assistant_json)
  match decoded_assistant {
    @gen.OutputMessage(message) => assert_eq(message.id, "message-1")
    _ => fail("expected assistant output message")
  }
  assert_eq(decoded_assistant.to_json(), assistant_json)

  let future = @json.parse("{\"type\":\"future_item\",\"value\":1}")
  let decoded_future : @gen.InputItem = @json.from_json(future)
  match decoded_future {
    @gen.Unknown(tag, raw) => {
      assert_eq(tag, "future_item")
      assert_eq(raw, future)
    }
    _ => fail("expected unknown InputItem")
  }
}

///|
test "generated Responses stream event variants decode inline fixtures" {
  let created : @gen.ResponseStreamEvent = @json.from_json(
    @json.parse(
      "{\"type\":\"response.created\",\"response\":" + responses_fixture() + "}",
    ),
  )
  match created {
    @gen.ResponseCreated(event) =>
      assert_eq(event.response.id, "resp_openrouter_fixture")
    _ => fail("expected response.created")
  }
  let delta : @gen.ResponseStreamEvent = @json.from_json(
    @json.parse(
      "{\"type\":\"response.output_text.delta\",\"item_id\":\"message-1\",\"output_index\":1,\"content_index\":0,\"delta\":\"Done\"}",
    ),
  )
  match delta {
    @gen.ResponseOutputTextDelta(event) => assert_eq(event.delta, "Done")
    _ => fail("expected response.output_text.delta")
  }
  let completed : @gen.ResponseStreamEvent = @json.from_json(
    @json.parse(
      "{\"type\":\"response.completed\",\"response\":" +
      responses_fixture() +
      "}",
    ),
  )
  match completed {
    @gen.ResponseCompleted(event) =>
      assert_eq(event.response.output.length(), 2)
    _ => fail("expected response.completed")
  }
}
