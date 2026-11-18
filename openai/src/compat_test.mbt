///|
// Shared replay helpers; provider payloads and provenance live in compat_*_test.mbt.
fn compat_canned(value : Json, status~ : Int32 = 200) -> @testing.Canned {
  @testing.Canned::bytes(status, body=@utf8.encode(value.stringify()))
}

///|
fn compat_request() -> @openai.ChatRequest {
  @openai.ChatRequest::new(model="fixture-model", messages=[
    @openai.ChatMessage::user("hello"),
  ])
}

///|
fn compat_chat(
  base_url : String,
  fixture : Json,
  reasoning : String?,
  finish : @openai.FinishReason,
) -> Unit raise {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new().expect(
      request => request.url == base_url + "/chat/completions",
      // Leading empty lines are DeepSeek's documented non-stream keepalive.
      @testing.Canned::bytes(
        200,
        body=@utf8.encode("\n\n" + fixture.stringify()),
      ),
    )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
      base_url~,
    )
    let result = api.chat_completion(compat_request()).unwrap()
    assert_eq(result.text, "hello")
    assert_eq(result.reasoning_content, reasoning)
    assert_eq(result.finish_reason, Some(finish))
    backend.verify()
  })
}

///|
fn compat_stream(
  base_url : String,
  chunks : Array[Json],
  expected : Array[@openai.ChatEvent],
  done~ : Bool = true,
) -> Unit raise {
  @driver.run_sync(() => {
    let stream = StringBuilder()
    stream.write_string(": keep-alive\n\n: OPENROUTER PROCESSING\n\n")
    for chunk in chunks {
      stream.write_string("data: " + chunk.stringify() + "\n\n")
    }
    if done {
      stream.write_string("data: [DONE]\n\n")
    }
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(200, body=@utf8.encode(stream.to_string())),
    )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
      base_url~,
    )
    let events : Array[@openai.ChatEvent] = []
    api
    .stream_chat_completion(compat_request(), event => events.push(event))
    .unwrap()
    assert_eq(events, expected)
    backend.verify()
  })
}

///|
fn compat_models(
  base_url : String,
  fixture : Json,
  created : Int64?,
) -> Unit raise {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new().expect(
      request => request.url == base_url + "/models",
      compat_canned(fixture),
    )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
      base_url~,
    )
    let models = api.list_models().unwrap()
    assert_eq(models.length(), 1)
    assert_eq(models[0].created, created)
    backend.verify()
  })
}

///|
fn compat_embeddings(
  base_url : String,
  fixture : Json,
  prompt_tokens : Int32?,
) -> Unit raise {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new().expect(
      request => request.url == base_url + "/embeddings",
      compat_canned(fixture),
    )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
      base_url~,
    )
    let embeddings = api
      .create_embeddings(
        @openai.EmbeddingRequest::new(model="fixture-model", input=["hi"]),
      )
      .unwrap()
    assert_eq(embeddings.prompt_tokens, prompt_tokens)
    assert_eq(embeddings.total_tokens, Some(2))
    assert_eq(embeddings.data[0].embedding, [0.25, -0.5])
    backend.verify()
  })
}

///|
// Constructed minimum Responses shape, shared by documented compatible endpoints.
fn compat_response() -> Json {
  {
    "id": "r",
    "object": "response",
    "created_at": 1,
    "status": "completed",
    "model": "fixture-model",
    "output": [
      {
        "type": "message",
        "id": "m",
        "role": "assistant",
        "status": "completed",
        "content": [{ "type": "output_text", "text": "hello" }],
      },
    ],
    "usage": { "input_tokens": 2, "output_tokens": 3, "total_tokens": 5 },
  }
}

///|
fn compat_responses(base_url : String) -> Unit raise {
  @driver.run_sync(() => {
    let raw = compat_response()
    let completed : Json = { "type": "response.completed", "response": raw }
    let backend = @testing.BackendStub::new()
      .expect(_ => true, compat_canned(raw))
      // Responses may terminate at EOF without a [DONE] sentinel.
      .expect(
        _ => true,
        @testing.Canned::bytes(
          200,
          body=@utf8.encode(
            "event: response.completed\ndata: " + completed.stringify() + "\n\n",
          ),
        ),
      )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
      base_url~,
    )
    let request = @openai.ResponseRequest::new(
      model="fixture-model",
      input="hi",
    )
    let result = match api.create_response(request) {
      Ok(result) => result
      Err(error) => fail(@debug.to_string(error))
    }
    assert_eq(result.output_text, "hello")
    assert_eq(
      result.usage,
      Some({ input_tokens: 2, output_tokens: 3, total_tokens: 5, }),
    )
    let events : Array[@openai.ResponseEvent] = []
    api.stream_response(request, event => events.push(event)).unwrap()
    assert_eq(events, [@openai.Completed(result)])
    backend.verify()
  })
}

///|
// Constructed common OpenAI chunk envelope; each provider supplies its own delta.
fn compat_chunk(delta : Json, finish~ : Json = Json::null()) -> Json {
  {
    "id": "c",
    "object": "chat.completion.chunk",
    "created": 1,
    "model": "fixture-model",
    "choices": [{ "index": 0, "delta": delta, "finish_reason": finish }],
  }
}

///|
fn compat_usage_chunk() -> Json {
  {
    "id": "c",
    "object": "chat.completion.chunk",
    "created": 1,
    "model": "fixture-model",
    "choices": [],
    "usage": { "prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5 },
  }
}
