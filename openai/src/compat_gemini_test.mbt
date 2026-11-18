///|
test "Gemini HTTP 200 chat with no message content returns empty text" {
  @driver.run_sync(() => {
    // Captured from the OpenAI-compatible endpoint on 2026-11-18.
    let body =
      #|{"choices":[{"finish_reason":"length","index":0,"message":{"role":"assistant"}}],"created":1794977886,"id":"XTD9arviDI6yvr0PxPKmyAw","model":"gemini-2.5-flash","object":"chat.completion","usage":{"completion_tokens":0,"prompt_tokens":4,"total_tokens":17}}
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(200, body=@utf8.encode(body)),
    )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
    )
    let result = match api.chat_completion(compat_request()) {
      Ok(result) => result
      Err(error) => fail(@debug.to_string(error))
    }
    assert_eq(result.text, "")
    assert_eq(result.finish_reason, Some(@openai.Length))
    assert_eq(
      result.usage,
      Some({ input_tokens: 4, output_tokens: 0, total_tokens: 17, }),
    )
    assert_eq(result.raw, @json.parse(body))
    backend.verify()
  })
}

///|
test "Gemini stream content and usage arrive without finish reason" {
  // Captured 2026-11-18, with the completion ID replaced.
  let body =
    #|{"choices":[{"delta":{"content":"Hello!","role":"assistant"},"index":0}],"created":1794981544,"id":"fixture","model":"gemini-2.5-flash","object":"chat.completion.chunk","usage":{"completion_tokens":2,"prompt_tokens":4,"total_tokens":20}}
  let chunk = @json.parse(body)
  let base = "https://generativelanguage.googleapis.com/v1beta/openai"
  for done in [false, true] {
    compat_stream(
      base,
      [chunk],
      [
        @openai.Delta("Hello!"),
        @openai.Usage({ input_tokens: 4, output_tokens: 2, total_tokens: 20, }),
      ],
      done~,
    )
  }
}

///|
test "ProtoJSON-style chat omissions retain buffered text and restore zero usage" {
  @driver.run_sync(() => {
    let raw : Json = {
      "id": "fixture",
      "created": 1794981544,
      "model": "gemini-2.5-flash",
      "object": "chat.completion",
      "choices": [{ "message": { "content": "hello" }, "logprobs": {} }],
      "usage": { "prompt_tokens": 4, "total_tokens": 4 },
    }
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      compat_canned(raw),
    )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
    )
    let result = api.chat_completion(compat_request()).unwrap()
    assert_eq(result.text, "hello")
    assert_eq(result.finish_reason, None)
    assert_eq(result.tool_calls, [])
    assert_eq(
      result.usage,
      Some({ input_tokens: 4, output_tokens: 0, total_tokens: 4, }),
    )
    assert_eq(result.raw, raw)
    backend.verify()
  })
}

///|
test "ProtoJSON-style stream omissions allow usage-only and tool deltas" {
  let base = "https://generativelanguage.googleapis.com/v1beta/openai"
  let tool : Json = {
    "id": "fixture",
    "created": 1794981544,
    "model": "gemini-2.5-flash",
    "object": "chat.completion.chunk",
    "choices": [
      {
        "delta": {
          "tool_calls": [
            { "index": 1 },
            { "id": "call_0", "function": { "name": "echo" } },
          ],
        },
      },
    ],
  }
  let usage : Json = {
    "id": "fixture",
    "created": 1794981544,
    "model": "gemini-2.5-flash",
    "object": "chat.completion.chunk",
    "usage": {},
  }
  compat_stream(base, [tool, usage], [
    @openai.ToolCallDelta(index=1, id=None, name=None, arguments="", extra={}),
    @openai.ToolCallDelta(
      index=0,
      id=Some("call_0"),
      name=Some("echo"),
      arguments="",
      extra={},
    ),
    @openai.Usage({ input_tokens: 0, output_tokens: 0, total_tokens: 0, }),
  ])
}

///|
test "streamed omissions and null content both contribute no text delta" {
  // Constructed stream chunks corresponding to the two no-text forms.
  let base = "https://generativelanguage.googleapis.com/v1beta/openai"
  for delta in [({ "role": "assistant" } : Json), { "content": null }] {
    compat_stream(base, [compat_chunk(delta, finish="length")], [
      @openai.Finished(@openai.Length),
    ])
  }
}

///|
test "Gemini embeddings decode omitted index and usage" {
  @driver.run_sync(() => {
    // Wire shape from the OpenAI-compatible endpoint on 2026-11-18.
    // The vectors are shortened. The second case reorders them and reports zero usage.
    let zero_wire : Json = { "object": "embedding", "embedding": [0.25, -0.5] }
    let one_wire : Json = {
      "object": "embedding",
      "embedding": [0.5, 0.75],
      "index": 1,
    }
    let zero : @openai.Embedding = { index: 0, embedding: [0.25, -0.5], }
    let one : @openai.Embedding = { index: 1, embedding: [0.5, 0.75], }
    let base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
    let model = "gemini-embedding-001"
    for
      (data, expected, total_tokens) in [
        ([zero_wire, one_wire], [zero, one], None),
        ([one_wire, zero_wire], [one, zero], Some(0)),
      ] {
      let fields : Map[String, Json] = {
        "object": "list",
        "data": Json(data),
        "model": Json(model),
      }
      if total_tokens is Some(tokens) {
        fields["usage"] = { "total_tokens": tokens }
      }
      let backend = @testing.BackendStub::new().expect(
        request => request.url == base_url + "/embeddings",
        compat_canned(Json(fields)),
      )
      let api = @openai.OpenAI::new(
        api_key="fixture",
        backend,
        @mock.FakeClock::new(),
        base_url~,
      )
      let result = match
        api.create_embeddings(
          @openai.EmbeddingRequest::new(model~, input=["hello", "world"]),
        ) {
        Ok(result) => result
        Err(error) => fail(@debug.to_string(error))
      }
      assert_eq(result.model, model)
      assert_eq(result.data, expected)
      assert_eq(result.prompt_tokens, None)
      assert_eq(result.total_tokens, total_tokens)
      backend.verify()
    }
  })
}

///|
test "Gemini assistant tool calls round-trip provider metadata" {
  @driver.run_sync(() => {
    // Constructed from Google's OpenAI thought-signature guide, 2026-11-18.
    let call : Json = {
      "id": "call_signed",
      "type": "function",
      "function": { "name": "echo", "arguments": "{\"value\":\"hello\"}" },
      "extra_content": {
        "google": {
          "thought_signature": "fixture-signature",
          "fixture_trace": true,
        },
      },
      "provider_extension": { "example": true },
    }
    let response : Json = {
      "id": "c",
      "object": "chat.completion",
      "created": 1,
      "model": "fixture-model",
      "choices": [
        {
          "index": 0,
          "message": { "role": "assistant", "tool_calls": [call] },
          "finish_reason": "tool_calls",
        },
      ],
    }
    for streaming in [false, true] {
      let backend = @testing.BackendStub::new()
        .expect(
          _ => true,
          if streaming {
            gemini_tool_stream_fixture()
          } else {
            compat_canned(response)
          },
        )
        .expect(_ => true, compat_canned(response))
      let api = @openai.OpenAI::new(
        api_key="fixture",
        backend,
        @mock.FakeClock::new(),
      )
      let calls = if streaming {
        let accumulated = @openai.ToolCallAccumulator::new()
        api
        .stream_chat_completion(compat_request(), event => {
          if event
            is @openai.ToolCallDelta(index~, id~, name~, arguments~, extra~) {
            accumulated.feed(index~, id?, name?, arguments~, extra~)
          }
        })
        .unwrap()
        accumulated.finish()
      } else {
        api.chat_completion(compat_request()).unwrap().tool_calls
      }
      assert_eq(
        calls[0].extra.get("extra_content"),
        Some({
          "google": {
            "thought_signature": "fixture-signature",
            "fixture_trace": true,
          },
        }),
      )
      ignore(
        api
        .chat_completion(
          @openai.ChatRequest::new(model="fixture-model", messages=[
            @openai.ChatMessage::user("hello"),
            @openai.ChatMessage::assistant_tool_calls(calls),
            @openai.ChatMessage::tool(
              tool_call_id="call_signed",
              content="hello",
            ),
          ]),
        )
        .unwrap(),
      )
      let sent = @json.parse(@utf8.decode(backend.sent()[1].body.unwrap()))
      guard sent is { "messages": [_, { "tool_calls": [replayed], .. }, _], .. } else {
        fail("expected an assistant tool call in the follow-up")
      }
      assert_eq(replayed, call)
      backend.verify()
    }
  })
}

///|
// Constructed SSE chunks exercise extension keys arriving in separate deltas.
fn gemini_tool_stream_fixture() -> @testing.Canned {
  let first = compat_chunk({
    "tool_calls": [
      {
        "index": 0,
        "id": "call_signed",
        "type": "function",
        "function": { "name": "echo", "arguments": "{\"value\":" },
        "extra_content": {
          "google": { "thought_signature": "fixture-signature" },
        },
      },
    ],
  })
  let last = compat_chunk(
    {
      "tool_calls": [
        {
          "index": 0,
          "function": { "arguments": "\"hello\"}" },
          "extra_content": { "google": { "fixture_trace": true } },
          "provider_extension": { "example": true },
        },
      ],
    },
    finish="tool_calls",
  )
  @testing.Canned::bytes(
    200,
    body=@utf8.encode(
      "data: " +
      first.stringify() +
      "\n\ndata: " +
      last.stringify() +
      "\n\ndata: [DONE]\n\n",
    ),
  )
}
