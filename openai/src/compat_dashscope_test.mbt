// Constructed from DashScope docs, 2026-11-15; not captured live.
// https://help.aliyun.com/en/model-studio/qwen-api-via-openai-chat-completions
// https://help.aliyun.com/en/model-studio/embedding-interfaces-compatible-with-openai
// https://help.aliyun.com/en/model-studio/compatibility-with-openai-responses-api

///|
test "DashScope reasoning, usage-only chunk, embeddings missing prompt count and Responses fixtures" {
  let base = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
  compat_chat(
    base,
    {
      "id": "c",
      "object": "chat.completion",
      "created": 1,
      "model": "fixture-model",
      "system_fingerprint": "",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "hello",
            "reasoning_content": "think",
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
      compat_chunk({ "reasoning_content": "think" }),
      compat_chunk({ "content": "hello" }, finish="stop"),
      compat_usage_chunk(),
    ],
    [
      @openai.ReasoningDelta("think"),
      @openai.Delta("hello"),
      @openai.Finished(@openai.Stop),
      @openai.Usage({ input_tokens: 2, output_tokens: 3, total_tokens: 5, }),
    ],
  )
  compat_embeddings(
    base,
    {
      "object": "list",
      "data": [{ "object": "embedding", "index": 0, "embedding": [0.25, -0.5] }],
      "model": "fixture-model",
      "usage": { "total_tokens": 2 },
    },
    None,
  )
  compat_responses(base)
}
