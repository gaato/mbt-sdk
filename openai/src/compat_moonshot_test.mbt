// Constructed from Kimi docs, 2026-11-15; not captured live.
// https://platform.kimi.com/docs/api/chat
// https://platform.kimi.com/docs/api/list-models
// https://platform.kimi.com/docs/guide/migrating-from-openai-to-kimi
// Responses minimum shape is a hypothesis from the migration guide, not a captured response.

///|
test "Moonshot nullable reasoning, streamed tools, usage, models and Responses fixtures" {
  let base = "https://api.moonshot.ai/v1"
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
          "message": {
            "role": "assistant",
            "content": "hello",
            "reasoning_content": null,
          },
          "finish_reason": "stop",
          "usage": {
            "prompt_tokens": 2,
            "completion_tokens": 3,
            "total_tokens": 5,
          },
        },
      ],
    },
    None,
    @openai.Stop,
  )
  compat_stream(
    base,
    [
      compat_chunk({ "reasoning_content": "think" }),
      compat_chunk({
        "tool_calls": [
          {
            "index": 0,
            "id": "call",
            "type": "function",
            "function": { "name": "lookup", "arguments": "{" },
          },
        ],
      }),
      compat_chunk(
        { "tool_calls": [{ "index": 0, "function": { "arguments": "}" } }] },
        finish="tool_calls",
      ),
      compat_usage_chunk(),
    ],
    [
      @openai.ReasoningDelta("think"),
      @openai.ToolCallDelta(
        index=0,
        id=Some("call"),
        name=Some("lookup"),
        arguments="{",
        extra={},
      ),
      @openai.ToolCallDelta(index=0, id=None, name=None, arguments="}", extra={}),
      @openai.Finished(@openai.ToolCalls),
      @openai.Usage({ input_tokens: 2, output_tokens: 3, total_tokens: 5, }),
    ],
  )
  compat_models(
    base,
    {
      "data": [
        {
          "id": "fixture-model",
          "created": 1,
          "owned_by": "moonshot",
          "context_length": 1000,
        },
      ],
    },
    Some(1L),
  )
  compat_responses(base)
}
