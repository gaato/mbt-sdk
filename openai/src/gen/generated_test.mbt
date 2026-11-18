///|
fn response(body : String) -> Bytes {
  @utf8.encode(body)
}

///|
fn success_head() -> @http.ResponseHead {
  { status: 200, headers: @http.Headers::empty(), }
}

///|
test "generated chat defaults preserve presence and explicit indices" {
  let buffered = @gen.create_chat_completion_decode_json({
    "id": "fixture",
    "created": 1,
    "model": "m",
    "choices": [
      { "index": 1, "finish_reason": "stop", "message": {} },
      {
        "message": {
          "annotations": [
            {
              "url_citation": {
                "url": "https://example.invalid",
                "title": "Example",
              },
            },
            {
              "url_citation": {
                "url": "https://example.invalid",
                "title": "Example with offsets",
                "start_index": 0,
                "end_index": 5,
              },
            },
          ],
        },
      },
    ],
  })
  assert_eq(buffered.choices.map(choice => choice.index), [1, 0])
  assert_eq(buffered.choices[0].finish_reason, Some(@gen.Stop))
  assert_eq(buffered.choices[1].finish_reason, None)
  let annotations = buffered.choices[1].message.annotations.unwrap()
  let citation = annotations[0].url_citation
  assert_eq((citation.start_index, citation.end_index), (None, None))
  assert_true(
    citation.to_json() is { "start_index"? : None, "end_index"? : None, .. },
  )
  let located = annotations[1].url_citation
  assert_eq((located.start_index, located.end_index), (Some(0), Some(5)))
  let empty = @gen.create_chat_completion_decode_json({
    "id": "fixture",
    "created": 1,
    "model": "m",
  })
  assert_eq(empty.choices, [])

  let streamed : @gen.CreateChatCompletionStreamResponse = @json.from_json({
    "id": "fixture",
    "created": 1,
    "model": "m",
    "choices": [
      { "delta": {}, "logprobs": {} },
      {
        "index": 1,
        "delta": {},
        "finish_reason": null,
        "logprobs": {
          "content": [
            { "token": "a" },
            {
              "token": "b",
              "logprob": -2,
              "bytes": null,
              "top_logprobs": [{ "token": "c" }],
            },
            { "token": "d", "logprob": 0 },
          ],
        },
      },
    ],
  })
  assert_eq(streamed.choices.map(choice => choice.index), [0, 1])
  assert_true(streamed.choices[0].finish_reason is @sdkjson.Absent)
  assert_true(streamed.choices[1].finish_reason is @sdkjson.Null)
  let sparse = streamed.choices[0].logprobs.to_option().unwrap()
  assert_true(sparse.content is @sdkjson.Absent)
  let tokens = streamed.choices[1].logprobs.to_option().unwrap().content
    .to_option()
    .unwrap()
  assert_eq(tokens[0].logprob, None)
  assert_true(tokens[0].to_json() is { "logprob"? : None, .. })
  assert_eq(tokens[0].top_logprobs, [])
  assert_true(tokens[0].bytes is @sdkjson.Absent)
  assert_eq(tokens[1].logprob, Some(-2.0))
  assert_true(tokens[1].bytes is @sdkjson.Null)
  assert_eq(tokens[1].top_logprobs[0].logprob, None)
  assert_true(tokens[1].top_logprobs[0].to_json() is { "logprob"? : None, .. })
  assert_true(tokens[1].top_logprobs[0].bytes is @sdkjson.Absent)
  assert_eq(tokens[2].logprob, Some(0.0))
}

///|
test "generated model decoders accept spec fixtures and Int64 above Int32" {
  let listed = @gen.list_models_decode(
    success_head(),
    response(
      "{\"object\":\"list\",\"data\":[{\"id\":\"model-id-0\",\"object\":\"model\",\"created\":2147483648,\"owned_by\":\"organization-owner\"}]}",
    ),
  ).unwrap()
  assert_eq(listed.data.length(), 1)
  assert_eq(listed.data[0].id, "model-id-0")
  assert_eq(listed.data[0].created, Some(2147483648L))
  assert_eq(listed.data[0].owned_by, Some("organization-owner"))

  let model = @gen.retrieve_model_decode(
    success_head(),
    response(
      "{\"id\":\"gpt-4o-mini\",\"object\":\"model\",\"created\":1686935002,\"owned_by\":\"openai\"}",
    ),
  ).unwrap()
  assert_eq(model.id, "gpt-4o-mini")
}

///|
test "generated embedding response decoder accepts the M3 fixture" {
  let decoded = @gen.create_embedding_decode(
    success_head(),
    response(
      "{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"embedding\":[0.0023064255,-0.009327292],\"index\":0}],\"model\":\"text-embedding-ada-002\",\"usage\":{\"prompt_tokens\":8,\"total_tokens\":8}}",
    ),
  ).unwrap()
  assert_eq(decoded.model, "text-embedding-ada-002")
  assert_eq(decoded.data.length(), 1)
  assert_eq(decoded.data[0].index, 0)
  assert_eq(decoded.data[0].embedding, [0.0023064255, -0.009327292])
  guard decoded.usage is Some(usage) else { fail("expected reported usage") }
  assert_eq(usage.prompt_tokens, Some(8))
  assert_eq(usage.total_tokens, 8)
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
      @json.parse(@utf8.decode(request.body.as_bytes().unwrap())),
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
test "missing required generated response field becomes Deserialization" {
  let result = @gen.retrieve_model_decode(
    success_head(),
    response("{\"created\":1,\"owned_by\":\"openai\"}"),
  )
  match result {
    Err(@client.Deserialization(_, message~, body~)) => {
      assert_eq(body, b"{\"created\":1,\"owned_by\":\"openai\"}")
      assert_true(message.contains("required だが欠落: "))
      assert_true(message.contains("id"))
    }
    _ => fail("missing id must return a decoding failure")
  }
}

///|
test "retrieve model request percent-encodes every non-unreserved path byte" {
  let request = @gen.retrieve_model_request("model/id with space")
  assert_eq(request.meth, @http.Get)
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
  let decoded = @gen.create_response_decode(
    success_head(),
    response(responses_fixture()),
  ).unwrap()
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
      assert_eq(usage.input_tokens_details.unwrap().cached_tokens, 2)
      assert_eq(usage.output_tokens_details.unwrap().reasoning_tokens, 3)
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
