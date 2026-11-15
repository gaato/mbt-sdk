// Constructed from the pinned Ollama source, not captured live (API calls forbidden).
// https://github.com/ollama/ollama/blob/a5864fcb33969705de3c0ebfedf4b2a16c970bcc/openai/openai.go
// https://github.com/ollama/ollama/blob/a5864fcb33969705de3c0ebfedf4b2a16c970bcc/docs/api/openai-compatibility.mdx
// Inspected via the supplied survey dated 2026-11-15.

///|
test "Ollama reasoning alias, stream, models, embeddings, retrieval and Responses fixtures" {
  let base = "http://localhost:11434/v1"
  compat_chat(
    base,
    {
      "id": "c",
      "object": "chat.completion",
      "created": 1,
      "model": "fixture-model",
      "system_fingerprint": "fp_ollama",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "hello",
            "reasoning": "think",
          },
          "finish_reason": "stop",
        },
      ],
    },
    Some("think"),
    @openai.Stop,
  )
  compat_stream(
    base,
    [
      compat_chunk({ "reasoning": "think" }),
      compat_chunk({ "content": "hello" }, finish="stop"),
    ],
    [
      @openai.ReasoningDelta("think"),
      @openai.Delta("hello"),
      @openai.Finished(@openai.Stop),
    ],
  )
  compat_models(
    base,
    {
      "data": [
        {
          "id": "fixture-model",
          "object": "model",
          "created": 1,
          "owned_by": "library",
        },
      ],
    },
    Some(1L),
  )
  compat_embeddings(
    base,
    {
      "data": [{ "object": "embedding", "index": 0, "embedding": [0.25, -0.5] }],
      "model": "fixture-model",
      "usage": { "prompt_tokens": 2, "total_tokens": 2 },
    },
    Some(2),
  )
  compat_responses(base)
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new().expect(
      request => request.url == base + "/models/fixture-model",
      compat_canned({
        "id": "fixture-model",
        "object": "model",
        "created": 1,
        "owned_by": "library",
      }),
    )
    let api = @openai.OpenAI::new(
      api_key="ignored",
      backend,
      @mock.FakeClock::new(),
      base_url=base,
    )
    assert_eq(api.retrieve_model("fixture-model").unwrap().id, "fixture-model")
    backend.verify()
  })
}
