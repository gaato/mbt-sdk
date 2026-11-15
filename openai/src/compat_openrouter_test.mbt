// Constructed from OpenRouter docs, 2026-11-15; not captured live.
// https://openrouter.ai/docs/api-reference/overview
// https://openrouter.ai/docs/api-reference/errors
// https://openrouter.ai/docs/api-reference/embeddings/create-embeddings

///|
test "OpenRouter chat, nonempty usage chunk, models, embeddings and Responses fixtures" {
  let base = "https://openrouter.ai/api/v1"
  compat_chat(
    base,
    {
      "id": "c",
      "object": "chat.completion",
      "created": 1,
      "model": "fixture-model",
      "choices": [
        {
          "index": 0,
          "message": { "role": "assistant", "content": "hello" },
          "finish_reason": "stop",
        },
      ],
    },
    None,
    @openai.Stop,
  )
  let last_chunk = compat_chunk({}, finish="stop")
  guard last_chunk is Object(fields) else { fail("chunk must be an object") }
  fields["usage"] = {
    "prompt_tokens": 2,
    "completion_tokens": 3,
    "total_tokens": 5,
    "cost": 0,
  }
  compat_stream(base, [compat_chunk({ "content": "hello" }), last_chunk], [
    @openai.Delta("hello"),
    @openai.Finished(@openai.Stop),
    @openai.Usage({ input_tokens: 2, output_tokens: 3, total_tokens: 5, }),
  ])
  compat_models(
    base,
    { "data": [{ "id": "fixture-model", "name": "Fixture", "pricing": {} }] },
    None,
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
}
