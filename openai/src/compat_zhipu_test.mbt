// Constructed from Zhipu/Z.AI docs, 2026-11-15; not captured live.
// https://docs.bigmodel.cn/cn/guide/develop/openai/introduction
// https://docs.bigmodel.cn/api-reference/

///|
test "Zhipu reasoning, open finish reasons, streaming and embeddings fixtures" {
  let base = "https://open.bigmodel.cn/api/paas/v4"
  compat_chat(
    base,
    {
      "id": "c",
      "created": 1,
      "model": "fixture-model",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "hello",
            "reasoning_content": "think",
          },
          "finish_reason": "sensitive",
        },
      ],
    },
    Some("think"),
    @openai.Unknown("sensitive"),
  )
  compat_stream(
    base,
    [
      compat_chunk({ "reasoning_content": "think" }),
      compat_chunk({ "content": "hello" }, finish="network_error"),
    ],
    [
      @openai.ReasoningDelta("think"),
      @openai.Delta("hello"),
      @openai.Finished(@openai.Unknown("network_error")),
    ],
  )
  compat_embeddings(
    base,
    {
      "data": [{ "object": "embedding", "index": 0, "embedding": [0.25, -0.5] }],
      "model": "fixture-model",
      "usage": { "prompt_tokens": 2, "completion_tokens": 0, "total_tokens": 2 },
    },
    Some(2),
  )
}
